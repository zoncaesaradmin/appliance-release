# Developer Guide

Audience: developer machine, build machine, or CI runner.

This page is the canonical starting point for working on
`appliance-release`. If you are operating a target Ubuntu host, use
[operator-guide.md](operator-guide.md) instead.

## What This Repo Owns

- bundle assembly
- final release signing
- publish/distribution helpers
- packaging automation that consumes `appliance-code` and `appliance-ctl`

If you need to change the `zonctl` source, work in `appliance-ctl`, not here.

## Repo Boundary

- `appliance-code` owns product artifacts such as the control-plane
  chart, schema, optional workflows engine artifacts, and signed `release-input`
- `appliance-ctl` owns the `zonctl` source, tests, and binary
- `appliance-release` owns packaging automation, bundle assembly
  workspace setup, signing material generation, and final bundle
  composition

## Day-To-Day Loop

```bash
make verify
bash ./scripts/build-full-bundle.sh
make product-bundle CONFIG=/abs/path/to/product-bundle.env
make clean
```

Use `make verify` before committing. It runs the local repo checks that
do not require a real host or a full product bundle, and finishes with
`make clean`.

For a completely local non-production smoke run with generated placeholders:

```bash
make product-bundle CONFIG="$(pwd)/configs/product-bundle.sample.env"
```

## Build-host modes: fully online or fully offline

Exactly **two** modes for third-party / tooling inputs — one policy for *all*
of them. Not a mix of GHCR-here / LAN-there.

| Mode | Config / flag | Inputs |
|---|---|---|
| Online | `build_flow.mode: online` / `OFFLINE_BUILD=0` | Public internet; tooling via unified `DEV_*` (mapped from `ONLINE_*`) |
| Offline | `build_flow.mode: offline` / `OFFLINE_BUILD=1` | LAN only after `make seed-build-deps`; tooling is already `DEV_*` |

The skill (or hand-run) **unifies once** into `DEV_*` + `OFFLINE_BUILD`. After
that, `build-full-bundle.sh` / `bootstrap-build-host.sh` / appliance-code
`Makefile` share one path — no `ONLINE_*` branching in packaging. There is no
separate `OFFLINE_*` env family: offline and LAN are the same `DEV_*` values.

Publish remaps `bundle_store` (LAN `DEV_*`) for `publish-release.sh` only.

See [offline-build-deps.md](offline-build-deps.md) and
`references/config.build-publish.example.yaml`.

### Offline seed (prerequisite for offline mode)

Seeds every `deps/*` package into the LAN Artifact Server (including
`dns`/coredns, `inference`/ollama, and `development-container`/`dev-build`).
Both online and offline packaging must work for each of those pins.

**`dev-build` dual publish:** `make seed-build-deps` updates the LAN copy only.
After changing `deps/development-container`, also publish manually to GHCR so
online packaging and `appliance-code` local service builds (`make dev-shell`,
control-plane / UI images, …) stay current. Exact commands:
[`deps/development-container/PACKAGE.md`](../deps/development-container/PACKAGE.md).

```bash
export DEV_REGISTRY=artifact-dns-1.appliance.internal
export DEV_REGISTRY_USER=admin
export DEV_REGISTRY_TOKEN=...
export DEV_REGISTRY_TLS_VERIFY=false
export DEV_IMAGE_REPO=development-container
make seed-build-deps
```

### Online bundle (hand-run — DEV_* already unified to GHCR)

```bash
DEV_REGISTRY=ghcr.io \
DEV_IMAGE_REPO=zoncaesaradmin/development-container \
DEV_IMAGE_NAME=dev-build DEV_IMAGE_TAG=latest \
DEV_REGISTRY_USER=... DEV_REGISTRY_TOKEN=... \
bash ./scripts/build-full-bundle.sh
# For publish-release.sh, point DEV_* at the LAN Artifact Server (bundle_store).
```

### Offline bundle (hand-run — DEV_* already unified to LAN)

