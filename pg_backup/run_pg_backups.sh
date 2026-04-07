#!/usr/bin/env bash
#------------------------------------------------------------------------------
# run_pg_backups.sh
# Uruchamia pg_backup.sh dla wielu baz PostgreSQL wg konfiguracji w JSON.
# Użycie:
#   run_pg_backups.sh [--config /ścieżka/do/pliku.json]
#------------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_VERSION="1.3.0"

DEFAULT_CONFIG="/usr/local/etc/pg_backup.json"
CONFIG_FILE="$DEFAULT_CONFIG"
LIST_MODE=0
CLI_DRY_RUN=0
RUN_NAME=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"; }
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  -c, --config <path>   Ścieżka do pliku JSON (domyślnie: $DEFAULT_CONFIG)
  -d, --dry-run         Tryb próbny: dodaj --dry-run do każdego wywołania pg_backup.sh
  -r, --run <name>      Uruchom tylko zadanie o podanej nazwie (wymaga -c)
  -l, --list            Wypisz nazwy i szczegóły wszystkich konfiguracji z pliku JSON i zakończ
  -v, --version         Wypisz wersję skryptu i zakończ
  -h, --help            Pomoc
EOF
}

# --- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -d|--dry-run) CLI_DRY_RUN=1; shift ;;
    -r|--run)
      [[ -z "${2:-}" ]] && { log "❌ Opcja -r wymaga podania nazwy zadania"; usage; exit 64; }
      RUN_NAME="$2"; shift 2 ;;
    -l|--list) LIST_MODE=1; shift ;;
    -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help|-\?) usage; exit 0 ;;
    *) log "❌ Nieznana opcja: $1"; usage; exit 64 ;;
  esac
done

# --- deps / config ---
command -v jq >/dev/null 2>&1 || { log "❌ ERROR: Brak 'jq' (sudo apt install jq)"; exit 1; }
[[ -r "$CONFIG_FILE" ]] || { log "❌ ERROR: Brak pliku konfiguracyjnego: $CONFIG_FILE"; exit 1; }

BACKUP_SCRIPT=$(jq -r '.backup_script // "/usr/local/bin/pg_backup.sh"' "$CONFIG_FILE")
BACKUP_ROOT=$(jq -r '.backup_root // "/mnt/dane/Backup"' "$CONFIG_FILE")
RETENTION_DEFAULT=$(jq -r '.default_retention // "14d"' "$CONFIG_FILE")
PG_DUMP_VERSION_DEFAULT=$(jq -r '.default_pg_dump_version // empty' "$CONFIG_FILE")

DEFAULT_HOST=$(jq -r '.default_host // null' "$CONFIG_FILE")
DEFAULT_PORT=$(jq -r '.default_port // 5432' "$CONFIG_FILE")
DEFAULT_USER=$(jq -r '.default_user // null' "$CONFIG_FILE")
DEFAULT_PASS=$(jq -r '.default_password // null' "$CONFIG_FILE")

GLOBAL_DRY_RUN=$(jq -r '.global_dry_run // false' "$CONFIG_FILE")
(( CLI_DRY_RUN )) && GLOBAL_DRY_RUN=true

DEFAULT_SSH_HOST=$(jq -r '.default_ssh_host // null' "$CONFIG_FILE")
DEFAULT_SSH_PORT=$(jq -r '.default_ssh_port // 22' "$CONFIG_FILE")
DEFAULT_SSH_USER=$(jq -r '.default_ssh_user // null' "$CONFIG_FILE")
DEFAULT_SSH_KEY=$(jq -r '.default_ssh_key // null' "$CONFIG_FILE")
DEFAULT_SSH_PASS=$(jq -r '.default_ssh_password // null' "$CONFIG_FILE")

