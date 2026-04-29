#!/usr/bin/env bash
#------------------------------------------------------------------------------
# file_backup.sh
# Creates full and incremental ZIP backups of a remote directory using rsync.
# Incremental backups contain changes relative to the previous backup and keep
# a reference to the full backup they belong to.
#------------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_VERSION="1.1.1"

usage() {
  cat <<'EOF'
Usage:
  file_backup.sh [OPTIONS]

Required options:
  --backup-name                  <name>   Logical backup name (used for paths)
  --source-host                  <host>   Remote host name or IP
  --source-dir                   <path>   Remote source directory to back up
  --backup-dir                   <path>   Local root directory for backups
  --retention-time               <time>   Retention for stored backup chains
  --full-backup-frequency        <time>   Frequency for full backups
  --incremental-backup-frequency <time>   Frequency for incremental backups

Optional:
  --ssh-port                     <port>   SSH port (default: 22)
  --ssh-user                     <user>   SSH username (default: current OS user)
  --ssh-key                      <path>   Path to SSH private key
  --ssh-password                 <pass>   SSH password (requires sshpass;
                                          mutually exclusive with --ssh-key)
  --remote-rsync-path            <path>   Absolute path to rsync on the remote
                                          host (optional)
  --exclude                      <glob>   rsync exclude pattern; repeatable
  --dry-run                               Do not connect remotely; create a
                                          simulated archive and update state
  -v, --version                           Show script version and exit
  -h, --help                              Show this help and exit

Examples:
  file_backup.sh \
    --backup-name documents \
    --source-host files.example.com \
    --source-dir /srv/data/documents \
    --backup-dir /var/local/backup/files \
    --retention-time 30d \
    --full-backup-frequency 7d \
    --incremental-backup-frequency 12h \
    --ssh-user backup \
    --ssh-key /root/.ssh/id_backup \
    --remote-rsync-path /usr/bin/rsync

  file_backup.sh \
    --dry-run \
    --backup-name media \
    --source-host storage.internal \
    --source-dir /srv/media \
    --backup-dir /tmp/file-backups \
    --retention-time 14d \
    --full-backup-frequency 30d \
    --incremental-backup-frequency 24h
EOF
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: $1" >&2
    exit 127
  }
}

parse_interval_to_seconds() {
  local value="$1"

  if [[ "$value" =~ ^([0-9]+)$ ]]; then
    echo $(( BASH_REMATCH[1] * 86400 ))
    return 0
  fi

  if [[ "$value" =~ ^([0-9]+)([wdhm])$ ]]; then
    local amount="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      w) echo $(( amount * 7 * 24 * 3600 )) ;;
      d) echo $(( amount * 24 * 3600 )) ;;
      h) echo $(( amount * 3600 )) ;;
      m) echo $(( amount * 60 )) ;;
      *) return 1 ;;
    esac
    return 0
  fi

  return 1
}

format_command() {
  local formatted=""
  printf -v formatted '%q ' "$@"
  printf '%s' "${formatted% }"
}

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

write_state_file() {
  local state_file="$1"
  local last_backup_id="$2"
  local last_backup_type="$3"
  local last_backup_epoch="$4"
  local last_full_id="$5"
  local last_full_epoch="$6"
  local tmp_file="${state_file}.tmp.$$"

  cat > "$tmp_file" <<EOF
LAST_BACKUP_ID=$last_backup_id
LAST_BACKUP_TYPE=$last_backup_type
LAST_BACKUP_EPOCH=$last_backup_epoch
LAST_FULL_ID=$last_full_id
LAST_FULL_EPOCH=$last_full_epoch
EOF

  mv "$tmp_file" "$state_file"
}

load_state_file() {
  local state_file="$1"
  LAST_BACKUP_ID=""
  LAST_BACKUP_TYPE=""
  LAST_BACKUP_EPOCH=0
  LAST_FULL_ID=""
  LAST_FULL_EPOCH=0

  [[ -r "$state_file" ]] || return 0

  while IFS='=' read -r key value; do
    case "$key" in
      LAST_BACKUP_ID) LAST_BACKUP_ID="$value" ;;
      LAST_BACKUP_TYPE) LAST_BACKUP_TYPE="$value" ;;
      LAST_BACKUP_EPOCH) LAST_BACKUP_EPOCH="$value" ;;
      LAST_FULL_ID) LAST_FULL_ID="$value" ;;
      LAST_FULL_EPOCH) LAST_FULL_EPOCH="$value" ;;
    esac
  done < "$state_file"
}

