#!/usr/bin/env bash
# Self-contained test harness for run_file_backups.sh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/run_file_backups.sh"
[[ -f "$SUT" ]] || { echo "ERROR: run_file_backups.sh not found at $SUT"; exit 1; }

PASS=0
FAIL=0
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

TMPBASE=""
CONFIG=""
CALL_LOG=""
FAKE_BACKUP_SH=""

pass() {
  PASS=$(( PASS + 1 ))
  [[ "$VERBOSE" -eq 1 ]] && printf '  PASS: %s\n' "$*" || true
}

fail() {
  FAIL=$(( FAIL + 1 ))
  printf '  FAIL: %s\n' "$*"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label"
    printf '       expected: %q\n' "$expected"
    printf '       actual:   %q\n' "$actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label"
    printf '       needle:   %q\n' "$needle"
    printf '       haystack: %q\n' "$haystack"
  fi
}

assert_file_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label"
    printf '       file:   %s\n' "$file"
    printf '       needle: %q\n' "$needle"
  fi
}

setup_fixtures() {
  TMPBASE=$(mktemp -d /tmp/rfb_test.XXXXXXXXXX)
  CONFIG="${TMPBASE}/config.json"
  CALL_LOG="${TMPBASE}/calls.log"
  FAKE_BACKUP_SH="${TMPBASE}/fake_file_backup.sh"

  : > "$CALL_LOG"

  cat > "$FAKE_BACKUP_SH" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${CALL_LOG}"
exit 0
STUB
  chmod +x "$FAKE_BACKUP_SH"
}

teardown_fixtures() {
  [[ -n "$TMPBASE" && -d "$TMPBASE" ]] && rm -rf "$TMPBASE" || true
}

write_config() {
  printf '%s\n' "$1" > "$CONFIG"
}

run_sut() {
  bash "$SUT" "$@" 2>&1 || true
}

call_count() {
  grep -c . "$CALL_LOG" 2>/dev/null || true
}

call_line() {
  sed -n "${1}p" "$CALL_LOG"
}

test_help_and_version() {
  printf '\n=== help and version tests ===\n'

  local out
  out=$(run_sut --help)
  assert_contains "help: shows Usage" "Usage:" "$out"
  assert_contains "help: mentions --config" "--config" "$out"

  out=$(run_sut --version)
  assert_eq "version: prints script version" "1.1.1" "$out"
}

test_missing_config() {
  printf '\n=== missing config test ===\n'

  local out rc=0
  out=$(bash "$SUT" -c "/nonexistent/file_backup_config_$$.json" 2>&1) || rc=$?
  assert_eq "missing config: exit code" "1" "$rc"
  assert_contains "missing config: error message" "Brak pliku konfiguracyjnego" "$out"
}

test_not_executable_script() {
  printf '\n=== backup script executability test ===\n'

  local bad_script="${TMPBASE}/not-executable.sh"
  printf '#!/usr/bin/env bash\n' > "$bad_script"

  write_config "$(cat <<JSON
{
  "backup_script": "${bad_script}",
  "backups": [
    {"name": "docs", "host": "h", "source_dir": "/srv/data"}
  ]
}
JSON
)"

  local out rc=0
  out=$(bash "$SUT" -c "$CONFIG" 2>&1) || rc=$?
  assert_eq "not executable: exit code" "1" "$rc"
  assert_contains "not executable: error message" "nie jest wykonywalny" "$out"
}

test_run_all_with_defaults() {
  printf '\n=== run all with defaults test ===\n'

  write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "30d",
  "default_full_backup_frequency": "7d",
  "default_incremental_backup_frequency": "12h",
  "default_host": "files.example.com",
  "default_ssh_port": 2222,
  "default_ssh_user": "backup",
  "default_ssh_key": "/root/.ssh/id_backup",
  "default_remote_rsync_path": "/usr/bin/rsync",
  "backups": [
    {"name": "docs", "source_dir": "/srv/docs"},
    {"name": "photos", "source_dir": "/srv/photos"}
  ]
}
JSON
)"

  local out
  out=$(run_sut -c "$CONFIG")

  assert_eq "run all: two invocations" "2" "$(call_count)"
  assert_contains "run all: first job has backup name" "--backup-name docs" "$(call_line 1)"
  assert_contains "run all: first job has default host" "--source-host files.example.com" "$(call_line 1)"
  assert_contains "run all: first job has default retention" "--retention-time 30d" "$(call_line 1)"
  assert_contains "run all: first job has default full frequency" "--full-backup-frequency 7d" "$(call_line 1)"
  assert_contains "run all: first job has default incremental frequency" "--incremental-backup-frequency 12h" "$(call_line 1)"
  assert_contains "run all: first job has default ssh key" "--ssh-key /root/.ssh/id_backup" "$(call_line 1)"
  assert_contains "run all: first job has default remote rsync path" "--remote-rsync-path /usr/bin/rsync" "$(call_line 1)"
  assert_contains "run all: logs start banner" "Start (2 zadań)" "$out"
}

