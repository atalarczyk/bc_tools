# PostgreSQL Backup Scripts

This directory contains two Bash scripts for PostgreSQL backups:

- `pg_backup.sh`: runs a single database backup, creates a checksum, and removes old files based on retention.
- `run_pg_backups.sh`: reads a JSON config and runs `pg_backup.sh` for multiple databases.

## 1) `pg_backup.sh` (single database backup)

### Purpose
- Create a timestamped PostgreSQL dump (`pg_dump -Fc -Z 9 --no-owner --no-privileges`).
- Optionally connect via SSH tunnel for databases behind firewalls/jump hosts.
- Optionally run in `--dry-run` mode (creates a dummy file, no DB connection).
- Detect available `pg_dump` versions across standard installation paths.
- Automatically handle old `pg_dump` versions that don't support the `-d` flag (pre-9.3).
- Create SHA256 checksum file alongside each dump.
- Prune old dump/checksum files older than `--retention-time`.
- Prevent concurrent runs for the same database using `flock`.
- Set restrictive file permissions (`umask 077`).

### Required options
- `--database-server <host>` — PostgreSQL server hostname or IP
- `--database-user <user>` — PostgreSQL username
- `--database-password <password>` — PostgreSQL password
- `--database-name <dbname>` — name of the database to back up
- `--backup-dir <path>` — directory where backups are stored
- `--retention-time <time>` — retention period (examples: `14d`, `2w`, `36h`, `90m`, `7` where plain number means days)

### Optional options
- `--database-port <port>` (default: `5432`)
- `--pg-dump-version <version>` — use specific `pg_dump` version (e.g. `13.23`)
- `-pv` — show available `pg_dump` versions and default version, then exit
- `-pv <version>` — use the specified `pg_dump` version (same as `--pg-dump-version`)
- `-v`, `--version` — print script version and exit
- `--dry-run` — do not connect to PostgreSQL, create dummy file instead
- `-h`, `--help` — show help and exit

`<version>` should match the numeric token from `pg_dump --version` output.
Example: from `pg_dump (PostgreSQL) 13.23 (Ubuntu 13.23-1.pgdg22.04+1)` use `13.23`.

### SSH tunnel options

Activated when `--ssh-host` is provided. Allows backing up databases accessible only through an SSH jump host.

- `--ssh-host <host>` — SSH server to tunnel through
- `--ssh-port <port>` — SSH port (default: `22`)
- `--ssh-user <user>` — SSH username (default: current OS user)
- `--ssh-key <path>` — path to SSH private key
- `--ssh-password <password>` — SSH password (requires `sshpass`; mutually exclusive with `--ssh-key`)
- `--ssh-local-port <port>` — local port for the tunnel (default: auto-assigned)

When an SSH tunnel is active, `pg_dump` connects to `127.0.0.1:<local-port>` instead of the original host. The tunnel is automatically torn down on exit.

### pg_dump version discovery

The script searches for `pg_dump` binaries in:
- `$PATH` (including versioned names like `pg_dump-14`, `pg_dump.14`)
- `/usr/lib/postgresql/*/bin/pg_dump` (Debian/Ubuntu packages)
- `/usr/pgsql-*/bin/pg_dump` (RHEL/CentOS packages)
- `/opt/postgresql-*/bin/pg_dump` (manual installations)

### Backup file structure

Files are stored in `<backup-dir>/<database-name>/`:
```
<backup-dir>/<database-name>/<database-name>-<timestamp>.dump
<backup-dir>/<database-name>/<database-name>-<timestamp>.dump.sha256
```

Timestamp format: `YYYYMMDDTHHMMSSz` (UTC).

### Concurrent execution

A lock file (`<backup-dir>/<database-name>/.pg_backup.lock`) prevents parallel runs for the same database. If another instance is already running, the script exits with code 0.

### Exit codes
- `0` — success (or another backup already running)
- `1` — runtime error (pg_dump failure, SSH tunnel failure, empty backup file)
- `64` — usage error (missing/invalid options, mutually exclusive SSH options)
- `127` — missing required command (`pg_dump`, `sshpass`, etc.)

### Examples
```bash
# Basic backup
./pg_backup.sh \
  --database-server db.example.com \
  --database-port 5432 \
  --database-user backupuser \
  --database-password 'S3cret!' \
  --database-name mydb \
  --backup-dir /var/local/backup/postgresql/dumps \
  --retention-time 14d

# Backup via SSH tunnel (key authentication)
./pg_backup.sh \
  --database-server db.internal \
  --database-user backupuser \
  --database-password 'S3cret!' \
  --database-name mydb \
  --backup-dir /var/local/backup/postgresql/dumps \
  --retention-time 14d \
  --ssh-host jump.example.com \
  --ssh-user tunnel \
  --ssh-key ~/.ssh/id_backup

# Backup via SSH tunnel (password authentication)
./pg_backup.sh \
  --database-server db.internal \
  --database-user backupuser \
  --database-password 'S3cret!' \
  --database-name mydb \
  --backup-dir /var/local/backup/postgresql/dumps \
  --retention-time 14d \
  --ssh-host jump.example.com \
  --ssh-user tunnel \
  --ssh-password 'SshPass!'

# List available pg_dump versions
./pg_backup.sh -pv

# Backup using a specific pg_dump version
./pg_backup.sh -pv 13.23 \
  --database-server db.example.com \
  --database-user backupuser \
  --database-password 'S3cret!' \
  --database-name mydb \
  --backup-dir /var/local/backup/postgresql/dumps \
  --retention-time 14d

# Dry-run (no database connection)
./pg_backup.sh --dry-run \
  --database-server localhost \
  --database-user test \
  --database-password x \
  --database-name mydb \
  --backup-dir /tmp/backups \
  --retention-time 2d
```