build_rsync_shell_command() {
  local -a shell_cmd=(
    ssh
    -p "$SSH_PORT"
    -o StrictHostKeyChecking=accept-new
  )

  [[ -n "$SSH_KEY" ]] && shell_cmd+=(-i "$SSH_KEY")

  if [[ -n "$SSH_PASS" ]]; then
    shell_cmd=(
      sshpass -p "$SSH_PASS"
      "${shell_cmd[@]}"
      -o PreferredAuthentications=password
    )
  fi

  format_command "${shell_cmd[@]}"
}

run_remote_command() {
  local remote_command="$1"
  local ssh_target=""
  local -a cmd=(
    ssh
    -p "$SSH_PORT"
    -o StrictHostKeyChecking=accept-new
  )

  ssh_target="${SSH_USER:+${SSH_USER}@}${SOURCE_HOST}"
  [[ -n "$SSH_KEY" ]] && cmd+=(-i "$SSH_KEY")

  if [[ -n "$SSH_PASS" ]]; then
    cmd=(
      sshpass -p "$SSH_PASS"
      "${cmd[@]}"
      -o PreferredAuthentications=password
    )
  fi

  cmd+=("$ssh_target" "$remote_command")
  "${cmd[@]}"
}

verify_remote_rsync_available() {
  local remote_command=""

  if [[ -n "$REMOTE_RSYNC_PATH" ]]; then
    remote_command="test -x $(shell_quote "$REMOTE_RSYNC_PATH")"
  else
    remote_command="command -v rsync >/dev/null 2>&1"
  fi

  if run_remote_command "$remote_command" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -n "$REMOTE_RSYNC_PATH" ]]; then
    log "ERROR: Remote rsync was not found or is not executable at '${REMOTE_RSYNC_PATH}' on '${SOURCE_HOST}'." >&2
    log "       Set --remote-rsync-path correctly or install rsync on the remote host." >&2
  else
    log "ERROR: Remote host '${SOURCE_HOST}' does not provide 'rsync' in PATH." >&2
    log "       Install rsync on the remote host or set --remote-rsync-path to its full path." >&2
  fi

  exit 127
}

build_remote_source() {
  local path="$SOURCE_DIR"
  if [[ "$path" != "/" ]]; then
    path="${path%/}/"
  fi

  local quoted_path=""
  printf -v quoted_path '%q' "$path"
  printf '%s:%s' "${SSH_USER:+${SSH_USER}@}${SOURCE_HOST}" "$quoted_path"
}

create_simulated_snapshot() {
  local target_dir="$1"
  mkdir -p "$target_dir/subdir"

  cat > "${target_dir}/README.dry-run.txt" <<EOF
[DRY-RUN] Simulated remote directory backup
Backup name: $BACKUP_NAME
Source host: $SOURCE_HOST
Source dir:  $SOURCE_DIR
EOF

  cat > "${target_dir}/subdir/state.txt" <<EOF
mode=dry-run
generated_at_utc=$BACKUP_ID
EOF
}

sync_remote_snapshot() {
  local target_dir="$1"
  local remote_source=""
  local rsync_shell=""
  local -a cmd=()
  local exclude_pattern=""

  mkdir -p "$target_dir"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    create_simulated_snapshot "$target_dir"
    return 0
  fi

  verify_remote_rsync_available
  remote_source="$(build_remote_source)"
  rsync_shell="$(build_rsync_shell_command)"
  cmd=(rsync -a --checksum --delete -e "$rsync_shell")
  [[ -n "$REMOTE_RSYNC_PATH" ]] && cmd+=(--rsync-path "$REMOTE_RSYNC_PATH")

  for exclude_pattern in "${EXCLUDES[@]}"; do
    cmd+=(--exclude "$exclude_pattern")
  done

  cmd+=("$remote_source" "$target_dir/")

  log "Syncing '${SOURCE_DIR}' from '${SOURCE_HOST}' ..."
  if ! "${cmd[@]}"; then
    log "ERROR: rsync failed while syncing the remote source." >&2
    exit 1
  fi
}

