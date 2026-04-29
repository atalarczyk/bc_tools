# File Backup Scripts

This directory contains two Bash scripts for backing up a remote directory to a local machine:

- `file_backup.sh`: performs a single full or incremental backup job, creates a ZIP archive and SHA256 checksum, and maintains local snapshot state.
- `run_file_backups.sh`: reads a JSON config and runs `file_backup.sh` for multiple jobs.

The implementation is intentionally similar in shape to `pg_backup`:

- one script for a single backup job
- one runner reading JSON config
- example config file
- self-contained Bash tests

## 1) `file_backup.sh` (single directory backup)

### Purpose

- Copy a directory from a remote machine to the local machine using `rsync`.
- Decide automatically whether the next archive should be full or incremental.
- Store each backup as a ZIP archive.
- Create a SHA256 checksum file for each ZIP archive.
- Prune old backup chains according to retention settings.
- Keep local state needed to calculate the next incremental backup.
- Prevent concurrent runs for the same backup job using `flock`.
- Support `--dry-run` mode.

### Backup model

- The first backup is always a full backup.
- A full backup is created again when `--full-backup-frequency` has elapsed since the last full backup.
- Otherwise, an incremental backup is created when `--incremental-backup-frequency` has elapsed since the last backup of any type.
- Incremental backups are based on the **previous backup**, not on the last full backup.
- Each incremental archive name clearly references the full backup chain it belongs to.
- Retention is applied to **inactive backup chains**: when an old full backup expires, the script removes that full backup together with all incrementals that belong to it.
- The currently active chain is preserved even if its base full backup is older than retention, so incrementals are never left without their required full backup.

### Required options

- `--backup-name <name>` — logical job name; used in archive names and local state paths
- `--source-host <host>` — remote host name or IP
- `--source-dir <path>` — remote directory to back up
- `--backup-dir <path>` — local root directory for backups
- `--retention-time <time>` — retention period for stored backup chains
- `--full-backup-frequency <time>` — how often to create a full backup
- `--incremental-backup-frequency <time>` — how often to create an incremental backup

### Optional options

- `--ssh-port <port>` — SSH port, default `22`
- `--ssh-user <user>` — SSH username, default current OS user
- `--ssh-key <path>` — SSH private key path
- `--ssh-password <password>` — SSH password; requires `sshpass`; mutually exclusive with `--ssh-key`
- `--remote-rsync-path <path>` — absolute path to `rsync` on the remote host; useful when `rsync` is installed outside the default remote `PATH`
- `--exclude <glob>` — `rsync` exclude pattern; may be repeated
- `--dry-run` — do not connect remotely; create a simulated archive and update state
- `-v`, `--version` — print script version and exit
- `-h`, `--help` — show help and exit

### Time format

Frequencies accept:

- bare number, meaning days: `7`
- weeks: `2w`
- days: `14d`
- hours: `12h`
- minutes: `30m`

### Output structure

Files are stored in:

```text
<backup-dir>/<backup-name>/
```

Example:

```text
<backup-dir>/<backup-name>/<backup-name>-full-<timestamp>.zip
<backup-dir>/<backup-name>/<backup-name>-full-<timestamp>.zip.sha256
<backup-dir>/<backup-name>/<backup-name>-inc-full-<full-id>-prev-<previous-id>-<timestamp>.zip
<backup-dir>/<backup-name>/<backup-name>-inc-full-<full-id>-prev-<previous-id>-<timestamp>.zip.sha256
<backup-dir>/<backup-name>/.state/
```

Timestamp format: `YYYYMMDDTHHMMSSZ` in UTC.

### Archive contents

Each ZIP archive contains:

```text
data/
.file_backup_meta/backup_info.txt
.file_backup_meta/deleted_paths.txt
```

Meaning:

- `data/` — full payload for a full backup, or changed/new files for an incremental backup
- `backup_info.txt` — metadata describing the archive
- `deleted_paths.txt` — paths deleted since the previous backup; used during restore of incrementals

### Local state

The script keeps local snapshots in:

```text
<backup-dir>/<backup-name>/.state/snapshots/
```

These snapshots are not the backup product exposed to the user. They exist only so the next run can decide what changed and build the next incremental ZIP archive.

### Concurrent execution

The lock file:

```text
<backup-dir>/<backup-name>/.file_backup.lock
```

prevents parallel runs for the same job. If another run is already active, the script exits with code `0`.

### Exit codes

- `0` — success, or another backup is already running, or no backup is due
- `1` — runtime error
- `64` — usage or validation error
- `127` — missing dependency

### Examples