# --- list backups (-l) ---
list_backups() {
  local count
  count=$(jq '.backups | length' "$CONFIG_FILE")
  printf 'Konfiguracja: %s\n' "$CONFIG_FILE"
  printf 'Liczba zadań: %d\n' "$count"
  if (( count == 0 )); then
    printf 'Brak zdefiniowanych zadań backupu.\n'
    return
  fi
  for i in $(seq 0 $((count - 1))); do
    local name host port user dbname backup_dir retention pg_dump_ver
    local ssh_host ssh_port ssh_user ssh_key ssh_pass ssh_local_port
    name=$(jq -r ".backups[$i].name" "$CONFIG_FILE")
    host=$(jq -r ".backups[$i].host // \"$DEFAULT_HOST\"" "$CONFIG_FILE")
    port=$(jq -r ".backups[$i].port // $DEFAULT_PORT" "$CONFIG_FILE")
    user=$(jq -r ".backups[$i].user // \"$DEFAULT_USER\"" "$CONFIG_FILE")
    dbname=$(jq -r ".backups[$i].database" "$CONFIG_FILE")
    backup_dir=$(jq -r ".backups[$i].backup_dir // \"$BACKUP_ROOT\"" "$CONFIG_FILE")
    retention=$(jq -r ".backups[$i].retention_time // \"$RETENTION_DEFAULT\"" "$CONFIG_FILE")
    pg_dump_ver=$(jq -r --arg default "$PG_DUMP_VERSION_DEFAULT" ".backups[$i].pg_dump_version // \$default // empty" "$CONFIG_FILE")
    ssh_host=$(jq -r --arg default "$DEFAULT_SSH_HOST" ".backups[$i].ssh_host // \$default" "$CONFIG_FILE")
    ssh_port=$(jq -r --arg default "$DEFAULT_SSH_PORT" ".backups[$i].ssh_port // \$default" "$CONFIG_FILE")
    ssh_user=$(jq -r --arg default "$DEFAULT_SSH_USER" ".backups[$i].ssh_user // \$default" "$CONFIG_FILE")
    ssh_key=$(jq -r --arg default "$DEFAULT_SSH_KEY" ".backups[$i].ssh_key // \$default" "$CONFIG_FILE")
    ssh_pass=$(jq -r --arg default "$DEFAULT_SSH_PASS" ".backups[$i].ssh_password // \$default" "$CONFIG_FILE")
    ssh_local_port=$(jq -r ".backups[$i].ssh_local_port // empty" "$CONFIG_FILE")

    printf '\n[%d] %s\n' "$((i+1))" "$name"
    printf '    host:       %s:%s\n' "${host:-<brak>}" "$port"
    printf '    user:       %s\n' "${user:-<brak>}"
    printf '    database:   %s\n' "${dbname:-<brak>}"
    printf '    backup_dir: %s\n' "$backup_dir"
    printf '    retention:  %s\n' "$retention"
    if [[ -n "$pg_dump_ver" ]]; then
      printf '    pg_dump:    %s\n' "$pg_dump_ver"
    fi
    if [[ -n "$ssh_host" && "$ssh_host" != "null" ]]; then
      local ssh_info="${ssh_user:+${ssh_user}@}${ssh_host}:${ssh_port}"
      if [[ -n "$ssh_key" && "$ssh_key" != "null" ]]; then ssh_info+=" key=${ssh_key}"; fi
      if [[ -n "$ssh_pass" && "$ssh_pass" != "null" ]]; then ssh_info+=" (hasło)"; fi
      if [[ -n "$ssh_local_port" ]]; then ssh_info+=" local_port=${ssh_local_port}"; fi
      printf '    ssh:        %s\n' "$ssh_info"
    fi
    local -a options=()
    readarray -t options < <(jq -r ".backups[$i].options[]?" "$CONFIG_FILE")
    if [[ ${#options[@]} -gt 0 ]]; then
      printf '    options:    %s\n' "${options[*]}"
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

# --- rozwiąż -r/--run na indeks ---
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
log "   Domyślne: host=${DEFAULT_HOST:-<brak>}, port=${DEFAULT_PORT}, user=${DEFAULT_USER:-<brak>}, retention=$RETENTION_DEFAULT, pg_dump=${PG_DUMP_VERSION_DEFAULT:-<domyślny z PATH>}"

# helper: sprawdź czy tablica opcji zawiera daną flagę
has_flag() {
  local flag="$1"; shift
  for opt in "$@"; do
    [[ "$opt" == "$flag" ]] && return 0
  done
  return 1
}

# --- iteracja po backupach ---
for i in "${LOOP_INDICES[@]}"; do
  NAME=$(jq -r ".backups[$i].name" "$CONFIG_FILE")
  HOST=$(jq -r ".backups[$i].host // \"$DEFAULT_HOST\"" "$CONFIG_FILE")
  PORT=$(jq -r ".backups[$i].port // $DEFAULT_PORT" "$CONFIG_FILE")
  USER=$(jq -r ".backups[$i].user // \"$DEFAULT_USER\"" "$CONFIG_FILE")
  PASS=$(jq -r ".backups[$i].password // \"$DEFAULT_PASS\"" "$CONFIG_FILE")
  DBNAME=$(jq -r ".backups[$i].database" "$CONFIG_FILE")
  BACKUP_DIR=$(jq -r ".backups[$i].backup_dir // \"$BACKUP_ROOT\"" "$CONFIG_FILE")
  RETENTION=$(jq -r ".backups[$i].retention_time // \"$RETENTION_DEFAULT\"" "$CONFIG_FILE")
  PG_DUMP_VERSION=$(jq -r --arg default "$PG_DUMP_VERSION_DEFAULT" ".backups[$i].pg_dump_version // \$default // empty" "$CONFIG_FILE")

  SSH_HOST=$(jq -r --arg default "$DEFAULT_SSH_HOST" ".backups[$i].ssh_host // \$default" "$CONFIG_FILE")
  SSH_PORT=$(jq -r --arg default "$DEFAULT_SSH_PORT" ".backups[$i].ssh_port // \$default" "$CONFIG_FILE")
  SSH_USER=$(jq -r --arg default "$DEFAULT_SSH_USER" ".backups[$i].ssh_user // \$default" "$CONFIG_FILE")
  SSH_KEY=$(jq -r --arg default "$DEFAULT_SSH_KEY" ".backups[$i].ssh_key // \$default" "$CONFIG_FILE")
  SSH_PASS=$(jq -r --arg default "$DEFAULT_SSH_PASS" ".backups[$i].ssh_password // \$default" "$CONFIG_FILE")
  SSH_LOCAL_PORT=$(jq -r ".backups[$i].ssh_local_port // empty" "$CONFIG_FILE")

  # walidacja
  if [[ -z "$HOST" || -z "$USER" || -z "$PASS" || -z "$DBNAME" ]]; then
    log "⚠️  [$NAME] Pominięto: brak wymaganych pól (host/user/pass/database)"
    continue
  fi

  # wczytaj tablicę opcji (jeśli istnieje)
  readarray -t OPTIONS < <(jq -r ".backups[$i].options[]?" "$CONFIG_FILE")

  # globalny dry-run: dodaj --dry-run, jeśli wpis sam go nie ma
  if [[ "$GLOBAL_DRY_RUN" == "true" ]] && ! has_flag "--dry-run" "${OPTIONS[@]}"; then
    OPTIONS+=("--dry-run")
  fi

  SSH_INFO="none"
  if [[ -n "$SSH_HOST" && "$SSH_HOST" != "null" ]]; then
    SSH_INFO="${SSH_USER:+${SSH_USER}@}${SSH_HOST}:${SSH_PORT}"
  fi
  log "⏩  [$NAME] host=$HOST port=$PORT db=$DBNAME retention=$RETENTION pg_dump=${PG_DUMP_VERSION:-<domyślny z PATH>} ssh=${SSH_INFO} dir=$BACKUP_DIR opts=${OPTIONS[*]:-—}"

  CMD=(
    "$BACKUP_SCRIPT"
    --database-server "$HOST"
    --database-port "$PORT"
    --database-user "$USER"
    --database-password "$PASS"
    --database-name "$DBNAME"
    --backup-dir "$BACKUP_DIR"
    --retention-time "$RETENTION"
  )
  [[ -n "$PG_DUMP_VERSION" ]] && CMD+=(--pg-dump-version "$PG_DUMP_VERSION")
  if [[ -n "$SSH_HOST" && "$SSH_HOST" != "null" ]]; then
    CMD+=(--ssh-host "$SSH_HOST" --ssh-port "$SSH_PORT")
    [[ -n "$SSH_USER" && "$SSH_USER" != "null" ]] && CMD+=(--ssh-user "$SSH_USER")
    [[ -n "$SSH_KEY" && "$SSH_KEY" != "null" ]] && CMD+=(--ssh-key "$SSH_KEY")
    [[ -n "$SSH_PASS" && "$SSH_PASS" != "null" ]] && CMD+=(--ssh-password "$SSH_PASS")
    [[ -n "$SSH_LOCAL_PORT" ]] && CMD+=(--ssh-local-port "$SSH_LOCAL_PORT")
  fi
  CMD+=("${OPTIONS[@]}")

  if "${CMD[@]}"; then
    log "✅ [$NAME] OK"
  else
    log "❌ [$NAME] BŁĄD"
  fi
  log "---------------------------------------------"
done

log "🎯 Zakończono wszystkie zadania."
