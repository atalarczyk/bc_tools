#!/usr/bin/env bash
# Self-contained test harness for file_backup.sh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/file_backup.sh"
[[ -f "$SUT" ]] || { echo "ERROR: file_backup.sh not found at $SUT"; exit 1; }

PASS=0
FAIL=0
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

TMPBASE=""
FAKE_BIN=""
BACKUP_ROOT=""
REMOTE_SOURCE=""
RSYNC_LOG=""
SSH_LOG=""
SSH_BEHAVIOR_FILE=""
KEY_FILE=""

STD_ARGS=()

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

assert_file_exists() {
  local label="$1" file="$2"
  if [[ -f "$file" ]]; then
    pass "$label"
  else
    fail "$label: missing $file"
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

run_sut() {
  PATH="${FAKE_BIN}:${PATH}" bash "$SUT" "$@" 2>&1 || true
}

run_sut_rc() {
  local rc=0
  PATH="${FAKE_BIN}:${PATH}" bash "$SUT" "$@" 2>&1 || rc=$?
  return "$rc"
}

setup_fixtures() {
  TMPBASE=$(mktemp -d /tmp/fileb_test.XXXXXXXXXX)
  FAKE_BIN="${TMPBASE}/bin"
  BACKUP_ROOT="${TMPBASE}/backups"
  REMOTE_SOURCE="${TMPBASE}/remote/source"
  RSYNC_LOG="${TMPBASE}/rsync.log"
  SSH_LOG="${TMPBASE}/ssh.log"
  SSH_BEHAVIOR_FILE="${TMPBASE}/ssh_behavior"
  KEY_FILE="${TMPBASE}/id_test"

  mkdir -p "$FAKE_BIN" "$BACKUP_ROOT" "$REMOTE_SOURCE/subdir"
  : > "$RSYNC_LOG"
  : > "$SSH_LOG"
  printf 'ok\n' > "$SSH_BEHAVIOR_FILE"
  printf 'dummy-key\n' > "$KEY_FILE"
  chmod 600 "$KEY_FILE"

  write_remote_file "alpha.txt" "alpha-v1"
  write_remote_file "subdir/beta.txt" "beta-v1"

  _write_fake_commands

  STD_ARGS=(
    --backup-name documents
    --source-host fakehost
    --source-dir "$REMOTE_SOURCE"
    --backup-dir "$BACKUP_ROOT"
    --retention-time 30d
    --full-backup-frequency 7d
    --incremental-backup-frequency 1m
    --ssh-user backup
    --ssh-key "$KEY_FILE"
  )
}

teardown_fixtures() {
  [[ -n "$TMPBASE" && -d "$TMPBASE" ]] && rm -rf "$TMPBASE" || true
}

_write_fake_commands() {
  cat > "${FAKE_BIN}/rsync" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${RSYNC_LOG}"
REAL_RSYNC="/usr/bin/rsync"
args=()
skip_next=0
for arg in "\$@"; do
  if [[ "\$skip_next" -eq 1 ]]; then
    skip_next=0
    continue
  fi
  if [[ "\$arg" == "-e" ]]; then
    skip_next=1
    continue
  fi
  if [[ "\$arg" != -* && "\$arg" == *@*:* ]]; then
    args+=("\${arg#*:}")
    continue
  fi
  args+=("\$arg")
done
exec "\$REAL_RSYNC" "\${args[@]}"
STUB

  cat > "${FAKE_BIN}/sshpass" <<STUB
#!/usr/bin/env bash
printf 'sshpass %s\n' "\$*" >> "${RSYNC_LOG}"
shift 2
exec "\$@"
STUB

  cat > "${FAKE_BIN}/ssh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${SSH_LOG}"
behavior=\$(cat "${SSH_BEHAVIOR_FILE}")
cmd="\${*: -1}"
if [[ "\$behavior" == "missing" ]]; then
  if [[ "\$cmd" == "command -v rsync >/dev/null 2>&1" || "\$cmd" == test\ -x* ]]; then
    exit 1
  fi
fi
exit 0
STUB

  chmod +x "${FAKE_BIN}/rsync" "${FAKE_BIN}/sshpass" "${FAKE_BIN}/ssh"
}

write_remote_file() {
  local relative_path="$1"
  local content="$2"
  mkdir -p "$(dirname "${REMOTE_SOURCE}/${relative_path}")"
  printf '%s\n' "$content" > "${REMOTE_SOURCE}/${relative_path}"
}

remove_remote_path() {
  rm -rf "${REMOTE_SOURCE}/$1"
}

job_dir() {
  printf '%s\n' "${BACKUP_ROOT}/documents"
}

state_file() {
  printf '%s\n' "$(job_dir)/.state/state.env"
}

full_archive_path() {
  find "$(job_dir)" -maxdepth 1 -type f -name 'documents-full-*.zip' | sort | tail -n 1
}

incremental_archive_path() {
  find "$(job_dir)" -maxdepth 1 -type f -name 'documents-inc-full-*.zip' | sort | tail -n 1
}

archive_count() {
  find "$(job_dir)" -maxdepth 1 -type f -name '*.zip' | wc -l | tr -d ' '
}

full_archive_count() {
  find "$(job_dir)" -maxdepth 1 -type f -name 'documents-full-*.zip' | wc -l | tr -d ' '
}

incremental_archive_count() {
  find "$(job_dir)" -maxdepth 1 -type f -name 'documents-inc-full-*.zip' | wc -l | tr -d ' '
}

state_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print $2 }' "$(state_file)"
}

