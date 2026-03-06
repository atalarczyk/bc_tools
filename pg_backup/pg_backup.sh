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

SCRIPT_VERSION="1.1.3"

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
  --pg-dump-version   <version>     Use specific pg_dump version (e.g. 13.23)
  -pv [version]                     Show available pg_dump versions and default;
                                    if version is provided, use version from
                                    "pg_dump --version" output (e.g. 13.23)
  -v, --version                     Show script version and exit
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

  pg_backup.sh -pv

  pg_backup.sh -pv 13.23 --database-server db.example.com \
               --database-user backupuser --database-password 'S3cret!' \
               --database-name mydb --backup-dir /mnt/dane/Backup --retention-time 14d
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
PRINT_PG_DUMP_VERSIONS=0
PG_DUMP_VERSION_REQUEST=""
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
    --pg-dump-version)   PG_DUMP_VERSION_REQUEST="$2"; shift 2 ;;
    -pv)
      if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
        PG_DUMP_VERSION_REQUEST="$2"
        shift 2
      else
        PRINT_PG_DUMP_VERSIONS=1
        shift
      fi
      ;;
    -v|--version)       echo "$SCRIPT_VERSION"; exit 0 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

#------------------------------------------------------------------------------
# Validate parameters
#------------------------------------------------------------------------------
if [[ "$PRINT_PG_DUMP_VERSIONS" -eq 0 ]]; then
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

