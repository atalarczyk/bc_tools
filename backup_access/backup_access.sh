#!/usr/bin/env bash
# backup_access.sh
# Manages read-only SFTP backup-access accounts on Ubuntu.
# See --help for usage.
#
# Each managed user gets:
#   - a system account
#   - a chroot jail under REMOUNT_ROOT/USERNAME/
#   - a read-only bind mount of a backup source directory to REMOUNT_ROOT/USERNAME/backups/
#   - a public-key file under AUTHORIZED_KEYS_DIR/USERNAME
#   - one Match User block in sshd_config (guarded by script markers)
#   - one block in a systemd oneshot service (guarded by script markers)

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly VERSION="1.3.0"
readonly SCRIPT_NAME="backup_access"
readonly MARKER_BEGIN="# BEGIN ${SCRIPT_NAME}"
readonly MARKER_END="# END ${SCRIPT_NAME}"

readonly DEFAULT_REMOUNT_ROOT="/srv/sftp"
readonly DEFAULT_SSH_CONFIG="/etc/ssh/sshd_config"
readonly DEFAULT_AUTHORIZED_KEYS_DIR="/etc/ssh/authorized_keys"
readonly SYSTEMD_SERVICE_NAME="backup-access-mounts"
readonly DEFAULT_SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SYSTEMD_SERVICE_NAME}.service"

readonly LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"

readonly VALID_KEY_TYPES=(
    "ssh-ed25519"
    "ssh-rsa"
    "ecdsa-sha2-nistp256"
    "ecdsa-sha2-nistp384"
    "ecdsa-sha2-nistp521"
    "sk-ssh-ed25519@openssh.com"
    "sk-ecdsa-sha2-nistp256@openssh.com"
)

# ---------------------------------------------------------------------------
# Environment variable overrides (for testing only – not exposed as CLI flags)
# ---------------------------------------------------------------------------
SYSTEMD_SERVICE_FILE="${SYSTEMD_SERVICE_FILE:-${DEFAULT_SYSTEMD_SERVICE_FILE}}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-/bin/systemctl}"
ADDUSER_BIN="${ADDUSER_BIN:-/usr/sbin/adduser}"
USERDEL_BIN="${USERDEL_BIN:-/usr/sbin/userdel}"
MOUNT_BIN="${MOUNT_BIN:-/bin/mount}"
UMOUNT_BIN="${UMOUNT_BIN:-/bin/umount}"
FINDMNT_BIN="${FINDMNT_BIN:-/bin/findmnt}"
CHOWN_BIN="${CHOWN_BIN:-/bin/chown}"
CHMOD_BIN="${CHMOD_BIN:-/bin/chmod}"
INSTALL_BIN="${INSTALL_BIN:-/usr/bin/install}"
STAT_BIN="${STAT_BIN:-/usr/bin/stat}"
# BA_SKIP_ROOT_CHECK=1  overrides require_root (testing only)

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
OPT_DRY_RUN=0
OPT_VERBOSE=0
OPT_MINIMAL_LIST=0
OPT_REMOUNT_ROOT="${DEFAULT_REMOUNT_ROOT}"
OPT_SSH_CONFIG="${DEFAULT_SSH_CONFIG}"
OPT_AUTHORIZED_KEYS_DIR="${DEFAULT_AUTHORIZED_KEYS_DIR}"
OPT_USER=""
OPT_PUBLIC_KEY=""
OPT_DIRECTORY=""
COMMAND=""

TEMP_FILES=()
LOCK_FD=""

# ---------------------------------------------------------------------------
# Cleanup and traps
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        [[ -f "${f}" ]] && rm -f "${f}" 2>/dev/null || true
    done
    if [[ -n "${LOCK_FD}" ]]; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    fi
    return "${exit_code}"
}
trap cleanup EXIT
trap 'log_error "Unexpected error at line ${LINENO}"; exit 1' ERR

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info() {
    printf '[INFO] %s\n' "$*" >&2
}
log_verbose() {
    [[ "${OPT_VERBOSE}" -eq 1 ]] && printf '[VERBOSE] %s\n' "$*" >&2 || true
}
log_warn() {
    printf '[WARN] %s\n' "$*" >&2
}
log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}
die() {
    log_error "$*"
    trap - ERR   # prevent the ERR trap from printing a redundant "Unexpected error" line
    exit 1
}

# ---------------------------------------------------------------------------
# Lock management
# ---------------------------------------------------------------------------
acquire_lock() {
    local fd
    exec {fd}>"${LOCK_FILE}"
    LOCK_FD="${fd}"
    flock -n "${LOCK_FD}" || die "Another instance of ${SCRIPT_NAME} is already running (${LOCK_FILE})"
    log_verbose "Lock acquired: ${LOCK_FILE}"
}

# ---------------------------------------------------------------------------
# Temp file management
# ---------------------------------------------------------------------------
make_temp() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/${SCRIPT_NAME}.XXXXXXXXXX")
    TEMP_FILES+=("${tmp}")
    printf '%s' "${tmp}"
}

# ---------------------------------------------------------------------------
# Command wrappers (allow environment overrides for testing)
# ---------------------------------------------------------------------------
cmd_chown()      { "${CHOWN_BIN}" "$@"; }
cmd_chmod()      { "${CHMOD_BIN}" "$@"; }
cmd_mount()      { "${MOUNT_BIN}" "$@"; }
cmd_umount()     { "${UMOUNT_BIN}" "$@"; }
cmd_findmnt()    { "${FINDMNT_BIN}" "$@"; }
cmd_adduser()    { "${ADDUSER_BIN}" "$@"; }
cmd_userdel()    { "${USERDEL_BIN}" "$@"; }
cmd_sshd_test()  { "${SSHD_BIN}" "$@"; }
cmd_systemctl()  { "${SYSTEMCTL_BIN}" "$@"; }
cmd_stat()       { "${STAT_BIN}" "$@"; }