age_state() {
  local last_backup_age="$1"
  local last_full_age="$2"
  local now
  local last_backup_id
  local last_backup_type
  local last_full_id

  now=$(date -u +%s)
  last_backup_id=$(state_value LAST_BACKUP_ID)
  last_backup_type=$(state_value LAST_BACKUP_TYPE)
  last_full_id=$(state_value LAST_FULL_ID)

  cat > "$(state_file)" <<EOF
LAST_BACKUP_ID=$last_backup_id
LAST_BACKUP_TYPE=$last_backup_type
LAST_BACKUP_EPOCH=$(( now - last_backup_age ))
LAST_FULL_ID=$last_full_id
LAST_FULL_EPOCH=$(( now - last_full_age ))
EOF
}

wait_next_second() {
  sleep 1
}

archive_listing() {
  unzip -Z1 "$1"
}

age_chain_files_minutes_ago() {
  local full_id="$1"
  local minutes="$2"

  find "$(job_dir)" -maxdepth 1 -type f \
    \( -name "documents-full-${full_id}.zip" \
    -o -name "documents-full-${full_id}.zip.sha256" \
    -o -name "documents-inc-full-${full_id}-prev-*.zip" \
    -o -name "documents-inc-full-${full_id}-prev-*.zip.sha256" \) \
    -exec touch -d "${minutes} minutes ago" {} +
}

set_remote_rsync_behavior() {
  printf '%s\n' "$1" > "$SSH_BEHAVIOR_FILE"
}

test_help_and_version() {
  printf '\n=== help and version tests ===\n'

  local out
  out=$(run_sut --help)
  assert_contains "help: shows Usage" "Usage:" "$out"
  assert_contains "help: shows full frequency option" "--full-backup-frequency" "$out"

  out=$(run_sut --version)
  assert_eq "version: prints script version" "1.1.1" "$out"
}

test_missing_required_options() {
  printf '\n=== required option validation tests ===\n'

  local out rc=0
  out=$(bash "$SUT" --backup-name docs 2>&1) || rc=$?
  assert_eq "missing options: exit code" "64" "$rc"
  assert_contains "missing options: message" "Missing required options" "$out"
}

test_invalid_values() {
  printf '\n=== invalid value tests ===\n'

  local out rc=0
  out=$(bash "$SUT" \
    --backup-name "bad/name" \
    --source-host fakehost \
    --source-dir /tmp/source \
    --backup-dir /tmp/backups \
    --retention-time 30d \
    --full-backup-frequency 7d \
    --incremental-backup-frequency 1h 2>&1) || rc=$?
  assert_eq "invalid backup name: exit code" "64" "$rc"
  assert_contains "invalid backup name: message" "--backup-name may contain only" "$out"

  rc=0
  out=$(bash "$SUT" \
    --backup-name docs \
    --source-host fakehost \
    --source-dir /tmp/source \
    --backup-dir /tmp/backups \
    --retention-time 30d \
    --full-backup-frequency abc \
    --incremental-backup-frequency 1h 2>&1) || rc=$?
  assert_eq "invalid full frequency: exit code" "64" "$rc"
  assert_contains "invalid full frequency: message" "Invalid --full-backup-frequency" "$out"

  rc=0
  out=$(bash "$SUT" \
    --backup-name docs \
    --source-host fakehost \
    --source-dir /tmp/source \
    --backup-dir /tmp/backups \
    --retention-time abc \
    --full-backup-frequency 7d \
    --incremental-backup-frequency 1h 2>&1) || rc=$?
  assert_eq "invalid retention: exit code" "64" "$rc"
  assert_contains "invalid retention: message" "Invalid --retention-time" "$out"
}