test_run_single_job() {
  printf '\n=== run single job test ===\n'

  write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "default_host": "files.example.com",
  "backups": [
    {"name": "docs", "source_dir": "/srv/docs"},
    {"name": "photos", "source_dir": "/srv/photos"}
  ]
}
JSON
)"

  run_sut -c "$CONFIG" -r photos >/dev/null

  assert_eq "run single: one invocation" "1" "$(call_count)"
  assert_contains "run single: selected job" "--backup-name photos" "$(call_line 1)"
}

test_global_dry_run_and_options_passthrough() {
  printf '\n=== global dry-run and options passthrough test ===\n'

  write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "30d",
  "default_host": "files.example.com",
  "default_full_backup_frequency": "7d",
  "default_incremental_backup_frequency": "6h",
  "global_dry_run": true,
  "backups": [
    {
      "name": "docs",
      "source_dir": "/srv/docs",
      "options": ["--exclude", "*.tmp", "--exclude", "cache/"]
    }
  ]
}
JSON
)"

  run_sut -c "$CONFIG" >/dev/null

  assert_eq "dry-run/options: one invocation" "1" "$(call_count)"
  assert_contains "dry-run/options: --dry-run added" "--dry-run" "$(call_line 1)"
  assert_contains "dry-run/options: first exclude passed through" "--exclude *.tmp" "$(call_line 1)"
  assert_contains "dry-run/options: second exclude passed through" "--exclude cache/" "$(call_line 1)"
}

test_skip_invalid_entry() {
  printf '\n=== invalid entry skip test ===\n'

  write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "default_host": "files.example.com",
  "backups": [
    {"name": "good", "source_dir": "/srv/good"},
    {"name": "bad"},
    {"name": "also-good", "host": "other.example.com", "source_dir": "/srv/other"}
  ]
}
JSON
)"

  local out
  out=$(run_sut -c "$CONFIG")

  assert_eq "skip invalid: two invocations" "2" "$(call_count)"
  assert_contains "skip invalid: warning printed" "Pominięto" "$out"
}

test_list_mode() {
  printf '\n=== list mode test ===\n'

  write_config "$(cat <<JSON
{
  "backup_script": "${FAKE_BACKUP_SH}",
  "backup_root": "/mnt/backups",
  "default_retention": "45d",
  "default_full_backup_frequency": "14d",
  "default_incremental_backup_frequency": "24h",
  "default_host": "files.example.com",
  "default_ssh_user": "backup",
  "default_remote_rsync_path": "/usr/bin/rsync",
  "backups": [
    {
      "name": "docs",
      "source_dir": "/srv/docs",
      "options": ["--exclude", "*.tmp"]
    }
  ]
}
JSON
)"

  local out
  out=$(run_sut -c "$CONFIG" --list)

  assert_contains "list: includes task name" "[1] docs" "$out"
  assert_contains "list: includes source_dir" "/srv/docs" "$out"
  assert_contains "list: includes retention" "45d" "$out"
  assert_contains "list: includes full frequency" "14d" "$out"
  assert_contains "list: includes remote rsync path" "/usr/bin/rsync" "$out"
  assert_contains "list: includes options" "--exclude *.tmp" "$out"
  assert_eq "list: does not invoke backup script" "0" "$(call_count)"
}

run_test() {
  local test_name="$1"
  setup_fixtures
  if "$test_name"; then
    :
  fi
  teardown_fixtures
}

main() {
  run_test test_help_and_version
  run_test test_missing_config
  run_test test_not_executable_script
  run_test test_run_all_with_defaults
  run_test test_run_single_job
  run_test test_global_dry_run_and_options_passthrough
  run_test test_skip_invalid_entry
  run_test test_list_mode

  printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

main
