#!/usr/bin/env bash
# test_backup_access.sh
# Self-contained test harness for backup_access.sh.
# Runs entirely in a temporary directory tree; never needs root.
# All external commands are replaced with lightweight stubs.
#
# Usage:
#   bash test_backup_access.sh [--verbose]
#   bash test_backup_access.sh -v

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/backup_access.sh"
[[ -f "${SUT}" ]] || { echo "ERROR: backup_access.sh not found at ${SUT}"; exit 1; }

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

TMPBASE=""        # set in setup_fixtures
FAKE_BIN=""
FAKE_MOUNTS=""    # file tracking fake-mounted paths
FAKE_LOG=""       # log of stub invocations
SSHD_CFG=""
SYSTEMD_SERVICE=""
AUTHKEYS_DIR=""
REMOUNT_ROOT=""
BACKUP_SRC=""

# A syntactically minimal sshd_config for the fake sshd validator
SSHD_CFG_MINIMAL='# sshd_config minimal fixture
Port 22
PermitRootLogin no
'

# A valid-looking test public key
TEST_KEY_ED="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBuTRJmClTRoVHMvGgxrOA9JFHi9DPHpyPCzLe8d7lOo test@host"
TEST_KEY_ED2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHuTRJmClTRoVHMvGgxrOA9JFHi9DPHpyPCzLe8d7lO2 test2@host"

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------
pass() {
    PASS=$(( PASS + 1 ))
    [[ "${VERBOSE}" -eq 1 ]] && printf '  PASS: %s\n' "$*" || true
}
fail() {
    FAIL=$(( FAIL + 1 ))
    printf '  FAIL: %s\n' "$*"
}
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        pass "${label}"
    else
        fail "${label}"
        printf '       expected: %q\n' "${expected}"
        printf '       actual:   %q\n' "${actual}"
    fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
        pass "${label}"
    else
        fail "${label}"
        printf '       needle:    %q\n' "${needle}"
        printf '       haystack:  %q\n' "${haystack}"
    fi
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if ! printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
        pass "${label}"
    else
        fail "${label}"
        printf '       should NOT contain: %q\n' "${needle}"
    fi
}
assert_file_contains() {
    local label="$1" needle="$2" file="$3"
    if grep -qF "${needle}" "${file}" 2>/dev/null; then
        pass "${label}"
    else
        fail "${label}"
        printf '       file:   %s\n' "${file}"
        printf '       needle: %q\n' "${needle}"
    fi
}
assert_file_not_contains() {
    local label="$1" needle="$2" file="$3"
    if ! grep -qF "${needle}" "${file}" 2>/dev/null; then
        pass "${label}"
    else
        fail "${label}"
        printf '       file should NOT contain: %q\n' "${needle}"
        printf '       file: %s\n' "${file}"
    fi
}
assert_file_exists() {
    local label="$1" file="$2"
    if [[ -f "${file}" ]]; then pass "${label}"; else fail "${label}: missing ${file}"; fi
}
assert_file_absent() {
    local label="$1" file="$2"
    if [[ ! -f "${file}" ]]; then pass "${label}"; else fail "${label}: unexpected file ${file}"; fi
}
assert_exits_ok() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "${label}"; else fail "${label}: expected exit 0"; fi
}
assert_exits_fail() {
    local label="$1"; shift
    if ! "$@" >/dev/null 2>&1; then pass "${label}"; else fail "${label}: expected non-zero exit"; fi
}

# ---------------------------------------------------------------------------
# Fixture setup / teardown
# ---------------------------------------------------------------------------
setup_fixtures() {
    TMPBASE=$(mktemp -d /tmp/ba_test.XXXXXXXXXX)
    FAKE_BIN="${TMPBASE}/bin"
    FAKE_MOUNTS="${TMPBASE}/mounts"
    FAKE_LOG="${TMPBASE}/cmd.log"
    SSHD_CFG="${TMPBASE}/sshd_config"
    SYSTEMD_SERVICE="${TMPBASE}/backup-access-mounts.service"
    AUTHKEYS_DIR="${TMPBASE}/authorized_keys"
    REMOUNT_ROOT="${TMPBASE}/sftp"
    BACKUP_SRC="${TMPBASE}/backup_src"

    mkdir -p "${FAKE_BIN}" "${AUTHKEYS_DIR}" "${REMOUNT_ROOT}" "${BACKUP_SRC}"
    touch "${FAKE_MOUNTS}" "${FAKE_LOG}"
    printf '%s' "${SSHD_CFG_MINIMAL}" > "${SSHD_CFG}"

    _write_fake_commands
}

teardown_fixtures() {
    [[ -n "${TMPBASE}" && -d "${TMPBASE}" ]] && rm -rf "${TMPBASE}" || true
}

_write_fake_commands() {
    # fake sshd: accept -t -f FILE; reject if FILE contains 'INVALID_SYNTAX'
    cat > "${FAKE_BIN}/sshd" <<'STUB'
#!/usr/bin/env bash
# fake sshd -t -f FILE
shift  # consume any leading flags until we find -f
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) shift ;;
        -f) shift
            if grep -qF 'INVALID_SYNTAX' "$1" 2>/dev/null; then
                echo "sshd: INVALID_SYNTAX in $1" >&2; exit 1
            fi
            exit 0 ;;
        *) shift ;;
    esac