### Dependencies
- `bash`, `find`, `date`, `flock`, `sha256sum`
- `pg_dump` (not required in `--dry-run`)
- `ssh` (only when using SSH tunnel)
- `sshpass` (only when using `--ssh-password`)
- `python3` or `shuf` (for auto-assigning SSH local port)

## 2) `run_pg_backups.sh` (multi database runner)

### Purpose
- Read a JSON config file.
- Apply global defaults (host/port/user/password/retention/backup dir/pg_dump version/SSH settings).
- Execute `pg_backup.sh` per entry in `backups[]`.
- Allow per-job overrides for all parameters.
- Support global dry-run mode (`global_dry_run`).

### Usage
```bash
./run_pg_backups.sh --config /usr/local/etc/pg_backup.json
```

Options:
- `-c`, `--config <path>` — path to JSON config (default: `/usr/local/etc/pg_backup.json`)
- `-v`, `--version` — print script version and exit
- `-h`, `--help` — show help

### Validation

The runner skips entries missing required fields (`host`, `user`, `password`, `database`) with a warning. It also validates that the `backup_script` path is executable before starting.

### Exit codes
- `0` — all backups completed (individual failures are logged but don't stop the batch)
- `1` — configuration error (missing `jq`, unreadable config file, non-executable backup script)
- `64` — usage error (unknown option)

### Dependencies
- `bash`, `jq`
- executable `pg_backup.sh` at the path defined in JSON (`backup_script`)

## 3) JSON config structure (`pg_backup.json`)

### Global fields
| Field | Description | Default |
|---|---|---|
| `backup_script` | Path to `pg_backup.sh` | `/usr/local/bin/pg_backup.sh` |
| `backup_root` | Default backup directory | `/mnt/dane/Backup` |
| `default_retention` | Default retention period | `14d` |
| `default_pg_dump_version` | Default `pg_dump` version string | system default |
| `default_host` | Default PostgreSQL host | — |
| `default_port` | Default PostgreSQL port | `5432` |
| `default_user` | Default PostgreSQL user | — |
| `default_password` | Default PostgreSQL password | — |
| `global_dry_run` | If `true`, appends `--dry-run` to each job | `false` |
| `default_ssh_host` | Default SSH tunnel host | — |
| `default_ssh_port` | Default SSH tunnel port | `22` |
| `default_ssh_user` | Default SSH username | — |
| `default_ssh_key` | Default SSH private key path | — |
| `default_ssh_password` | Default SSH password | — |

### Per backup entry (`backups[]`) fields
| Field | Description | Inherits from |
|---|---|---|
| `name` | Label used in logs | — |
| `database` | Database name (required) | — |
| `host` | PostgreSQL host | `default_host` |
| `port` | PostgreSQL port | `default_port` |
| `user` | PostgreSQL user | `default_user` |
| `password` | PostgreSQL password | `default_password` |
| `backup_dir` | Backup directory | `backup_root` |
| `retention_time` | Retention period | `default_retention` |
| `pg_dump_version` | `pg_dump` version | `default_pg_dump_version` |
| `ssh_host` | SSH tunnel host | `default_ssh_host` |
| `ssh_port` | SSH tunnel port | `default_ssh_port` |
| `ssh_user` | SSH username | `default_ssh_user` |
| `ssh_key` | SSH private key path | `default_ssh_key` |
| `ssh_password` | SSH password | `default_ssh_password` |
| `ssh_local_port` | Local port for SSH tunnel | auto-assigned |
| `options` | Array of extra CLI flags for `pg_backup.sh` | — |

### Example config
```json
{
  "backup_script": "/usr/local/bin/pg_backup.sh",
  "backup_root": "/var/local/backup/postgresql/dumps",
  "default_retention": "14d",
  "default_pg_dump_version": "13.23",
  "default_host": "db.example.com",
  "default_port": 5432,
  "default_user": "backupuser",
  "default_password": "S3cret!",
  "global_dry_run": false,
  "default_ssh_host": null,
  "default_ssh_port": 22,
  "default_ssh_user": null,
  "default_ssh_key": null,
  "default_ssh_password": null,
  "backups": [
    {
      "name": "mydb1",
      "database": "mydb1"
    },
    {
      "name": "erpdb",
      "host": "erpserver.local",
      "port": 5433,
      "user": "pgadmin",
      "password": "AdminPass",
      "database": "erpdb",
      "backup_dir": "/srv/backups",
      "retention_time": "30d",
      "pg_dump_version": "14.18",
      "options": ["--dry-run"]
    },
    {
      "name": "remote-db",
      "database": "appdb",
      "ssh_host": "jump.example.com",
      "ssh_user": "tunnel",
      "ssh_key": "/root/.ssh/id_backup"
    }
  ]
}
```

## 4) Typical flow

1. Prepare config JSON.
2. Make scripts executable:
```bash
chmod +x pg_backup.sh run_pg_backups.sh
```
3. Run once manually:
```bash
./run_pg_backups.sh --config /path/to/pg_backup.json
```
4. Add to cron/systemd timer for scheduled backups.

## 5) Notes

- Both scripts use `set -Eeuo pipefail` for strict error handling.
- Log messages in `run_pg_backups.sh` are in Polish.
- `pg_backup.sh` writes checksum files next to dump files in the database backup directory.
- Backup files are created with restrictive permissions (owner-only read/write).
- The `global_dry_run` flag in config does not override per-job `--dry-run` if already present in `options`.
