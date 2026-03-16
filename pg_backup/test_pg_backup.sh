#!/usr/bin/env bash
# test_pg_backup.sh
# Self-contained test harness for pg_backup.sh.
# Runs entirely in a temporary directory tree; never needs a real PostgreSQL
# server.  All external commands (pg_dump, ssh, sshpass, lsof, ss) are
# replaced with lightweight stubs.
#
# Usage:
#   bash test_pg_backup.sh [--verbose | -v]

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/pg_backup.sh"
[[ -f "${SUT}" ]] || { echo "ERROR: pg_backup.sh not found at ${SUT}"; exit 1; }

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

TMPBASE=""          # set in setup_fixtures
FAKE_BIN=""         # directory with stub commands
FAKE_LOG=""         # log of stub invocations
BACKUP_ROOT=""      # --backup-dir target

# Standard arguments used by most tests (dry-run mode, so no real pg_dump needed)
STD_ARGS=()

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
assert_contains_regex() {
    local label="$1" pattern="$2" haystack="$3"
    if printf '%s' "${haystack}" | grep -qE -- "${pattern}"; then
        pass "${label}"
    else
        fail "${label}"
        printf '       pattern:   %q\n' "${pattern}"
        printf '       haystack:  %q\n' "${haystack}"
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
assert_file_exists() {
    local label="$1" file="$2"
    if [[ -f "${file}" ]]; then pass "${label}"; else fail "${label}: missing ${file}"; fi
}
assert_file_absent() {
    local label="$1" file="$2"
    if [[ ! -f "${file}" ]]; then pass "${label}"; else fail "${label}: unexpected file ${file}"; fi
}
assert_exit_code() {
    local label="$1" expected="$2"; shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    assert_eq "${label}" "${expected}" "${rc}"
}

# Run the SUT with fake PATH prepended.  Captures combined stdout+stderr.
run_sut() {
    PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" "$@" 2>&1 || true
}

# Run expecting a specific exit code; return the output.
run_sut_rc() {
    local rc=0
    PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" "$@" 2>&1 || rc=$?
    return "${rc}"
}

# ---------------------------------------------------------------------------
# Fixture setup / teardown
# ---------------------------------------------------------------------------
setup_fixtures() {
    TMPBASE=$(mktemp -d /tmp/pgb_test.XXXXXXXXXX)
    FAKE_BIN="${TMPBASE}/bin"
    FAKE_LOG="${TMPBASE}/cmd.log"
    BACKUP_ROOT="${TMPBASE}/backups"

    mkdir -p "${FAKE_BIN}" "${BACKUP_ROOT}"
    touch "${FAKE_LOG}"

    _write_fake_commands

    STD_ARGS=(
        --database-server db.example.com
        --database-user backupuser
        --database-password 'S3cret!'
        --database-name testdb
        --backup-dir "${BACKUP_ROOT}"
        --retention-time 14d
    )
}

teardown_fixtures() {
    [[ -n "${TMPBASE}" && -d "${TMPBASE}" ]] && rm -rf "${TMPBASE}" || true
}

_write_fake_commands() {
    # --- fake pg_dump (v16.3): writes a non-empty file to -f target ---
    cat > "${FAKE_BIN}/pg_dump" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "pg_dump (PostgreSQL) 16.3"
    exit 0
fi
# Find the -f argument and write dummy data there
outfile=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) outfile="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "${outfile}" ]]; then
    echo "FAKE_PG_DUMP_OUTPUT" > "${outfile}"
fi
exit 0
STUB

    # --- fake pg_dump that fails ---
    cat > "${FAKE_BIN}/pg_dump_fail" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "pg_dump (PostgreSQL) 16.3"
    exit 0
fi
exit 1
STUB

    # --- fake pg_dump v8.4 (old, no -d support) ---
    cat > "${FAKE_BIN}/pg_dump-8.4" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "pg_dump (PostgreSQL) 8.4.22"
    exit 0
fi
outfile=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) outfile="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "${outfile}" ]]; then
    echo "FAKE_PG_DUMP_84_OUTPUT" > "${outfile}"
fi
exit 0
STUB

    # --- fake pg_dump v9.3 (supports -d) ---
    cat > "${FAKE_BIN}/pg_dump-9.3" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "pg_dump (PostgreSQL) 9.3.25"
    exit 0
fi
outfile=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) outfile="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "${outfile}" ]]; then
    echo "FAKE_PG_DUMP_93_OUTPUT" > "${outfile}"