get_owner() { cmd_stat -c '%U:%G' "$1" 2>/dev/null; }
get_perms() { cmd_stat -c '%a' "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_username() {
    local user="$1"
    [[ -n "${user}" ]] || die "Username must not be empty"
    [[ "${user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
        || die "Invalid username '${user}': must match ^[a-z_][a-z0-9_-]{0,31}$"
}

validate_absolute_path() {
    local path="$1"
    local label="$2"
    [[ "${path}" == /* ]] || die "${label} must be an absolute path (got: '${path}')"
}

validate_directory_exists() {
    local dir="$1"
    local label="$2"
    [[ -d "${dir}" ]] || die "${label} '${dir}' does not exist or is not a directory"
}

validate_public_key() {
    local key="$1"
    [[ -n "${key}" ]] || die "Public key must not be empty"

    # Must be exactly one line
    local line_count
    line_count=$(printf '%s' "${key}" | wc -l)
    [[ "${line_count}" -eq 0 ]] \
        || die "Public key must be a single line (got ${line_count} newlines)"

    local key_type key_data
    key_type=$(printf '%s' "${key}" | awk '{print $1}')
    key_data=$(printf '%s' "${key}" | awk '{print $2}')

    [[ "${key_type}" != "ssh-dss" ]] || die "ssh-dss keys are not supported"

    local valid=0
    local t
    for t in "${VALID_KEY_TYPES[@]}"; do
        [[ "${key_type}" == "${t}" ]] && valid=1 && break
    done
    [[ "${valid}" -eq 1 ]] \
        || die "Unsupported key type '${key_type}'; accepted: ${VALID_KEY_TYPES[*]}"

    [[ -n "${key_data}" ]] || die "Public key is missing key data"
    printf '%s' "${key_data}" | base64 -d >/dev/null 2>&1 \
        || die "Public key data is not valid base64"

    log_verbose "Public key validated: type=${key_type}"
}

# ---------------------------------------------------------------------------
# Mount detection
# ---------------------------------------------------------------------------
is_mounted() {
    local mountpoint="$1"
    cmd_findmnt --noheadings --output TARGET "${mountpoint}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Block helpers (operate on file content)
# ---------------------------------------------------------------------------

# Returns 0 (true) if a managed block for USERNAME exists in FILE.
has_managed_block() {
    local file="$1"
    local username="$2"
    [[ -f "${file}" ]] || return 1
    grep -qxF "${MARKER_BEGIN} ${username}" "${file}" 2>/dev/null
}

# Counts how many BEGIN markers exist for USERNAME in FILE.
count_managed_blocks() {
    local file="$1"
    local username="$2"
    [[ -f "${file}" ]] || { printf '0'; return 0; }
    grep -cxF "${MARKER_BEGIN} ${username}" "${file}" 2>/dev/null || printf '0'
}

# Read stdin; write to stdout with the managed block for USERNAME removed.
remove_block_from_stream() {
    local username="$1"
    local begin="${MARKER_BEGIN} ${username}"
    local end="${MARKER_END} ${username}"
    local in_block=0
    while IFS= read -r line; do
        if [[ "${line}" == "${begin}" ]]; then
            in_block=1
        fi
        if [[ "${in_block}" -eq 0 ]]; then
            printf '%s\n' "${line}"
        fi
        if [[ "${line}" == "${end}" ]]; then
            in_block=0
        fi
    done
}

# Print all managed usernames from FILE, one per line, sorted.
get_managed_users_from_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    grep -E "^${MARKER_BEGIN} " "${file}" 2>/dev/null \
        | sed "s/^${MARKER_BEGIN} //" \
        | sort -u \
        || true
}

# Print the source directory recorded in the managed service block for USERNAME.
get_service_source_dir() {
    local username="$1"
    [[ -f "${SYSTEMD_SERVICE_FILE}" ]] || return 0
    local begin="${MARKER_BEGIN} ${username}"
    local end="${MARKER_END} ${username}"
    local in_block=0
    while IFS= read -r line; do
        if [[ "${line}" == "${begin}" ]]; then
            in_block=1; continue; fi
        if [[ "${line}" == "${end}" ]]; then
            break; fi
        if [[ "${in_block}" -eq 1 ]]; then
            # Parse: ExecStart=/bin/mount --bind SOURCE MOUNTPOINT
            if [[ "${line}" =~ ExecStart=.*\ --bind\ (.+)\ (.+) ]]; then
                printf '%s' "${BASH_REMATCH[1]}"
                return
            fi
        fi
    done < "${SYSTEMD_SERVICE_FILE}"
}

# ---------------------------------------------------------------------------
# Block builders
# ---------------------------------------------------------------------------
build_ssh_block() {
    local username="$1"
    local remount_root="$2"
    local authkeys_dir="$3"
    printf '%s %s\n' "${MARKER_BEGIN}" "${username}"
    printf 'Match User %s\n' "${username}"
    printf '    AuthorizedKeysFile %s/%%u\n' "${authkeys_dir}"
    printf '    ChrootDirectory %s/%s\n' "${remount_root}" "${username}"
    printf '    ForceCommand internal-sftp -R -d /backups\n'
    printf '    AllowTcpForwarding no\n'
    printf '    X11Forwarding no\n'
    printf '    PermitTTY no\n'
    printf '    PasswordAuthentication no\n'
    printf '    AuthenticationMethods publickey\n'
    printf '%s %s\n' "${MARKER_END}" "${username}"
}

build_service_header() {
    cat <<EOF
[Unit]
Description=Backup access read-only bind mounts (managed by ${SCRIPT_NAME})
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
EOF
}

build_service_user_block() {
    local username="$1"
    local source_dir="$2"
    local remount_root="$3"
    local mp="${remount_root}/${username}/backups"
    printf '%s %s\n' "${MARKER_BEGIN}" "${username}"
    printf 'ExecStart=/bin/mount --bind %s %s\n' "${source_dir}" "${mp}"
    printf 'ExecStart=/bin/mount -o remount,ro,bind %s\n' "${mp}"
    printf 'ExecStop=-/bin/umount %s\n' "${mp}"
    printf '%s %s\n' "${MARKER_END}" "${username}"
}

# ---------------------------------------------------------------------------
# Atomic file replacement (same-directory temp + mv for atomicity)
# ---------------------------------------------------------------------------
# Returns the backup path on stdout.
atomic_replace_file() {
    local target="$1"
    local new_content_file="$2"
    local dir
    dir=$(dirname "${target}")
    local backup
    backup="${target}.bak.$(date +%Y%m%d%H%M%S).$$"
    local tmp_target
    tmp_target=$(mktemp "${dir}/.${SCRIPT_NAME}.XXXXXXXXXX")
    TEMP_FILES+=("${tmp_target}")

    cp "${new_content_file}" "${tmp_target}"
    cmd_chown root:root "${tmp_target}"
    cmd_chmod 644 "${tmp_target}"

    cp -a "${target}" "${backup}"
    log_verbose "Backup created: ${backup}"

    mv -f "${tmp_target}" "${target}"
    log_verbose "File replaced: ${target}"

    printf '%s' "${backup}"
}

# ---------------------------------------------------------------------------
# sshd_config management
# ---------------------------------------------------------------------------

# Pre-flight read-only check: verify the Subsystem sftp line is either absent
# or already set to "internal-sftp".  Dies immediately if a conflicting line
# is found.  Safe to call before any state has been modified.
assert_sshd_subsystem_compatible() {
    local config="${OPT_SSH_CONFIG}"
    [[ -f "${config}" ]] || die "sshd config not found: ${config}"

    local in_match=0
    while IFS= read -r line; do
        if [[ "${in_match}" -eq 0 ]] && [[ "${line}" =~ ^[[:space:]]*Match[[:space:]] ]]; then
            in_match=1
        fi
        if [[ "${line}" =~ ^[[:space:]]*Subsystem[[:space:]]+sftp[[:space:]]+(.*) ]]; then
            if [[ "${in_match}" -eq 1 ]]; then
                die "Found 'Subsystem sftp' inside a Match block in ${config}. This is invalid configuration – review ${config} manually."
            fi
            local subsys_val="${BASH_REMATCH[1]}"
            subsys_val="${subsys_val#"${subsys_val%%[! ]*}"}"
            subsys_val="${subsys_val%"${subsys_val##*[! ]}"}"
            if [[ "${subsys_val}" != "internal-sftp" ]]; then
                die "Conflicting global 'Subsystem sftp ${subsys_val}' line already exists in ${config}. Remove or update it manually before proceeding."
            fi
        fi
    done < "${config}"
}

# Validate sshd config file with sshd -t.
validate_sshd_config() {
    local config_file="$1"
    log_verbose "Validating sshd config: ${config_file}"
    cmd_sshd_test -t -f "${config_file}"
}

# Build the final desired sshd_config content for adding/updating USERNAME:
#   - Strips any existing managed block for USERNAME
#   - Ensures global "Subsystem sftp internal-sftp" exists (before first Match)
#   - Appends the new managed block at the end
# Aborts if a conflicting Subsystem sftp line is found.
# Writes result to OUTFILE.
build_sshd_config_with_user() {
    local username="$1"
    local config="${OPT_SSH_CONFIG}"
    local remount_root="${OPT_REMOUNT_ROOT}"
    local authkeys_dir="${OPT_AUTHORIZED_KEYS_DIR}"
    local outfile="$2"

    local in_block=0
    local in_match=0
    local subsystem_found=0
    local inserted_subsystem=0

    while IFS= read -r line; do
        # Strip existing managed block
        if [[ "${line}" == "${MARKER_BEGIN} ${username}" ]]; then
            in_block=1; continue
        fi
        if [[ "${line}" == "${MARKER_END} ${username}" ]]; then
            in_block=0; continue
        fi
        [[ "${in_block}" -eq 1 ]] && continue

        # Detect transition into first Match block
        if [[ "${in_match}" -eq 0 ]] && [[ "${line}" =~ ^[[:space:]]*Match[[:space:]] ]]; then
            in_match=1
            if [[ "${subsystem_found}" -eq 0 ]]; then
                printf 'Subsystem sftp internal-sftp\n\n' >> "${outfile}"
                inserted_subsystem=1
            fi
        fi

        # Detect Subsystem sftp line
        if [[ "${line}" =~ ^[[:space:]]*Subsystem[[:space:]]+sftp[[:space:]]+(.*) ]]; then
            if [[ "${in_match}" -eq 1 ]]; then
                die "Found 'Subsystem sftp' inside a Match block in ${config}. This is invalid configuration – review ${config} manually."
            fi
            local subsys_val="${BASH_REMATCH[1]}"
            # Trim leading/trailing whitespace from the captured value
            subsys_val="${subsys_val#"${subsys_val%%[! ]*}"}"
            subsys_val="${subsys_val%"${subsys_val##*[! ]}"}"
            if [[ "${subsys_val}" != "internal-sftp" ]]; then
                die "Conflicting global 'Subsystem sftp ${subsys_val}' line already exists in ${config}. Remove or update it manually before proceeding."
            fi
            subsystem_found=1
        fi

        printf '%s\n' "${line}" >> "${outfile}"
    done < "${config}"

    # Append Subsystem line at end of global section if no Match blocks found and not present
    if [[ "${subsystem_found}" -eq 0 && "${inserted_subsystem}" -eq 0 ]]; then
        printf '\nSubsystem sftp internal-sftp\n' >> "${outfile}"
    fi

    # Append new managed block
    printf '\n' >> "${outfile}"
    build_ssh_block "${username}" "${remount_root}" "${authkeys_dir}" >> "${outfile}"
}

# Add or update the managed sshd_config block for USERNAME.
# Validates with sshd -t before replacing the file.
update_sshd_config_for_user() {
    local username="$1"
    local config="${OPT_SSH_CONFIG}"
    [[ -f "${config}" ]] || die "sshd config not found: ${config}"

    local tmp
    tmp=$(make_temp)

    build_sshd_config_with_user "${username}" "${tmp}"

    validate_sshd_config "${tmp}" \
        || die "sshd config validation failed; no changes were made to ${config}"

    atomic_replace_file "${config}" "${tmp}" >/dev/null
    log_info "sshd_config updated for '${username}'"
}

# Remove the managed block for USERNAME from sshd_config.
remove_ssh_block_for_user() {
    local username="$1"
    local config="${OPT_SSH_CONFIG}"

    if ! has_managed_block "${config}" "${username}"; then
        log_warn "No managed SSH block found for '${username}' in ${config}"
        return 0
    fi

    local tmp
    tmp=$(make_temp)
    remove_block_from_stream "${username}" < "${config}" > "${tmp}"

    validate_sshd_config "${tmp}" \
        || die "sshd config validation failed after removing block for '${username}'; no changes made"

    atomic_replace_file "${config}" "${tmp}" >/dev/null
    log_info "Managed SSH block removed for '${username}'"
}

# ---------------------------------------------------------------------------
# Systemd service management
# ---------------------------------------------------------------------------

# Add or update the managed block for USERNAME in the systemd service.
# Creates the service file if it does not exist.
update_systemd_service_for_user() {
    local username="$1"
    local source_dir="$2"
    local user_block
    user_block=$(build_service_user_block "${username}" "${source_dir}" "${OPT_REMOUNT_ROOT}")

    if [[ ! -f "${SYSTEMD_SERVICE_FILE}" ]]; then
        # Create new service file
        local tmp
        tmp=$(make_temp)
        {
            build_service_header
            printf '%s\n' "${user_block}"
            printf '\n[Install]\nWantedBy=multi-user.target\n'
        } > "${tmp}"
        cp "${tmp}" "${SYSTEMD_SERVICE_FILE}"
        cmd_chown root:root "${SYSTEMD_SERVICE_FILE}"
        cmd_chmod 644 "${SYSTEMD_SERVICE_FILE}"
        cmd_systemctl daemon-reload
        cmd_systemctl enable "${SYSTEMD_SERVICE_NAME}.service"
        log_info "Created and enabled systemd service: ${SYSTEMD_SERVICE_FILE}"
        return
    fi

    # Update existing service: remove old block for this user (if any),
    # then insert new block before the [Install] section.
    local cleaned
    cleaned=$(make_temp)
    if has_managed_block "${SYSTEMD_SERVICE_FILE}" "${username}"; then
        remove_block_from_stream "${username}" < "${SYSTEMD_SERVICE_FILE}" > "${cleaned}"
    else
        cp "${SYSTEMD_SERVICE_FILE}" "${cleaned}"
    fi

    local tmp
    tmp=$(make_temp)
    local install_found=0
    while IFS= read -r line; do
        if [[ "${line}" == "[Install]" && "${install_found}" -eq 0 ]]; then
            install_found=1
            printf '%s\n\n' "${user_block}" >> "${tmp}"
        fi
        printf '%s\n' "${line}" >> "${tmp}"
    done < "${cleaned}"
    if [[ "${install_found}" -eq 0 ]]; then
        printf '%s\n' "${user_block}" >> "${tmp}"
    fi

    atomic_replace_file "${SYSTEMD_SERVICE_FILE}" "${tmp}" >/dev/null
    cmd_systemctl daemon-reload
    log_info "Systemd service updated for '${username}' (source: ${source_dir})"
}

# Remove the managed block for USERNAME from the systemd service.
# If no managed blocks remain, disables and removes the service file.
remove_systemd_service_for_user() {
    local username="$1"

    if [[ ! -f "${SYSTEMD_SERVICE_FILE}" ]]; then
        log_warn "Systemd service file not found: ${SYSTEMD_SERVICE_FILE}"
        return 0
    fi

    if ! has_managed_block "${SYSTEMD_SERVICE_FILE}" "${username}"; then
        log_warn "No managed block found for '${username}' in ${SYSTEMD_SERVICE_FILE}"
        return 0
    fi

    local tmp
    tmp=$(make_temp)
    remove_block_from_stream "${username}" < "${SYSTEMD_SERVICE_FILE}" > "${tmp}"

    # Check if any managed blocks remain
    local remaining
    remaining=$(grep -c "^${MARKER_BEGIN} " "${tmp}" 2>/dev/null) || remaining=0

    if [[ "${remaining}" -eq 0 ]]; then
        # No more users: disable and remove the service
        cmd_systemctl disable "${SYSTEMD_SERVICE_NAME}.service" 2>/dev/null || true
        rm -f "${SYSTEMD_SERVICE_FILE}"
        cmd_systemctl daemon-reload
        log_info "Removed systemd service (no managed users remain): ${SYSTEMD_SERVICE_FILE}"
    else
        atomic_replace_file "${SYSTEMD_SERVICE_FILE}" "${tmp}" >/dev/null
        cmd_systemctl daemon-reload
        log_info "Managed block removed for '${username}' from systemd service"
    fi
}

# ---------------------------------------------------------------------------
# Mount operations
# ---------------------------------------------------------------------------
mount_user_dir() {
    local username="$1"
    local source_dir="$2"
    local mp="${OPT_REMOUNT_ROOT}/${username}/backups"

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would bind-mount ${source_dir} -> ${mp} (read-only)"
        return 0
    fi

    cmd_mount --bind "${source_dir}" "${mp}"
    cmd_mount -o remount,ro,bind "${mp}"
    log_info "Mounted ${source_dir} -> ${mp} (read-only bind)"
}

unmount_user_dir() {
    local username="$1"
    local mp="${OPT_REMOUNT_ROOT}/${username}/backups"

    if ! is_mounted "${mp}"; then
        log_verbose "Not mounted, nothing to unmount: ${mp}"
        return 0
    fi

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would unmount ${mp}"
        return 0
    fi

    cmd_umount "${mp}" || log_warn "umount failed for ${mp} (continuing)"
    log_info "Unmounted ${mp}"
}

# ---------------------------------------------------------------------------
# Chroot directory management
# ---------------------------------------------------------------------------
create_chroot_tree() {
    local username="$1"
    local chroot_dir="${OPT_REMOUNT_ROOT}/${username}"
    local backups_dir="${chroot_dir}/backups"

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would create ${backups_dir} (root:root 755 on path elements)"
        return 0
    fi

    mkdir -p "${backups_dir}"
    # sshd requires ChrootDirectory and all parents up to / to be root:root 755
    cmd_chown root:root "${OPT_REMOUNT_ROOT}" "${chroot_dir}" "${backups_dir}"
    cmd_chmod 755 "${OPT_REMOUNT_ROOT}" "${chroot_dir}" "${backups_dir}"
    log_info "Created chroot tree: ${backups_dir}"
}

remove_chroot_tree() {
    local username="$1"
    local chroot_dir="${OPT_REMOUNT_ROOT}/${username}"

    if [[ ! -d "${chroot_dir}" ]]; then
        log_verbose "Chroot directory not found, nothing to remove: ${chroot_dir}"
        return 0
    fi

    local backups_dir="${chroot_dir}/backups"
    if is_mounted "${backups_dir}"; then
        log_warn "Cannot remove chroot tree: ${backups_dir} is still mounted"
        return 1
    fi

    # Safety: only remove if the tree contains nothing unexpected (just the backups/ subdir)
    local file_count
    file_count=$(find "${chroot_dir}" -mindepth 1 | wc -l)
    if [[ "${file_count}" -gt 1 ]]; then
        log_warn "Chroot tree ${chroot_dir} contains unexpected entries; not removing automatically"
        return 1
    fi

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would remove chroot tree: ${chroot_dir}"
        return 0
    fi

    rm -rf "${chroot_dir}"
    log_info "Removed chroot tree: ${chroot_dir}"
}

# ---------------------------------------------------------------------------
# Authorized keys management
# ---------------------------------------------------------------------------
write_authorized_key() {
    local username="$1"
    local public_key="$2"
    local key_file="${OPT_AUTHORIZED_KEYS_DIR}/${username}"

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would write authorized key to ${key_file}"
        return 0
    fi

    if [[ ! -d "${OPT_AUTHORIZED_KEYS_DIR}" ]]; then
        mkdir -p "${OPT_AUTHORIZED_KEYS_DIR}"
        cmd_chown root:root "${OPT_AUTHORIZED_KEYS_DIR}"
        cmd_chmod 755 "${OPT_AUTHORIZED_KEYS_DIR}"
    fi

    printf '%s\n' "${public_key}" > "${key_file}"
    cmd_chown root:root "${key_file}"
    cmd_chmod 644 "${key_file}"
    log_info "Wrote authorized key: ${key_file}"
}

remove_authorized_key() {
    local username="$1"
    local key_file="${OPT_AUTHORIZED_KEYS_DIR}/${username}"

    if [[ ! -f "${key_file}" ]]; then
        log_verbose "Key file not found: ${key_file}"
        return 0
    fi

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would remove key file: ${key_file}"
        return 0
    fi

    rm -f "${key_file}"
    log_info "Removed authorized key file: ${key_file}"
}

read_authorized_key() {
    local username="$1"
    local key_file="${OPT_AUTHORIZED_KEYS_DIR}/${username}"
    [[ -f "${key_file}" ]] && cat "${key_file}" || true
}

# ---------------------------------------------------------------------------
# OS user management
# ---------------------------------------------------------------------------
user_exists() {
    id "${1}" >/dev/null 2>&1
}

create_os_user() {
    local username="$1"

    if user_exists "${username}"; then
        log_verbose "OS user '${username}' already exists"
        return 0
    fi

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would create system user: ${username}"
        return 0
    fi

    cmd_adduser --system --group --shell /usr/sbin/nologin --home / "${username}"
    log_info "Created system user: ${username}"
}

delete_os_user() {
    local username="$1"

    if ! user_exists "${username}"; then
        log_verbose "OS user '${username}' does not exist"
        return 0
    fi

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would delete OS user: ${username}"
        return 0
    fi

    cmd_userdel "${username}"
    log_info "Deleted OS user: ${username}"
}

# ---------------------------------------------------------------------------
# COMMAND: list
# ---------------------------------------------------------------------------
cmd_list() {
    local ssh_users service_users all_users

    ssh_users=$(get_managed_users_from_file "${OPT_SSH_CONFIG}")
    service_users=$(get_managed_users_from_file "${SYSTEMD_SERVICE_FILE}")

    all_users=$(printf '%s\n%s\n' "${ssh_users}" "${service_users}" \
        | sort -u | grep -v '^$') || true

    if [[ -z "${all_users}" ]]; then
        log_info "No managed users found"
        return 0
    fi

    if [[ "${OPT_MINIMAL_LIST}" -eq 1 ]]; then
        printf 'USER\tDIRECTORY\n'
    else
        printf 'USER\tDIRECTORY\tPUBLIC_KEY\n'
    fi

    local username
    while IFS= read -r username; do
        [[ -z "${username}" ]] && continue

        local key dir
        dir=$(get_service_source_dir "${username}")

        if [[ "${OPT_MINIMAL_LIST}" -eq 1 ]]; then
            printf '%s\t%s\n' \
                "${username}" \
                "${dir:-<missing>}"
        else
            key=$(read_authorized_key "${username}")
            printf '%s\t%s\t%s\n' \
                "${username}" \
                "${dir:-<missing>}" \
                "${key:-<missing>}"
        fi

        if [[ "${OPT_VERBOSE}" -eq 1 ]]; then
            local sshd_count service_count
            sshd_count=$(count_managed_blocks "${OPT_SSH_CONFIG}" "${username}")
            service_count=$(count_managed_blocks "${SYSTEMD_SERVICE_FILE}" "${username}")

            user_exists "${username}" \
                || log_warn "  [INCONSISTENCY] OS user '${username}' missing"
            [[ -f "${OPT_AUTHORIZED_KEYS_DIR}/${username}" ]] \
                || log_warn "  [INCONSISTENCY] Key file missing: ${OPT_AUTHORIZED_KEYS_DIR}/${username}"
            has_managed_block "${SYSTEMD_SERVICE_FILE}" "${username}" \
                || log_warn "  [INCONSISTENCY] No managed service block for '${username}'"
            has_managed_block "${OPT_SSH_CONFIG}" "${username}" \
                || log_warn "  [INCONSISTENCY] No managed SSH block for '${username}'"
            [[ "${sshd_count}" -le 1 ]] \
                || log_warn "  [INCONSISTENCY] Duplicate managed SSH blocks (${sshd_count}) for '${username}'"
            [[ "${service_count}" -le 1 ]] \
                || log_warn "  [INCONSISTENCY] Duplicate managed service blocks (${service_count}) for '${username}'"
            local mp="${OPT_REMOUNT_ROOT}/${username}/backups"
            if [[ ! -d "${mp}" ]]; then
                log_warn "  [INCONSISTENCY] Mountpoint directory missing: ${mp}"
            elif ! is_mounted "${mp}"; then
                log_warn "  [INCONSISTENCY] Mountpoint not mounted: ${mp}"
            fi
        fi
    done <<< "${all_users}"
}

# ---------------------------------------------------------------------------
# COMMAND: add
# ---------------------------------------------------------------------------
cmd_add() {
    [[ -n "${OPT_USER}" ]]       || die "add requires --user"
    [[ -n "${OPT_PUBLIC_KEY}" ]] || die "add requires --public-key"
    [[ -n "${OPT_DIRECTORY}" ]]  || die "add requires --directory"

    validate_username "${OPT_USER}"
    validate_absolute_path "${OPT_REMOUNT_ROOT}"       "--remount-root"
    validate_absolute_path "${OPT_SSH_CONFIG}"         "--ssh-config"
    validate_absolute_path "${OPT_AUTHORIZED_KEYS_DIR}" "--authorized-keys-dir"
    validate_absolute_path "${OPT_DIRECTORY}"          "--directory"
    validate_directory_exists "${OPT_DIRECTORY}"       "--directory"
    validate_public_key "${OPT_PUBLIC_KEY}"

    local username="${OPT_USER}"
    local source_dir="${OPT_DIRECTORY}"
    local mp="${OPT_REMOUNT_ROOT}/${username}/backups"
    local key_file="${OPT_AUTHORIZED_KEYS_DIR}/${username}"

    # Idempotency: if exact desired state already exists, succeed silently.
    if has_managed_block "${OPT_SSH_CONFIG}" "${username}"; then
        local existing_key existing_dir
        existing_key=$(read_authorized_key "${username}")
        existing_dir=$(get_service_source_dir "${username}")

        if [[ "${existing_key}" == "${OPT_PUBLIC_KEY}" ]] \
            && [[ "${existing_dir}" == "${source_dir}" ]] \
            && user_exists "${username}" \
            && is_mounted "${mp}"; then
            log_info "No changes needed: '${username}' is already in the desired state"
            return 0
        fi
        die "User '${username}' is already managed but differs from the requested state. Use 'modify' to update."
    fi

    # Partial state guard
    if user_exists "${username}" \
        || has_managed_block "${SYSTEMD_SERVICE_FILE}" "${username}" \
        || [[ -f "${key_file}" ]]; then
        die "User '${username}' has partial managed state (OS user or fstab block or key file exists). Use 'delete' to clean up first, or 'modify' to update."
    fi

    # Pre-flight check: fail fast if sshd_config has a conflicting Subsystem line,
    # before any OS user, chroot tree, key file, fstab, or mount change is made.
    assert_sshd_subsystem_compatible

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Planned actions for 'add ${username}':"
        log_info "  1. Create system user: ${username}"
        log_info "  2. Create chroot tree: ${mp}"
        log_info "  3. Write authorized key: ${key_file}"
        log_info "  4. Add systemd service block: ${source_dir} -> ${mp}"
        log_info "  5. Bind mount ${source_dir} -> ${mp} (read-only)"
        log_info "  6. Add sshd_config Match block + ensure global Subsystem sftp internal-sftp"
        log_info "  Next step: systemctl reload ssh"
        return 0
    fi

    acquire_lock

    create_os_user "${username}"
    create_chroot_tree "${username}"
    write_authorized_key "${username}" "${OPT_PUBLIC_KEY}"
    update_systemd_service_for_user "${username}" "${source_dir}"
    mount_user_dir "${username}" "${source_dir}"
    update_sshd_config_for_user "${username}"

    log_info "User '${username}' added successfully."
    log_info "Next step: systemctl reload ssh"
}

# ---------------------------------------------------------------------------
# COMMAND: modify
# ---------------------------------------------------------------------------
cmd_modify() {
    [[ -n "${OPT_USER}" ]] || die "modify requires --user"
    [[ -n "${OPT_PUBLIC_KEY}" || -n "${OPT_DIRECTORY}" ]] \
        || die "modify requires at least one of --public-key or --directory"

    validate_username "${OPT_USER}"
    validate_absolute_path "${OPT_REMOUNT_ROOT}"        "--remount-root"
    validate_absolute_path "${OPT_SSH_CONFIG}"          "--ssh-config"
    validate_absolute_path "${OPT_AUTHORIZED_KEYS_DIR}" "--authorized-keys-dir"

    local username="${OPT_USER}"

    has_managed_block "${OPT_SSH_CONFIG}" "${username}" \
        || die "No managed SSH block found for '${username}'. Use 'add' first."

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Planned actions for 'modify ${username}':"
        [[ -n "${OPT_PUBLIC_KEY}" ]] && log_info "  - Update authorized key"
        if [[ -n "${OPT_DIRECTORY}" ]]; then
            log_info "  - Unmount old mountpoint if mounted"
            log_info "  - Update systemd service block to: ${OPT_DIRECTORY}"
            log_info "  - Bind mount ${OPT_DIRECTORY} -> ${OPT_REMOUNT_ROOT}/${username}/backups (read-only)"
        fi
        return 0
    fi

    acquire_lock

    if [[ -n "${OPT_PUBLIC_KEY}" ]]; then
        validate_public_key "${OPT_PUBLIC_KEY}"
        write_authorized_key "${username}" "${OPT_PUBLIC_KEY}"
    fi

    if [[ -n "${OPT_DIRECTORY}" ]]; then
        validate_absolute_path "${OPT_DIRECTORY}"    "--directory"
        validate_directory_exists "${OPT_DIRECTORY}" "--directory"
        unmount_user_dir "${username}"
        update_systemd_service_for_user "${username}" "${OPT_DIRECTORY}"
        mount_user_dir "${username}" "${OPT_DIRECTORY}"
    fi

    log_info "User '${username}' modified successfully."
    log_info "Next step: systemctl reload ssh"
}

# ---------------------------------------------------------------------------
# COMMAND: delete
# ---------------------------------------------------------------------------
cmd_delete() {
    [[ -n "${OPT_USER}" ]] || die "delete requires --user"
    validate_username "${OPT_USER}"

    local username="${OPT_USER}"
    local has_ssh=0 has_service=0
    has_managed_block "${OPT_SSH_CONFIG}" "${username}" && has_ssh=1 || true
    has_managed_block "${SYSTEMD_SERVICE_FILE}" "${username}" && has_service=1 || true

    if [[ "${has_ssh}" -eq 0 && "${has_service}" -eq 0 ]]; then
        log_warn "No managed state found for '${username}'; nothing to delete"
        return 0
    fi

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Planned actions for 'delete ${username}':"
        [[ "${has_ssh}" -eq 1 ]]     && log_info "  - Remove managed SSH block from ${OPT_SSH_CONFIG}"
        [[ "${has_service}" -eq 1 ]] && log_info "  - Remove managed service block from ${SYSTEMD_SERVICE_FILE}"
        log_info "  - Unmount ${OPT_REMOUNT_ROOT}/${username}/backups if mounted"
        log_info "  - Remove authorized key: ${OPT_AUTHORIZED_KEYS_DIR}/${username}"
        log_info "  - Remove OS user: ${username}"
        log_info "  - Remove chroot tree: ${OPT_REMOUNT_ROOT}/${username} (if safe)"
        log_info "  Next step: systemctl reload ssh"
        return 0
    fi

    acquire_lock

    # 1. Remove SSH block first to close the access path
    [[ "${has_ssh}" -eq 1 ]]     && remove_ssh_block_for_user "${username}"
    # 2. Unmount before touching service
    unmount_user_dir "${username}"
    # 3. Remove systemd service block
    [[ "${has_service}" -eq 1 ]] && remove_systemd_service_for_user "${username}"
    # 4. Remove key file
    remove_authorized_key "${username}"
    # 5. Remove OS user
    delete_os_user "${username}"
    # 6. Remove chroot tree (best-effort)
    remove_chroot_tree "${username}" || log_warn "Chroot tree not removed (see above)"

    log_info "User '${username}' deleted successfully."
    log_info "Next step: systemctl reload ssh"
}

# ---------------------------------------------------------------------------
# COMMAND: admin-recreate-mounts
# ---------------------------------------------------------------------------
cmd_admin_recreate_mounts() {
    validate_absolute_path "${OPT_REMOUNT_ROOT}" "--remount-root"
    validate_absolute_path "${OPT_SSH_CONFIG}"   "--ssh-config"

    local ssh_users service_users
    ssh_users=$(get_managed_users_from_file "${OPT_SSH_CONFIG}")
    service_users=$(get_managed_users_from_file "${SYSTEMD_SERVICE_FILE}")

    local changed=0

    # 1. Remove orphaned service entries (in service, not in sshd_config)
    if [[ -n "${service_users}" ]]; then
        local svc_user
        while IFS= read -r svc_user; do
            [[ -z "${svc_user}" ]] && continue
            if [[ -z "${ssh_users}" ]] \
                || ! printf '%s\n' "${ssh_users}" | grep -qxF "${svc_user}"; then
                log_info "Orphaned service entry: '${svc_user}'"
                local mp="${OPT_REMOUNT_ROOT}/${svc_user}/backups"
                if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
                    is_mounted "${mp}" \
                        && log_info "[DRY-RUN] Would unmount ${mp}"
                    log_info "[DRY-RUN] Would remove service block for '${svc_user}'"
                else
                    unmount_user_dir "${svc_user}"
                    remove_systemd_service_for_user "${svc_user}"
                fi
                changed=1
            fi
        done <<< "${service_users}"
    fi

    # 2. Process users that should have mounts (in sshd_config)
    if [[ -n "${ssh_users}" ]]; then
        local ssh_user
        while IFS= read -r ssh_user; do
            [[ -z "${ssh_user}" ]] && continue
            local mp="${OPT_REMOUNT_ROOT}/${ssh_user}/backups"

            if has_managed_block "${SYSTEMD_SERVICE_FILE}" "${ssh_user}"; then
                # Service entry exists: ensure mount is active
                if ! is_mounted "${mp}"; then
                    local source_dir
                    source_dir=$(get_service_source_dir "${ssh_user}")
                    if [[ -z "${source_dir}" ]]; then
                        log_warn "Service entry for '${ssh_user}' has no source directory; skipping"
                        continue
                    fi
                    if [[ ! -d "${source_dir}" ]]; then
                        log_warn "Source directory '${source_dir}' for '${ssh_user}' does not exist; skipping"
                        continue
                    fi
                    if [[ ! -d "${mp}" ]]; then
                        log_warn "Mountpoint '${mp}' for '${ssh_user}' does not exist; skipping"
                        continue
                    fi
                    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
                        log_info "[DRY-RUN] Would mount ${source_dir} -> ${mp} (read-only)"
                    else
                        mount_user_dir "${ssh_user}" "${source_dir}"
                    fi
                    changed=1
                fi
            else
                # No service entry: cannot determine source directory
                log_warn "No service entry for managed user '${ssh_user}'; use 'modify -d DIR -u ${ssh_user}' to set the source directory"
                changed=1
            fi
        done <<< "${ssh_users}"
    fi

    if [[ "${changed}" -eq 0 ]]; then
        log_info "No changes needed: all mounts are consistent"
    fi
}

# ---------------------------------------------------------------------------
# COMMAND: admin-check-all
# ---------------------------------------------------------------------------
CHECK_FAIL_COUNT=0

_check_ok() {
    log_verbose "[OK] $*"
}

_check_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    (( CHECK_FAIL_COUNT++ )) || true
}

_check_user() {
    local username="$1"
    printf '[CHECK] === %s ===\n' "${username}" >&2

    # 1. OS user exists
    if user_exists "${username}"; then
        _check_ok "${username}: OS user exists"
    else
        _check_fail "${username}: OS user missing"
    fi

    # 2. sshd_config block exists
    if has_managed_block "${OPT_SSH_CONFIG}" "${username}"; then
        _check_ok "${username}: sshd_config block present"
    else
        _check_fail "${username}: sshd_config block missing"
    fi

    # 3. sshd_config block not duplicated
    local sshd_count
    sshd_count=$(count_managed_blocks "${OPT_SSH_CONFIG}" "${username}")
    if [[ "${sshd_count}" -le 1 ]]; then
        _check_ok "${username}: sshd_config block count OK (${sshd_count})"
    else
        _check_fail "${username}: sshd_config has ${sshd_count} duplicate blocks"
    fi

    # 4. systemd service block exists
    if has_managed_block "${SYSTEMD_SERVICE_FILE}" "${username}"; then
        _check_ok "${username}: systemd service block present"
    else
        _check_fail "${username}: systemd service block missing"
    fi

    # 5. systemd service block not duplicated
    local service_count
    service_count=$(count_managed_blocks "${SYSTEMD_SERVICE_FILE}" "${username}")
    if [[ "${service_count}" -le 1 ]]; then
        _check_ok "${username}: systemd service block count OK (${service_count})"
    else
        _check_fail "${username}: systemd service has ${service_count} duplicate blocks"
    fi

    # 6. Source directory exists
    local source_dir
    source_dir=$(get_service_source_dir "${username}")
    if [[ -n "${source_dir}" ]]; then
        if [[ -d "${source_dir}" ]]; then
            _check_ok "${username}: source directory exists (${source_dir})"
        else
            _check_fail "${username}: source directory missing: ${source_dir}"
        fi
    else
        _check_fail "${username}: no source directory found in service block"
    fi

    # 7. Chroot base dir exists
    local chroot_dir="${OPT_REMOUNT_ROOT}/${username}"
    if [[ -d "${chroot_dir}" ]]; then
        _check_ok "${username}: chroot directory exists"
    else
        _check_fail "${username}: chroot directory missing: ${chroot_dir}"
    fi

    # 8. Chroot base dir ownership and permissions
    if [[ -d "${chroot_dir}" ]]; then
        local owner perms
        owner=$(get_owner "${chroot_dir}")
        perms=$(get_perms "${chroot_dir}")
        if [[ "${owner}" == "root:root" ]]; then
            _check_ok "${username}: chroot dir owner is root:root"
        else
            _check_fail "${username}: chroot dir owner is ${owner} (expected root:root)"
        fi
        if [[ "${perms}" == "755" ]]; then
            _check_ok "${username}: chroot dir mode is 755"
        else
            _check_fail "${username}: chroot dir mode is ${perms} (expected 755)"
        fi
    fi

    # 9. Backups mountpoint dir exists
    local mp="${chroot_dir}/backups"
    if [[ -d "${mp}" ]]; then
        _check_ok "${username}: backups mountpoint exists"
    else
        _check_fail "${username}: backups mountpoint missing: ${mp}"
    fi

    # 10. Backups mountpoint ownership and permissions
    if [[ -d "${mp}" ]]; then
        local mp_owner mp_perms
        mp_owner=$(get_owner "${mp}")
        mp_perms=$(get_perms "${mp}")
        if [[ "${mp_owner}" == "root:root" ]]; then
            _check_ok "${username}: backups dir owner is root:root"
        else
            _check_fail "${username}: backups dir owner is ${mp_owner} (expected root:root)"
        fi
        if [[ "${mp_perms}" == "755" ]]; then
            _check_ok "${username}: backups dir mode is 755"
        else
            _check_fail "${username}: backups dir mode is ${mp_perms} (expected 755)"
        fi
    fi

    # 11. Authorized key file exists
    local key_file="${OPT_AUTHORIZED_KEYS_DIR}/${username}"
    if [[ -f "${key_file}" ]]; then
        _check_ok "${username}: authorized key file exists"
    else
        _check_fail "${username}: authorized key file missing: ${key_file}"
    fi

    # 12. Authorized key file ownership and permissions
    if [[ -f "${key_file}" ]]; then
        local kf_owner kf_perms
        kf_owner=$(get_owner "${key_file}")
        kf_perms=$(get_perms "${key_file}")
        if [[ "${kf_owner}" == "root:root" ]]; then
            _check_ok "${username}: key file owner is root:root"
        else
            _check_fail "${username}: key file owner is ${kf_owner} (expected root:root)"
        fi
        if [[ "${kf_perms}" == "644" ]]; then
            _check_ok "${username}: key file mode is 644"
        else
            _check_fail "${username}: key file mode is ${kf_perms} (expected 644)"
        fi
    fi

    # 13. Authorized key file is non-empty
    if [[ -f "${key_file}" ]]; then
        if [[ -s "${key_file}" ]]; then
            _check_ok "${username}: key file is non-empty"
        else
            _check_fail "${username}: key file is empty"
        fi
    fi

    # 14. Mount is active
    if is_mounted "${mp}"; then
        _check_ok "${username}: mount is active"
    else
        _check_fail "${username}: mount is NOT active: ${mp}"
    fi
}

cmd_admin_check_all() {
    validate_absolute_path "${OPT_REMOUNT_ROOT}" "--remount-root"
    validate_absolute_path "${OPT_SSH_CONFIG}"   "--ssh-config"

    local ssh_users service_users all_users
    ssh_users=$(get_managed_users_from_file "${OPT_SSH_CONFIG}")
    service_users=$(get_managed_users_from_file "${SYSTEMD_SERVICE_FILE}")

    all_users=$(printf '%s\n%s\n' "${ssh_users}" "${service_users}" \
        | sort -u | grep -v '^$') || true

    if [[ -z "${all_users}" ]]; then
        log_info "No managed users found; nothing to check"
        return 0
    fi

    CHECK_FAIL_COUNT=0
    local users_checked=0

    local username
    while IFS= read -r username; do
        [[ -z "${username}" ]] && continue
        _check_user "${username}"
        (( users_checked++ )) || true
    done <<< "${all_users}"

    printf '\n=== Summary: %d users checked, %d problems found ===\n' \
        "${users_checked}" "${CHECK_FAIL_COUNT}" >&2

    [[ "${CHECK_FAIL_COUNT}" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# require_root
# ---------------------------------------------------------------------------
require_root() {
    # BA_SKIP_ROOT_CHECK=1 bypasses the check during testing
    [[ "${BA_SKIP_ROOT_CHECK:-0}" -eq 1 ]] && return 0
    [[ "${EUID}" -eq 0 ]] || die "This command requires root privileges (EUID must be 0)"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
print_help() {
    cat <<'HELP'
backup_access.sh — manage read-only SFTP backup-access accounts

SYNOPSIS
    backup_access.sh COMMAND [OPTIONS]

COMMANDS
    list          Print all managed users (sorted) with key and directory
    add           Add a new managed SFTP user
    modify        Update an existing managed user (key and/or directory)
    delete        Remove a managed user and all associated state
    admin-recreate-mounts
                  Reconcile systemd mount service with managed accounts:
                  mount unmounted entries, remove orphaned entries
    admin-check-all
                  Verify all managed users have correct, complete configuration.
                  Checks OS user, config blocks, directories, permissions, keys,
                  and mounts. Use --verbose for [OK] details.
    -h, --help    Show this help message (may appear as first argument only)
    -i, --info    Show version and exit

OPTIONS
    -h, --help                Show this help message
    -t, --dry-run             Validate and plan; make no changes
    -v, --verbose             Enable verbose output; report inconsistencies for list
    -m, --minimal-list        list only: print USER and DIRECTORY columns (omit PUBLIC_KEY)
    -r, --remount-root DIR    Chroot base directory       (default: /srv/sftp)
    -s, --ssh-config FILE     Path to sshd_config         (default: /etc/ssh/sshd_config)
    -a, --authorized-keys-dir DIR
                              Authorized keys directory   (default: /etc/ssh/authorized_keys)
    -u, --user USERNAME       Username (required for add, modify, delete)
    -k, --public-key KEY      SSH public key string (required for add; optional for modify)
    -d, --directory DIR       Backup source directory (required for add; optional for modify)

NOTES
    - add, modify, and delete require root privileges.
    - Only configuration blocks marked with
        # BEGIN backup_access USERNAME … # END backup_access USERNAME
      are created or modified.  All other content in sshd_config and the
      systemd service file is left untouched.
    - The global line "Subsystem sftp internal-sftp" is added to sshd_config
      if absent.  If a conflicting "Subsystem sftp <other>" line is found, the
      script aborts rather than silently rewriting it.
    - sshd is NOT reloaded automatically.  After every change the script prints
      the required next step.
    - modify does NOT rename the account.

EXAMPLES
    List managed users:
        backup_access.sh list

    List with verbose inconsistency report:
        backup_access.sh list -v

    Add a user:
        backup_access.sh add \
            -u backupuser \
            -k "ssh-ed25519 AAAA... user@host" \
            -d /var/backups/myapp

    Update public key only:
        backup_access.sh modify \
            -u backupuser \
            -k "ssh-ed25519 BBBB... newkey@host"

    Update source directory only:
        backup_access.sh modify \
            -u backupuser \
            -d /var/backups/newapp

    Delete a user:
        backup_access.sh delete -u backupuser

    Dry-run an add:
        backup_access.sh add --dry-run \
            -u backupuser \
            -k "ssh-ed25519 AAAA..." \
            -d /var/backups/myapp
HELP
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    [[ $# -eq 0 ]] && { print_help; exit 0; }

    # First argument must be a command or help flag
    case "$1" in
        -h|--help)            print_help; exit 0 ;;
        -i|--info)            printf '%s %s\n' "${SCRIPT_NAME}" "${VERSION}"; exit 0 ;;
        list|add|modify|delete|admin-recreate-mounts|admin-check-all) COMMAND="$1"; shift ;;
        *) die "First argument must be a command: list add modify delete admin-recreate-mounts admin-check-all -h --help -i --info  (got: '$1')" ;;
    esac

    # Parse remaining options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                print_help; exit 0 ;;
            -t|--dry-run)
                OPT_DRY_RUN=1; shift ;;
            -v|--verbose)
                OPT_VERBOSE=1; shift ;;
            -m|--minimal-list)
                OPT_MINIMAL_LIST=1; shift ;;
            -r|--remount-root)
                [[ $# -ge 2 ]] || die "-r/--remount-root requires an argument"
                OPT_REMOUNT_ROOT="$2"; shift 2 ;;
            -s|--ssh-config)
                [[ $# -ge 2 ]] || die "-s/--ssh-config requires an argument"
                OPT_SSH_CONFIG="$2"; shift 2 ;;
            -a|--authorized-keys-dir)
                [[ $# -ge 2 ]] || die "-a/--authorized-keys-dir requires an argument"
                OPT_AUTHORIZED_KEYS_DIR="$2"; shift 2 ;;
            -u|--user)
                [[ $# -ge 2 ]] || die "-u/--user requires an argument"
                OPT_USER="$2"; shift 2 ;;
            -k|--public-key)
                [[ $# -ge 2 ]] || die "-k/--public-key requires an argument"
                OPT_PUBLIC_KEY="$2"; shift 2 ;;
            -d|--directory)
                [[ $# -ge 2 ]] || die "-d/--directory requires an argument"
                OPT_DIRECTORY="$2"; shift 2 ;;
            *)
                die "Unknown option: '$1'  (use --help for usage)" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    case "${COMMAND}" in
        list)   cmd_list ;;
        add)    require_root; cmd_add ;;
        modify) require_root; cmd_modify ;;
        delete) require_root; cmd_delete ;;
        admin-recreate-mounts) require_root; cmd_admin_recreate_mounts ;;
        admin-check-all) require_root; cmd_admin_check_all ;;
    esac
}

main "$@"
