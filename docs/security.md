# Security Model

This describes what is actually implemented today. See
[release-plan.md](release-plan.md) for the full Security And Supply Chain
policy this repository is working toward.

## Verification Chain

Everything traces back to one pinned ed25519 public key
(`--public-key`, `internal/verify.PublicKey`):

1. **Release manifest (offline mode).** `release-manifest.json` is
   schema-validated (`schemas/release-manifest.v1.schema.json`), then its
   detached signature `release-manifest.sig` is verified against the
   pinned key (`internal/bundle.Load`).
2. **Every bundle artifact (offline mode).** Each entry the manifest
   lists is checked against its recorded SHA-256 digest and size
   (`internal/verify`). There is no per-file signature — the manifest's
   own signature covers every digest it lists, so a single verified
   signature binds the entire bundle.
3. **Backups.** Every backed-up file's digest is recorded in the backup's
   own manifest and re-verified before any restore (`internal/backup.Verify`).
   A backup that fails verification is never restored from.

All of this fails closed: a missing file, a digest mismatch, or a
signature that doesn't verify is an error, never a warning or a silent
fallback. There is no remote fallback endpoint anywhere in this chain.

## K3s Ownership

`internal/k3s.DecideOwnership` is the single place that decides whether an
install may proceed:

- No installed-state and no existing K3s service → fresh install.
- Installed-state recorded and the service is present → reuse (same
  Zon version) or upgrade (different version).
- Installed-state recorded but the service is missing → `repair`, not a
  fresh install.
- No installed-state, a K3s service exists, and a prior install attempt
  is on record (the journal shows a previous `install` transaction) →
  rejected; the message points at `repair`, since this looks like a
  crashed install rather than a genuinely pre-existing cluster.
- No installed-state, a K3s service exists, and there's no prior install
  attempt on record → **adoption is considered**. `internal/k3s.InspectCluster`
  checks node health (`kubectl get nodes`) and whether any pods exist
  outside `kube-system`/`kube-public`/`kube-node-lease`/the platform's own
  namespace (`kubectl get pods --all-namespaces`):
  - Healthy and no foreign workloads → adopted automatically. K3s is
    upgraded to the bundle's pinned version only if the running version
    doesn't already match; a matching version is left untouched entirely.
  - Unhealthy and/or carrying foreign workloads → refused unless
    `--force-adopt` is passed. Zon never silently modifies a cluster it
    didn't create.

## Redaction

`internal/redact.Redactor` scrubs registered secret values from log output
and support bundles before they are ever written anywhere — the scrubbing
happens in the `slog.Handler` wrapper and in `internal/support.Build`, not
as a best-effort filter applied afterward. No component in this repository
currently generates or handles a real secret value (no TLS material or
passwords are generated yet — see release-plan.md step 10 of the Fresh
Install Sequence, not yet implemented), so today this pipeline has nothing
concrete to scrub, but every code path that will eventually carry a secret
already flows through it.

## Destructive-Command Confirmation

`uninstall` and `factory-reset` both require an explicit, non-interactive
confirmation token before any host mutation happens:

- **`uninstall`** (preserves the data directory) requires `--confirm <token>`.
- **`factory-reset`** (wipes the data directory) requires all of:
  - `--confirm <token>`
  - `--acknowledge-data-loss`
  - either `--backup-id <id>` referencing a backup that passes integrity
    verification, or the explicit `--force-data-loss` override.

Each gate is checked independently and in order, before `internal/teardown`
is ever called — a request missing any one of them fails with a specific
message naming the missing flag, not a generic refusal. There is currently
no interactive (TTY-prompt) confirmation path; the token model above is
the "controlled non-interactive operation" the release plan calls for.

## Offline Operation

V1 lifecycle operation never performs a public-network call. Every
verification, install, upgrade, backup, and restore step operates on
local files, the local K3s API, and locally-invoked binaries
(`ctr`, `helm`, `kubectl`). This is exercised directly: several packages
(`internal/verify`, `internal/images`, `internal/helm`, `internal/install`)
include a regression test that points the process's DNS resolver at a
dialer which always errors and proves the relevant offline operation
still succeeds.
