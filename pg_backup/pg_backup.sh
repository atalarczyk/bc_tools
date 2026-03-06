#!/usr/bin/env bash
#------------------------------------------------------------------------------
# PostgreSQL Remote Backup Script with Retention, Dry-Run, and Named Parameters
#------------------------------------------------------------------------------
# Description:
#   Creates timestamped backups from a remote PostgreSQL server, stores them
#   in a structured backup directory, generates SHA256 checksums, and removes
#   backups older than the specified retention time.
#
# Usage Example:
#   pg_backup.sh \
#     --database-server db.example.com \
#     --database-port 5433 \
#     --database-user backupuser \
#     --database-password 'S3cret!' \
#     --database-name mydb \
#     --backup-dir /mnt/dane/Backup \
#     --retention-time 14d
#
# Dry-run Example (simulates backup without DB connection):
#   pg_backup.sh \
#     --dry-run \
#     --database-server db.example.com \
#     --database-user backupuser \
#     --database-password dummy \
#     --database-name mydb \
#     --backup-dir /mnt/dane/Backup \
#     --retention-time 7d
#------------------------------------------------------------------------------

set -Eeuo pipefail

#------------------------------------------------------------------------------
# Helper: print usage
#------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  pg_backup.sh [OPTIONS]

Required options:
  --database-server   <host>        PostgreSQL server hostname or IP
  --database-user     <user>        PostgreSQL username
  --database-password <password>    PostgreSQL password
  --database-name     <dbname>      Name of the database to back up
  --backup-dir        <path>        Directory where backups are stored
  --retention-time    <time>        Retention (e.g., 7d, 2w, 36h, 90m)

Optional:
  --database-port     <port>        PostgreSQL port (default: 5432)
  --dry-run                         Do not connect to PostgreSQL, create dummy file
  -h, --help                        Show this help and exit

Examples:
  pg_backup.sh --database-server db.example.com \
               --database-port 5432 \
               --database-user backupuser \
               --database-password 'S3cret!' \
               --database-name mydb \
               --backup-dir /mnt/dane/Backup \
               --retention-time 14d

  pg_backup.sh --dry-run --database-server localhost \
               --database-user test --database-password x \
               --database-name mydb --backup-dir /tmp/backups --retention-time 2d
EOF
}


#------------------------------------------------------------------------------
# Helper: print log message
#------------------------------------------------------------------------------
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

#------------------------------------------------------------------------------
# Parse named parameters
#------------------------------------------------------------------------------
DRY_RUN=0
DB_HOST="" DB_PORT=5432 DB_USER="" DB_PASS="" DB_NAME="" BACKUP_ROOT="" RETENTION_RAW=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --database-server)   DB_HOST="$2"; shift 2 ;;
    --database-port)     DB_PORT="$2"; shift 2 ;;
    --database-user)     DB_USER="$2"; shift 2 ;;
    --database-password) DB_PASS="$2"; shift 2 ;;
    --database-name)     DB_NAME="$2"; shift 2 ;;
    --backup-dir)        BACKUP_ROOT="$2"; shift 2 ;;
    --retention-time)    RETENTION_RAW="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

#------------------------------------------------------------------------------
# Validate parameters
#------------------------------------------------------------------------------
missing=()
[[ -z "$DB_HOST" ]]        && missing+=("--database-server")
[[ -z "$DB_USER" ]]        && missing+=("--database-user")
[[ -z "$DB_PASS" ]]        && missing+=("--database-password")
[[ -z "$DB_NAME" ]]        && missing+=("--database-name")
[[ -z "$BACKUP_ROOT" ]]    && missing+=("--backup-dir")
[[ -z "$RETENTION_RAW" ]]  && missing+=("--retention-time")

if (( ${#missing[@]} )); then
  echo "ERROR: Missing required options: ${missing[*]}" >&2
  echo
  usage
  exit 64
fi

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------
parse_retention_to_minutes() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)$ ]]; then
    echo $((BASH_REMATCH[1] * 1440)); return 0
  fi
  if [[ "$s" =~ ^([0-9]+)([wdhm])$ ]]; then
    local n="${BASH_REMATCH[1]}"
    local u="${BASH_REMATCH[2]}"
    case "$u" in
      w) echo $((n * 10080));; # 7*24*60
      d) echo $((n * 1440));;
      h) echo $((n * 60));;
      m) echo $((n));;
      *) return 1;;
    esac
    return 0
  fi
  return 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing required command: $1" >&2; exit 127; }
}

#------------------------------------------------------------------------------
# Prerequisites
#------------------------------------------------------------------------------
require_cmd find
require_cmd date
require_cmd flock
require_cmd sha256sum
if [[ "$DRY_RUN" -eq 0 ]]; then
  require_cmd pg_dump
fi

umask 077

#------------------------------------------------------------------------------
# Prepare environment
#------------------------------------------------------------------------------
BACKUP_DIR="${BACKUP_ROOT%/}/${DB_NAME}"
mkdir -p "$BACKUP_DIR"

LOCKFILE="${BACKUP_DIR}/.pg_backup.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { log "Another backup is running (lock: $LOCKFILE). Exiting."; exit 0; }

if ! RETENTION_MINUTES="$(parse_retention_to_minutes "$RETENTION_RAW")"; then
  log "ERROR: Invalid retention-time: '$RETENTION_RAW'. Use e.g. 14d, 2w, 36h, 90m, or 7." >&2
  exit 64
fi

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
OUTFILE="${BACKUP_DIR}/${DB_NAME}-${TS}.dump"
CHKSUM="${DB_NAME}-${TS}.dump.sha256"

#------------------------------------------------------------------------------
# Backup or simulate
#------------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Simulating backup for '${DB_NAME}' on '${DB_HOST}:${DB_PORT}' ..."
  cat > "$OUTFILE" <<EOF
[DRY-RUN] PostgreSQL Backup Simulation
Database:   $DB_NAME
Server:     $DB_HOST
Port:       $DB_PORT
User:       $DB_USER
Timestamp:  $TS
EOF
else
  log "Starting backup of '${DB_NAME}' from '${DB_HOST}:${DB_PORT}' ..."
  export PGPASSWORD="$DB_PASS"
  if ! pg_dump \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -Fc -Z 9 \
    --no-owner --no-privileges \
    -f "$OUTFILE"; then
    log "ERROR: pg_dump failed." >&2
    exit 1
  fi
  unset PGPASSWORD
fi

#------------------------------------------------------------------------------
# Checksum + cleanup
#------------------------------------------------------------------------------
if [[ ! -s "$OUTFILE" ]]; then
  log "ERROR: Backup file is empty: $OUTFILE" >&2
  exit 1
fi

sha256sum "$OUTFILE" > "$CHKSUM"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Dummy backup created: $OUTFILE"
  log "[DRY-RUN] Checksum file created: $CHKSUM"
else
  log "Backup created: $OUTFILE"
  log "Checksum saved: $CHKSUM"
fi

log "Pruning backups older than ${RETENTION_RAW} (${RETENTION_MINUTES} minutes)..."
find "$BACKUP_DIR" -maxdepth 1 -type f \
  \( -name "${DB_NAME}-*.dump" -o -name "${DB_NAME}-*.dump.sha256" \) \
  -mmin +"$RETENTION_MINUTES" -print -delete

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Completed successfully."
else
  log "Backup ${DB_NAME} completed successfully."
fi