```bash
OFFLINE_BUILD=1 \
DEV_REGISTRY=... DEV_IMAGE_REPO=development-container \
DEV_REGISTRY_USER=... DEV_REGISTRY_TOKEN=... DEV_REGISTRY_TLS_VERIFY=false \
bash ./scripts/build-full-bundle.sh
```

## Which Workflow To Use

- Normal CI/build-machine path:
  use the next section of this guide
- Manual low-level bundle debugging:
  [manual-bundle-assembly.md](manual-bundle-assembly.md)
- Target-host install / upgrade / reset:
  [operator-guide.md](operator-guide.md)

## Normal Build / CI Path

This is the supported end-to-end release build flow. Prefer the skill config
`build_flow.mode: online|offline` (see
`.agents/skills/release/references/config.build-publish.example.yaml`).

**Online** (hand-run; unify to DEV_* first):

```bash
DEV_REGISTRY=ghcr.io \
DEV_IMAGE_REPO=zoncaesaradmin/development-container \
DEV_IMAGE_NAME=dev-build DEV_IMAGE_TAG=latest \
DEV_REGISTRY_USER=<github-username> \
DEV_REGISTRY_TOKEN=<PAT with read:packages> \
bash ./scripts/build-full-bundle.sh
```

**Offline** (after seed; DEV_* = LAN):

```bash
OFFLINE_BUILD=1 \
DEV_REGISTRY=artifact-dns-1.appliance.internal \
DEV_IMAGE_REPO=development-container \
DEV_REGISTRY_USER=... \
DEV_REGISTRY_TOKEN=... \
DEV_REGISTRY_TLS_VERIFY=false \
bash ./scripts/build-full-bundle.sh
```

Optional: `PRODUCT_VERSION=…` overrides `configs/default-product-version`.

In offline mode, K3s / Helm / CRDs / host-packages come from the LAN files API.
Online mode uses public upstreams for those same pins (K3s from GitHub, Helm
from get.helm.sh). Files API / LAN build-cache stay off when `OFFLINE_BUILD=0`.

The `DEV_*` tooling image (`dev-build`) builds product images on the build host
only. It is **not** packaged into the appliance. Each release exports signed
deliverables under `RELEASE_WORK_ROOT/export/` according to `APPLIANCE_PACKS`
(default `all`):

- `appliance-${PRODUCT_VERSION}-foundation.tar.gz` (foundation; always included)
- `appliance-${PRODUCT_VERSION}-developer.tar.gz` (when selected)
- `appliance-${PRODUCT_VERSION}-inference.tar.gz` (when selected)
- `release-index.yaml` (lists packs built this run + capability → pack map)

```bash
# Default: build and stage every pack
bash ./scripts/build-full-bundle.sh

# Faster iteration examples
APPLIANCE_PACKS=foundation bash ./scripts/build-full-bundle.sh
APPLIANCE_PACKS=foundation,developer bash ./scripts/build-full-bundle.sh
APPLIANCE_PACKS=foundation,inference bash ./scripts/build-full-bundle.sh
```

That script:

- sources stable defaults from `configs/product-bundle.ci.env`
- uses the current `appliance-release` checkout as the driver repo
- clones or refreshes `appliance-code` and `appliance-ctl`
  (with `OFFLINE_BUILD=1` / `USE_LOCAL_CHECKOUTS=1`, uses synced local trees)
- packages OCI/host payloads under one source policy: public upstreams (online)
  or LAN only (offline; seed with `make seed-build-deps` first)
- asks `appliance-code` to build `release-input-${PRODUCT_VERSION}.tar.gz`
- assembles and verifies the final signed bundle
- exports the delivery files into `RELEASE_WORK_ROOT/export`

Outputs:

