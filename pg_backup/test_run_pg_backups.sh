#!/usr/bin/env bash
# test_run_pg_backups.sh
# Self-contained test harness for run_pg_backups.sh.
# Runs entirely in a temporary directory tree.  The real pg_backup.sh is
# replaced with a stub that logs received arguments so we can verify the
# command-line that run_pg_backups.sh constructs.
#
# Usage:
#   bash test_run_pg_backups.sh [--verbose | -v]

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Locate the script under test
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/run_pg_backups.sh"
[[ -f "${SUT}" ]] || { echo "ERROR: run_pg_backups.sh not found at ${SUT}"; exit 1; }

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

TMPBASE=""          # set in setup_fixtures
FAKE_BACKUP_SH=""   # path to the stub pg_backup.sh
CALL_LOG=""         # file where the stub logs each invocation's args
CONFIG=""           # path to the JSON config written per-test

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

# ---------------------------------------------------------------------------
# Fixture setup / teardown
# ---------------------------------------------------------------------------
setup_fixtures() {
    TMPBASE=$(mktemp -d /tmp/rpb_test.XXXXXXXXXX)
    CALL_LOG="${TMPBASE}/calls.log"
    CONFIG="${TMPBASE}/config.json"
    FAKE_BACKUP_SH="${TMPBASE}/fake_pg_backup.sh"

    touch "${CALL_LOG}"

    # The stub pg_backup.sh: logs all received arguments (one invocation
    # per line, args separated by ASCII unit separator \x1f for safe parsing).
    cat > "${FAKE_BACKUP_SH}" <<STUB
#!/usr/bin/env bash
# Fake pg_backup.sh stub — logs arguments and exits 0.
printf '%s' "\$*" >> "${CALL_LOG}"
printf '\n' >> "${CALL_LOG}"
exit 0
STUB
    chmod +x "${FAKE_BACKUP_SH}"
}

teardown_fixtures() {
    [[ -n "${TMPBASE}" && -d "${TMPBASE}" ]] && rm -rf "${TMPBASE}" || true
}

# Write a JSON config file.  Accepts raw JSON as the argument.
write_config() {
    printf '%s\n' "$1" > "${CONFIG}"
}

# Run the SUT, capturing combined stdout+stderr.
run_sut() {
    bash "${SUT}" "$@" 2>&1 || true
}

# Run the SUT and capture exit code.
run_sut_rc() {
    local rc=0
    bash "${SUT}" "$@" 2>&1 || rc=$?
    return "${rc}"
}

# Reset the call log between tests.
reset_call_log() {
    : > "${CALL_LOG}"
}

# Return the Nth invocation line from the call log (1-based).
call_line() {
    sed -n "${1}p" "${CALL_LOG}"
}

# Count the number of invocations recorded.
call_count() {
    local n
    n=$(grep -c . "${CALL_LOG}" 2>/dev/null) || true
    echo "${n:-0}"
}

# Create a failing stub variant of pg_backup.sh
write_failing_backup_sh() {
    local target="$1"
    cat > "${target}" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${CALL_LOG}"
exit 1
STUB
    chmod +x "${target}"
}

# ---------------------------------------------------------------------------
# Test groups
# ---------------------------------------------------------------------------

test_help_and_version() {
    printf '\n=== help and version tests ===\n'

    local out
    out=$(run_sut --help)
    assert_contains "help: shows Usage" "Usage:" "${out}"
    assert_contains "help: shows --config" "--config" "${out}"

    out=$(run_sut -h)
    assert_contains "-h also shows help" "Usage:" "${out}"

    out=$(run_sut --version)
    assert_eq "version: prints version" "1.2.0" "${out}"

    out=$(run_sut -v)
    assert_eq "-v also prints version" "1.2.0" "${out}"
}

test_unknown_option() {
    printf '\n=== unknown option test ===\n'

    local out rc=0
    out=$(bash "${SUT}" --nonsense 2>&1) || rc=$?
    assert_eq "unknown option: non-zero exit" "64" "${rc}"
    assert_contains "unknown option: error message" "Nieznana opcja" "${out}"
}