done
exit 0
STUB

    # fake adduser: record call; optionally create /etc/passwd entry stub
    cat > "${FAKE_BIN}/adduser" <<STUB
#!/usr/bin/env bash
printf 'adduser %s\n' "\$*" >> "${FAKE_LOG}"
# Simulate the user existing by creating a sentinel file
printf '%s\n' "\${@: -1}" >> "${TMPBASE}/users"
STUB

    # fake userdel: record call; remove sentinel
    cat > "${FAKE_BIN}/userdel" <<STUB
#!/usr/bin/env bash
printf 'userdel %s\n' "\$*" >> "${FAKE_LOG}"
local_user="\${@: -1}"
if [[ -f "${TMPBASE}/users" ]]; then
    grep -vxF "\${local_user}" "${TMPBASE}/users" > "${TMPBASE}/users.tmp" || true
    mv "${TMPBASE}/users.tmp" "${TMPBASE}/users"
fi
STUB

    # fake mount: record call; mark mountpoint as mounted
    cat > "${FAKE_BIN}/mount" <<STUB
#!/usr/bin/env bash
printf 'mount %s\n' "\$*" >> "${FAKE_LOG}"
# Last non-option argument is the mountpoint
mp=""
for arg; do [[ "\${arg}" != -* ]] && mp="\${arg}"; done
[[ -n "\${mp}" ]] && printf '%s\n' "\${mp}" >> "${FAKE_MOUNTS}"
STUB

    # fake umount: remove mountpoint from FAKE_MOUNTS
    cat > "${FAKE_BIN}/umount" <<STUB
#!/usr/bin/env bash
printf 'umount %s\n' "\$*" >> "${FAKE_LOG}"
mp="\${@: -1}"
if [[ -f "${FAKE_MOUNTS}" ]]; then
    grep -vxF "\${mp}" "${FAKE_MOUNTS}" > "${FAKE_MOUNTS}.tmp" || true
    mv "${FAKE_MOUNTS}.tmp" "${FAKE_MOUNTS}"
fi
STUB

    # fake findmnt: exit 0 if mountpoint is listed in FAKE_MOUNTS
    cat > "${FAKE_BIN}/findmnt" <<STUB
#!/usr/bin/env bash
# Called as: findmnt --noheadings --output TARGET MOUNTPOINT
mp="\${@: -1}"
if grep -qxF "\${mp}" "${FAKE_MOUNTS}" 2>/dev/null; then
    printf '%s\n' "\${mp}"
    exit 0
fi
exit 1
STUB

    # fake chown / chmod / install: no-ops that just log
    cat > "${FAKE_BIN}/chown" <<STUB
#!/usr/bin/env bash
printf 'chown %s\n' "\$*" >> "${FAKE_LOG}"
STUB
    cat > "${FAKE_BIN}/chmod" <<STUB
#!/usr/bin/env bash
printf 'chmod %s\n' "\$*" >> "${FAKE_LOG}"
STUB
    cat > "${FAKE_BIN}/install" <<STUB