collect_incremental_changes() {
  local previous_snapshot="$1"
  local current_snapshot="$2"
  local changes_file="$3"
  local deletions_file="$4"
  local line=""
  local status=""
  local relative_path=""

  : > "$changes_file"
  : > "$deletions_file"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS='|' read -r status relative_path <<< "$line"

    if [[ "$status" == *deleting* ]]; then
      [[ -n "$relative_path" ]] && printf '%s\n' "$relative_path" >> "$deletions_file"
      continue
    fi

    [[ -n "$relative_path" ]] || continue
    [[ "$relative_path" == "." ]] && continue
    printf '%s\n' "$relative_path" >> "$changes_file"
  done < <(
    rsync -a --checksum --delete --dry-run --itemize-changes --out-format='%i|%n' \
      "$current_snapshot/" "$previous_snapshot/"
  )
}

stage_incremental_payload() {
  local current_snapshot="$1"
  local changes_file="$2"
  local payload_dir="$3"

  mkdir -p "$payload_dir"
  [[ -s "$changes_file" ]] || return 0

  rsync -a --files-from="$changes_file" "$current_snapshot/" "$payload_dir/"
}

write_backup_metadata() {
  local metadata_dir="$1"
  local backup_type="$2"
  local backup_id="$3"
  local base_full_id="$4"
  local previous_backup_id="$5"
  local changed_count="$6"
  local deleted_count="$7"

  cat > "${metadata_dir}/backup_info.txt" <<EOF
backup_name=$BACKUP_NAME
backup_type=$backup_type
backup_id=$backup_id
base_full_id=$base_full_id
previous_backup_id=$previous_backup_id
source_host=$SOURCE_HOST
source_dir=$SOURCE_DIR
ssh_user=${SSH_USER:-$(id -un)}
retention_time=$RETENTION_RAW
full_backup_frequency=$FULL_FREQ_RAW
incremental_backup_frequency=$INCREMENTAL_FREQ_RAW
changed_entries=$changed_count
deleted_entries=$deleted_count
created_at_utc=$backup_id
EOF
}

prune_expired_backup_chains() {
  local active_full_id="$1"
  local full_archive=""
  local full_basename=""
  local full_id=""
  local matches=""
  local deleted_any=0

  log "Pruning backup chains older than ${RETENTION_RAW} (${RETENTION_MINUTES} minutes)..."

  while IFS= read -r -d '' full_archive; do
    full_basename="$(basename "$full_archive")"
    full_id="${full_basename#${BACKUP_NAME}-full-}"
    full_id="${full_id%.zip}"

    if [[ "$full_id" == "$active_full_id" ]]; then
      continue
    fi

    matches="$(find "$full_archive" -prune -mmin +"$RETENTION_MINUTES" -print)"
    [[ -n "$matches" ]] || continue

    deleted_any=1
    log "Removing expired backup chain based on full backup '${full_id}' ..."
    find "$BACKUP_DIR" -maxdepth 1 -type f \
      \( -name "${BACKUP_NAME}-full-${full_id}.zip" \
      -o -name "${BACKUP_NAME}-full-${full_id}.zip.sha256" \
      -o -name "${BACKUP_NAME}-inc-full-${full_id}-prev-*.zip" \
      -o -name "${BACKUP_NAME}-inc-full-${full_id}-prev-*.zip.sha256" \) \
      -print -delete
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${BACKUP_NAME}-full-*.zip" -print0)

  if [[ "$deleted_any" -eq 0 ]]; then
    log "No expired inactive backup chains to prune."
  fi
}

create_archive_and_checksum() {
  local package_dir="$1"
  local archive_path="$2"
  local checksum_path="$3"

  (
    cd "$package_dir"
    zip -qry -9 "$archive_path" data .file_backup_meta
  )

  (
    cd "$(dirname "$archive_path")"
    sha256sum "$(basename "$archive_path")"
  ) > "$checksum_path"
}

replace_directory() {
  local src_dir="$1"
  local dst_dir="$2"

  rm -rf "$dst_dir"
  mv "$src_dir" "$dst_dir"
}

