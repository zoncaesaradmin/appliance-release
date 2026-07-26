# Security Model

This page describes the implemented trust, ownership, and safety rules.
For the larger historical execution plan, see
[archive/release-plan.md](archive/release-plan.md).

## Verification Chain

Everything traces back to one pinned Ed25519 public key:

1. `release-manifest.json` is schema-validated and its detached signature
   `release-manifest.sig` is verified against `--public-key`
2. every bundle artifact is verified against the digest and size recorded in
   the manifest
3. backups record per-file digests and are re-verified before restore

All of this fails closed. There is no remote fallback endpoint anywhere in the
chain.

## K3s Ownership

`internal/k3s.DecideOwnership` is the single place that decides whether an
install may proceed:

- no installed-state and no existing K3s service:
  fresh install
- installed-state recorded and service present:
  reuse or upgrade
- installed-state recorded but service missing:
  `repair`, not fresh install
- no installed-state, K3s exists, and a prior install attempt is recorded:
  reject and point to `repair`
- no installed-state, K3s exists, and no prior install attempt is recorded:
  consider adoption

Adoption behavior:

- healthy cluster with no foreign workloads:
  adopt automatically
- unhealthy cluster or cluster with foreign workloads:
  refuse unless `--force-adopt` is passed

Zon never silently modifies a cluster it did not create when unrelated
workloads are present.

## Redaction

`internal/redact.Redactor` scrubs registered secret values from log output and
support bundles before they are written anywhere. The scrubbing happens in the
logging and support-bundle paths themselves, not as a best-effort filter later.

## Destructive Command Confirmation

`uninstall` and `factory-reset` require explicit non-interactive confirmation
tokens before any host mutation happens.

- `uninstall` requires `--confirm <token>`
- `factory-reset` requires:
  `--confirm <token>`, `--acknowledge-data-loss`, and either a verified
  `--backup-id` or `--force-data-loss`
- `--wipe-workspaces` is separately required when builder workspace source
  trees under `/data/zon/workspaces` must also be removed

## Offline Operation

V1 lifecycle operation never performs a public-network call. Verification,
install, upgrade, backup, and restore all operate on:

- local files
- the local K3s API
- locally-invoked binaries such as `ctr`, `helm`, and `kubectl`