fi
exit 0
STUB

    # --- fake ssh: log the call and exit 0 ---
    cat > "${FAKE_BIN}/ssh" <<STUB
#!/usr/bin/env bash
printf 'ssh %s\n' "\$*" >> "${FAKE_LOG}"
exit 0
STUB

    # --- fake sshpass: log the call and exec the rest ---
    cat > "${FAKE_BIN}/sshpass" <<STUB
#!/usr/bin/env bash
printf 'sshpass %s\n' "\$*" >> "${FAKE_LOG}"
# Skip -p <password> then exec remaining args
shift 2
exec "\$@"
STUB

    # --- fake lsof: return a fake PID ---
    cat > "${FAKE_BIN}/lsof" <<'STUB'
#!/usr/bin/env bash
echo "99999"
exit 0
STUB

    # --- fake ss: no output (fallback path) ---
    cat > "${FAKE_BIN}/ss" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

    chmod +x "${FAKE_BIN}"/*
}

# ---------------------------------------------------------------------------
# Test groups
# ---------------------------------------------------------------------------

test_help_and_version() {
    printf '\n=== help and version tests ===\n'

    local out
    out=$(run_sut --help)
    assert_contains "help: shows Usage" "Usage:" "${out}"
    assert_contains "help: shows --database-server" "--database-server" "${out}"
    assert_contains "help: shows SSH tunnel section" "--ssh-host" "${out}"
    assert_contains "help: shows --ssh-password" "--ssh-password" "${out}"

    out=$(run_sut -h)
    assert_contains "-h also shows help" "Usage:" "${out}"

    out=$(run_sut --version)
    assert_eq "version: prints version string" "1.2.0" "${out}"

    out=$(run_sut -v)
    assert_eq "-v also prints version" "1.2.0" "${out}"
}

test_missing_required_args() {
    printf '\n=== missing required arguments tests ===\n'

    local out

    # No arguments at all
    out=$(run_sut)
    assert_contains "no args: error about missing options" "ERROR: Missing required options" "${out}"

    # Missing --database-server only
    out=$(run_sut --database-user u --database-password p \
                  --database-name db --backup-dir /tmp --retention-time 7d)
    assert_contains "missing --database-server" "--database-server" "${out}"

    # Missing --database-user only
    out=$(run_sut --database-server h --database-password p \
                  --database-name db --backup-dir /tmp --retention-time 7d)
    assert_contains "missing --database-user" "--database-user" "${out}"

    # Missing --database-password only
    out=$(run_sut --database-server h --database-user u \
                  --database-name db --backup-dir /tmp --retention-time 7d)
    assert_contains "missing --database-password" "--database-password" "${out}"

    # Missing --database-name only
    out=$(run_sut --database-server h --database-user u --database-password p \
                  --backup-dir /tmp --retention-time 7d)
    assert_contains "missing --database-name" "--database-name" "${out}"

    # Missing --backup-dir only
    out=$(run_sut --database-server h --database-user u --database-password p \
                  --database-name db --retention-time 7d)
    assert_contains "missing --backup-dir" "--backup-dir" "${out}"

    # Missing --retention-time only
    out=$(run_sut --database-server h --database-user u --database-password p \
                  --database-name db --backup-dir /tmp)
    assert_contains "missing --retention-time" "--retention-time" "${out}"

    # Multiple missing
    out=$(run_sut --database-server h)
    assert_contains "multiple missing: --database-user" "--database-user" "${out}"
    assert_contains "multiple missing: --database-password" "--database-password" "${out}"
    assert_contains "multiple missing: --database-name" "--database-name" "${out}"
}

test_unknown_option() {
    printf '\n=== unknown option test ===\n'

    local out
    out=$(run_sut --database-server h --nonsense-flag foo)
    assert_contains "unknown option rejected" "Unknown option" "${out}"
}

test_invalid_retention_time() {
    printf '\n=== invalid retention time tests ===\n'

    local out

    out=$(run_sut --dry-run "${STD_ARGS[@]:0:10}" --retention-time "abc")
    assert_contains "invalid retention 'abc'" "Invalid retention-time" "${out}"

    out=$(run_sut --dry-run "${STD_ARGS[@]:0:10}" --retention-time "7x")
    assert_contains "invalid retention '7x'" "Invalid retention-time" "${out}"

    out=$(run_sut --dry-run "${STD_ARGS[@]:0:10}" --retention-time "")
    assert_contains "empty retention" "Missing required options" "${out}"
}

test_valid_retention_formats() {
    printf '\n=== valid retention format tests ===\n'

    local out

    # Days
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name retdays --backup-dir "${BACKUP_ROOT}" --retention-time 14d)
    assert_contains "14d retention: completes" "Completed successfully" "${out}"
    rm -rf "${BACKUP_ROOT}/retdays"

    # Weeks
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name retweeks --backup-dir "${BACKUP_ROOT}" --retention-time 2w)
    assert_contains "2w retention: completes" "Completed successfully" "${out}"
    rm -rf "${BACKUP_ROOT}/retweeks"

    # Hours
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name rethours --backup-dir "${BACKUP_ROOT}" --retention-time 36h)
    assert_contains "36h retention: completes" "Completed successfully" "${out}"
    rm -rf "${BACKUP_ROOT}/rethours"

    # Minutes
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name retmins --backup-dir "${BACKUP_ROOT}" --retention-time 90m)
    assert_contains "90m retention: completes" "Completed successfully" "${out}"
    rm -rf "${BACKUP_ROOT}/retmins"

    # Bare number (days)
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name retbare --backup-dir "${BACKUP_ROOT}" --retention-time 7)
    assert_contains "bare number retention: completes" "Completed successfully" "${out}"
    rm -rf "${BACKUP_ROOT}/retbare"
}

test_dry_run_basic() {
    printf '\n=== dry-run basic tests ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}")

    assert_contains "dry-run: output says DRY-RUN" "[DRY-RUN]" "${out}"
    assert_contains "dry-run: mentions database name" "testdb" "${out}"
    assert_contains "dry-run: mentions server" "db.example.com" "${out}"
    assert_contains "dry-run: completes successfully" "Completed successfully" "${out}"

    # Verify backup file was created
    local dump_files
    dump_files=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump" 2>/dev/null | wc -l)
    assert_eq "dry-run: dump file created" "1" "${dump_files}"

    # Verify checksum file was created
    local chk_files
    chk_files=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump.sha256" 2>/dev/null | wc -l)
    assert_eq "dry-run: checksum file created" "1" "${chk_files}"

    # Verify dump file content
    local dump_file
    dump_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump" | head -1)
    assert_file_contains "dry-run: dump has simulation header" "[DRY-RUN] PostgreSQL Backup Simulation" "${dump_file}"
    assert_file_contains "dry-run: dump has database name" "Database:   testdb" "${dump_file}"
    assert_file_contains "dry-run: dump has server" "Server:     db.example.com" "${dump_file}"
    assert_file_contains "dry-run: dump has port" "Port:       5432" "${dump_file}"
    assert_file_contains "dry-run: dump has user" "User:       backupuser" "${dump_file}"

    # Verify checksum file contains valid sha256sum output
    local chk_file
    chk_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump.sha256" | head -1)
    assert_file_contains "dry-run: checksum references dump file" "testdb-" "${chk_file}"

    # Clean up for next tests
    rm -rf "${BACKUP_ROOT}/testdb"
}

test_dry_run_custom_port() {
    printf '\n=== dry-run custom port test ===\n'

    local out
    out=$(run_sut --dry-run \
        --database-server db.example.com \
        --database-port 5433 \
        --database-user backupuser \
        --database-password 'S3cret!' \
        --database-name portdb \
        --backup-dir "${BACKUP_ROOT}" \
        --retention-time 7d)

    assert_contains "custom port: mentions 5433" "5433" "${out}"
    assert_contains "custom port: completes" "Completed successfully" "${out}"

    local dump_file
    dump_file=$(find "${BACKUP_ROOT}/portdb" -name "portdb-*.dump" | head -1)
    assert_file_contains "custom port: dump has port 5433" "Port:       5433" "${dump_file}"

    rm -rf "${BACKUP_ROOT}/portdb"
}

test_real_backup_with_fake_pg_dump() {
    printf '\n=== real backup (fake pg_dump) tests ===\n'

    local out
    out=$(run_sut "${STD_ARGS[@]}")

    assert_not_contains "real backup: no DRY-RUN" "[DRY-RUN]" "${out}"
    assert_contains "real backup: starting message" "Starting backup" "${out}"
    assert_contains "real backup: completed" "completed successfully" "${out}"

    # Verify dump file
    local dump_file
    dump_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump" | head -1)
    assert_file_exists "real backup: dump file exists" "${dump_file}"
    assert_file_contains "real backup: dump has fake pg_dump output" "FAKE_PG_DUMP_OUTPUT" "${dump_file}"

    # Verify checksum
    local chk_file
    chk_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump.sha256" | head -1)
    assert_file_exists "real backup: checksum file exists" "${chk_file}"

    # Verify checksum is valid
    local chk_ok=0
    ( cd "${BACKUP_ROOT}/testdb" && sha256sum -c "$(basename "${chk_file}")" >/dev/null 2>&1 ) && chk_ok=1
    assert_eq "real backup: checksum verifies" "1" "${chk_ok}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_pg_dump_failure() {
    printf '\n=== pg_dump failure test ===\n'

    # Replace pg_dump with a failing version
    cp "${FAKE_BIN}/pg_dump_fail" "${FAKE_BIN}/pg_dump_orig"
    cp "${FAKE_BIN}/pg_dump" "${FAKE_BIN}/pg_dump_good"
    cp "${FAKE_BIN}/pg_dump_fail" "${FAKE_BIN}/pg_dump"

    local out rc=0
    out=$(PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" "${STD_ARGS[@]}" 2>&1) || rc=$?

    assert_eq "pg_dump failure: non-zero exit" "1" "${rc}"
    assert_contains "pg_dump failure: error message" "pg_dump failed" "${out}"

    # Restore working pg_dump
    cp "${FAKE_BIN}/pg_dump_good" "${FAKE_BIN}/pg_dump"
    rm -f "${FAKE_BIN}/pg_dump_orig" "${FAKE_BIN}/pg_dump_good"
    rm -rf "${BACKUP_ROOT}/testdb"
}

test_pg_dump_version_discovery() {
    printf '\n=== pg_dump version discovery tests ===\n'

    local out
    out=$(run_sut -pv)

    assert_contains "pv: shows pg_dump version" "16.3" "${out}"
    assert_contains "pv: shows binary path" "pg_dump" "${out}"

    # -pv with version selection
    out=$(run_sut -pv 16.3 --dry-run "${STD_ARGS[@]}")
    assert_contains "pv 16.3: selects correct version" "v16.3" "${out}"
    assert_contains "pv 16.3: completes" "Completed successfully" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_pg_dump_version_not_found() {
    printf '\n=== pg_dump version not found test ===\n'

    local out rc=0
    out=$(PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" \
        --pg-dump-version 99.99 --dry-run "${STD_ARGS[@]}" 2>&1) || rc=$?

    assert_eq "version not found: exit 64" "64" "${rc}"
    assert_contains "version not found: error message" "not available" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_pg_dump_version_selection() {
    printf '\n=== pg_dump --pg-dump-version selection test ===\n'

    local out
    out=$(run_sut --pg-dump-version 16.3 --dry-run "${STD_ARGS[@]}")
    assert_contains "pg-dump-version 16.3: uses selected version" "v16.3" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_backup_directory_structure() {
    printf '\n=== backup directory structure tests ===\n'

    run_sut --dry-run "${STD_ARGS[@]}" >/dev/null

    # Backup dir should be BACKUP_ROOT/DB_NAME
    [[ -d "${BACKUP_ROOT}/testdb" ]]
    assert_eq "backup dir: testdb subdir created" "0" "$?"

    # Lock file should exist
    assert_file_exists "backup dir: lock file present" "${BACKUP_ROOT}/testdb/.pg_backup.lock"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_retention_pruning() {
    printf '\n=== retention pruning tests ===\n'

    local db_dir="${BACKUP_ROOT}/prunedb"
    mkdir -p "${db_dir}"

    # Create old dummy files (use touch with old timestamp)
    touch -d "30 days ago" "${db_dir}/prunedb-20250101T000000Z.dump"
    touch -d "30 days ago" "${db_dir}/prunedb-20250101T000000Z.dump.sha256"
    # Create a recent file that should NOT be pruned
    touch "${db_dir}/prunedb-recent.dump"

    local out
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name prunedb \
        --backup-dir "${BACKUP_ROOT}" \
        --retention-time 7d)

    assert_contains "pruning: mentions pruning" "Pruning" "${out}"

    # Old files should be deleted
    assert_file_absent "pruning: old dump deleted" "${db_dir}/prunedb-20250101T000000Z.dump"
    assert_file_absent "pruning: old checksum deleted" "${db_dir}/prunedb-20250101T000000Z.dump.sha256"
    # Recent non-matching file should remain
    assert_file_exists "pruning: non-matching file preserved" "${db_dir}/prunedb-recent.dump"

    rm -rf "${db_dir}"
}

test_locking() {
    printf '\n=== locking tests ===\n'

    local db_dir="${BACKUP_ROOT}/lockdb"
    mkdir -p "${db_dir}"

    # Acquire the lock manually
    local lockfile="${db_dir}/.pg_backup.lock"
    exec 8>"${lockfile}"
    flock -n 8

    local out
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name lockdb \
        --backup-dir "${BACKUP_ROOT}" \
        --retention-time 7d)

    assert_contains "locking: detects existing lock" "Another backup is running" "${out}"

    # Release lock
    flock -u 8
    exec 8>&-

    rm -rf "${db_dir}"
}

test_checksum_verification() {
    printf '\n=== checksum verification test ===\n'

    run_sut --dry-run "${STD_ARGS[@]}" >/dev/null

    local chk_file
    chk_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump.sha256" | head -1)

    # Verify checksum passes
    local chk_ok=0
    ( cd "${BACKUP_ROOT}/testdb" && sha256sum -c "$(basename "${chk_file}")" >/dev/null 2>&1 ) && chk_ok=1
    assert_eq "checksum: dry-run dump verifies" "1" "${chk_ok}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

# ---------------------------------------------------------------------------
# SSH tunnel tests
# ---------------------------------------------------------------------------

test_ssh_tunnel_dry_run() {
    printf '\n=== SSH tunnel dry-run tests ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-user tunnel \
        --ssh-port 2222)

    assert_contains "ssh dry-run: would open tunnel" "Would open SSH tunnel" "${out}"
    assert_contains "ssh dry-run: mentions ssh host" "jump.example.com" "${out}"
    assert_contains "ssh dry-run: mentions tunnel user" "tunnel@" "${out}"
    assert_contains "ssh dry-run: pg_dump would connect to 127.0.0.1" "127.0.0.1" "${out}"
    assert_contains "ssh dry-run: completes" "Completed successfully" "${out}"

    # Verify the dry-run dump still shows ORIGINAL host, not 127.0.0.1
    local dump_file
    dump_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump" | head -1)
    assert_file_contains "ssh dry-run: dump shows original server" "Server:     db.example.com" "${dump_file}"
    assert_file_contains "ssh dry-run: dump shows original port" "Port:       5432" "${dump_file}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_tunnel_dry_run_with_key() {
    printf '\n=== SSH tunnel dry-run with key tests ===\n'

    # Create a fake key file
    local keyfile="${TMPBASE}/test_key"
    echo "FAKE_KEY" > "${keyfile}"

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-user tunnel \
        --ssh-key "${keyfile}")

    assert_contains "ssh key dry-run: would open tunnel" "Would open SSH tunnel" "${out}"
    assert_contains "ssh key dry-run: mentions key" "${keyfile}" "${out}"
    assert_contains "ssh key dry-run: completes" "Completed successfully" "${out}"

    rm -f "${keyfile}"
    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_tunnel_dry_run_with_password() {
    printf '\n=== SSH tunnel dry-run with password tests ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-user tunnel \
        --ssh-password 'SshPass!')

    assert_contains "ssh pass dry-run: would open tunnel" "Would open SSH tunnel" "${out}"
    assert_contains "ssh pass dry-run: mentions sshpass" "sshpass" "${out}"
    assert_contains "ssh pass dry-run: completes" "Completed successfully" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_tunnel_dry_run_no_user() {
    printf '\n=== SSH tunnel dry-run without --ssh-user ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com)

    assert_contains "ssh no user: would open tunnel" "Would open SSH tunnel" "${out}"
    # Without --ssh-user, SSH_TARGET should be just the host (no user@ prefix)
    assert_contains "ssh no user: target is host only" "jump.example.com" "${out}"
    assert_contains "ssh no user: completes" "Completed successfully" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_tunnel_dry_run_custom_local_port() {
    printf '\n=== SSH tunnel dry-run with custom local port ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-local-port 15432)

    assert_contains "ssh custom port: mentions 15432" "15432" "${out}"
    assert_contains "ssh custom port: completes" "Completed successfully" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_key_and_password_mutually_exclusive() {
    printf '\n=== SSH key + password mutually exclusive test ===\n'

    local keyfile="${TMPBASE}/test_key"
    echo "FAKE_KEY" > "${keyfile}"

    local out rc=0
    out=$(PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-key "${keyfile}" \
        --ssh-password 'SshPass!' 2>&1) || rc=$?

    assert_eq "key+password: exit 64" "64" "${rc}"
    assert_contains "key+password: error message" "mutually exclusive" "${out}"

    rm -f "${keyfile}"
    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_key_not_readable() {
    printf '\n=== SSH key not readable test ===\n'

    local out rc=0
    out=$(PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-key "/nonexistent/key/file" 2>&1) || rc=$?

    assert_eq "key not readable: exit 64" "64" "${rc}"
    assert_contains "key not readable: error message" "not found or not readable" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_password_missing_sshpass() {
    printf '\n=== SSH password without sshpass test ===\n'

    # Remove sshpass from fake bin to simulate it missing
    local sshpass_backup="${TMPBASE}/sshpass_bak"
    mv "${FAKE_BIN}/sshpass" "${sshpass_backup}"

    # Build a PATH that has FAKE_BIN (without sshpass) + system dirs, but
    # shadow any real system sshpass with a non-executable placeholder so
    # that "command -v sshpass" fails.
    local NOSSHPASS_BIN="${TMPBASE}/nosshpass_bin"
    mkdir -p "${NOSSHPASS_BIN}"
    # Create a non-executable sshpass — bash skips non-executable files in
    # PATH, but having it here doesn't help if a real one sits later.
    # Instead, create a wrapper that immediately exits 127.
    cat > "${NOSSHPASS_BIN}/sshpass" <<'STUB'
#!/bin/false
STUB
    # Intentionally NOT chmod +x — "command -v" will skip it.
    # However, if the system has a real sshpass further in PATH, command -v
    # will still find it.  To guarantee hiding it, use a small wrapper trick:
    # override sshpass as an executable that reports itself as missing.
    # (command -v checks executability, so the non-executable placeholder
    # won't shadow a real one.)
    #
    # Robust approach: create an executable sshpass that exits 127 so it
    # appears in command -v but the SUT checks via "command -v ... >/dev/null"
    # which needs exit 0.  Actually command -v itself prints the path and
    # exits 0 if it finds it, regardless of what the script does.
    #
    # Simplest: just delete the placeholder and instead put a small function
    # override via env.  But we can't override builtins from env.
    #
    # Cleanest fix: filter PATH to exclude dirs that contain sshpass.
    rm -f "${NOSSHPASS_BIN}/sshpass"
    local filtered_path="${FAKE_BIN}"
    local IFS_bak="$IFS"
    IFS=':'
    for d in ${PATH}; do
        [[ -x "${d}/sshpass" ]] && continue
        filtered_path="${filtered_path}:${d}"
    done
    IFS="$IFS_bak"

    local out rc=0
    out=$(PATH="${filtered_path}" bash "${SUT}" --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-password 'SshPass!' 2>&1) || rc=$?

    assert_eq "missing sshpass: exit 127" "127" "${rc}"
    assert_contains "missing sshpass: error mentions sshpass" "sshpass" "${out}"
    assert_contains "missing sshpass: install hint for apt" "sudo apt install sshpass" "${out}"
    assert_contains "missing sshpass: install hint for yum" "sudo yum install sshpass" "${out}"
    assert_contains "missing sshpass: install hint for brew" "brew install sshpass" "${out}"

    # Restore sshpass
    mv "${sshpass_backup}" "${FAKE_BIN}/sshpass"
    rm -rf "${NOSSHPASS_BIN}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_tunnel_log_shows_original_host() {
    printf '\n=== SSH tunnel: log shows original host ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com)

    # The "Simulating backup" message should mention original host, not 127.0.0.1
    assert_contains "ssh log: simulating shows original host" "db.example.com:5432" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

# ---------------------------------------------------------------------------
# pg_dump version edge cases
# ---------------------------------------------------------------------------

test_pg_dump_old_version_no_d_flag() {
    printf '\n=== pg_dump old version (no -d) test ===\n'

    # Use the 8.4 fake — the script should pass DB_NAME as positional, not -d
    local out
    out=$(run_sut --pg-dump-version 8.4 "${STD_ARGS[@]}")
    assert_contains "old pg_dump 8.4: completes" "completed successfully" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_pg_dump_93_version_with_d_flag() {
    printf '\n=== pg_dump 9.3 (supports -d) test ===\n'

    local out
    out=$(run_sut --pg-dump-version 9.3 "${STD_ARGS[@]}")
    assert_contains "pg_dump 9.3: completes" "completed successfully" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

# ---------------------------------------------------------------------------
# Multiple backups / isolation tests
# ---------------------------------------------------------------------------

test_multiple_databases_isolation() {
    printf '\n=== multiple databases isolation test ===\n'

    # Backup two different databases
    run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name db_alpha \
        --backup-dir "${BACKUP_ROOT}" --retention-time 7d >/dev/null

    run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name db_beta \
        --backup-dir "${BACKUP_ROOT}" --retention-time 7d >/dev/null

    # Each should have its own subdirectory
    local alpha_dumps beta_dumps
    alpha_dumps=$(find "${BACKUP_ROOT}/db_alpha" -name "db_alpha-*.dump" 2>/dev/null | wc -l)
    beta_dumps=$(find "${BACKUP_ROOT}/db_beta" -name "db_beta-*.dump" 2>/dev/null | wc -l)

    assert_eq "isolation: db_alpha has dump" "1" "${alpha_dumps}"
    assert_eq "isolation: db_beta has dump" "1" "${beta_dumps}"

    # Alpha dir should NOT contain beta files
    local cross_contamination
    cross_contamination=$(find "${BACKUP_ROOT}/db_alpha" -name "db_beta-*" 2>/dev/null | wc -l)
    assert_eq "isolation: no cross-contamination" "0" "${cross_contamination}"

    rm -rf "${BACKUP_ROOT}/db_alpha" "${BACKUP_ROOT}/db_beta"
}

test_backup_file_naming() {
    printf '\n=== backup file naming test ===\n'

    run_sut --dry-run "${STD_ARGS[@]}" >/dev/null

    # Files should match pattern: DB_NAME-YYYYMMDDTHHMMSSZ.dump
    local dump_file
    dump_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump" | head -1)
    local basename_dump
    basename_dump=$(basename "${dump_file}")

    assert_contains_regex "naming: matches timestamp pattern" \
        '^testdb-[0-9]{8}T[0-9]{6}Z\.dump$' "${basename_dump}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_backup_permissions() {
    printf '\n=== backup file permissions test ===\n'

    run_sut --dry-run "${STD_ARGS[@]}" >/dev/null

    # umask 077 means files should be 600 (rw-------)
    local dump_file
    dump_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump" | head -1)
    local perms
    perms=$(stat -c '%a' "${dump_file}")
    assert_eq "permissions: dump is 600" "600" "${perms}"

    local chk_file
    chk_file=$(find "${BACKUP_ROOT}/testdb" -name "testdb-*.dump.sha256" | head -1)
    perms=$(stat -c '%a' "${chk_file}")
    assert_eq "permissions: checksum is 600" "600" "${perms}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_pv_flag_standalone() {
    printf '\n=== -pv flag standalone test ===\n'

    # -pv alone should print versions and exit without requiring other args
    local out rc=0
    out=$(PATH="${FAKE_BIN}:${PATH}" bash "${SUT}" -pv 2>&1) || rc=$?

    assert_eq "-pv standalone: exits 0" "0" "${rc}"
    assert_contains "-pv standalone: shows pg_dump info" "pg_dump" "${out}"
}

test_pv_flag_with_version() {
    printf '\n=== -pv flag with version argument ===\n'

    # -pv with a version should select that version and proceed
    local out
    out=$(run_sut -pv 16.3 --dry-run "${STD_ARGS[@]}")
    assert_contains "-pv with version: uses 16.3" "v16.3" "${out}"
    assert_contains "-pv with version: completes" "Completed successfully" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_retention_pruning_preserves_recent() {
    printf '\n=== retention pruning preserves recent files ===\n'

    local db_dir="${BACKUP_ROOT}/keepdb"
    mkdir -p "${db_dir}"

    # Create a "recent" backup file (touched now, well within 14d)
    touch "${db_dir}/keepdb-20260315T120000Z.dump"
    touch "${db_dir}/keepdb-20260315T120000Z.dump.sha256"

    local out
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name keepdb \
        --backup-dir "${BACKUP_ROOT}" \
        --retention-time 14d)

    # Recent files should NOT be deleted
    assert_file_exists "recent dump preserved" "${db_dir}/keepdb-20260315T120000Z.dump"
    assert_file_exists "recent checksum preserved" "${db_dir}/keepdb-20260315T120000Z.dump.sha256"

    rm -rf "${db_dir}"
}

test_retention_pruning_ignores_other_files() {
    printf '\n=== retention pruning ignores non-matching files ===\n'

    local db_dir="${BACKUP_ROOT}/otherdb"
    mkdir -p "${db_dir}"

    # Create old file that does NOT match the database name pattern
    touch -d "30 days ago" "${db_dir}/unrelated-file.txt"
    touch -d "30 days ago" "${db_dir}/another.dump"

    local out
    out=$(run_sut --dry-run \
        --database-server h --database-user u --database-password p \
        --database-name otherdb \
        --backup-dir "${BACKUP_ROOT}" \
        --retention-time 1d)

    # Unrelated files should still be there
    assert_file_exists "pruning: unrelated txt preserved" "${db_dir}/unrelated-file.txt"
    assert_file_exists "pruning: non-matching dump preserved" "${db_dir}/another.dump"

    rm -rf "${db_dir}"
}

test_ssh_tunnel_auto_port_selection() {
    printf '\n=== SSH tunnel auto port selection ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com)

    # Should mention a port number in the tunnel output (auto-selected)
    assert_contains_regex "ssh auto-port: mentions a port" "127\.0\.0\.1:[0-9]+" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_tunnel_command_with_key() {
    printf '\n=== SSH tunnel command construction with key ===\n'

    local keyfile="${TMPBASE}/test_key2"
    echo "FAKE_KEY" > "${keyfile}"

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-user tunnel \
        --ssh-key "${keyfile}" \
        --ssh-local-port 15432)

    assert_contains "ssh cmd key: has -i flag" "-i ${keyfile}" "${out}"
    assert_contains "ssh cmd key: has ExitOnForwardFailure" "ExitOnForwardFailure=yes" "${out}"
    assert_contains "ssh cmd key: has StrictHostKeyChecking" "StrictHostKeyChecking=accept-new" "${out}"
    assert_contains "ssh cmd key: has -L forwarding" "127.0.0.1:15432:db.example.com:5432" "${out}"

    rm -f "${keyfile}"
    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_tunnel_command_with_password() {
    printf '\n=== SSH tunnel command construction with password ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-user tunnel \
        --ssh-password 'MyPass' \
        --ssh-local-port 15432)

    assert_contains "ssh cmd pass: has sshpass prefix" "sshpass -p MyPass" "${out}"
    assert_contains "ssh cmd pass: has PreferredAuthentications" "PreferredAuthentications=password" "${out}"
    assert_contains "ssh cmd pass: has -L forwarding" "127.0.0.1:15432:db.example.com:5432" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_default_port() {
    printf '\n=== SSH default port (22) test ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com)

    assert_contains "ssh default port: uses 22" "-p 22" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

test_ssh_custom_port() {
    printf '\n=== SSH custom port test ===\n'

    local out
    out=$(run_sut --dry-run "${STD_ARGS[@]}" \
        --ssh-host jump.example.com \
        --ssh-port 2222)

    assert_contains "ssh custom port: uses 2222" "-p 2222" "${out}"

    rm -rf "${BACKUP_ROOT}/testdb"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    printf 'pg_backup.sh test harness\n'
    printf 'SUT: %s\n' "${SUT}"

    setup_fixtures
    trap teardown_fixtures EXIT

    # Help, version, argument validation
    test_help_and_version
    test_missing_required_args
    test_unknown_option

    # Retention time parsing
    test_invalid_retention_time
    test_valid_retention_formats

    # Dry-run mode
    test_dry_run_basic
    test_dry_run_custom_port

    # Real backup (with fake pg_dump)
    test_real_backup_with_fake_pg_dump
    test_pg_dump_failure

    # pg_dump version management
    test_pg_dump_version_discovery
    test_pg_dump_version_not_found
    test_pg_dump_version_selection
    test_pg_dump_old_version_no_d_flag
    test_pg_dump_93_version_with_d_flag
    test_pv_flag_standalone
    test_pv_flag_with_version

    # Backup structure and artifacts
    test_backup_directory_structure
    test_backup_file_naming
    test_backup_permissions
    test_checksum_verification

    # Locking
    test_locking

    # Retention pruning
    test_retention_pruning
    test_retention_pruning_preserves_recent
    test_retention_pruning_ignores_other_files

    # Multiple databases
    test_multiple_databases_isolation

    # SSH tunnel tests
    test_ssh_tunnel_dry_run
    test_ssh_tunnel_dry_run_with_key
    test_ssh_tunnel_dry_run_with_password
    test_ssh_tunnel_dry_run_no_user
    test_ssh_tunnel_dry_run_custom_local_port
    test_ssh_tunnel_auto_port_selection
    test_ssh_tunnel_command_with_key
    test_ssh_tunnel_command_with_password
    test_ssh_default_port
    test_ssh_custom_port
    test_ssh_tunnel_log_shows_original_host

    # SSH tunnel validation
    test_ssh_key_and_password_mutually_exclusive
    test_ssh_key_not_readable
    test_ssh_password_missing_sshpass

    printf '\n=== Results ===\n'
    printf 'PASS: %d\n' "${PASS}"
    printf 'FAIL: %d\n' "${FAIL}"

    [[ "${FAIL}" -eq 0 ]]
}

main "$@"