refresh_snapshot_state_full() {
  local current_snapshot="$1"
  local full_tmp="${SNAPSHOT_DIR}/full_base.tmp.$$"
  local latest_tmp="${SNAPSHOT_DIR}/latest.tmp.$$"

  rm -rf "$full_tmp" "$latest_tmp"
  mv "$current_snapshot" "$full_tmp"
  mkdir -p "$latest_tmp"

  if ! cp -al "$full_tmp/." "$latest_tmp/" 2>/dev/null; then
    rsync -a "$full_tmp/" "$latest_tmp/"
  fi

  replace_directory "$full_tmp" "$FULL_SNAPSHOT_DIR"
  replace_directory "$latest_tmp" "$LATEST_SNAPSHOT_DIR"
}

refresh_snapshot_state_incremental() {
  local current_snapshot="$1"
  local latest_tmp="${SNAPSHOT_DIR}/latest.tmp.$$"

  rm -rf "$latest_tmp"
  mv "$current_snapshot" "$latest_tmp"
  replace_directory "$latest_tmp" "$LATEST_SNAPSHOT_DIR"
}

BACKUP_NAME=""
SOURCE_HOST=""
SOURCE_DIR=""
BACKUP_ROOT=""
RETENTION_RAW=""
FULL_FREQ_RAW=""
INCREMENTAL_FREQ_RAW=""
SSH_PORT=22
SSH_USER=""
SSH_KEY=""
SSH_PASS=""
REMOTE_RSYNC_PATH=""
DRY_RUN=0
declare -a EXCLUDES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-name) BACKUP_NAME="$2"; shift 2 ;;
    --source-host) SOURCE_HOST="$2"; shift 2 ;;
    --source-dir) SOURCE_DIR="$2"; shift 2 ;;
    --backup-dir) BACKUP_ROOT="$2"; shift 2 ;;
    --retention-time) RETENTION_RAW="$2"; shift 2 ;;
    --full-backup-frequency) FULL_FREQ_RAW="$2"; shift 2 ;;
    --incremental-backup-frequency) INCREMENTAL_FREQ_RAW="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --ssh-password) SSH_PASS="$2"; shift 2 ;;
    --remote-rsync-path) REMOTE_RSYNC_PATH="$2"; shift 2 ;;
    --exclude) EXCLUDES+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

missing=()
[[ -z "$BACKUP_NAME" ]] && missing+=("--backup-name")
[[ -z "$SOURCE_HOST" ]] && missing+=("--source-host")
[[ -z "$SOURCE_DIR" ]] && missing+=("--source-dir")
[[ -z "$BACKUP_ROOT" ]] && missing+=("--backup-dir")
[[ -z "$RETENTION_RAW" ]] && missing+=("--retention-time")
[[ -z "$FULL_FREQ_RAW" ]] && missing+=("--full-backup-frequency")
[[ -z "$INCREMENTAL_FREQ_RAW" ]] && missing+=("--incremental-backup-frequency")

