# backup_access — Implementation Notes

## Design Notes and Assumptions

### Config file handling

All edits to `sshd_config` and `/etc/fstab` follow the same pattern: build the
entire new file content in a `mktemp` file inside the *same directory* as the
target, then `mv -f` it into place. This makes the replacement atomic within the
same filesystem and avoids partial writes. A timestamped
`.bak.YYYYMMDDHHMMSS.PID` copy is kept beside the target for operator-driven
rollback.

### Managed-block markers

```
# BEGIN backup_access USERNAME
...
# END backup_access USERNAME
```

All read/write/remove operations are scoped exclusively to these marker pairs.
Lines outside any managed block are reproduced byte-for-byte.

### sshd_config: single-pass transform

`build_sshd_config_with_user` reads the existing config once, simultaneously:

- strips any stale managed block for the user
- detects and rejects a conflicting `Subsystem sftp` line (or one inside a Match block)
- inserts `Subsystem sftp internal-sftp` before the first `Match` block if absent
- appends the new managed block at the end

The resulting file is validated with `sshd -t -f TMPFILE` before the atomic
rename. If validation fails the original is untouched.

### Idempotency (add)

If all five conditions are simultaneously true — managed SSH block, managed
fstab block, key file with identical content, OS user, bind mount active —
`add` exits 0 with "no changes needed". Any partial match (managed block exists
but content differs) directs the operator to `modify`.

### Mount state

`is_mounted` delegates to `findmnt --noheadings --output TARGET <path>`, which
is more reliable than parsing `/proc/mounts` or running `mountpoint`. Rollback
of mount state on error is best-effort: the script warns but does not die if
`umount` fails during `delete`.

### Root check bypass for tests

`BA_SKIP_ROOT_CHECK=1` disables the EUID check. This variable is documented in
the script but not exposed as a CLI flag.

### Service reload

The script never calls `systemctl reload ssh`. It prints the required next step
after every mutating command.

### Assumptions

- Ubuntu with `/usr/sbin/adduser` (Debian-style). On RHEL/Alpine the
  `ADDUSER_BIN` override is needed.
- `findmnt` from `util-linux` is present (default on Ubuntu ≥ 16.04).
- The chroot directory (`/srv/sftp/USERNAME`) and all ancestors up to `/` must
  be owned `root:root` mode `755` — this is an OpenSSH `ChrootDirectory` hard
  requirement.
- Only one `AuthorizedKeysFile` directive is written per user (the global
  `AuthorizedKeysFile` setting is not touched; the per-user override inside the
  Match block takes precedence).

---

## Test Harness Design

The harness (`test_backup_access.sh`) is entirely self-contained and runs
without root. It creates a tree under `mktemp -d` and wires the following
environment-variable overrides into every invocation of the script under test:

| Override | Fake behaviour |
|---|---|
| `FSTAB_FILE` | temp file, pre-seeded with a comment line |
| `SSHD_BIN` | bash stub: exits 1 if file contains `INVALID_SYNTAX`, else 0 |
| `ADDUSER_BIN` | logs the call; appends username to a `users` sentinel file |
| `USERDEL_BIN` | logs the call; removes username from sentinel file |
| `MOUNT_BIN` | logs the call; appends mountpoint to a `mounts` state file |
| `UMOUNT_BIN` | logs the call; removes mountpoint from state file |
| `FINDMNT_BIN` | returns 0/1 by consulting the `mounts` state file |
| `CHOWN_BIN`, `CHMOD_BIN`, `INSTALL_BIN` | log-only no-ops |
| `PATH` (prefix) | fake `id` binary consults the `users` sentinel |
| `BA_SKIP_ROOT_CHECK` | `1` — bypasses EUID check |

---

## Test Results

**88 PASS / 0 FAIL**

| Test group | Tests | Coverage |
|---|---|---|
| Help and flag tests | 5 | `--help`, `-h`, no-args, flag documentation |
| Validation tests | 15 | Username regex, ssh-dss rejection, unknown key type, multi-line key, relative paths, non-existent dir, missing required flags, unknown command/option |
| Subsystem sftp line tests | 5 | Inserted when absent, not duplicated, conflicting line aborts without writing block, Subsystem inside Match block aborts |
| sshd_config managed block tests | 13 | All 8 required directives present, unrelated lines preserved, block removed on delete |
| fstab managed block tests | 7 | Bind + remount,ro lines, original content preserved, block removed on delete |
| add idempotency tests | 4 | Exact-match → "no changes needed", unchanged files, differing params → "use modify" |
| modify tests | 9 | Key-only change leaves sshd/fstab untouched; dir-only change leaves key/sshd untouched; unknown user rejected |
| delete tests | 9 | SSH block, fstab block, key file all removed; Subsystem line and unrelated lines preserved; non-managed user warns |
| dry-run tests | 8 | add and delete dry-run: DRY-RUN output, zero file mutations, no key file created |
| list output tests | 5 | Sorted order with 3 users, correct dir per user, deterministic across two calls |
| Multi-user isolation tests | 6 | Deleting one user leaves peer's SSH block, fstab block, and key file intact |
| sshd validation failure tests | 2 | `sshd -t` failure aborts; block not written to real config |

---

## What Was Validated vs. What Requires Real-System Verification

### Validated by the test harness (no root required)

- All config-file text transformations (insert, update, remove managed blocks)
- Correct content of every sshd_config directive and fstab entry
- Preservation of all unmanaged config lines
- `Subsystem sftp internal-sftp` insertion, deduplication, conflict detection
- `sshd -t` validation gate (using the controlled fake sshd)
- Idempotency logic
- Modify key-only and directory-only isolation
- Delete scope (only managed state removed)
- Dry-run produces no side effects
- Sorted, deterministic `list` output
- All input-validation error paths
- Multi-user isolation

### Requires real-system verification (needs root + live OpenSSH)

| Item | Why |
|---|---|
| `adduser --system --group --shell /usr/sbin/nologin --home /` | Actual user creation and PAM integration |
| `mount --bind` + `mount -o remount,ro,bind` | Kernel bind-mount semantics |
| `sshd -t` against real sshd_config syntax | Catches sshd version-specific directive names |
| `ChrootDirectory` enforcement | sshd rejects the chroot if ownership/mode is wrong; must be tested with a live `sftp` connection |
| `ForceCommand internal-sftp -R` read-only enforcement | Only verifiable with an actual SFTP session |
| `AuthorizedKeysFile /etc/ssh/authorized_keys/%u` with `AuthenticationMethods publickey` | Requires a real SSH handshake |
| Atomic `mv` across filesystems | If `TMPDIR` is on a different filesystem than `/etc`, the same-dir temp strategy is essential; confirm `/etc` and `/tmp` are on the same filesystem or set `TMPDIR` accordingly |
| `flock` behaviour under concurrent invocation | Needs two parallel processes on a real system |
