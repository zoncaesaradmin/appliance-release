# Changelog

This repository has not yet cut a signed public release — there is no
accepted `appliance-code` product input to assemble a bundle against yet
(see [docs/release-plan.md](docs/release-plan.md)'s Release Pipeline and
execution ledger). This file tracks implemented capability as of each
point in the repository's history instead of numbered product releases,
and will switch to dated release entries once R5-02 (final qualification
and publication) actually happens.

## Unreleased

### Added

- Versioned JSON schemas (`schemas/`) for the release-input manifest,
  final release manifest, installed-state record, evidence reports, and
  every CLI command's structured result, each with valid/invalid fixtures.
- Read-only host preflight against the qualified v1 baseline (Ubuntu
  Server 24.04 LTS, `amd64`; see [docs/support-matrix.md](docs/support-matrix.md)).
- Digest, signature, and provenance verification, plus vulnerability
  policy evaluation against signed, scoped, expiring exceptions.
- A lifecycle CLI skeleton: host-wide installer lock, atomic transaction
  journal (with interrupted-operation detection), redacted logging, and
  dry-run support.
- K3s install/configuration/ownership adapter, enforcing that an
  unrelated pre-existing cluster is never adopted.
- Offline OCI image preload into the K3s image store, and Helm
  application adapters.
- End-to-end `zonctl install`, verifying a signed bundle and running
  the full fresh-install sequence with bounded rollback on failure.
- `zonctl status`, `verify`, `repair`, and `support-bundle` (the last
  producing a redacted diagnostic archive).
- `zonctl backup` and `restore`, with an automated offline RPO/RTO
  drill proving byte-for-byte data integrity across a simulated disaster.
- `zonctl upgrade` implementing the N-1 upgrade policy, mandatory
  pre-upgrade backup, and restore-based rollback on failure.
- `zonctl uninstall` (data-preserving) and `zonctl factory-reset`
  (destructive, gated on a verified backup or an explicit override, both
  requiring an explicit confirmation token).
- Public documentation: [install](docs/install.md), [upgrade](docs/upgrade.md),
  [backup/restore](docs/backup-restore.md), [security](docs/security.md),
  [troubleshooting](docs/troubleshooting.md), [support matrix](docs/support-matrix.md),
  [offline verification guide](docs/verification.md), and [NOTICES](NOTICES.md).

### Known Gaps

- `zonctl verify` checks installed-state's own validity and current
  K3s health; it does not yet re-verify every installed artifact's digest
  against the original release manifest (the manifest isn't retained
  post-install yet).
- Upgrade does not yet coordinate in-flight workflow activity or run
  product-supplied migration hooks — see [docs/upgrade.md](docs/upgrade.md#whats-not-yet-wired).
- No component generates real secrets or TLS material yet (Fresh Install
  Sequence step 10), so the redaction pipeline is wired but has nothing
  concrete to scrub today.
- Bundle assembly itself (acquiring, pinning, and packaging third-party
  inputs into a real air-gap archive) has not been implemented; every
  test in this repository exercises the installer/lifecycle logic against
  small fixture bundles, not a real assembled release.
