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
#   - one block in /etc/fstab (guarded by script markers)

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="backup_access"
readonly MARKER_BEGIN="# BEGIN ${SCRIPT_NAME}"
readonly MARKER_END="# END ${SCRIPT_NAME}"

readonly DEFAULT_REMOUNT_ROOT="/srv/sftp"
readonly DEFAULT_SSH_CONFIG="/etc/ssh/sshd_config"
readonly DEFAULT_AUTHORIZED_KEYS_DIR="/etc/ssh/authorized_keys"

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
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
ADDUSER_BIN="${ADDUSER_BIN:-/usr/sbin/adduser}"
USERDEL_BIN="${USERDEL_BIN:-/usr/sbin/userdel}"
MOUNT_BIN="${MOUNT_BIN:-/bin/mount}"
UMOUNT_BIN="${UMOUNT_BIN:-/bin/umount}"
FINDMNT_BIN="${FINDMNT_BIN:-/bin/findmnt}"
CHOWN_BIN="${CHOWN_BIN:-/bin/chown}"
CHMOD_BIN="${CHMOD_BIN:-/bin/chmod}"
INSTALL_BIN="${INSTALL_BIN:-/usr/bin/install}"
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

# Print the source directory recorded in the managed fstab block for USERNAME.
get_fstab_source_dir() {
    local username="$1"
    [[ -f "${FSTAB_FILE}" ]] || return 0
    local begin="${MARKER_BEGIN} ${username}"
    local end="${MARKER_END} ${username}"
    local in_block=0
    while IFS= read -r line; do
        if [[ "${line}" == "${begin}" ]]; then
            in_block=1; continue; fi
        if [[ "${line}" == "${end}" ]]; then
            break; fi
        if [[ "${in_block}" -eq 1 ]]; then
            local src
            src=$(printf '%s' "${line}" | awk '{print $1}')
            if [[ -n "${src}" && "${src}" != "#" ]]; then
                printf '%s' "${src}"
                return
            fi
        fi
    done < "${FSTAB_FILE}"
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

build_fstab_block() {
    local username="$1"
    local source_dir="$2"
    local remount_root="$3"
    local mp="${remount_root}/${username}/backups"
    printf '%s %s\n' "${MARKER_BEGIN}" "${username}"
    printf '%s  %s  none  bind              0 0\n' "${source_dir}" "${mp}"
    printf '%s  %s  none  bind,remount,ro   0 0\n' "${source_dir}" "${mp}"
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
# fstab management
# ---------------------------------------------------------------------------

# Add or update the managed fstab block for USERNAME with SOURCE_DIR.
update_fstab_for_user() {
    local username="$1"
    local source_dir="$2"
    local config="${FSTAB_FILE}"
    [[ -f "${config}" ]] || die "fstab not found: ${config}"

    local new_block
    new_block=$(build_fstab_block "${username}" "${source_dir}" "${OPT_REMOUNT_ROOT}")

    local tmp
    tmp=$(make_temp)

    if has_managed_block "${config}" "${username}"; then
        remove_block_from_stream "${username}" < "${config}" > "${tmp}"
    else
        cp "${config}" "${tmp}"
    fi
    printf '\n%s\n' "${new_block}" >> "${tmp}"

    atomic_replace_file "${config}" "${tmp}" >/dev/null
    log_info "fstab updated for '${username}' (source: ${source_dir})"
}

# Remove the managed fstab block for USERNAME.
remove_fstab_for_user() {
    local username="$1"
    local config="${FSTAB_FILE}"

    if ! has_managed_block "${config}" "${username}"; then
        log_warn "No managed fstab block found for '${username}' in ${config}"
        return 0
    fi

    local tmp
    tmp=$(make_temp)
    remove_block_from_stream "${username}" < "${config}" > "${tmp}"

    atomic_replace_file "${config}" "${tmp}" >/dev/null
    log_info "Managed fstab block removed for '${username}'"
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
    local ssh_users fstab_users all_users

    ssh_users=$(get_managed_users_from_file "${OPT_SSH_CONFIG}")
    fstab_users=$(get_managed_users_from_file "${FSTAB_FILE}")

    all_users=$(printf '%s\n%s\n' "${ssh_users}" "${fstab_users}" \
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
        dir=$(get_fstab_source_dir "${username}")

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
            local sshd_count fstab_count
            sshd_count=$(count_managed_blocks "${OPT_SSH_CONFIG}" "${username}")
            fstab_count=$(count_managed_blocks "${FSTAB_FILE}" "${username}")

            user_exists "${username}" \
                || log_warn "  [INCONSISTENCY] OS user '${username}' missing"
            [[ -f "${OPT_AUTHORIZED_KEYS_DIR}/${username}" ]] \
                || log_warn "  [INCONSISTENCY] Key file missing: ${OPT_AUTHORIZED_KEYS_DIR}/${username}"
            has_managed_block "${FSTAB_FILE}" "${username}" \
                || log_warn "  [INCONSISTENCY] No managed fstab block for '${username}'"
            has_managed_block "${OPT_SSH_CONFIG}" "${username}" \
                || log_warn "  [INCONSISTENCY] No managed SSH block for '${username}'"
            [[ "${sshd_count}" -le 1 ]] \
                || log_warn "  [INCONSISTENCY] Duplicate managed SSH blocks (${sshd_count}) for '${username}'"
            [[ "${fstab_count}" -le 1 ]] \
                || log_warn "  [INCONSISTENCY] Duplicate managed fstab blocks (${fstab_count}) for '${username}'"
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
        existing_dir=$(get_fstab_source_dir "${username}")

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
        || has_managed_block "${FSTAB_FILE}" "${username}" \
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
        log_info "  4. Add fstab block: ${source_dir} -> ${mp}"
        log_info "  5. Bind mount ${source_dir} -> ${mp} (read-only)"
        log_info "  6. Add sshd_config Match block + ensure global Subsystem sftp internal-sftp"
        log_info "  Next step: systemctl reload ssh"
        return 0
    fi

    acquire_lock

    create_os_user "${username}"
    create_chroot_tree "${username}"
    write_authorized_key "${username}" "${OPT_PUBLIC_KEY}"
    update_fstab_for_user "${username}" "${source_dir}"
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
            log_info "  - Update fstab block to: ${OPT_DIRECTORY}"
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
        update_fstab_for_user "${username}" "${OPT_DIRECTORY}"
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
    local has_ssh=0 has_fstab=0
    has_managed_block "${OPT_SSH_CONFIG}" "${username}" && has_ssh=1 || true
    has_managed_block "${FSTAB_FILE}"     "${username}" && has_fstab=1 || true

    if [[ "${has_ssh}" -eq 0 && "${has_fstab}" -eq 0 ]]; then
        log_warn "No managed state found for '${username}'; nothing to delete"
        return 0
    fi

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Planned actions for 'delete ${username}':"
        [[ "${has_ssh}" -eq 1 ]]   && log_info "  - Remove managed SSH block from ${OPT_SSH_CONFIG}"
        [[ "${has_fstab}" -eq 1 ]] && log_info "  - Remove managed fstab block from ${FSTAB_FILE}"
        log_info "  - Unmount ${OPT_REMOUNT_ROOT}/${username}/backups if mounted"
        log_info "  - Remove authorized key: ${OPT_AUTHORIZED_KEYS_DIR}/${username}"
        log_info "  - Remove OS user: ${username}"
        log_info "  - Remove chroot tree: ${OPT_REMOUNT_ROOT}/${username} (if safe)"
        log_info "  Next step: systemctl reload ssh"
        return 0
    fi

    acquire_lock

    # 1. Remove SSH block first to close the access path
    [[ "${has_ssh}" -eq 1 ]]   && remove_ssh_block_for_user "${username}"
    # 2. Unmount before touching fstab
    unmount_user_dir "${username}"
    # 3. Remove fstab block
    [[ "${has_fstab}" -eq 1 ]] && remove_fstab_for_user "${username}"
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
    -h, --help    Show this help message (may appear as first argument only)

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
      are created or modified.  All other content in sshd_config and fstab is
      left untouched.
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
        list|add|modify|delete) COMMAND="$1"; shift ;;
        *) die "First argument must be a command: list add modify delete -h --help  (got: '$1')" ;;
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
    esac
}

main "$@"