#!/usr/bin/env bash
printf 'install %s\n' "\$*" >> "${FAKE_LOG}"
STUB

    cat > "${FAKE_BIN}/systemctl" <<STUB
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "${FAKE_LOG}"
STUB

    chmod +x "${FAKE_BIN}"/*
}

# Override user_exists: check sentinel file instead of id(1)
# We monkey-patch by exporting a variable the SUT can't override (can't),
# so instead we export a wrapper: BA_USER_EXISTS_FILE points to the users file.
# The SUT's user_exists() calls `id` which is the real id command.
# To make `id USERNAME` succeed for fake users, we need a different approach.
#
# Strategy: provide a fake 'id' wrapper that consults FAKE_USERS_FILE.
_write_fake_id() {
    cat > "${FAKE_BIN}/id" <<STUB
#!/usr/bin/env bash
# If called with a username argument, check sentinel file
if [[ \$# -eq 1 ]]; then
    if grep -qxF "\$1" "${TMPBASE}/users" 2>/dev/null; then
        printf 'uid=999(%s) gid=999(%s)\n' "\$1" "\$1"
        exit 0
    fi
    exit 1
fi
# No argument: print current user info
exec /usr/bin/id "\$@"
STUB
    chmod +x "${FAKE_BIN}/id"
}

# Run the SUT with all environment overrides pointing at test fixtures.
run_sut() {
    SYSTEMD_SERVICE_FILE="${SYSTEMD_SERVICE}" \
    SSHD_BIN="${FAKE_BIN}/sshd" \
    SYSTEMCTL_BIN="${FAKE_BIN}/systemctl" \
    ADDUSER_BIN="${FAKE_BIN}/adduser" \
    USERDEL_BIN="${FAKE_BIN}/userdel" \
    MOUNT_BIN="${FAKE_BIN}/mount" \
    UMOUNT_BIN="${FAKE_BIN}/umount" \
    FINDMNT_BIN="${FAKE_BIN}/findmnt" \
    CHOWN_BIN="${FAKE_BIN}/chown" \
    CHMOD_BIN="${FAKE_BIN}/chmod" \
    INSTALL_BIN="${FAKE_BIN}/install" \
    BA_SKIP_ROOT_CHECK=1 \
    PATH="${FAKE_BIN}:${PATH}" \
    bash "${SUT}" "$@"
}

# Run and capture combined stdout+stderr.
run_sut_output() {
    run_sut "$@" 2>&1 || true
}

# Run expecting failure; capture output.
run_sut_fail() {
    local out rc=0
    out=$(run_sut "$@" 2>&1) || rc=$?
    printf '%s' "${out}"
    return "${rc}"
}

# Convenience: reset sshd_config to minimal fixture.
reset_sshd_cfg() {
    printf '%s' "${SSHD_CFG_MINIMAL}" > "${SSHD_CFG}"
}

# Convenience: reset systemd service fixture (remove the file).
reset_service() {
    rm -f "${SYSTEMD_SERVICE}"
}

# ---------------------------------------------------------------------------
# Test groups
# ---------------------------------------------------------------------------

test_validation() {
    printf '\n=== Validation tests ===\n'

    # Invalid username: starts with digit
    local out
    out=$(run_sut_output add -u 9bad -k "${TEST_KEY_ED}" -d "${BACKUP_SRC}")
    assert_contains "reject username starting with digit" "Invalid username" "${out}"

    # Invalid username: uppercase
    out=$(run_sut_output add -u BadUser -k "${TEST_KEY_ED}" -d "${BACKUP_SRC}")
    assert_contains "reject uppercase username" "Invalid username" "${out}"

    # Invalid username: too long (33 chars)
    out=$(run_sut_output add -u "$(printf 'a%.0s' {1..33})" -k "${TEST_KEY_ED}" -d "${BACKUP_SRC}")
    assert_contains "reject username >32 chars" "Invalid username" "${out}"

    # ssh-dss rejected
    out=$(run_sut_output add -u testuser -k "ssh-dss AAAA... comment" -d "${BACKUP_SRC}")
    assert_contains "reject ssh-dss key" "ssh-dss" "${out}"

    # Unknown key type
    out=$(run_sut_output add -u testuser -k "ssh-foo AAAA... comment" -d "${BACKUP_SRC}")
    assert_contains "reject unknown key type" "Unsupported key type" "${out}"

    # Multi-line key
    out=$(run_sut_output add -u testuser -k "$(printf 'ssh-ed25519 AAAA\nsecondline')" -d "${BACKUP_SRC}")
    assert_contains "reject multi-line key" "single line" "${out}"

    # Non-absolute remount root
    out=$(run_sut_output add -r "relative/path" -u testuser -k "${TEST_KEY_ED}" -d "${BACKUP_SRC}")
    assert_contains "reject relative remount-root" "absolute path" "${out}"

    # Non-existent source directory
    out=$(run_sut_output add -u testuser -k "${TEST_KEY_ED}" -d "/nonexistent/path/$$")
    assert_contains "reject non-existent source dir" "does not exist" "${out}"

    # Missing required flags for add
    out=$(run_sut_output add -u testuser)
    assert_contains "add: missing --public-key and --directory" "requires --public-key" "${out}"

    out=$(run_sut_output add -u testuser -k "${TEST_KEY_ED}")
    assert_contains "add: missing --directory" "requires --directory" "${out}"

    # modify: missing --user
    out=$(run_sut_output modify -k "${TEST_KEY_ED}")
    assert_contains "modify: missing --user" "requires --user" "${out}"

    # modify: no key or dir
    out=$(run_sut_output modify -u testuser)
    assert_contains "modify: at least one of --public-key/--directory" "requires at least one" "${out}"

    # delete: missing --user
    out=$(run_sut_output delete)
    assert_contains "delete: missing --user" "requires --user" "${out}"

    # Unknown command
    out=$(run_sut_output badcommand 2>&1 || true)
    assert_contains "reject unknown command" "First argument must be a command" "${out}"

    # Unknown option
    out=$(run_sut_output list --nosuchthing 2>&1 || true)
    assert_contains "reject unknown option" "Unknown option" "${out}"
}

test_sshd_config_subsystem() {
    printf '\n=== Subsystem sftp line tests ===\n'
    _write_fake_id

    # Case 1: config has no Subsystem line → should be added
    reset_sshd_cfg
    run_sut add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u testuser \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}" >/dev/null 2>&1
    assert_file_contains "Subsystem line inserted when absent" \
        "Subsystem sftp internal-sftp" "${SSHD_CFG}"

    # Case 2: Subsystem line already correct → should be preserved, not duplicated
    local count
    count=$(grep -c "Subsystem sftp internal-sftp" "${SSHD_CFG}")
    assert_eq "Subsystem line not duplicated" "1" "${count}"

    # Case 3: Conflicting Subsystem line → must abort
    reset_sshd_cfg
    printf 'Subsystem sftp /usr/lib/openssh/sftp-server\n' >> "${SSHD_CFG}"
    local out
    out=$(run_sut_output add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u testuser2 \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}")
    assert_contains "conflicting Subsystem aborts" "Conflicting" "${out}"
    assert_file_not_contains "conflicting Subsystem: no block added" \
        "BEGIN backup_access testuser2" "${SSHD_CFG}"

    # Case 4: Subsystem inside a Match block → must abort
    reset_sshd_cfg
    printf 'Match User somebody\n    Subsystem sftp internal-sftp\n' >> "${SSHD_CFG}"
    out=$(run_sut_output add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u testuser3 \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}")
    assert_contains "Subsystem in Match block aborts" "Match block" "${out}"

    # Restore clean config for subsequent tests
    reset_sshd_cfg
}

test_sshd_config_block() {
    printf '\n=== sshd_config managed block tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    run_sut add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u blocktest \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}" >/dev/null 2>&1

    assert_file_contains "BEGIN marker present" \
        "# BEGIN backup_access blocktest" "${SSHD_CFG}"
    assert_file_contains "END marker present" \
        "# END backup_access blocktest" "${SSHD_CFG}"
    assert_file_contains "Match User line" \
        "Match User blocktest" "${SSHD_CFG}"
    assert_file_contains "ChrootDirectory line" \
        "ChrootDirectory ${REMOUNT_ROOT}/blocktest" "${SSHD_CFG}"
    assert_file_contains "ForceCommand line" \
        "ForceCommand internal-sftp -R -d /backups" "${SSHD_CFG}"
    assert_file_contains "AllowTcpForwarding no" \
        "AllowTcpForwarding no" "${SSHD_CFG}"
    assert_file_contains "PermitTTY no" \
        "PermitTTY no" "${SSHD_CFG}"
    assert_file_contains "PasswordAuthentication no" \
        "PasswordAuthentication no" "${SSHD_CFG}"
    assert_file_contains "AuthenticationMethods publickey" \
        "AuthenticationMethods publickey" "${SSHD_CFG}"

    # Unrelated config lines must be preserved
    assert_file_contains "original Port line preserved" \
        "Port 22" "${SSHD_CFG}"
    assert_file_contains "original PermitRootLogin preserved" \
        "PermitRootLogin no" "${SSHD_CFG}"

    # Clean up
    run_sut delete \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u blocktest >/dev/null 2>&1

    assert_file_not_contains "block removed after delete" \
        "# BEGIN backup_access blocktest" "${SSHD_CFG}"
    assert_file_contains "Port line still present after delete" \
        "Port 22" "${SSHD_CFG}"
}

test_systemd_service_block() {
    printf '\n=== systemd service managed block tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    run_sut add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u svctest \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}" >/dev/null 2>&1

    local mp="${REMOUNT_ROOT}/svctest/backups"
    assert_file_exists "service file created" "${SYSTEMD_SERVICE}"
    assert_file_contains "service BEGIN marker" \
        "# BEGIN backup_access svctest" "${SYSTEMD_SERVICE}"
    assert_file_contains "service END marker" \
        "# END backup_access svctest" "${SYSTEMD_SERVICE}"
    assert_file_contains "service bind mount line" \
        "ExecStart=/bin/mount --bind ${BACKUP_SRC} ${mp}" "${SYSTEMD_SERVICE}"
    assert_file_contains "service remount ro line" \
        "ExecStart=/bin/mount -o remount,ro,bind ${mp}" "${SYSTEMD_SERVICE}"
    assert_file_contains "service umount line" \
        "ExecStop=-/bin/umount ${mp}" "${SYSTEMD_SERVICE}"
    assert_file_contains "service Unit section" \
        "[Unit]" "${SYSTEMD_SERVICE}"
    assert_file_contains "service Type=oneshot" \
        "Type=oneshot" "${SYSTEMD_SERVICE}"
    assert_file_contains "service RemainAfterExit" \
        "RemainAfterExit=yes" "${SYSTEMD_SERVICE}"
    assert_file_contains "service Install section" \
        "[Install]" "${SYSTEMD_SERVICE}"
    assert_file_contains "service WantedBy" \
        "WantedBy=multi-user.target" "${SYSTEMD_SERVICE}"

    # Delete removes the block; with no users left, file is removed
    run_sut delete \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u svctest >/dev/null 2>&1

    assert_file_absent "service file removed when last user deleted" \
        "${SYSTEMD_SERVICE}"
}

test_add_idempotency() {
    printf '\n=== add idempotency tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    # First add
    run_sut add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u idem \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}" >/dev/null 2>&1

    local sshd_before
    sshd_before=$(cat "${SSHD_CFG}")
    local service_before
    service_before=$(cat "${SYSTEMD_SERVICE}")

    # Second add with identical parameters: should say "no changes needed"
    local out
    out=$(run_sut_output add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u idem \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}")
    assert_contains "idempotent add reports no changes" "No changes needed" "${out}"
    assert_eq "sshd_config unchanged after idempotent add" "${sshd_before}" "$(cat "${SSHD_CFG}")"
    assert_eq "service unchanged after idempotent add" "${service_before}" "$(cat "${SYSTEMD_SERVICE}")"

    # Second add with different key should fail with "use modify"
    out=$(run_sut_output add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u idem \
        -k "${TEST_KEY_ED2}" \
        -d "${BACKUP_SRC}")
    assert_contains "add with changed key tells to use modify" "modify" "${out}"

    # Clean up
    run_sut delete \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u idem >/dev/null 2>&1
}

test_modify() {
    printf '\n=== modify tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    run_sut add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u moduser \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}" >/dev/null 2>&1

    local sshd_before
    sshd_before=$(cat "${SSHD_CFG}")

    # --- modify key only ---
    run_sut modify \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u moduser \
        -k "${TEST_KEY_ED2}" >/dev/null 2>&1

    local new_key
    new_key=$(cat "${AUTHKEYS_DIR}/moduser")
    assert_eq "modify key: new key written" "${TEST_KEY_ED2}" "${new_key}"
    # SSH block should be unchanged
    assert_eq "modify key only: sshd_config block unchanged" "${sshd_before}" "$(cat "${SSHD_CFG}")"
    # service source should still be old
    assert_file_contains "modify key only: service source unchanged" \
        "${BACKUP_SRC}" "${SYSTEMD_SERVICE}"

    # --- modify directory only ---
    local BACKUP_SRC2="${TMPBASE}/backup_src2"
    mkdir -p "${BACKUP_SRC2}"
    local service_before
    service_before=$(cat "${SYSTEMD_SERVICE}")

    run_sut modify \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u moduser \
        -d "${BACKUP_SRC2}" >/dev/null 2>&1

    assert_file_contains "modify dir: new source in service block" \
        "${BACKUP_SRC2}" "${SYSTEMD_SERVICE}"
    assert_file_not_contains "modify dir: old source absent from service" \
        "--bind ${BACKUP_SRC} " "${SYSTEMD_SERVICE}"
    assert_file_contains "modify dir: managed block still present" \
        "# BEGIN backup_access moduser" "${SYSTEMD_SERVICE}"
    # sshd_config block must not have changed
    assert_eq "modify dir only: sshd_config unchanged" "${sshd_before}" "$(cat "${SSHD_CFG}")"
    # key must not have changed
    new_key=$(cat "${AUTHKEYS_DIR}/moduser")
    assert_eq "modify dir only: key unchanged" "${TEST_KEY_ED2}" "${new_key}"

    # modify on non-managed user must fail
    local out
    out=$(run_sut_output modify \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u nosuchuser \
        -k "${TEST_KEY_ED}")
    assert_contains "modify unknown user fails" "Use 'add' first" "${out}"

    # Clean up
    run_sut delete \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u moduser >/dev/null 2>&1
}

test_delete() {
    printf '\n=== delete tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    run_sut add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u deluser \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}" >/dev/null 2>&1

    # Verify state was created
    assert_file_contains "add: SSH block present before delete" \
        "# BEGIN backup_access deluser" "${SSHD_CFG}"
    assert_file_contains "add: service block present before delete" \
        "# BEGIN backup_access deluser" "${SYSTEMD_SERVICE}"
    assert_file_exists "add: key file present before delete" \
        "${AUTHKEYS_DIR}/deluser"

    run_sut delete \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u deluser >/dev/null 2>&1

    assert_file_not_contains "delete: SSH block removed" \
        "# BEGIN backup_access deluser" "${SSHD_CFG}"
    assert_file_absent "delete: service file removed (last user)" \
        "${SYSTEMD_SERVICE}"
    assert_file_absent "delete: key file removed" \
        "${AUTHKEYS_DIR}/deluser"

    # Global Subsystem line must remain after delete
    assert_file_contains "delete: Subsystem line preserved" \
        "Subsystem sftp internal-sftp" "${SSHD_CFG}"

    # Unrelated content must remain
    assert_file_contains "delete: Port 22 preserved" \
        "Port 22" "${SSHD_CFG}"

    # Deleting non-managed user: should warn but not fail
    local out
    out=$(run_sut_output delete \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u ghostuser)
    assert_contains "delete non-managed user: warns" "nothing to delete" "${out}"
}

test_dry_run() {
    printf '\n=== dry-run tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    local sshd_snap
    sshd_snap=$(cat "${SSHD_CFG}")

    local out
    out=$(run_sut_output add --dry-run \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u dryuser \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}")

    assert_contains "dry-run add: output says DRY-RUN" "DRY-RUN" "${out}"
    assert_eq "dry-run add: sshd_config not modified" "${sshd_snap}" "$(cat "${SSHD_CFG}")"
    assert_file_absent "dry-run add: no service file created" "${SYSTEMD_SERVICE}"
    assert_file_absent "dry-run add: no key file created" "${AUTHKEYS_DIR}/dryuser"

    # Add for real, then dry-run delete
    run_sut add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u dryuser \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}" >/dev/null 2>&1

    sshd_snap=$(cat "${SSHD_CFG}")
    local service_snap
    service_snap=$(cat "${SYSTEMD_SERVICE}")

    out=$(run_sut_output delete --dry-run \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u dryuser)

    assert_contains "dry-run delete: output says DRY-RUN" "DRY-RUN" "${out}"
    assert_eq "dry-run delete: sshd_config not modified" "${sshd_snap}" "$(cat "${SSHD_CFG}")"
    assert_eq "dry-run delete: service not modified" "${service_snap}" "$(cat "${SYSTEMD_SERVICE}")"
    assert_file_exists "dry-run delete: key file still present" "${AUTHKEYS_DIR}/dryuser"

    # Clean up
    run_sut delete \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u dryuser >/dev/null 2>&1
}

test_list_output() {
    printf '\n=== list output tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    local BACKUP_SRC_B="${TMPBASE}/backup_b"
    local BACKUP_SRC_C="${TMPBASE}/backup_c"
    mkdir -p "${BACKUP_SRC_B}" "${BACKUP_SRC_C}"

    # Add three users out of alphabetical order
    run_sut add -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u zuser -k "${TEST_KEY_ED}" -d "${BACKUP_SRC}" >/dev/null 2>&1
    run_sut add -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u auser -k "${TEST_KEY_ED}" -d "${BACKUP_SRC_B}" >/dev/null 2>&1
    run_sut add -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u muser -k "${TEST_KEY_ED2}" -d "${BACKUP_SRC_C}" >/dev/null 2>&1

    local out
    out=$(run_sut_output list \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}")

    # Check sorted order
    local users_in_order
    users_in_order=$(printf '%s\n' "${out}" | grep -v '^USER' | awk '{print $1}' | tr '\n' ' ')
    assert_eq "list output is sorted" "auser muser zuser " "${users_in_order}"

    # Check correct directory reported
    assert_contains "list: zuser has correct dir" "${BACKUP_SRC}" "${out}"
    assert_contains "list: auser has correct dir" "${BACKUP_SRC_B}" "${out}"
    assert_contains "list: muser has correct dir" "${BACKUP_SRC_C}" "${out}"

    # Second run must produce identical output (deterministic)
    local out2
    out2=$(run_sut_output list \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}")
    assert_eq "list output is deterministic" "${out}" "${out2}"

    # --minimal-list: only USER and DIRECTORY columns
    local out_min
    out_min=$(run_sut_output list --minimal-list \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}")
    assert_contains     "minimal-list: header has USER"      "USER"          "${out_min}"
    assert_contains     "minimal-list: header has DIRECTORY" "DIRECTORY"     "${out_min}"
    assert_not_contains "minimal-list: header has no PUBLIC_KEY" "PUBLIC_KEY" "${out_min}"
    assert_contains     "minimal-list: auser dir present"   "${BACKUP_SRC_B}" "${out_min}"
    assert_not_contains "minimal-list: key absent"          "${TEST_KEY_ED}"  "${out_min}"
    # Each data line must have exactly 2 tab-separated fields
    local bad_field_count
    bad_field_count=$(printf '%s\n' "${out_min}" | tail -n +2 | awk -F'\t' 'NF!=2' | wc -l)
    assert_eq "minimal-list: every data row has exactly 2 fields" "0" "${bad_field_count}"

    # -m short form works identically
    local out_m
    out_m=$(run_sut_output list -m \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}")
    assert_eq "minimal-list: -m and --minimal-list identical" "${out_min}" "${out_m}"

    # Clean up
    for u in zuser auser muser; do
        run_sut delete -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
            -u "${u}" >/dev/null 2>&1
    done
}

test_multiple_users_no_interference() {
    printf '\n=== multi-user isolation tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    local SRC_A="${TMPBASE}/src_a" SRC_B="${TMPBASE}/src_b"
    mkdir -p "${SRC_A}" "${SRC_B}"

    run_sut add -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u alice -k "${TEST_KEY_ED}" -d "${SRC_A}" >/dev/null 2>&1
    run_sut add -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u bob   -k "${TEST_KEY_ED2}" -d "${SRC_B}" >/dev/null 2>&1

    # Delete alice; bob's blocks must be intact
    run_sut delete -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u alice >/dev/null 2>&1

    assert_file_not_contains "alice SSH block gone" \
        "# BEGIN backup_access alice" "${SSHD_CFG}"
    assert_file_contains "bob SSH block intact" \
        "# BEGIN backup_access bob" "${SSHD_CFG}"
    assert_file_not_contains "alice service block gone" \
        "# BEGIN backup_access alice" "${SYSTEMD_SERVICE}"
    assert_file_contains "bob service block intact" \
        "# BEGIN backup_access bob" "${SYSTEMD_SERVICE}"
    assert_file_absent "alice key gone" "${AUTHKEYS_DIR}/alice"
    assert_file_exists "bob key intact" "${AUTHKEYS_DIR}/bob"

    # Clean up
    run_sut delete -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u bob >/dev/null 2>&1
}

test_list_empty() {
    printf '\n=== list on empty config (regression: grep pipefail) ===\n'
    reset_sshd_cfg
    reset_service

    # Config files exist but contain zero managed blocks (service file absent).
    # Prior to the fix, grep exiting 1 (no matches) propagated through the
    # pipefail pipeline and triggered the ERR trap at the call site in cmd_list.
    local out rc=0
    out=$(run_sut_output list \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}") || rc=$?

    assert_eq  "list empty: exits 0"               "0"                    "${rc}"
    assert_contains "list empty: reports no users" "No managed users found" "${out}"
    assert_not_contains "list empty: no ERR trap"  "Unexpected error"       "${out}"
}

test_sshd_validation_failure() {
    printf '\n=== sshd validation failure tests ===\n'
    _write_fake_id

    # Inject INVALID_SYNTAX into the config so fake sshd -t returns 1
    reset_sshd_cfg
    printf 'INVALID_SYNTAX\n' >> "${SSHD_CFG}"

    local out
    out=$(run_sut_output add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u valtest \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}")

    assert_contains "sshd validation failure: script aborts" "validation failed" "${out}"
    assert_file_not_contains "sshd validation failure: block not written" \
        "# BEGIN backup_access valtest" "${SSHD_CFG}"

    reset_sshd_cfg
}

test_conflicting_subsystem_preflight() {
    printf '\n=== conflicting Subsystem pre-flight: no side effects ===\n'
    _write_fake_id
    reset_service

    # Simulate sshd_config with a conflicting Subsystem sftp line (the real-world
    # trigger: Ubuntu ships "Subsystem sftp /usr/lib/openssh/sftp-server").
    reset_sshd_cfg
    printf 'Subsystem sftp /usr/lib/openssh/sftp-server\n' >> "${SSHD_CFG}"

    local out
    out=$(run_sut_output add \
        -r "${REMOUNT_ROOT}" \
        -s "${SSHD_CFG}" \
        -a "${AUTHKEYS_DIR}" \
        -u preflightuser \
        -k "${TEST_KEY_ED}" \
        -d "${BACKUP_SRC}")

    # Must abort with a clear message
    assert_contains "preflight: reports conflicting Subsystem" "Conflicting" "${out}"

    # Must not have created any side effects before the abort
    assert_file_absent "preflight: no service file created" \
        "${SYSTEMD_SERVICE}"
    assert_file_absent "preflight: no key file written" \
        "${AUTHKEYS_DIR}/preflightuser"
    assert_file_not_contains "preflight: no SSH block written" \
        "# BEGIN backup_access preflightuser" "${SSHD_CFG}"
    # OS user must not have been created
    local out2
    out2=$(run_sut_output list \
        -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}")
    assert_not_contains "preflight: user not listed" "preflightuser" "${out2}"

    reset_sshd_cfg
}

test_admin_recreate_mounts() {
    printf '\n=== admin-recreate-mounts tests ===\n'
    _write_fake_id
    reset_sshd_cfg
    reset_service

    local SRC_A="${TMPBASE}/src_a" SRC_B="${TMPBASE}/src_b" SRC_C="${TMPBASE}/src_c"
    mkdir -p "${SRC_A}" "${SRC_B}" "${SRC_C}"

    # --- Setup: add two users normally ---
    run_sut add -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u alpha -k "${TEST_KEY_ED}" -d "${SRC_A}" >/dev/null 2>&1
    run_sut add -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
        -u beta  -k "${TEST_KEY_ED2}" -d "${SRC_B}" >/dev/null 2>&1

    # --- Scenario 1: everything consistent → no changes needed ---
    local out
    out=$(run_sut_output admin-recreate-mounts \
        -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}")
    assert_contains "consistent: no changes needed" "No changes needed" "${out}"

    # --- Scenario 2: unmounted entry → should mount it ---
    # Simulate alpha's mount being lost (remove from fake mounts tracking)
    local mp_alpha="${REMOUNT_ROOT}/alpha/backups"
    grep -vxF "${mp_alpha}" "${FAKE_MOUNTS}" > "${FAKE_MOUNTS}.tmp" || true
    mv "${FAKE_MOUNTS}.tmp" "${FAKE_MOUNTS}"
    # Verify it's no longer "mounted"
    assert_exits_fail "alpha unmounted" \
        bash -c "grep -qxF '${mp_alpha}' '${FAKE_MOUNTS}'"

    out=$(run_sut_output admin-recreate-mounts \
        -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}")
    assert_contains "remount: alpha mounted" "Mounted" "${out}"
    # Verify alpha is now mounted again
    assert_exits_ok "alpha remounted check" \
        bash -c "grep -qxF '${mp_alpha}' '${FAKE_MOUNTS}'"

    # --- Scenario 3: orphaned service entry → should remove it ---
    # Manually inject an orphan entry into the service file (a user not in sshd_config)
    local orphan_block
    orphan_block=$(printf '# BEGIN backup_access orphan\nExecStart=/bin/mount --bind %s %s/orphan/backups\nExecStart=/bin/mount -o remount,ro,bind %s/orphan/backups\nExecStop=-/bin/umount %s/orphan/backups\n# END backup_access orphan' \
        "${SRC_C}" "${REMOUNT_ROOT}" "${REMOUNT_ROOT}" "${REMOUNT_ROOT}")
    # Insert before [Install] in the service file
    local tmp_svc
    tmp_svc=$(mktemp)
    while IFS= read -r line; do
        if [[ "${line}" == "[Install]" ]]; then
            printf '%s\n\n' "${orphan_block}" >> "${tmp_svc}"
        fi
        printf '%s\n' "${line}" >> "${tmp_svc}"
    done < "${SYSTEMD_SERVICE}"
    cp "${tmp_svc}" "${SYSTEMD_SERVICE}"
    rm -f "${tmp_svc}"

    assert_file_contains "orphan injected" \
        "# BEGIN backup_access orphan" "${SYSTEMD_SERVICE}"

    out=$(run_sut_output admin-recreate-mounts \
        -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}")
    assert_contains "orphan: detected" "Orphaned service entry" "${out}"
    assert_file_not_contains "orphan: removed from service" \
        "# BEGIN backup_access orphan" "${SYSTEMD_SERVICE}"
    # Non-orphan entries must survive
    assert_file_contains "orphan: alpha still in service" \
        "# BEGIN backup_access alpha" "${SYSTEMD_SERVICE}"
    assert_file_contains "orphan: beta still in service" \
        "# BEGIN backup_access beta" "${SYSTEMD_SERVICE}"

    # --- Scenario 4: user in sshd_config but no service entry → should warn ---
    # Manually add an SSH block for 'gamma' without a service entry
    local gamma_ssh_block
    gamma_ssh_block=$(printf '# BEGIN backup_access gamma\nMatch User gamma\n    ChrootDirectory %s/gamma\n    ForceCommand internal-sftp -R -d /backups\n# END backup_access gamma' \
        "${REMOUNT_ROOT}")
    printf '\n%s\n' "${gamma_ssh_block}" >> "${SSHD_CFG}"

    out=$(run_sut_output admin-recreate-mounts \
        -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}")
    assert_contains "missing entry: warns about gamma" "No service entry" "${out}"
    assert_contains "missing entry: suggests modify" "modify" "${out}"

    # --- Scenario 5: dry-run → no changes ---
    # Remove alpha's mount again to have a pending change
    grep -vxF "${mp_alpha}" "${FAKE_MOUNTS}" > "${FAKE_MOUNTS}.tmp" || true
    mv "${FAKE_MOUNTS}.tmp" "${FAKE_MOUNTS}"

    local service_snap
    service_snap=$(cat "${SYSTEMD_SERVICE}")

    out=$(run_sut_output admin-recreate-mounts --dry-run \
        -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}")
    assert_contains "dry-run: says DRY-RUN" "DRY-RUN" "${out}"
    assert_eq "dry-run: service unchanged" "${service_snap}" "$(cat "${SYSTEMD_SERVICE}")"
    # Alpha should still be unmounted (dry-run didn't mount it)
    assert_exits_fail "dry-run: alpha still unmounted" \
        bash -c "grep -qxF '${mp_alpha}' '${FAKE_MOUNTS}'"

    # Clean up
    for u in alpha beta; do
        run_sut delete -r "${REMOUNT_ROOT}" -s "${SSHD_CFG}" -a "${AUTHKEYS_DIR}" \
            -u "${u}" >/dev/null 2>&1
    done
    # Remove the manually added gamma SSH block
    reset_sshd_cfg
    reset_service
}

test_help_flag() {
    printf '\n=== help and flag tests ===\n'

    local out
    out=$(bash "${SUT}" --help 2>&1 || true)
    assert_contains "help: SYNOPSIS present" "SYNOPSIS" "${out}"
    assert_contains "help: EXAMPLES present" "EXAMPLES" "${out}"
    assert_contains "help: --dry-run documented" "--dry-run" "${out}"

    out=$(bash "${SUT}" -h 2>&1 || true)
    assert_contains "-h also shows help" "SYNOPSIS" "${out}"

    out=$(bash "${SUT}" 2>&1 || true)
    assert_contains "no args shows help" "SYNOPSIS" "${out}"

    out=$(bash "${SUT}" -i 2>&1 || true)
    assert_contains "-i shows version" "1.2.0" "${out}"
    assert_contains "-i shows script name" "backup_access" "${out}"

    out=$(bash "${SUT}" --info 2>&1 || true)
    assert_contains "--info shows version" "1.2.0" "${out}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    printf 'backup_access.sh test harness\n'
    printf 'SUT: %s\n' "${SUT}"

    setup_fixtures
    trap teardown_fixtures EXIT

    test_help_flag
    test_validation
    test_sshd_config_subsystem
    test_sshd_config_block
    test_systemd_service_block
    test_add_idempotency
    test_modify
    test_delete
    test_dry_run
    test_list_output
    test_multiple_users_no_interference
    test_list_empty
    test_sshd_validation_failure
    test_conflicting_subsystem_preflight
    test_admin_recreate_mounts

    printf '\n=== Results ===\n'
    printf 'PASS: %d\n' "${PASS}"
    printf 'FAIL: %d\n' "${FAIL}"

    [[ "${FAIL}" -eq 0 ]]
}

main "$@"
