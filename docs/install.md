# Install Reference

This describes the current, implemented behavior of `zonctl install`. It
covers what ships today; see [release-plan.md](release-plan.md) for the
overall plan and execution ledger, and [security.md](security.md) for the
trust model behind every verification step mentioned here.

## Bundle-Only V1

`zonctl install` runs from one verified source in v1: an extracted,
signed appliance bundle passed via `--bundle-dir`. The bundle contains
the pinned K3s binary, K3s platform images, application OCI images, the
Helm chart, bundle-local helper binaries (`helm`, `kubectl`, `ctr` via
the bundled launcher layout), default configuration, and the signed
`release-manifest.json` that binds them together.

## Prerequisites

- A host that passes `zonctl preflight`. See
  [support-matrix.md](support-matrix.md) for the qualified target-host
  baseline. Installation refuses to proceed if preflight reports
  `unsupported` or `operator-action` findings.
- The extracted air-gap release bundle directory (contains
  `release-manifest.json`, `release-manifest.sig`, and every artifact the
  manifest lists).
- The pinned release-signing public key (`--public-key`). This is the
  root of trust for installation: every other verification step chains
  from a valid signature against this key.

## Running Install

```
zonctl install \
  --bundle-dir /path/to/extracted/bundle \
  --public-key /path/to/release-signing.pub \
  --state-dir /var/lib/zon/state \
  [--node-name my-node] \
  [--dry-run] \
  [--output text|json]
```

`--state-dir` defaults to `/var/lib/zon/state` and holds the installer lock,
transaction journal, `installed-state.json`, and evidence reports.
`--public-key` defaults to
`/etc/zon/keys/release-signing.pub`. `--node-name` defaults to the host's
hostname. `--force-adopt` takes ownership of an existing K3s cluster that
isn't obviously safe to adopt — see [K3s Ownership](security.md#k3s-ownership).

## What Install Actually Does

`zonctl install` (`internal/install.Orchestrator.Install`) runs, in order:

1. **Resolve artifacts** (`internal/install.Source`).
   `release-manifest.json` is schema-checked, its detached signature
   (`release-manifest.sig`) is verified against `--public-key`, and every
   entry's digest and size are re-verified against the files on disk.
   Any mismatch, missing artifact, or bad signature fails closed before
   anything else happens.
2. **Preflight.** The real host is detected and evaluated; an `unsupported`
   or `operator-action` overall status blocks the install.
3. **K3s ownership decision.** installed-state and the actual K3s service on
   the host are reconciled. A fresh host (no installed-state, no existing
   K3s service) always proceeds. An existing but unrecorded K3s service is
   either rejected as an interrupted prior install (run `repair`), adopted
   automatically if it's healthy and carries no foreign workloads, or
   refused pending `--force-adopt` otherwise — see
   [security.md](security.md#k3s-ownership).
4. **K3s install.** The release-owned `config.yaml` and systemd unit are
   written, the verified K3s binary is installed, and the service is
   started.
5. **Image preload.** Every `k3s-images` and `oci-images`
   bundle entry is digest-verified and imported directly into the K3s
   (containerd) image store — K3s platform images first, then application
   images — so no pod ever needs to pull from a registry.
6. **Chart apply.** The exact Zon Helm chart is installed via
   bundle-local `helm upgrade --install` against the bundle's
   schema-validated values file. The target host does not need a separate
   Helm package installed.
7. **Application bootstrap.** First-run application initialization is driven
   by `zonctl` in the same install workflow. For a human operator,
   `zonctl install` prompts on the terminal for the first administrator
   password; for automation, it accepts protected stdin-driven input rather
   than requiring a hand-created password file. Requiring the operator to
   `kubectl exec` into the control-plane pod is not an acceptable product
   workflow. The release/install contract is therefore: installer-owned
   bootstrap, replay disabled after success, and no secret material exposed on
   the command line.
8. **Persist installed-state.** On success, `installed-state.json` records
   the installed version, component versions, and K3s ownership.

If any step from image preload onward fails, install rolls back exactly
what it did this run: newly imported images are removed, a failed chart
apply is uninstalled, and K3s is stopped. V1 never silently substitutes
an unpinned or unverified artifact for one that failed to resolve, and
it never falls back to the network.

## First Admin Model

The intended operator workflow is:

1. `zonctl install` accepts the first-admin credential through a terminal
   prompt for a human operator, or through protected stdin for automation.
2. `zonctl` invokes the supported bootstrap path against the freshly deployed
   control plane.
3. The application disables bootstrap replay after success.

Manual pod access is still useful for engineering and break-glass debugging,
but it is not the supported first-time admin creation experience for
customers.

## Evidence

Every install run persists an `evidence.v1` report under
`<state-dir>/evidence/evidence-<transaction-id>.json`, combining the
bundle-verification checks, the preflight checks, and the image/chart
checks from this run. `zonctl support-bundle` collects this alongside
`installed-state.json` into a single redacted archive; see
[troubleshooting.md](troubleshooting.md).
