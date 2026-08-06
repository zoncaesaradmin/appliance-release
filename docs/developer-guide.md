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
  chart, schema, optional Argo artifacts, and signed `release-input`
- `appliance-ctl` owns the `zonctl` source, tests, and binary
- `appliance-release` owns packaging automation, bundle assembly
  workspace setup, signing material generation, and final bundle
  composition

## Day-To-Day Loop

```bash
make verify
bash ./scripts/ci/build-full-bundle.sh
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

## Which Workflow To Use

- Normal CI/build-machine path:
  use the next section of this guide
- Manual low-level bundle debugging:
  [manual-bundle-assembly.md](manual-bundle-assembly.md)
- Target-host install / upgrade / reset:
  [operator-guide.md](operator-guide.md)

## Normal Build / CI Path

This is the supported end-to-end release build flow.

```bash
DEV_REGISTRY=artifact-dns-1.appliance.internal \
DEV_REGISTRY_TOKEN=... \
DEV_REGISTRY_TLS_VERIFY=false \
DEV_IMAGE_REPO=development-container \
DEV_IMAGE_NAME=dev-build \
DEV_IMAGE_TAG=latest \
bash ./scripts/ci/build-full-bundle.sh
```

Optional: `PRODUCT_VERSION=…` overrides `configs/default-product-version`.

K3s binary and airgap images are downloaded during the build from the appliance
files API (same layout seedable by `scripts/ci/fetch-k3s-inputs.sh`):

`https://$DEV_REGISTRY/api/v1/files/k3s/<K3S_VERSION>/…`

`K3S_VERSION` defaults from `configs/product-bundle.ci.env`.

For the complete product (default), the build packages `registry.local/dev-build`
from `${DEV_REGISTRY}/${DEV_IMAGE_REPO}/${DEV_IMAGE_NAME}:${DEV_IMAGE_TAG}`.

That script:

- sources stable defaults from `configs/product-bundle.ci.env`
- uses the current `appliance-release` checkout as the driver repo
- clones or refreshes `appliance-code` and `appliance-ctl`
- always packages OCI/host payloads by export/pull on the build host
  (network, with an automatic LAN build-cache on `DEV_REGISTRY` when set).
  Local pre-supplied image archive / CRD / host-packages dir knobs are not
  supported
- asks `appliance-code` to build `release-input-${PRODUCT_VERSION}.tar.gz`
- assembles and verifies the final signed bundle
- exports the delivery files into `EXPORT_DIR` or `RELEASE_WORK_ROOT/export`

Outputs:

- `${RELEASE_WORK_ROOT}/workspace/out/appliance-${PRODUCT_VERSION}-bundle`
- `${RELEASE_WORK_ROOT}/export/appliance-${PRODUCT_VERSION}-bundle.tar.gz`
- `${RELEASE_WORK_ROOT}/export/release-signing.pub`

Product packaging always exports the complete host package super-set
(`mdns` + `wifi-ap`) for the selected `OS_VERSION` baseline under
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
bash ./scripts/ci/bootstrap-build-host.sh
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

Publishing is intentionally separate from build.

The simple flow is:

1. Build the release bundle on the CI/build machine.
2. Export:
   - `appliance-<version>-bundle.tar.gz`
   - `release-signing.pub`
   - `sha256sum.txt`
   - `install-http-release.sh`
3. Copy those files to a download server over SSH/SCP.
4. Serve them over HTTP or HTTPS.
5. Let the customer download them and install from local disk.

Example:

```bash
export PRODUCT_VERSION=0.1.0   # optional; defaults from configs/default-product-version
make publish-release \
  EXPORT_DIR=/home/zonsys/appliance-build/export \
  PUBLISH_SERVER=release@downloads.example.internal \
  PUBLISH_REMOTE_ROOT=/srv/www/releases \
  PUBLISH_PUBLIC_BASE_URL=http://downloads.example.internal/releases
```

The published `install-http-release.sh` helper takes a required
`--appliance-name` and optional `--appliance-profile` (default `core`). Other
values are product defaults stamped at publish or set near the top of the
script for rare overrides (including `BUILD_CATALOG_PATH` for builder).

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

- `make init-simple-workspace`
- `make fetch-release-input`
- `make assemble-simple-bundle`
- `make verify-bundle`

## Before Merging Changes

1. Run `make verify`.
2. Run `make product-bundle CONFIG="$(pwd)/configs/product-bundle.sample.env"`
   if you changed packaging flow and want a full local smoke test.
3. If you changed bundle examples or config shape, review the generated
   workspace files and JSON examples.
4. If you changed `zonctl`, validate those changes in `appliance-ctl`.