get_pg_dump_version() {
  local bin="$1" out=""
  out="$("$bin" --version 2>/dev/null || true)"
  if [[ "$out" =~ ([0-9]+([.][0-9]+)*) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "unknown"
  fi
}

pg_dump_supports_d_option() {
  local version="$1" major="" minor="0"
  if [[ ! "$version" =~ ^([0-9]+)([.]([0-9]+))? ]]; then
    # If version parsing fails, assume modern behavior.
    return 0
  fi

  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[3]:-0}"

  if (( major > 9 )); then
    return 0
  fi

  if (( major < 9 )); then
    return 1
  fi

  (( minor >= 3 ))
}

declare -a PG_DUMP_BINARIES=()
declare -a PG_DUMP_VERSIONS=()
declare -A PG_DUMP_SEEN=()
DEFAULT_PG_DUMP_BIN=""
DEFAULT_PG_DUMP_VERSION=""
SELECTED_PG_DUMP_BIN=""
SELECTED_PG_DUMP_VERSION=""

add_pg_dump_candidate() {
  local candidate="$1" version=""
  [[ -n "$candidate" && -x "$candidate" ]] || return 0
  [[ -z "${PG_DUMP_SEEN[$candidate]:-}" ]] || return 0

  PG_DUMP_SEEN["$candidate"]=1
  version="$(get_pg_dump_version "$candidate")"
  PG_DUMP_BINARIES+=("$candidate")
  PG_DUMP_VERSIONS+=("$version")
}

discover_pg_dump_binaries() {
  local candidate="" base="" dir=""
  local nullglob_was_set=0
  local -a path_dirs=()

  PG_DUMP_BINARIES=()
  PG_DUMP_VERSIONS=()
  PG_DUMP_SEEN=()

  DEFAULT_PG_DUMP_BIN="$(command -v pg_dump 2>/dev/null || true)"
  if [[ -n "$DEFAULT_PG_DUMP_BIN" ]]; then
    DEFAULT_PG_DUMP_VERSION="$(get_pg_dump_version "$DEFAULT_PG_DUMP_BIN")"
    add_pg_dump_candidate "$DEFAULT_PG_DUMP_BIN"
  else
    DEFAULT_PG_DUMP_VERSION=""
  fi

  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob

  IFS=':' read -r -a path_dirs <<< "${PATH:-}"
  for dir in "${path_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for candidate in "$dir"/pg_dump*; do
      [[ -x "$candidate" ]] || continue
      base="${candidate##*/}"
      [[ "$base" =~ ^pg_dump([._-]?[0-9]+([.][0-9]+)*)?$ ]] || continue
      add_pg_dump_candidate "$candidate"
    done
  done

  for candidate in /usr/lib/postgresql/*/bin/pg_dump /usr/pgsql-*/bin/pg_dump /opt/postgresql-*/bin/pg_dump; do
    [[ -x "$candidate" ]] || continue
    add_pg_dump_candidate "$candidate"
  done

  if [[ "$nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi
}

print_pg_dump_versions() {
  local i="" marker=""
  if [[ -n "$DEFAULT_PG_DUMP_BIN" ]]; then
    log "Default pg_dump: v${DEFAULT_PG_DUMP_VERSION} (${DEFAULT_PG_DUMP_BIN})"
  else
    log "Default pg_dump: not found in PATH"
  fi

  if (( ${#PG_DUMP_BINARIES[@]} == 0 )); then
    log "No pg_dump binaries found in PATH/common PostgreSQL install directories."
    return 1
  fi

  log "Available pg_dump binaries:"
  for i in "${!PG_DUMP_BINARIES[@]}"; do
    marker=""
    [[ "${PG_DUMP_BINARIES[$i]}" == "$DEFAULT_PG_DUMP_BIN" ]] && marker=" [default]"
    log "  - v${PG_DUMP_VERSIONS[$i]} | ${PG_DUMP_BINARIES[$i]}${marker}"
  done
}

select_pg_dump_version() {
  local requested="$1" i="" version=""
  SELECTED_PG_DUMP_BIN=""
  SELECTED_PG_DUMP_VERSION=""

  for i in "${!PG_DUMP_BINARIES[@]}"; do
    version="${PG_DUMP_VERSIONS[$i]}"
    if [[ "$version" == "$requested" || "$version" == "$requested".* ]]; then
      SELECTED_PG_DUMP_BIN="${PG_DUMP_BINARIES[$i]}"
      SELECTED_PG_DUMP_VERSION="$version"
      return 0
    fi
  done
  return 1
}

#------------------------------------------------------------------------------
# Prerequisites
#------------------------------------------------------------------------------
require_cmd find
require_cmd date
require_cmd flock
require_cmd sha256sum
discover_pg_dump_binaries

if [[ "$PRINT_PG_DUMP_VERSIONS" -eq 1 ]]; then
  print_pg_dump_versions || true
  exit 0
fi

if [[ -n "$PG_DUMP_VERSION_REQUEST" ]]; then
  if ! select_pg_dump_version "$PG_DUMP_VERSION_REQUEST"; then
    log "ERROR: Requested pg_dump version '${PG_DUMP_VERSION_REQUEST}' is not available."
    print_pg_dump_versions || true
    exit 64
  fi
else
  SELECTED_PG_DUMP_BIN="$DEFAULT_PG_DUMP_BIN"
  SELECTED_PG_DUMP_VERSION="$DEFAULT_PG_DUMP_VERSION"
fi

if [[ "$DRY_RUN" -eq 0 && -z "$SELECTED_PG_DUMP_BIN" ]]; then
  log "ERROR: pg_dump is required but no default pg_dump was found in PATH."
  log "Use -pv to list available versions or pass -pv <version>."
  exit 127
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
CHKSUM="${BACKUP_DIR}/${DB_NAME}-${TS}.dump.sha256"

#------------------------------------------------------------------------------
# Backup or simulate
#------------------------------------------------------------------------------
PG_DUMP_LOG_INFO="pg_dump=not-found"
if [[ -n "$SELECTED_PG_DUMP_BIN" ]]; then
  PG_DUMP_LOG_INFO="pg_dump=v${SELECTED_PG_DUMP_VERSION} (${SELECTED_PG_DUMP_BIN})"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] Simulating backup for '${DB_NAME}' on '${DB_HOST}:${DB_PORT}' using ${PG_DUMP_LOG_INFO} ..."
  cat > "$OUTFILE" <<EOF
[DRY-RUN] PostgreSQL Backup Simulation
Database:   $DB_NAME
Server:     $DB_HOST
Port:       $DB_PORT
User:       $DB_USER
Timestamp:  $TS
EOF
else
  log "Starting backup of '${DB_NAME}' from '${DB_HOST}:${DB_PORT}' using ${PG_DUMP_LOG_INFO} ..."
  export PGPASSWORD="$DB_PASS"
  PG_DUMP_CMD=(
    "$SELECTED_PG_DUMP_BIN"
    -h "$DB_HOST"
    -p "$DB_PORT"
    -U "$DB_USER"
    -Fc -Z 9
    --no-owner --no-privileges
    -f "$OUTFILE"
  )

  if pg_dump_supports_d_option "$SELECTED_PG_DUMP_VERSION"; then
    PG_DUMP_CMD+=(-d "$DB_NAME")
  else
    PG_DUMP_CMD+=("$DB_NAME")
  fi

  if ! "${PG_DUMP_CMD[@]}"; then
    unset PGPASSWORD
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

(
  cd "$BACKUP_DIR"
  sha256sum "$(basename "$OUTFILE")"
) > "$CHKSUM"

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
