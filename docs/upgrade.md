# Upgrading the Appliance

`zonctl upgrade` implements the N-1 upgrade sequence
(`internal/upgrade.Orchestrator.Upgrade`): the target release states which
prior versions it may upgrade from, and everything else is refused or
rolled back rather than left in an unclear state.

## Running Upgrade

Like `install`, `upgrade` reads the target release's artifacts through an
`install.Source` — online by default, offline as an explicit opt-in. Both
modes run the identical sequence below; only where the artifacts come
from differs.

Online (default):

```
zonctl upgrade \
  --manifest-url https://releases.example.com/zon/2.4.0/platform-manifest.json \
  --state-dir /var/lib/zon \
  [--output text|json]
```

Offline:

```
zonctl upgrade \
  --bundle-dir /path/to/extracted/target/bundle \
  --public-key /path/to/release-signing.pub \
  --state-dir /var/lib/zon \
  [--output text|json]
```

## What Upgrade Actually Does

1. **Load current state.** `installed-state.json` must exist and record
   K3s ownership; there is nothing to upgrade from otherwise (`install`
   is what you want for a fresh host).
2. **Resolve and verify the target release's artifacts** via the same
   `install.Source` abstraction `install` uses: the offline bundle's
   schema/signature/per-entry digest chain, or the online platform
   manifest's schema validation plus per-artifact digest verification and
   `helm pull` from its OCI chart reference (see
   [security.md](security.md#verification-chain)).
3. **Compatibility checks, both fail closed:**
   - The installed version must appear in the target release's
     `supportedUpgradeSources` list. Anything else is refused before any
     mutation happens — this is the N-1 policy in practice: a release
     only declares itself compatible with the version(s) it was actually
     tested against.
   - The target's Argo version must not be older than the installed one.
     A CRD downgrade is refused outright.
4. **Mandatory pre-upgrade backup.** Before anything is changed, a backup
   is taken and its integrity is immediately verified (see
   [backup-restore.md](backup-restore.md)). This is the recovery point
   every later failure in this sequence rolls back to.
5. **Stage new images (offline mode only).** The bundle's K3s and
   application images are digest-verified and preloaded, in the same
   K3s-platform-first order `install` uses. Online mode preloads nothing
   here — K3s pulls images itself once the new chart references them.
6. **K3s binary swap — only if the K3s version actually changed.** If the
   target's K3s version matches what's installed, the binary, config, and
   unit are left untouched. If it differs, the current binary/config/unit
   are each snapshotted (`<path>.previous`) before being replaced, so a
   later failure can restore them exactly.
7. **Apply the new CRDs and chart.**
8. **Persist the updated installed-state**, recording the source and
   target versions on the upgrade's `lastOperation`.

## Failed-Upgrade Recovery

Any failure from step 5 onward triggers a **restore-based rollback**:

- If the K3s binary/config/unit were changed, they are reverted from their
  `.previous` snapshots first.
- The data directory is then restored from the pre-upgrade backup
  (`internal/backup.Restore`): K3s is stopped, the data directory is wiped
  and replaced with the verified backup contents, and K3s is restarted.

The command result's `status` field is `rolled-back` (not just `failed`)
whenever this recovery path actually ran, so tooling and operators can
tell "the upgrade failed and nothing changed" apart from "the upgrade
failed and rollback executed" at a glance.

## What's Not Yet Wired

Coordinating in-flight Argo Workflows before an upgrade and running
product-supplied migration hooks (`release-plan.md`'s "supported
application mechanism") depend on `appliance-code` capabilities not yet
integrated into this orchestrator. This is a known scope boundary — the
upgrade sequence today covers K3s, CRDs, images, and the chart, not
in-cluster application state migration.