```bash
# Full/incremental backups of a remote directory over SSH key auth
./file_backup.sh \
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

# Same, with rsync excludes
./file_backup.sh \
  --backup-name media \
  --source-host files.example.com \
  --source-dir /srv/media \
  --backup-dir /var/local/backup/files \
  --retention-time 45d \
  --full-backup-frequency 14d \
  --incremental-backup-frequency 24h \
  --exclude '*.tmp' \
  --exclude 'cache/'

# Password-based SSH auth
./file_backup.sh \
  --backup-name reports \
  --source-host files.example.com \
  --source-dir /srv/reports \
  --backup-dir /var/local/backup/files \
  --retention-time 60d \
  --full-backup-frequency 30d \
  --incremental-backup-frequency 24h \
  --ssh-user backup \
  --ssh-password 'SshPass!'

# Dry-run
./file_backup.sh \
  --dry-run \
  --backup-name reports \
  --source-host files.example.com \
  --source-dir /srv/reports \
  --backup-dir /tmp/file-backups \
  --retention-time 14d \
  --full-backup-frequency 30d \
  --incremental-backup-frequency 24h
```

### Retention notes

- Retention uses the same time format as backup frequencies, for example `30d`, `8w`, `24h`, `90m`, or `14`.
- Pruning happens after a successful backup run.
- The retention decision is based on the age of the full backup that starts a chain.
- When a chain expires, the script removes:
  - the full ZIP archive
  - the full checksum file
  - every incremental ZIP archive belonging to that full backup
  - every checksum file for those incrementals

### Remote rsync requirement

- The local machine must have `rsync` installed.
- The remote source host must also have `rsync` installed, because `rsync over SSH` starts `rsync` on both sides.
- If the remote host has `rsync`, but not in the default shell `PATH`, set `--remote-rsync-path`, for example `/usr/bin/rsync` or `/usr/local/bin/rsync`.
- If remote `rsync` is missing entirely, install it on the source host, for example:

```bash
sudo apt install rsync
```

### Restore notes

To restore a chain:

1. Unpack the relevant full backup archive.
2. Unpack incremental archives in chronological order.
3. After each incremental archive, delete the paths listed in `.file_backup_meta/deleted_paths.txt`.

Because incrementals are based on the previous backup, restoring the most recent state requires:

- the last full backup in the chain
- every incremental archive created after that full backup

## 2) `run_file_backups.sh` (multi-job runner)

### Purpose

- Read a JSON config file.
- Apply global defaults.
- Execute `file_backup.sh` for every configured job.
- Optionally run only one selected job.
- Support global dry-run mode.
- List effective configuration for all jobs.

### Usage

```bash
./run_file_backups.sh --config /usr/local/etc/file_backup.json
```

Options:

- `-c`, `--config <path>` — path to JSON config; default `/usr/local/etc/file_backup.json`
- `-d`, `--dry-run` — append `--dry-run` to each backup job
- `-r`, `--run <name>` — run only one named job
- `-l`, `--list` — list all configured jobs and exit
- `-v`, `--version` — print script version and exit
- `-h`, `--help`, `-?` — show help

### Validation

The runner:

- requires `jq`
- requires a readable config file
- requires the configured `file_backup.sh` path to be executable
- skips jobs missing `name`, `host`, or `source_dir`

### Exit codes

- `0` — runner completed
- `1` — configuration error
- `64` — usage error

### Cron / scheduling

`run_file_backups.sh` itself does not decide whether a given job should produce a full or incremental archive. It only starts `file_backup.sh` for each configured job.

The actual decision is made inside `file_backup.sh` based on:

- `retention_time`
- `full_backup_frequency`
- `incremental_backup_frequency`
- local state from previous runs

This means the cron job should usually run **more often** than the smallest backup interval you want to guarantee.

Practical rule:

- if the smallest configured incremental interval is `12h`, run cron at least every hour
- if the smallest configured incremental interval is `1h`, run cron every 10-15 minutes
- if you run cron less often than the configured interval, backups will only be created when cron actually starts the script

Important consequence:

- `incremental_backup_frequency=12h` does not create backups automatically every 12 hours by itself
- it means: "when the script is started, create an incremental backup if at least 12 hours have passed since the previous backup"

Examples:

```cron
# Check all backup jobs every hour.
# file_backup.sh will create archives only when a job is due.
0 * * * * /usr/local/bin/run_file_backups.sh -c /usr/local/etc/file_backup.json >> /var/log/file_backup.log 2>&1

# Check all backup jobs every 15 minutes.
# Useful when some jobs have short incremental intervals.
*/15 * * * * /usr/local/bin/run_file_backups.sh -c /usr/local/etc/file_backup.json >> /var/log/file_backup.log 2>&1
```