test_missing_config_file() {
    printf '\n=== missing config file test ===\n'

    local out rc=0
    out=$(bash "${SUT}" -c "/nonexistent/config_$$.json" 2>&1) || rc=$?
    assert_eq "missing config: non-zero exit" "1" "${rc}"
    assert_contains "missing config: error message" "Brak pliku konfiguracyjnego" "${out}"
}

test_backup_script_not_executable() {
    printf '\n=== backup script not executable test ===\n'

    local bad_script="${TMPBASE}/not_executable.sh"
    echo "#!/bin/bash" > "${bad_script}"
    # Intentionally not chmod +x

    write_config "$(cat <<JSON
{
  "backup_script": "${bad_script}",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [{"name": "db1", "database": "db1"}]
}
JSON
)"

    local out rc=0
    out=$(bash "${SUT}" -c "${CONFIG}" 2>&1) || rc=$?
    assert_eq "not executable: non-zero exit" "1" "${rc}"
    assert_contains "not executable: error message" "nie jest wykonywalny" "${out}"
}

test_empty_backups_array() {
    printf '\n=== empty backups array test ===\n'

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backups": []
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "empty backups: info message" "Brak zada" "${out}"
}

test_single_backup_defaults() {
    printf '\n=== single backup with defaults test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "db.example.com",
  "default_port": 5432,
  "default_user": "backupuser",
  "default_password": "S3cret!",
  "backups": [
    {"name": "mydb", "database": "mydb"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "single default: completes" "Zakończono" "${out}"
    assert_contains "single default: OK status" "OK" "${out}"

    # Verify the stub was called exactly once
    assert_eq "single default: one invocation" "1" "$(call_count)"

    # Verify the arguments passed to pg_backup.sh
    local args
    args=$(call_line 1)
    assert_contains "single default: --database-server" "--database-server db.example.com" "${args}"
    assert_contains "single default: --database-port" "--database-port 5432" "${args}"
    assert_contains "single default: --database-user" "--database-user backupuser" "${args}"
    assert_contains "single default: --database-password" "--database-password S3cret!" "${args}"
    assert_contains "single default: --database-name" "--database-name mydb" "${args}"
    assert_contains "single default: --backup-dir" "--backup-dir /mnt/backups" "${args}"
    assert_contains "single default: --retention-time" "--retention-time 14d" "${args}"
}

test_per_backup_overrides() {
    printf '\n=== per-backup overrides test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/default",
  "default_retention": "14d",
  "default_host": "default-host",
  "default_port": 5432,
  "default_user": "default-user",
  "default_password": "default-pass",
  "backups": [
    {
      "name": "custom",
      "host": "custom-host",
      "port": 5433,
      "user": "custom-user",
      "password": "custom-pass",
      "database": "customdb",
      "backup_dir": "/srv/custom",
      "retention_time": "30d"
    }
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "override: host" "--database-server custom-host" "${args}"
    assert_contains "override: port" "--database-port 5433" "${args}"
    assert_contains "override: user" "--database-user custom-user" "${args}"
    assert_contains "override: password" "--database-password custom-pass" "${args}"
    assert_contains "override: database" "--database-name customdb" "${args}"
    assert_contains "override: backup_dir" "--backup-dir /srv/custom" "${args}"
    assert_contains "override: retention" "--retention-time 30d" "${args}"
}

test_pg_dump_version_default() {
    printf '\n=== default pg_dump_version test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_pg_dump_version": "13.23",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "default pg_dump_version: passed" "--pg-dump-version 13.23" "${args}"
}

test_pg_dump_version_per_backup() {
    printf '\n=== per-backup pg_dump_version override test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_pg_dump_version": "13.23",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1", "pg_dump_version": "15.1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "per-backup pg_dump: uses override" "--pg-dump-version 15.1" "${args}"
    assert_not_contains "per-backup pg_dump: not default" "--pg-dump-version 13.23" "${args}"
}

test_pg_dump_version_none() {
    printf '\n=== no pg_dump_version test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_not_contains "no pg_dump_version: omitted" "--pg-dump-version" "${args}"
}

test_global_dry_run() {
    printf '\n=== global_dry_run test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "global_dry_run": true,
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "global dry-run: log shows true" "global_dry_run=true" "${out}"

    local args
    args=$(call_line 1)
    assert_contains "global dry-run: --dry-run added" "--dry-run" "${args}"
}

test_global_dry_run_no_duplicate() {
    printf '\n=== global_dry_run does not duplicate --dry-run ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "global_dry_run": true,
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1", "options": ["--dry-run"]}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    # Count occurrences of --dry-run
    local count
    count=$(printf '%s' "${args}" | grep -o -- '--dry-run' | wc -l)
    assert_eq "global dry-run: no duplicate --dry-run" "1" "${count}"
}

test_global_dry_run_false() {
    printf '\n=== global_dry_run=false does not add --dry-run ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "global_dry_run": false,
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_not_contains "dry-run false: no --dry-run" "--dry-run" "${args}"
}

test_options_array() {
    printf '\n=== options array passthrough test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1", "options": ["--dry-run"]}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "options array: --dry-run passed" "--dry-run" "${args}"
}

test_missing_required_fields_skips() {
    printf '\n=== missing required fields: backup skipped ===\n'
    reset_call_log

    # Use explicitly empty strings to trigger the -z check in the SUT.
    # (jq -r returns "null" for missing fields, which is non-empty;
    # only literal "" in JSON produces a truly empty string.)
    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "",
  "default_user": "",
  "default_password": "",
  "backups": [
    {"name": "incomplete", "database": "db1"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "missing fields: skipped message" "Pominięto" "${out}"
    assert_eq "missing fields: zero invocations" "0" "$(call_count)"
}

test_missing_host_skips() {
    printf '\n=== missing host (empty default): backup skipped ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "",
  "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "nohost", "database": "db1"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "missing host: skipped" "Pominięto" "${out}"
    assert_eq "missing host: zero invocations" "0" "$(call_count)"
}

test_missing_database_skips() {
    printf '\n=== empty database field: backup skipped ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "nodb", "database": ""}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "missing database: skipped" "Pominięto" "${out}"
    assert_eq "missing database: zero invocations" "0" "$(call_count)"
}

test_multiple_backups() {
    printf '\n=== multiple backups test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"},
    {"name": "db2", "database": "db2"},
    {"name": "db3", "database": "db3"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")

    assert_eq "multiple: three invocations" "3" "$(call_count)"
    assert_contains "multiple: db1 logged" "[db1]" "${out}"
    assert_contains "multiple: db2 logged" "[db2]" "${out}"
    assert_contains "multiple: db3 logged" "[db3]" "${out}"

    # Each invocation gets the correct database
    assert_contains "multiple: call 1 has db1" "--database-name db1" "$(call_line 1)"
    assert_contains "multiple: call 2 has db2" "--database-name db2" "$(call_line 2)"
    assert_contains "multiple: call 3 has db3" "--database-name db3" "$(call_line 3)"
}

test_mixed_valid_and_invalid() {
    printf '\n=== mixed valid and invalid backups ===\n'
    reset_call_log

    # Use an empty database to trigger the skip (jq returns "null" for
    # missing fields, which is non-empty; only "" triggers -z).
    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "good1", "database": "good1"},
    {"name": "bad1", "database": ""},
    {"name": "good2", "database": "good2"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")

    assert_eq "mixed: two invocations (one skipped)" "2" "$(call_count)"
    assert_contains "mixed: bad1 skipped" "Pominięto" "${out}"
    assert_contains "mixed: good1 OK" "[good1] OK" "${out}"
    assert_contains "mixed: good2 OK" "[good2] OK" "${out}"
}

test_backup_failure_reporting() {
    printf '\n=== backup failure reporting test ===\n'
    reset_call_log

    local failing_sh="${TMPBASE}/failing_pg_backup.sh"
    write_failing_backup_sh "${failing_sh}"

    write_config "$(cat <<JSON
{
  "backup_script": "${failing_sh}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "faildb", "database": "faildb"},
    {"name": "afterfail", "database": "afterfail"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")

    assert_contains "failure: reports error for faildb" "BŁĄD" "${out}"
    assert_contains "failure: reports error for faildb by name" "[faildb]" "${out}"
    # Script should continue after failure and process next backup
    assert_eq "failure: both backups attempted" "2" "$(call_count)"
    assert_contains "failure: completes all tasks" "Zakończono" "${out}"
}

test_default_port_fallback() {
    printf '\n=== default port fallback (5432) test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "default port: 5432" "--database-port 5432" "${args}"
}

test_default_retention_fallback() {
    printf '\n=== default retention fallback (14d) test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "default retention: 14d" "--retention-time 14d" "${args}"
}

test_default_backup_root_fallback() {
    printf '\n=== default backup_root fallback test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "default backup_root: /mnt/dane/Backup" "--backup-dir /mnt/dane/Backup" "${args}"
}

# ---------------------------------------------------------------------------
# SSH tunnel parameter tests
# ---------------------------------------------------------------------------

test_ssh_per_backup() {
    printf '\n=== SSH tunnel per-backup test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {
      "name": "tunneldb",
      "database": "tunneldb",
      "ssh_host": "jump.example.com",
      "ssh_port": 2222,
      "ssh_user": "tunnel",
      "ssh_key": "/root/.ssh/id_tunnel"
    }
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "ssh per-backup: --ssh-host" "--ssh-host jump.example.com" "${args}"
    assert_contains "ssh per-backup: --ssh-port" "--ssh-port 2222" "${args}"
    assert_contains "ssh per-backup: --ssh-user" "--ssh-user tunnel" "${args}"
    assert_contains "ssh per-backup: --ssh-key" "--ssh-key /root/.ssh/id_tunnel" "${args}"
}

test_ssh_per_backup_password() {
    printf '\n=== SSH tunnel per-backup with password test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {
      "name": "passdb",
      "database": "passdb",
      "ssh_host": "jump.example.com",
      "ssh_user": "tunnel",
      "ssh_password": "SshPass!"
    }
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "ssh password: --ssh-host" "--ssh-host jump.example.com" "${args}"
    assert_contains "ssh password: --ssh-password" "--ssh-password SshPass!" "${args}"
    assert_not_contains "ssh password: no --ssh-key" "--ssh-key" "${args}"
}

test_ssh_per_backup_local_port() {
    printf '\n=== SSH tunnel per-backup with local port ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {
      "name": "localportdb",
      "database": "localportdb",
      "ssh_host": "jump.example.com",
      "ssh_local_port": 15432
    }
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "ssh local-port: --ssh-local-port" "--ssh-local-port 15432" "${args}"
}

test_ssh_defaults() {
    printf '\n=== SSH tunnel default fields test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "default_ssh_host": "default-jump.example.com",
  "default_ssh_port": 2222,
  "default_ssh_user": "default-tunnel",
  "default_ssh_key": "/root/.ssh/default_key",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "ssh defaults: --ssh-host" "--ssh-host default-jump.example.com" "${args}"
    assert_contains "ssh defaults: --ssh-port" "--ssh-port 2222" "${args}"
    assert_contains "ssh defaults: --ssh-user" "--ssh-user default-tunnel" "${args}"
    assert_contains "ssh defaults: --ssh-key" "--ssh-key /root/.ssh/default_key" "${args}"
}

test_ssh_default_password() {
    printf '\n=== SSH tunnel default password test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "default_ssh_host": "jump.example.com",
  "default_ssh_user": "tunnel",
  "default_ssh_password": "DefaultSshPass",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "ssh default password: --ssh-password" "--ssh-password DefaultSshPass" "${args}"
    assert_not_contains "ssh default password: no --ssh-key" "--ssh-key" "${args}"
}

test_ssh_per_backup_overrides_defaults() {
    printf '\n=== SSH per-backup overrides defaults ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "default_ssh_host": "default-jump",
  "default_ssh_port": 22,
  "default_ssh_user": "default-user",
  "default_ssh_key": "/default/key",
  "backups": [
    {
      "name": "db1",
      "database": "db1",
      "ssh_host": "custom-jump",
      "ssh_port": 3333,
      "ssh_user": "custom-user",
      "ssh_key": "/custom/key"
    }
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_contains "ssh override: host" "--ssh-host custom-jump" "${args}"
    assert_contains "ssh override: port" "--ssh-port 3333" "${args}"
    assert_contains "ssh override: user" "--ssh-user custom-user" "${args}"
    assert_contains "ssh override: key" "--ssh-key /custom/key" "${args}"
    assert_not_contains "ssh override: no default host" "default-jump" "${args}"
    assert_not_contains "ssh override: no default key" "/default/key" "${args}"
}

test_ssh_not_passed_when_null() {
    printf '\n=== SSH args not passed when null/absent ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_not_contains "no ssh: no --ssh-host" "--ssh-host" "${args}"
    assert_not_contains "no ssh: no --ssh-port" "--ssh-port" "${args}"
    assert_not_contains "no ssh: no --ssh-user" "--ssh-user" "${args}"
    assert_not_contains "no ssh: no --ssh-key" "--ssh-key" "${args}"
    assert_not_contains "no ssh: no --ssh-password" "--ssh-password" "${args}"
    assert_not_contains "no ssh: no --ssh-local-port" "--ssh-local-port" "${args}"
}

test_ssh_null_defaults_not_passed() {
    printf '\n=== SSH null defaults not passed ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "default_ssh_host": null,
  "default_ssh_user": null,
  "default_ssh_key": null,
  "default_ssh_password": null,
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    local args
    args=$(call_line 1)
    assert_not_contains "null defaults: no --ssh-host" "--ssh-host" "${args}"
    assert_not_contains "null defaults: no --ssh-key" "--ssh-key" "${args}"
    assert_not_contains "null defaults: no --ssh-password" "--ssh-password" "${args}"
}

test_ssh_info_in_log() {
    printf '\n=== SSH info in log output ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {
      "name": "sshlog",
      "database": "sshlog",
      "ssh_host": "jump.example.com",
      "ssh_port": 2222,
      "ssh_user": "tunnel"
    }
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "ssh log: shows tunnel info" "tunnel@jump.example.com:2222" "${out}"
}

test_ssh_info_none_when_no_tunnel() {
    printf '\n=== SSH info shows "none" when no tunnel ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "nosssh", "database": "nossh"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "no ssh log: shows ssh=none" "ssh=none" "${out}"
}

# ---------------------------------------------------------------------------
# Log output tests
# ---------------------------------------------------------------------------

test_start_log_message() {
    printf '\n=== start log message test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_pg_dump_version": "13.23",
  "global_dry_run": false,
  "default_host": "h", "default_port": 5433, "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "start log: task count" "1 zada" "${out}"
    assert_contains "start log: config path" "config=${CONFIG}" "${out}"
    assert_contains "start log: global_dry_run" "global_dry_run=false" "${out}"
    assert_contains "start log: default host" "host=h" "${out}"
    assert_contains "start log: default port" "port=5433" "${out}"
    assert_contains "start log: default user" "user=u" "${out}"
    assert_contains "start log: default retention" "retention=14d" "${out}"
    assert_contains "start log: pg_dump version" "pg_dump=13.23" "${out}"
}

test_per_backup_log_message() {
    printf '\n=== per-backup log message test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {
      "name": "logtest",
      "host": "myhost",
      "port": 5433,
      "database": "logdb",
      "retention_time": "30d",
      "options": ["--dry-run"]
    }
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "backup log: name" "[logtest]" "${out}"
    assert_contains "backup log: host" "host=myhost" "${out}"
    assert_contains "backup log: port" "port=5433" "${out}"
    assert_contains "backup log: db" "db=logdb" "${out}"
    assert_contains "backup log: retention" "retention=30d" "${out}"
    assert_contains "backup log: separator" "-----" "${out}"
}

test_completion_message() {
    printf '\n=== completion message test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "db1", "database": "db1"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "completion: final message" "Zakończono wszystkie zadania" "${out}"
}

# ---------------------------------------------------------------------------
# Config file with alternate --config flag
# ---------------------------------------------------------------------------

test_config_flag_long() {
    printf '\n=== --config flag test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "cfgdb", "database": "cfgdb"}
  ]
}
JSON
)"

    local out
    out=$(run_sut --config "${CONFIG}")
    assert_contains "config flag long: runs" "[cfgdb] OK" "${out}"
}

test_config_flag_short() {
    printf '\n=== -c flag test ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "cfgdb", "database": "cfgdb"}
  ]
}
JSON
)"

    local out
    out=$(run_sut -c "${CONFIG}")
    assert_contains "config flag short: runs" "[cfgdb] OK" "${out}"
}

