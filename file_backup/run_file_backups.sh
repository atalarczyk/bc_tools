#!/usr/bin/env bash
#------------------------------------------------------------------------------
# run_file_backups.sh
# Runs file_backup.sh for multiple jobs defined in a JSON config.
#------------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_VERSION="1.1.1"

DEFAULT_CONFIG="/usr/local/etc/file_backup.json"
CONFIG_FILE="$DEFAULT_CONFIG"
LIST_MODE=0
CLI_DRY_RUN=0
RUN_NAME=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  -c, --config <path>   Ścieżka do pliku JSON (domyślnie: $DEFAULT_CONFIG)
  -d, --dry-run         Tryb próbny: dodaj --dry-run do każdego wywołania file_backup.sh
  -r, --run <name>      Uruchom tylko zadanie o podanej nazwie
  -l, --list            Wypisz wszystkie zadania z ich efektywną konfiguracją
  -v, --version         Wypisz wersję skryptu i zakończ
  -h, --help            Pomoc
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -d|--dry-run) CLI_DRY_RUN=1; shift ;;
    -r|--run)
      [[ -z "${2:-}" ]] && { log "❌ Opcja -r wymaga podania nazwy zadania"; usage; exit 64; }
      RUN_NAME="$2"
      shift 2
      ;;
    -l|--list) LIST_MODE=1; shift ;;
    -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help|-\?) usage; exit 0 ;;
    *) log "❌ Nieznana opcja: $1"; usage; exit 64 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { log "❌ ERROR: Brak 'jq' (sudo apt install jq)"; exit 1; }
[[ -r "$CONFIG_FILE" ]] || { log "❌ ERROR: Brak pliku konfiguracyjnego: $CONFIG_FILE"; exit 1; }

BACKUP_SCRIPT=$(jq -r '.backup_script // "/usr/local/bin/file_backup.sh"' "$CONFIG_FILE")
BACKUP_ROOT=$(jq -r '.backup_root // "/mnt/dane/Backup/files"' "$CONFIG_FILE")
RETENTION_DEFAULT=$(jq -r '.default_retention // "30d"' "$CONFIG_FILE")
FULL_FREQUENCY_DEFAULT=$(jq -r '.default_full_backup_frequency // "7d"' "$CONFIG_FILE")
INCREMENTAL_FREQUENCY_DEFAULT=$(jq -r '.default_incremental_backup_frequency // "24h"' "$CONFIG_FILE")

DEFAULT_HOST=$(jq -r '.default_host // empty' "$CONFIG_FILE")
DEFAULT_PORT=$(jq -r '.default_ssh_port // 22' "$CONFIG_FILE")
DEFAULT_USER=$(jq -r '.default_ssh_user // empty' "$CONFIG_FILE")
DEFAULT_KEY=$(jq -r '.default_ssh_key // empty' "$CONFIG_FILE")
DEFAULT_PASS=$(jq -r '.default_ssh_password // empty' "$CONFIG_FILE")
DEFAULT_REMOTE_RSYNC_PATH=$(jq -r '.default_remote_rsync_path // empty' "$CONFIG_FILE")

GLOBAL_DRY_RUN=$(jq -r '.global_dry_run // false' "$CONFIG_FILE")
(( CLI_DRY_RUN )) && GLOBAL_DRY_RUN=true

has_flag() {
  local flag="$1"
  shift
  local opt=""
  for opt in "$@"; do
    [[ "$opt" == "$flag" ]] && return 0
  done
  return 1
}