Example interpretation:

- cron every hour
- `full_backup_frequency=7d`
- `incremental_backup_frequency=12h`

In that setup:

- the script checks every hour whether a backup is due
- it creates a full backup roughly every 7 days
- between full backups it creates incremental backups no more often than every 12 hours
- on runs where nothing is due, it exits cleanly with a log message

Recommended approach on Ubuntu:

- place one cron entry for `run_file_backups.sh`
- choose the cron frequency based on the most frequent job in the JSON config
- keep the cron interval comfortably smaller than the shortest incremental interval
- if you want stricter timing than classic cron gives, consider a `systemd` timer

## 3) JSON config structure (`file_backup.json`)

### Global fields

| Field | Description | Default |
|---|---|---|
| `backup_script` | Path to `file_backup.sh` | `/usr/local/bin/file_backup.sh` |
| `backup_root` | Default local backup root | `/mnt/dane/Backup/files` |
| `default_retention` | Default retention period | `30d` |
| `default_full_backup_frequency` | Default full backup interval | `7d` |
| `default_incremental_backup_frequency` | Default incremental backup interval | `24h` |
| `default_host` | Default remote host | — |
| `default_ssh_port` | Default SSH port | `22` |
| `default_ssh_user` | Default SSH username | current OS user |
| `default_ssh_key` | Default SSH key | — |
| `default_ssh_password` | Default SSH password | — |
| `default_remote_rsync_path` | Default remote `rsync` path | remote host `PATH` |
| `global_dry_run` | If `true`, appends `--dry-run` to every job | `false` |

### Per-backup fields (`backups[]`)

| Field | Description | Inherits from |
|---|---|---|
| `name` | Job name; required | — |
| `source_dir` | Remote directory to back up; required | — |
| `host` | Remote host | `default_host` |
| `backup_dir` | Local backup root | `backup_root` |
| `retention_time` | Backup chain retention period | `default_retention` |
| `full_backup_frequency` | Full backup interval | `default_full_backup_frequency` |
| `incremental_backup_frequency` | Incremental backup interval | `default_incremental_backup_frequency` |
| `ssh_port` | SSH port | `default_ssh_port` |
| `ssh_user` | SSH user | `default_ssh_user` |
| `ssh_key` | SSH key path | `default_ssh_key` |
| `ssh_password` | SSH password | `default_ssh_password` |
| `remote_rsync_path` | Remote `rsync` path | `default_remote_rsync_path` |
| `options` | Extra CLI tokens passed to `file_backup.sh` | — |

### Example config

```json
{
  "backup_script": "/usr/local/bin/file_backup.sh",
  "backup_root": "/var/local/backup/files",
  "default_retention": "30d",
  "default_full_backup_frequency": "7d",
  "default_incremental_backup_frequency": "12h",
  "default_host": "files.example.com",
  "default_ssh_port": 22,
  "default_ssh_user": "backup",
  "default_ssh_key": "/root/.ssh/id_backup",
  "default_ssh_password": null,
  "default_remote_rsync_path": "/usr/bin/rsync",
  "global_dry_run": false,
  "backups": [
    {
      "name": "documents",
      "source_dir": "/srv/data/documents"
    },
    {
      "name": "photos",
      "source_dir": "/srv/data/photos",
      "retention_time": "45d",
      "full_backup_frequency": "14d",
      "incremental_backup_frequency": "24h"
    },
    {
      "name": "erp-export",
      "host": "erp-storage.internal",
      "source_dir": "/var/lib/exports",
      "backup_dir": "/srv/backups/files",
      "ssh_user": "syncuser",
      "ssh_key": "/root/.ssh/id_erp_backup",
      "remote_rsync_path": "/usr/local/bin/rsync",
      "options": ["--exclude", "*.tmp", "--exclude", "cache/"]
    }
  ]
}
```

## 4) Tests

Run:

```bash
bash test_file_backup.sh
bash test_run_file_backups.sh
```

Both tests are self-contained and run in temporary directories.

## 5) Dependencies

- `bash`
- `rsync`
- `rsync` on the remote source host as well
- `zip`
- `unzip` for inspecting archives during restore and tests
- `sha256sum`
- `flock`
- `mktemp`
- `find`
- `jq` for `run_file_backups.sh`
- `sshpass` only when using `--ssh-password`

## 6) Ubuntu notes

The scripts are designed to run on Ubuntu. Typical package installs:

```bash
sudo apt install rsync zip unzip jq
sudo apt install sshpass   # only if password-based SSH auth is needed
```