test_full_backup_creation() {
  printf '\n=== full backup creation test ===\n'

  local out archive checksum listing
  out=$(run_sut "${STD_ARGS[@]}")
  assert_contains "full backup: completion log" "completed successfully" "$out"
  assert_eq "full backup: one archive created" "1" "$(archive_count)"

  archive=$(full_archive_path)
  checksum="${archive}.sha256"
  listing=$(archive_listing "$archive")

  assert_file_exists "full backup: archive exists" "$archive"
  assert_file_exists "full backup: checksum exists" "$checksum"
  assert_contains "full backup: archive contains alpha.txt" "data/alpha.txt" "$listing"
  assert_contains "full backup: archive contains beta.txt" "data/subdir/beta.txt" "$listing"
  assert_contains "full backup: archive contains metadata" ".file_backup_meta/backup_info.txt" "$listing"
  assert_file_contains "full backup: checksum references archive file" "$(basename "$archive")" "$checksum"
  assert_file_contains "full backup: state marks full backup" "LAST_BACKUP_TYPE=full" "$(state_file)"
}

test_no_backup_due() {
  printf '\n=== no backup due test ===\n'

  run_sut "${STD_ARGS[@]}" >/dev/null
  local out
  out=$(run_sut "${STD_ARGS[@]}")

  assert_contains "no backup due: message" "No backup due" "$out"
  assert_eq "no backup due: still one archive" "1" "$(archive_count)"
}

test_incremental_backup_creation() {
  printf '\n=== incremental backup creation test ===\n'

  local full_archive full_id out inc_archive listing deleted_manifest info_manifest

  run_sut "${STD_ARGS[@]}" >/dev/null
  full_archive=$(full_archive_path)
  full_id=$(basename "$full_archive")
  full_id="${full_id#documents-full-}"
  full_id="${full_id%.zip}"

  write_remote_file "alpha.txt" "alpha-v2"
  write_remote_file "new.txt" "new-file"
  remove_remote_path "subdir/beta.txt"
  age_state 7200 7200
  wait_next_second

  out=$(run_sut "${STD_ARGS[@]}")
  inc_archive=$(incremental_archive_path)
  listing=$(archive_listing "$inc_archive")
  deleted_manifest=$(unzip -p "$inc_archive" .file_backup_meta/deleted_paths.txt)
  info_manifest=$(unzip -p "$inc_archive" .file_backup_meta/backup_info.txt)

  assert_contains "incremental backup: log mentions incremental mode" "Starting incremental backup" "$out"
  assert_eq "incremental backup: two archives total" "2" "$(archive_count)"
  assert_contains "incremental backup: name references base full id" "documents-inc-full-${full_id}" "$(basename "$inc_archive")"
  assert_contains "incremental backup: archive contains changed alpha.txt" "data/alpha.txt" "$listing"
  assert_contains "incremental backup: archive contains new.txt" "data/new.txt" "$listing"
  assert_contains "incremental backup: archive contains deleted paths file" ".file_backup_meta/deleted_paths.txt" "$listing"
  assert_contains "incremental backup: deletion manifest contains removed file" "subdir/beta.txt" "$deleted_manifest"
  assert_contains "incremental backup: metadata marks incremental" "backup_type=incremental" "$info_manifest"
  assert_contains "incremental backup: metadata keeps base full id" "base_full_id=${full_id}" "$info_manifest"
  assert_contains "incremental backup: metadata keeps previous backup id" "previous_backup_id=${full_id}" "$info_manifest"
}

test_full_backup_takes_precedence() {
  printf '\n=== full backup precedence test ===\n'

  run_sut "${STD_ARGS[@]}" >/dev/null
  age_state $(( 8 * 24 * 3600 )) $(( 8 * 24 * 3600 ))
  wait_next_second

  local out
  out=$(run_sut "${STD_ARGS[@]}")

  assert_contains "full precedence: log mentions full backup" "Starting full backup" "$out"
  assert_eq "full precedence: two full archives exist" "2" "$(full_archive_count)"
}

test_retention_keeps_active_chain() {
  printf '\n=== retention keeps active chain test ===\n'

  local full_archive full_id out

  run_sut "${STD_ARGS[@]}" --retention-time 5m >/dev/null
  full_archive=$(full_archive_path)
  full_id=$(basename "$full_archive")
  full_id="${full_id#documents-full-}"
  full_id="${full_id%.zip}"

  age_chain_files_minutes_ago "$full_id" 10
  write_remote_file "alpha.txt" "alpha-v3"
  age_state 7200 7200
  wait_next_second

  out=$(run_sut "${STD_ARGS[@]}" --retention-time 5m)

  assert_contains "retention active chain: no pruning performed" "No expired inactive backup chains to prune" "$out"
  assert_eq "retention active chain: full archive kept" "1" "$(full_archive_count)"
  assert_eq "retention active chain: incremental archive created" "1" "$(incremental_archive_count)"
}

