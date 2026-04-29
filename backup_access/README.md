# Backup Access Script

`backup_access.sh` manages read-only SFTP backup-access accounts on Ubuntu.

Each managed user gets:
- a system account
- a chroot jail under `REMOUNT_ROOT/USERNAME/`
- a read-only bind mount of a backup source directory to `REMOUNT_ROOT/USERNAME/backups/`
- a public-key file under `AUTHORIZED_KEYS_DIR/USERNAME`
- one `Match User` block in `sshd_config` (guarded by script markers)
- one block in a systemd oneshot service (guarded by script markers)

## Commands

```
backup_access.sh COMMAND [OPTIONS]
```

| Command | Description |
|---|---|
| `list` | Print all managed users (sorted) with their directory and public key |
| `add` | Add a new managed SFTP user |
| `modify` | Update an existing managed user (key and/or directory) |
| `delete` | Remove a managed user and all associated state |
| `admin-recreate-mounts` | Reconcile systemd mount service with managed accounts: mount unmounted entries, remove orphaned entries |
| `admin-check-all` | Verify all managed users have correct, complete configuration (OS user, config blocks, directories, permissions, keys, and mounts) |
| `-h`, `--help` | Show help message (may appear as first argument only) |
| `-i`, `--info` | Show version and exit |

`add`, `modify`, and `delete` require root privileges.

## Options

| Option | Description | Default |
|---|---|---|
| `-t`, `--dry-run` | Validate and plan; make no changes | — |
| `-v`, `--verbose` | Enable verbose output; report inconsistencies for `list` | — |
| `-m`, `--minimal-list` | `list` only: print `USER` and `DIRECTORY` columns (omit `PUBLIC_KEY`) | — |
| `-r`, `--remount-root DIR` | Chroot base directory | `/srv/sftp` |
| `-s`, `--ssh-config FILE` | Path to `sshd_config` | `/etc/ssh/sshd_config` |
| `-a`, `--authorized-keys-dir DIR` | Authorized keys directory | `/etc/ssh/authorized_keys` |
| `-u`, `--user USERNAME` | Username (required for `add`, `modify`, `delete`) | — |
| `-k`, `--public-key KEY` | SSH public key string (required for `add`; optional for `modify`) | — |
| `-d`, `--directory DIR` | Backup source directory (required for `add`; optional for `modify`) | — |

## Accepted SSH key types

- `ssh-ed25519`
- `ssh-rsa`
- `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521`
- `sk-ssh-ed25519@openssh.com`
- `sk-ecdsa-sha2-nistp256@openssh.com`

`ssh-dss` keys are explicitly rejected.

## File and directory structure

```
/srv/sftp/                          # REMOUNT_ROOT (chroot base)
└── USERNAME/                       # chroot jail (root:root 755)
    └── backups/                    # read-only bind mount of source directory (root:root 755)

/etc/ssh/authorized_keys/USERNAME   # public key file (root:root 644)
/etc/ssh/sshd_config                # managed Match User block appended
/etc/systemd/system/backup-access-mounts.service  # managed bind mount unit
```

## sshd_config block

The following block is appended to `sshd_config` for each managed user (wrapped in script markers):

```
# BEGIN backup_access USERNAME
Match User USERNAME
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    ChrootDirectory /srv/sftp/USERNAME
    ForceCommand internal-sftp -R -d /backups
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication no
    AuthenticationMethods publickey
# END backup_access USERNAME
```

The global `Subsystem sftp internal-sftp` line is added to `sshd_config` automatically if absent. If a conflicting `Subsystem sftp <other>` line is found, the script aborts without making any changes.

The script validates the resulting config with `sshd -t` before replacing the file. `sshd` is **not** reloaded automatically — the script prints the required next step after each change.

## Systemd service

Bind mounts are managed by a systemd oneshot service (`backup-access-mounts.service`). Each user's mount entry is guarded by script markers inside the service file. When the last managed user is removed, the service is disabled and the file is deleted.

## Concurrency

A lock file (`/var/lock/backup_access.lock`) prevents parallel runs. If another instance is already running, the script exits with an error.

## Idempotency

`add` is idempotent: if the user already exists with the exact same key and directory, it exits silently without error. If the user exists with different settings, it exits with an error directing you to use `modify` instead.

## Exit codes

- `0` — success
- `1` — runtime error (failed system call, failed validation, partial/inconsistent state)
- `64` — usage error (unknown option, missing required argument, wrong first argument)

## Examples

```bash
# List all managed users
./backup_access.sh list

# List with verbose inconsistency report
./backup_access.sh list -v

# List user names and directories only (no public key column)
./backup_access.sh list -m

# Add a user
./backup_access.sh add \
    -u backupuser \
    -k "ssh-ed25519 AAAA... user@host" \
    -d /var/backups/myapp

# Dry-run an add (shows planned actions, makes no changes)
./backup_access.sh add --dry-run \
    -u backupuser \
    -k "ssh-ed25519 AAAA..." \
    -d /var/backups/myapp

# Update public key only
./backup_access.sh modify \
    -u backupuser \
    -k "ssh-ed25519 BBBB... newkey@host"

# Update source directory only
./backup_access.sh modify \
    -u backupuser \
    -d /var/backups/newapp

# Delete a user
./backup_access.sh delete -u backupuser

# Reconcile mounts after a reboot (remount any unmounted entries)
./backup_access.sh admin-recreate-mounts

# Verify all managed users have complete and correct configuration
./backup_access.sh admin-check-all

# Same with verbose [OK]/[FAIL] details per check
./backup_access.sh admin-check-all -v
```

## Typical flow

1. Make the script executable:
```bash
chmod +x backup_access.sh
```

2. Add a user:
```bash
./backup_access.sh add \
    -u backupuser \
    -k "ssh-ed25519 AAAA... user@host" \
    -d /var/backups/myapp
```

3. Reload sshd (script prints this reminder after each change):
```bash
systemctl reload ssh
```

4. Verify the configuration is consistent:
```bash
./backup_access.sh admin-check-all
```

5. Add the systemd service to auto-mount on boot (done automatically by `add`):
```bash
systemctl enable backup-access-mounts.service
```

## Notes

- Uses `set -Eeuo pipefail` for strict error handling.
- All file replacements (`sshd_config`, systemd service) are atomic: a timestamped `.bak` file is kept alongside the original.
- Only configuration blocks wrapped in `# BEGIN backup_access USERNAME` / `# END backup_access USERNAME` markers are created or modified. All other content in `sshd_config` and the systemd service file is left untouched.
- `modify` does **not** rename the account; use `delete` then `add` to rename.
- `admin-check-all` exits with code `1` if any check fails; suitable for use in monitoring scripts.
- Several internal binaries (`sshd`, `systemctl`, `adduser`, etc.) can be overridden via environment variables for testing purposes.