- `${RELEASE_WORK_ROOT}/workspace/out/appliance-${PRODUCT_VERSION}-foundation` (foundation pack dir)
- `${RELEASE_WORK_ROOT}/export/appliance-${PRODUCT_VERSION}-foundation.tar.gz`
- `${RELEASE_WORK_ROOT}/export/appliance-${PRODUCT_VERSION}-developer.tar.gz` (when developer pack selected)
- `${RELEASE_WORK_ROOT}/export/appliance-${PRODUCT_VERSION}-inference.tar.gz` (when inference pack selected)
- `${RELEASE_WORK_ROOT}/export/release-index.yaml`
- `${RELEASE_WORK_ROOT}/export/release-signing.pub`

Product packaging always exports the complete host package super-set
(`mdns` + `wifi-client` + `wifi-ap`) for the selected `OS_VERSION` baseline under
`ubuntu/<version>/amd64/*.deb` on the build host (apt download during export).
That tree is copied into signed `host-packages/`. Install stages the .deb
payload offline but leaves mDNS and Wi-Fi AP services off; admins enable them
day-2 via Admin UI / control-plane host APIs (with PSK supplied at enable time
for Wi-Fi AP). Optional `COMPONENT_CACHE_DIR` enables fingerprint-based reuse
of component outputs (Phase C); assemble and sign always re-run.

## One-Time Build Host Bootstrap

Because `appliance-code` builds the control-plane image inside its shared dev
container, the Linux build host needs the Podman / registry bootstrap once:

```bash
export DEV_REGISTRY_USER=<github-username>
export DEV_REGISTRY_TOKEN=<PAT with read:packages>
bash ./scripts/bootstrap-build-host.sh
```

## Config-Driven Build Path

If you already have a fully written env file, run:

```bash
make product-bundle CONFIG=/path/to/product-bundle.env
```

Start from these templates if you want examples:

- `configs/product-bundle.ci.env`
- `configs/product-bundle.sample.env`

## Publish A Built Release

One product sequence on the build host (after `DEV_*` and `RELEASE_WORK_ROOT`
are set). For CI, prefer the Makefile trigger from the repo root:

```bash
make build-and-publish
```

That runs bootstrap → build → publish and aborts on the first failure.
The same leaf scripts, if you prefer to call them by hand:

```bash
bash ./scripts/bootstrap-build-host.sh
bash ./scripts/build-full-bundle.sh
bash ./scripts/publish-release.sh
```

`publish-release.sh` uploads the packs listed in `export/release-index.yaml`
(from the last build). Default build is `APPLIANCE_PACKS=all` (foundation +
developer + inference). Selective builds only publish what was staged.

Publish uploads to:

`https://$DEV_REGISTRY/api/v1/files/appliance/<version>/`

Optional: `bash ./scripts/publish-release.sh --latest-alias` also
uploads under `appliance/latest/`. `PRODUCT_VERSION` defaults from
`configs/default-product-version`.

The published `install-release.sh` helper takes a required
`--appliance-name` and optional `--appliance-profile` (default `core`). Other
values are product defaults stamped at publish or set near the top of the
script for rare overrides.

For the target-host runbook itself, see
[operator-guide.md](operator-guide.md).

## Real Bundle Targets

`assemble-bundle` and `verify-bundle` use an external `zonctl` binary for
producing and verifying a signed extracted bundle:

```bash
BUNDLE_CONFIG=/abs/path/to/bundle-assembly.json make assemble-bundle
BUNDLE_DIR=/abs/path/to/bundle PUBLIC_KEY=/abs/path/to/release-signing.pub make verify-bundle
```

By default these targets look for `../appliance-ctl/bin/zonctl`. If
your binary lives elsewhere, set `ZONCTL_BINARY=/abs/path/to/zonctl`.

## Lower-Level Targets

If you need to debug a specific stage, these targets still exist:

- `make init-bundle-workspace`
- `make verify-bundle`

## Before Merging Changes

1. Run `make verify`.
2. Run `make product-bundle CONFIG="$(pwd)/configs/product-bundle.sample.env"`
   if you changed packaging flow and want a full local smoke test.
3. If you changed bundle examples or config shape, review the generated
   workspace files and JSON examples.
4. If you changed `zonctl`, validate those changes in `appliance-ctl`.
