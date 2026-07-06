# Installing Zon

This describes the current, implemented behavior of `zonctl install`. It
covers what ships today; see [release-plan.md](release-plan.md) for the
overall plan and execution ledger, and [security.md](security.md) for the
trust model behind every verification step mentioned here.

Implementation package names referenced below now live in the
`appliance-ctl` repo, which owns the `zonctl` source tree.

## Bundle-Only V1

`zonctl install` runs from one verified source in v1: an extracted,
signed appliance bundle passed via `--bundle-dir`. The bundle contains
the pinned K3s binary, K3s platform images, application OCI images, the
Helm chart, Argo CRDs, default configuration, and the signed
`release-manifest.json` that binds them together.

## Prerequisites

- A host that passes `zonctl preflight` (see [Host Requirements](#host-requirements)
  below). Installation refuses to proceed if preflight reports `unsupported`
  or `operator-action` findings.
- The extracted air-gap release bundle directory (contains
  `release-manifest.json`, `release-manifest.sig`, and every artifact the
  manifest lists).
- The pinned release-signing public key (`--public-key`). This is the
  root of trust for installation: every other verification step chains
  from a valid signature against this key.

## Host Requirements

The qualified v1 baseline (see [support-matrix.md](support-matrix.md) and
`internal/preflight`) is:

- Ubuntu Server 22.04 LTS or 24.04 LTS, `amd64`
- At least 4 CPUs and 8 GiB RAM
- A local `ext4` filesystem for the platform data directory, with at least
  50 GiB free space and 200,000 free inodes
- cgroup v2, kernel user namespaces, and IPv4 forwarding enabled (IPv4
  forwarding is auto-fixed by the installer if disabled; the rest are
  operator-action findings that must be resolved before install proceeds)
- A synchronized system clock, an internally resolvable hostname, and ports
  `6443`, `10250`, and `8472` free (the K3s single-node baseline; additional
  product-specific ports are added once `appliance-code`'s configuration
  schema pins them)
- No conflicting `docker`, `microk8s`, or unrelated `kubelet` service, and no
  active host firewall blocking the required ports

Run `zonctl preflight --output json` to get a full machine-readable
report before installing.

## Running Install

```
zonctl install \
  --bundle-dir /path/to/extracted/bundle \
  --public-key /path/to/release-signing.pub \
  --state-dir /var/lib/zon \
  [--node-name my-node] \
  [--dry-run] \
  [--output text|json]
```

`--state-dir` defaults to `/var/lib/zon` and holds the installer lock,
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
6. **CRDs and chart.** The bundled Argo CRDs are applied, then the exact
   Zon Helm chart is installed via `helm upgrade --install` against
   the bundle's schema-validated values file.
7. **Persist installed-state.** On success, `installed-state.json` records
   the installed version, component versions, and K3s ownership.

If any step from image preload onward fails, install rolls back exactly
what it did this run: newly imported images are removed, a failed chart
apply is uninstalled, and K3s is stopped. V1 never silently substitutes
an unpinned or unverified artifact for one that failed to resolve, and
it never falls back to the network.

## Evidence

Every install run persists an `evidence.v1` report under
`<state-dir>/evidence/evidence-<transaction-id>.json`, combining the
bundle-verification checks, the preflight checks, and the image/CRD/chart
checks from this run. `zonctl support-bundle` collects this alongside
`installed-state.json` into a single redacted archive; see
[troubleshooting.md](troubleshooting.md).