list_backups() {
  local count
  count=$(jq '.backups | length' "$CONFIG_FILE")
  printf 'Konfiguracja: %s\n' "$CONFIG_FILE"
  printf 'Liczba zadań: %d\n' "$count"
  if (( count == 0 )); then
    printf 'Brak zdefiniowanych zadań backupu.\n'
    return
  fi

  local i
  for i in $(seq 0 $((count - 1))); do
    local name host source_dir backup_dir retention full_freq inc_freq ssh_port ssh_user ssh_key ssh_pass remote_rsync_path
    local -a options=()

    name=$(jq -r ".backups[$i].name // empty" "$CONFIG_FILE")
    host=$(jq -r --arg default "$DEFAULT_HOST" ".backups[$i].host // \$default // empty" "$CONFIG_FILE")
    source_dir=$(jq -r ".backups[$i].source_dir // empty" "$CONFIG_FILE")
    backup_dir=$(jq -r ".backups[$i].backup_dir // \"$BACKUP_ROOT\"" "$CONFIG_FILE")
    retention=$(jq -r ".backups[$i].retention_time // \"$RETENTION_DEFAULT\"" "$CONFIG_FILE")
    full_freq=$(jq -r ".backups[$i].full_backup_frequency // \"$FULL_FREQUENCY_DEFAULT\"" "$CONFIG_FILE")
    inc_freq=$(jq -r ".backups[$i].incremental_backup_frequency // \"$INCREMENTAL_FREQUENCY_DEFAULT\"" "$CONFIG_FILE")
    ssh_port=$(jq -r ".backups[$i].ssh_port // $DEFAULT_PORT" "$CONFIG_FILE")
    ssh_user=$(jq -r --arg default "$DEFAULT_USER" ".backups[$i].ssh_user // \$default // empty" "$CONFIG_FILE")
    ssh_key=$(jq -r --arg default "$DEFAULT_KEY" ".backups[$i].ssh_key // \$default // empty" "$CONFIG_FILE")
    ssh_pass=$(jq -r --arg default "$DEFAULT_PASS" ".backups[$i].ssh_password // \$default // empty" "$CONFIG_FILE")
    remote_rsync_path=$(jq -r --arg default "$DEFAULT_REMOTE_RSYNC_PATH" ".backups[$i].remote_rsync_path // \$default // empty" "$CONFIG_FILE")
    readarray -t options < <(jq -r ".backups[$i].options[]?" "$CONFIG_FILE")

    if [[ "$GLOBAL_DRY_RUN" == "true" ]] && ! has_flag "--dry-run" "${options[@]}"; then
      options+=("--dry-run")
    fi

    printf '\n[%d] %s\n' "$((i + 1))" "$name"
    printf '    host:         %s\n' "${host:-<brak>}"
    printf '    source_dir:   %s\n' "${source_dir:-<brak>}"
    printf '    backup_dir:   %s\n' "$backup_dir"
    printf '    retention:    %s\n' "$retention"
    printf '    full_every:   %s\n' "$full_freq"
    printf '    incr_every:   %s\n' "$inc_freq"
    printf '    ssh_port:     %s\n' "$ssh_port"
    printf '    ssh_user:     %s\n' "${ssh_user:-<bieżący użytkownik>}"
    if [[ -n "$ssh_key" ]]; then
      printf '    ssh_key:      %s\n' "$ssh_key"
    fi
    if [[ -n "$ssh_pass" ]]; then
      printf '    ssh_password: ***\n'
    fi
    if [[ -n "$remote_rsync_path" ]]; then
      printf '    remote_rsync: %s\n' "$remote_rsync_path"
    fi
    if [[ ${#options[@]} -gt 0 ]]; then
      printf '    options:      %s\n' "${options[*]}"
    fi
  done
}

if (( LIST_MODE )); then
  list_backups
  exit 0
fi

[[ -x "$BACKUP_SCRIPT" ]] || { log "❌ ERROR: Skrypt $BACKUP_SCRIPT nie jest wykonywalny"; exit 1; }

BACKUP_COUNT=$(jq '.backups | length' "$CONFIG_FILE")
(( BACKUP_COUNT > 0 )) || { log "ℹ️  Brak zadań backupu w $CONFIG_FILE"; exit 0; }

LOOP_INDICES=()
if [[ -n "$RUN_NAME" ]]; then
  RUN_INDEX=$(jq -r --arg name "$RUN_NAME" \
    '.backups | to_entries[] | select(.value.name == $name) | .key' \
    "$CONFIG_FILE" | head -1)
  if [[ -z "$RUN_INDEX" ]]; then
    log "❌ ERROR: Zadanie '$RUN_NAME' nie istnieje w $CONFIG_FILE"
    exit 1
  fi
  LOOP_INDICES=("$RUN_INDEX")
  log "▶️  Start (1 zadanie: $RUN_NAME) | config=$CONFIG_FILE | global_dry_run=$GLOBAL_DRY_RUN"
else
  mapfile -t LOOP_INDICES < <(seq 0 $((BACKUP_COUNT - 1)))
  log "▶️  Start ($BACKUP_COUNT zadań) | config=$CONFIG_FILE | global_dry_run=$GLOBAL_DRY_RUN"
fi

log "   Domyślne: host=${DEFAULT_HOST:-<brak>}, ssh_port=${DEFAULT_PORT}, ssh_user=${DEFAULT_USER:-<bieżący>}, retention=${RETENTION_DEFAULT}, full=${FULL_FREQUENCY_DEFAULT}, incremental=${INCREMENTAL_FREQUENCY_DEFAULT}, remote_rsync=${DEFAULT_REMOTE_RSYNC_PATH:-<z PATH na hoście zdalnym>}"

for i in "${LOOP_INDICES[@]}"; do
  NAME=$(jq -r ".backups[$i].name // empty" "$CONFIG_FILE")
  HOST=$(jq -r --arg default "$DEFAULT_HOST" ".backups[$i].host // \$default // empty" "$CONFIG_FILE")
  SOURCE_DIR=$(jq -r ".backups[$i].source_dir // empty" "$CONFIG_FILE")
  BACKUP_DIR=$(jq -r ".backups[$i].backup_dir // \"$BACKUP_ROOT\"" "$CONFIG_FILE")
  RETENTION=$(jq -r ".backups[$i].retention_time // \"$RETENTION_DEFAULT\"" "$CONFIG_FILE")
  FULL_FREQUENCY=$(jq -r ".backups[$i].full_backup_frequency // \"$FULL_FREQUENCY_DEFAULT\"" "$CONFIG_FILE")
  INCREMENTAL_FREQUENCY=$(jq -r ".backups[$i].incremental_backup_frequency // \"$INCREMENTAL_FREQUENCY_DEFAULT\"" "$CONFIG_FILE")
  SSH_PORT=$(jq -r ".backups[$i].ssh_port // $DEFAULT_PORT" "$CONFIG_FILE")
  SSH_USER=$(jq -r --arg default "$DEFAULT_USER" ".backups[$i].ssh_user // \$default // empty" "$CONFIG_FILE")
  SSH_KEY=$(jq -r --arg default "$DEFAULT_KEY" ".backups[$i].ssh_key // \$default // empty" "$CONFIG_FILE")
  SSH_PASS=$(jq -r --arg default "$DEFAULT_PASS" ".backups[$i].ssh_password // \$default // empty" "$CONFIG_FILE")
  REMOTE_RSYNC_PATH=$(jq -r --arg default "$DEFAULT_REMOTE_RSYNC_PATH" ".backups[$i].remote_rsync_path // \$default // empty" "$CONFIG_FILE")

  if [[ -z "$NAME" || -z "$HOST" || -z "$SOURCE_DIR" ]]; then
    log "⚠️  [${NAME:-<bez nazwy>}] Pominięto: brak wymaganych pól (name/host/source_dir)"
    continue
  fi

  readarray -t OPTIONS < <(jq -r ".backups[$i].options[]?" "$CONFIG_FILE")
  if [[ "$GLOBAL_DRY_RUN" == "true" ]] && ! has_flag "--dry-run" "${OPTIONS[@]}"; then
    OPTIONS+=("--dry-run")
  fi

  log "⏩  [$NAME] host=$HOST source=$SOURCE_DIR retention=$RETENTION full=$FULL_FREQUENCY incremental=$INCREMENTAL_FREQUENCY ssh_port=$SSH_PORT remote_rsync=${REMOTE_RSYNC_PATH:-<z PATH>} dir=$BACKUP_DIR opts=${OPTIONS[*]:-—}"

  CMD=(
    "$BACKUP_SCRIPT"
    --backup-name "$NAME"
    --source-host "$HOST"
    --source-dir "$SOURCE_DIR"
    --backup-dir "$BACKUP_DIR"
    --retention-time "$RETENTION"
    --full-backup-frequency "$FULL_FREQUENCY"
    --incremental-backup-frequency "$INCREMENTAL_FREQUENCY"
    --ssh-port "$SSH_PORT"
  )

  [[ -n "$SSH_USER" ]] && CMD+=(--ssh-user "$SSH_USER")
  [[ -n "$SSH_KEY" ]] && CMD+=(--ssh-key "$SSH_KEY")
  [[ -n "$SSH_PASS" ]] && CMD+=(--ssh-password "$SSH_PASS")
  [[ -n "$REMOTE_RSYNC_PATH" ]] && CMD+=(--remote-rsync-path "$REMOTE_RSYNC_PATH")
  CMD+=("${OPTIONS[@]}")

  if "${CMD[@]}"; then
    log "✅ [$NAME] OK"
  else
    log "❌ [$NAME] BŁĄD"
  fi
  log "---------------------------------------------"
done

log "🎯 Zakończono wszystkie zadania."