if (( ${#missing[@]} )); then
  echo "ERROR: Missing required options: ${missing[*]}" >&2
  echo
  usage
  exit 64
fi

if [[ ! "$BACKUP_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: --backup-name may contain only letters, digits, dot, underscore, and dash." >&2
  exit 64
fi

if [[ -n "$SSH_KEY" && -n "$SSH_PASS" ]]; then
  echo "ERROR: --ssh-key and --ssh-password are mutually exclusive." >&2
  exit 64
fi

if [[ -n "$SSH_KEY" && ! -r "$SSH_KEY" ]]; then
  echo "ERROR: SSH key file not found or not readable: $SSH_KEY" >&2
  exit 64
fi

if ! FULL_FREQ_SECONDS="$(parse_interval_to_seconds "$FULL_FREQ_RAW")"; then
  echo "ERROR: Invalid --full-backup-frequency: '$FULL_FREQ_RAW'. Use e.g. 7d, 2w, 12h, 30m, or 7." >&2
  exit 64
fi

if ! RETENTION_SECONDS="$(parse_interval_to_seconds "$RETENTION_RAW")"; then
  echo "ERROR: Invalid --retention-time: '$RETENTION_RAW'. Use e.g. 14d, 2w, 12h, 30m, or 7." >&2
  exit 64
fi

if ! INCREMENTAL_FREQ_SECONDS="$(parse_interval_to_seconds "$INCREMENTAL_FREQ_RAW")"; then
  echo "ERROR: Invalid --incremental-backup-frequency: '$INCREMENTAL_FREQ_RAW'. Use e.g. 12h, 2d, 30m, or 7." >&2
  exit 64
fi

if (( RETENTION_SECONDS <= 0 || FULL_FREQ_SECONDS <= 0 || INCREMENTAL_FREQ_SECONDS <= 0 )); then
  echo "ERROR: Retention time and backup frequencies must be greater than zero." >&2
  exit 64
fi

RETENTION_MINUTES=$(( RETENTION_SECONDS / 60 ))

require_cmd date
require_cmd find
require_cmd flock
require_cmd mktemp
require_cmd rsync
require_cmd sha256sum
require_cmd zip

if [[ "$DRY_RUN" -eq 0 ]]; then
  require_cmd ssh
fi

if [[ -n "$SSH_PASS" && "$DRY_RUN" -eq 0 ]]; then
  require_cmd sshpass
fi

umask 077

BACKUP_DIR="${BACKUP_ROOT%/}/${BACKUP_NAME}"
STATE_DIR="${BACKUP_DIR}/.state"
SNAPSHOT_DIR="${STATE_DIR}/snapshots"
LATEST_SNAPSHOT_DIR="${SNAPSHOT_DIR}/latest"
FULL_SNAPSHOT_DIR="${SNAPSHOT_DIR}/full_base"
STATE_FILE="${STATE_DIR}/state.env"
LOCKFILE="${BACKUP_DIR}/.file_backup.lock"

mkdir -p "$SNAPSHOT_DIR"

exec 9>"$LOCKFILE"
flock -n 9 || { log "Another backup is already running (lock: $LOCKFILE). Exiting."; exit 0; }

load_state_file "$STATE_FILE"

NOW_EPOCH="$(date -u +%s)"
BACKUP_MODE="none"
MODE_REASON="no backup is due"

if [[ ! -d "$FULL_SNAPSHOT_DIR" || -z "$LAST_FULL_ID" || "$LAST_FULL_EPOCH" -eq 0 ]]; then
  BACKUP_MODE="full"
  MODE_REASON="no previous full backup state was found"
elif (( NOW_EPOCH - LAST_FULL_EPOCH >= FULL_FREQ_SECONDS )); then
  BACKUP_MODE="full"
  MODE_REASON="the full backup interval has elapsed"
elif [[ ! -d "$LATEST_SNAPSHOT_DIR" || -z "$LAST_BACKUP_ID" || "$LAST_BACKUP_EPOCH" -eq 0 ]]; then
  BACKUP_MODE="full"
  MODE_REASON="the latest snapshot state is missing"
elif (( NOW_EPOCH - LAST_BACKUP_EPOCH >= INCREMENTAL_FREQ_SECONDS )); then
  BACKUP_MODE="incremental"
  MODE_REASON="the incremental backup interval has elapsed"
fi

if [[ "$BACKUP_MODE" == "none" ]]; then
  log "No backup due for '${BACKUP_NAME}' (${MODE_REASON})."
  exit 0
fi

BACKUP_ID="$(date -u +'%Y%m%dT%H%M%SZ')"
WORK_DIR="$(mktemp -d "${STATE_DIR}/work.${BACKUP_ID}.XXXXXX")"
CURRENT_SNAPSHOT_DIR="${WORK_DIR}/current"
PACKAGE_DIR="${WORK_DIR}/package"
PACKAGE_DATA_DIR="${PACKAGE_DIR}/data"
PACKAGE_META_DIR="${PACKAGE_DIR}/.file_backup_meta"
CHANGES_FILE="${WORK_DIR}/changed_paths.txt"
DELETIONS_FILE="${PACKAGE_META_DIR}/deleted_paths.txt"
CHANGED_COUNT=0
DELETED_COUNT=0

cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$PACKAGE_DATA_DIR" "$PACKAGE_META_DIR"

log "Starting ${BACKUP_MODE} backup for '${BACKUP_NAME}' because ${MODE_REASON}."
if [[ "$DRY_RUN" -eq 1 ]]; then
  rsync_shell_preview=""
  remote_source_preview=""
  remote_source_preview="$(build_remote_source)"
  rsync_shell_preview="$(build_rsync_shell_command)"
  if [[ -n "$REMOTE_RSYNC_PATH" ]]; then
    log "[DRY-RUN] Would sync: $(format_command rsync -a --checksum --delete -e "$rsync_shell_preview" --rsync-path "$REMOTE_RSYNC_PATH" "$remote_source_preview" "$CURRENT_SNAPSHOT_DIR/")"
  else
    log "[DRY-RUN] Would sync: $(format_command rsync -a --checksum --delete -e "$rsync_shell_preview" "$remote_source_preview" "$CURRENT_SNAPSHOT_DIR/")"
  fi
fi

sync_remote_snapshot "$CURRENT_SNAPSHOT_DIR"

if [[ "$BACKUP_MODE" == "full" ]]; then
  rsync -a "$CURRENT_SNAPSHOT_DIR/" "$PACKAGE_DATA_DIR/"
  : > "$DELETIONS_FILE"
  BASE_FULL_ID="$BACKUP_ID"
  PREVIOUS_BACKUP_ID="${LAST_BACKUP_ID:-none}"
  ARCHIVE_NAME="${BACKUP_NAME}-full-${BACKUP_ID}.zip"
  CHANGED_COUNT="$(find "$CURRENT_SNAPSHOT_DIR" -mindepth 1 | wc -l | tr -d ' ')"
  DELETED_COUNT=0
else
  collect_incremental_changes "$LATEST_SNAPSHOT_DIR" "$CURRENT_SNAPSHOT_DIR" "$CHANGES_FILE" "$DELETIONS_FILE"
  stage_incremental_payload "$CURRENT_SNAPSHOT_DIR" "$CHANGES_FILE" "$PACKAGE_DATA_DIR"

  if [[ -s "$CHANGES_FILE" ]]; then
    CHANGED_COUNT="$(wc -l < "$CHANGES_FILE" | tr -d ' ')"
  else
    CHANGED_COUNT=0
  fi

  if [[ -s "$DELETIONS_FILE" ]]; then
    DELETED_COUNT="$(wc -l < "$DELETIONS_FILE" | tr -d ' ')"
  else
    DELETED_COUNT=0
  fi

  BASE_FULL_ID="$LAST_FULL_ID"
  PREVIOUS_BACKUP_ID="$LAST_BACKUP_ID"
  ARCHIVE_NAME="${BACKUP_NAME}-inc-full-${BASE_FULL_ID}-prev-${PREVIOUS_BACKUP_ID}-${BACKUP_ID}.zip"
fi

write_backup_metadata \
  "$PACKAGE_META_DIR" \
  "$BACKUP_MODE" \
  "$BACKUP_ID" \
  "$BASE_FULL_ID" \
  "$PREVIOUS_BACKUP_ID" \
  "$CHANGED_COUNT" \
  "$DELETED_COUNT"

ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
create_archive_and_checksum "$PACKAGE_DIR" "$ARCHIVE_PATH" "$CHECKSUM_PATH"

if [[ "$BACKUP_MODE" == "full" ]]; then
  refresh_snapshot_state_full "$CURRENT_SNAPSHOT_DIR"
  write_state_file "$STATE_FILE" "$BACKUP_ID" "full" "$NOW_EPOCH" "$BACKUP_ID" "$NOW_EPOCH"
  ACTIVE_FULL_ID="$BACKUP_ID"
else
  refresh_snapshot_state_incremental "$CURRENT_SNAPSHOT_DIR"
  write_state_file "$STATE_FILE" "$BACKUP_ID" "incremental" "$NOW_EPOCH" "$LAST_FULL_ID" "$LAST_FULL_EPOCH"
  ACTIVE_FULL_ID="$LAST_FULL_ID"
fi

prune_expired_backup_chains "$ACTIVE_FULL_ID"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Archive created: $ARCHIVE_PATH"
  log "[DRY-RUN] Checksum created: $CHECKSUM_PATH"
else
  log "Archive created: $ARCHIVE_PATH"
  log "Checksum created: $CHECKSUM_PATH"
fi

log "Backup '${BACKUP_NAME}' completed successfully."
