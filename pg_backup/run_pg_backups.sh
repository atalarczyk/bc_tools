#!/usr/bin/env bash
#------------------------------------------------------------------------------
# run_pg_backups.sh
# Uruchamia pg_backup.sh dla wielu baz PostgreSQL wg konfiguracji w JSON.
# Użycie:
#   run_pg_backups.sh [--config /ścieżka/do/pliku.json]
#------------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_VERSION="1.1.0"

DEFAULT_CONFIG="/usr/local/etc/pg_backup.json"
CONFIG_FILE="$DEFAULT_CONFIG"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"; }
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  -c, --config <path>   Ścieżka do pliku JSON (domyślnie: $DEFAULT_CONFIG)
  -v, --version         Wypisz wersję skryptu i zakończ
  -h, --help            Pomoc
EOF
}

# --- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
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

[[ -x "$BACKUP_SCRIPT" ]] || { log "❌ ERROR: Skrypt $BACKUP_SCRIPT nie jest wykonywalny"; exit 1; }

BACKUP_COUNT=$(jq '.backups | length' "$CONFIG_FILE")
(( BACKUP_COUNT > 0 )) || { log "ℹ️  Brak zadań backupu w $CONFIG_FILE"; exit 0; }

log "▶️  Start ($BACKUP_COUNT zadań) | config=$CONFIG_FILE | global_dry_run=$GLOBAL_DRY_RUN"
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
for i in $(seq 0 $((BACKUP_COUNT - 1))); do
  NAME=$(jq -r ".backups[$i].name" "$CONFIG_FILE")
  HOST=$(jq -r ".backups[$i].host // \"$DEFAULT_HOST\"" "$CONFIG_FILE")
  PORT=$(jq -r ".backups[$i].port // $DEFAULT_PORT" "$CONFIG_FILE")
  USER=$(jq -r ".backups[$i].user // \"$DEFAULT_USER\"" "$CONFIG_FILE")
  PASS=$(jq -r ".backups[$i].password // \"$DEFAULT_PASS\"" "$CONFIG_FILE")
  DBNAME=$(jq -r ".backups[$i].database" "$CONFIG_FILE")
  BACKUP_DIR=$(jq -r ".backups[$i].backup_dir // \"$BACKUP_ROOT\"" "$CONFIG_FILE")
  RETENTION=$(jq -r ".backups[$i].retention_time // \"$RETENTION_DEFAULT\"" "$CONFIG_FILE")
  PG_DUMP_VERSION=$(jq -r --arg default "$PG_DUMP_VERSION_DEFAULT" ".backups[$i].pg_dump_version // \$default // empty" "$CONFIG_FILE")

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

  log "⏩  [$NAME] host=$HOST port=$PORT db=$DBNAME retention=$RETENTION pg_dump=${PG_DUMP_VERSION:-<domyślny z PATH>} dir=$BACKUP_DIR opts=${OPTIONS[*]:-—}"

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
  CMD+=("${OPTIONS[@]}")

  if "${CMD[@]}"; then
    log "✅ [$NAME] OK"
  else
    log "❌ [$NAME] BŁĄD"
  fi
  log "---------------------------------------------"
done

log "🎯 Zakończono wszystkie zadania."