# ---------------------------------------------------------------------------
# Edge case: backup_script default fallback
# ---------------------------------------------------------------------------

test_backup_script_default() {
    printf '\n=== backup_script field default fallback ===\n'
    reset_call_log

    # When backup_script is absent from JSON, it defaults to
    # /usr/local/bin/pg_backup.sh — which won't be executable in test.
    # So this should fail with the "nie jest wykonywalny" error.
    write_config "$(cat <<JSON
{
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [{"name": "db1", "database": "db1"}]
}
JSON
)"

    local out rc=0
    out=$(bash "${SUT}" -c "${CONFIG}" 2>&1) || rc=$?
    assert_eq "backup_script default: fails (not executable)" "1" "${rc}"
    assert_contains "backup_script default: mentions path" "/usr/local/bin/pg_backup.sh" "${out}"
}

# ---------------------------------------------------------------------------
# Multiple SSH configs in same batch
# ---------------------------------------------------------------------------

test_mixed_ssh_and_non_ssh() {
    printf '\n=== mixed SSH and non-SSH backups ===\n'
    reset_call_log

    write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "14d",
  "default_host": "h", "default_user": "u", "default_password": "p",
  "backups": [
    {"name": "plain", "database": "plaindb"},
    {
      "name": "tunneled",
      "database": "tunneleddb",
      "ssh_host": "jump.example.com",
      "ssh_user": "tunnel",
      "ssh_key": "/root/.ssh/id_rsa"
    }
  ]
}
JSON
)"

    run_sut -c "${CONFIG}" >/dev/null

    assert_eq "mixed ssh: two invocations" "2" "$(call_count)"

    local args1 args2
    args1=$(call_line 1)
    args2=$(call_line 2)

    assert_not_contains "mixed ssh: plain has no --ssh-host" "--ssh-host" "${args1}"
    assert_contains "mixed ssh: tunneled has --ssh-host" "--ssh-host jump.example.com" "${args2}"
    assert_contains "mixed ssh: tunneled has --ssh-user" "--ssh-user tunnel" "${args2}"
    assert_contains "mixed ssh: tunneled has --ssh-key" "--ssh-key /root/.ssh/id_rsa" "${args2}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    printf 'run_pg_backups.sh test harness\n'
    printf 'SUT: %s\n' "${SUT}"

    setup_fixtures
    trap teardown_fixtures EXIT

    # Help, version, argument validation
    test_help_and_version
    test_unknown_option
    test_missing_config_file
    test_backup_script_not_executable
    test_backup_script_default

    # Config flags
    test_config_flag_long
    test_config_flag_short

    # Empty / missing backups
    test_empty_backups_array
    test_missing_required_fields_skips
    test_missing_host_skips
    test_missing_database_skips

    # Single backup with defaults
    test_single_backup_defaults
    test_default_port_fallback
    test_default_retention_fallback
    test_default_backup_root_fallback

    # Per-backup overrides
    test_per_backup_overrides

    # pg_dump version
    test_pg_dump_version_default
    test_pg_dump_version_per_backup
    test_pg_dump_version_none

    # Dry-run
    test_global_dry_run
    test_global_dry_run_no_duplicate
    test_global_dry_run_false

    # Options array
    test_options_array

    # Multiple backups
    test_multiple_backups
    test_mixed_valid_and_invalid

    # Failure handling
    test_backup_failure_reporting

    # SSH tunnel parameters
    test_ssh_per_backup
    test_ssh_per_backup_password
    test_ssh_per_backup_local_port
    test_ssh_defaults
    test_ssh_default_password
    test_ssh_per_backup_overrides_defaults
    test_ssh_not_passed_when_null
    test_ssh_null_defaults_not_passed
    test_mixed_ssh_and_non_ssh

    # Log output
    test_ssh_info_in_log
    test_ssh_info_none_when_no_tunnel
    test_start_log_message
    test_per_backup_log_message
    test_completion_message

    printf '\n=== Results ===\n'
    printf 'PASS: %d\n' "${PASS}"
    printf 'FAIL: %d\n' "${FAIL}"

    [[ "${FAIL}" -eq 0 ]]
}

main "$@"
