# Backup And Restore Reference

`zonctl backup` and `zonctl restore` (`internal/backup`) implement a
coordinated, offline backup and a clean-node restore.

## Backup

```
zonctl backup --state-dir /var/lib/zon/state [--output text|json]
```

Backup refuses to run if nothing is installed. Otherwise it:

1. **Stops K3s** to take a consistent snapshot rather than copying a live,
   potentially-changing datastore.
2. **Copies the K3s data directory** into a new directory under
   `<state-dir>/backups/<backup-id>/data`, recording every file's SHA-256
   digest and size as it goes.
3. **Writes a manifest** (`<backup-id>/manifest.json`) with the backup ID,
   creation time, platform version, and the full file list.
4. **Restarts K3s.** This happens even if the copy step failed, so a
   backup failure never leaves the platform down.

The command result reports `backupId` and the total `sizeBytes` captured.

## Restore

```
zonctl restore --backup-id <backup-id> --state-dir /var/lib/zon/state [--output text|json]
```

This is a **clean-node restore**: the current data directory is fully
replaced by the backup's contents, not merged with them. Restore:

1. **Verifies the backup's integrity first.** Every file's digest is
   recomputed and compared against the manifest. Any mismatch or missing
   file fails the restore closed — the host is never touched if the
   backup itself can't be trusted.
2. **Stops K3s, wipes the data directory, copies in the verified backup,
   and restarts K3s.**

## RPO/RTO

Every stage of both `backup` and `restore` — stopping K3s, copying data,
restarting K3s — is recorded as a timed `evidence.v1` check
(`backup-stop-k3s`, `backup-copy-data`, `backup-restart-k3s`,
`restore-stop-k3s`, `restore-copy-data`, `restore-start-k3s`), each with a
`durationMs`. This is what makes RPO/RTO measurable rather than anecdotal:
the automated drill in `internal/backup/backup_test.go` backs up a live
directory, simulates data loss, restores it, and asserts the restored
data is byte-for-byte identical to what was backed up while every stage
reports a real duration.

## Where Backups Fit Into Upgrade and Factory-Reset

- `zonctl upgrade` takes and verifies a backup automatically before
  changing anything, and restores from it on failure — see
  [upgrade.md](upgrade.md).
- `zonctl factory-reset` requires either a `--backup-id` that passes
  verification or an explicit `--force-data-loss` override before it will
  wipe the data directory — see [security.md](security.md).