test_retention_prunes_inactive_chain() {
  printf '\n=== retention prunes inactive chain test ===\n'

  local full_archive full_id out

  run_sut "${STD_ARGS[@]}" --retention-time 5m >/dev/null
  full_archive=$(full_archive_path)
  full_id=$(basename "$full_archive")
  full_id="${full_id#documents-full-}"
  full_id="${full_id%.zip}"

  write_remote_file "alpha.txt" "alpha-v4"
  age_state 7200 7200
  wait_next_second
  run_sut "${STD_ARGS[@]}" --retention-time 5m >/dev/null

  age_chain_files_minutes_ago "$full_id" 10
  age_state $(( 8 * 24 * 3600 )) $(( 8 * 24 * 3600 ))
  wait_next_second

  out=$(run_sut "${STD_ARGS[@]}" --retention-time 5m)

  assert_contains "retention inactive chain: pruning log shown" "Removing expired backup chain based on full backup '${full_id}'" "$out"
  assert_eq "retention inactive chain: only one archive remains" "1" "$(archive_count)"
  assert_eq "retention inactive chain: only current full archive remains" "1" "$(full_archive_count)"
  assert_eq "retention inactive chain: old incrementals removed" "0" "$(incremental_archive_count)"
}

test_dry_run_backup_creation() {
  printf '\n=== dry-run backup creation test ===\n'

  local out archive listing
  out=$(run_sut --dry-run "${STD_ARGS[@]}")
  archive=$(full_archive_path)
  listing=$(archive_listing "$archive")

  assert_contains "dry-run: log mentions dry-run" "[DRY-RUN]" "$out"
  assert_contains "dry-run: simulated file stored in archive" "data/README.dry-run.txt" "$listing"
}

test_rsync_options_logging() {
  printf '\n=== rsync option propagation test ===\n'

  run_sut "${STD_ARGS[@]}" --exclude "*.tmp" --exclude "cache/" >/dev/null

  assert_file_contains "rsync options: exclude glob logged" "--exclude *.tmp" "$RSYNC_LOG"
  assert_file_contains "rsync options: exclude directory logged" "--exclude cache/" "$RSYNC_LOG"
}

test_remote_rsync_path_option() {
  printf '\n=== remote rsync path option test ===\n'

  local out
  out=$(run_sut "${STD_ARGS[@]}" --remote-rsync-path /opt/rsync/bin/rsync)

  assert_contains "remote rsync path: backup succeeds" "completed successfully" "$out"
  assert_file_contains "remote rsync path: rsync receives --rsync-path" "--rsync-path /opt/rsync/bin/rsync" "$RSYNC_LOG"
  assert_file_contains "remote rsync path: ssh preflight checks configured path" "test -x '/opt/rsync/bin/rsync'" "$SSH_LOG"
}

test_remote_rsync_missing_message() {
  printf '\n=== remote rsync missing message test ===\n'

  local out rc=0
  set_remote_rsync_behavior missing
  out=$(PATH="${FAKE_BIN}:${PATH}" bash "$SUT" "${STD_ARGS[@]}" 2>&1) || rc=$?

  assert_eq "remote rsync missing: exit code" "127" "$rc"
  assert_contains "remote rsync missing: clear message" "does not provide 'rsync' in PATH" "$out"
}

test_ssh_password_mode() {
  printf '\n=== ssh password mode test ===\n'

  local out
  out=$(run_sut \
    --backup-name documents \
    --source-host fakehost \
    --source-dir "$REMOTE_SOURCE" \
    --backup-dir "$BACKUP_ROOT" \
    --retention-time 30d \
    --full-backup-frequency 7d \
    --incremental-backup-frequency 1m \
    --ssh-user backup \
    --ssh-password secret)

  assert_contains "ssh password: backup succeeds" "completed successfully" "$out"
  assert_file_contains "ssh password: sshpass appears in rsync transport log" "sshpass -p secret" "$RSYNC_LOG"
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
  run_test test_missing_required_options
  run_test test_invalid_values
  run_test test_full_backup_creation
  run_test test_no_backup_due
  run_test test_incremental_backup_creation
  run_test test_full_backup_takes_precedence
  run_test test_retention_keeps_active_chain
  run_test test_retention_prunes_inactive_chain
  run_test test_dry_run_backup_creation
  run_test test_rsync_options_logging
  run_test test_remote_rsync_path_option
  run_test test_remote_rsync_missing_message
  run_test test_ssh_password_mode

  printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

main
