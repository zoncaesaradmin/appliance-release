# Build Machine / CI Workflow

Audience: build machine or CI runner only.

This is the normal end-to-end release build path. It is not for the target
Ubuntu host.

This repo exposes one primary CI entrypoint and one lower-level debug path:

```bash
bash ./scripts/ci/build-full-bundle.sh
make product-bundle CONFIG=/abs/path/to/product-bundle.env
```

The supported model is:

- `appliance-code` produces a prepared `release-input` artifact during the CI run
- `appliance-ctl` provides the `zonctl` source and binary
- `appliance-release` consumes that `release-input`, stages the remaining
  K3s installer artifacts, and assembles the final signed bundle

When the product handoff includes optional Phase 1 Argo Workflows artifacts
(chart, CRDs, controller image, executor image), this repo now carries those
through the bundle automatically as part of the same manifest-driven flow.

## Normal CI Command

If your build machine already checked out `appliance-release`, the preferred
single command is:

```bash
PRODUCT_VERSION=0.1.0 \
CODE_REPO_SOURCE=https://git.example.invalid/zon/appliance-code.git \
CTL_REPO_SOURCE=https://git.example.invalid/zon/appliance-ctl.git \
K3S_BINARY_SOURCE=/ci/inputs/k3s \
K3S_AIRGAP_IMAGES_SOURCE=/ci/inputs/k3s-airgap-images-amd64.tar.zst \
bash ./scripts/ci/build-full-bundle.sh
```

That script will:

- source the stable defaults from [configs/product-bundle.ci.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.ci.env)
- use the current `appliance-release` checkout as the driver repo
- clone `appliance-code` and `appliance-ctl` on the first run, then refresh those same clones under `WORK_ROOT/repos` on later runs
- ask `appliance-code` to build `release-input-${PRODUCT_VERSION}.tar.gz` from inside its dev container
- write the resolved bundle config into `WORK_ROOT/workspace/generated`
- assemble and verify the final signed bundle
- export the customer delivery files into `EXPORT_DIR` or `WORK_ROOT/export`

On every run, the script recreates the generated workspace, artifacts, and
exported delivery files. The dependency repo clones are refreshed in place.

## Outputs

- `${WORK_ROOT}/workspace/out/appliance-${PRODUCT_VERSION}-bundle`
- `${WORK_ROOT}/export/appliance-${PRODUCT_VERSION}-bundle.tar.gz`
- `${WORK_ROOT}/export/release-signing.pub`

## One-Time Build-Host Bootstrap

Because the `release-input` producer path in `appliance-code` builds the
control-plane image inside that repo's shared dev container, the Linux build
host needs the Podman / registry bootstrap once:

```bash
export REGISTRY_USER=<github-username>
export REGISTRY_TOKEN=<PAT with read:packages>
bash ./scripts/ci/bootstrap-build-host.sh
```

After that, later CI runs should stay non-interactive.

## Real Inputs

The primary script expects these external K3s inputs:

- `k3s`
- `k3s-airgap-images-amd64.tar.zst`
- optionally, `HELM_BINARY=/abs/path/to/helm` if you want to override the
  pinned auto-downloaded Helm artifact

`release-input-${PRODUCT_VERSION}.tar.gz` is produced during the run by the
cloned `appliance-code` repo.

## Config-Driven Flow

If you already have a fully written env file, run:

```bash
make product-bundle CONFIG=/path/to/product-bundle.env
```

Start from these templates if you want examples:

- [configs/product-bundle.ci.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.ci.env)
- [configs/product-bundle.sample.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.sample.env)

Use this lower-level path when you are debugging bundle inputs or intentionally
overriding staged artifacts.

## Local Smoke Run

For a completely local non-production smoke run with generated placeholders:

```bash
make product-bundle CONFIG="$(pwd)/configs/product-bundle.sample.env"
```

That flow auto-generates a placeholder `release-input`, placeholder control
plane/K3s artifacts, a placeholder Helm binary, assembles a sample bundle,
and verifies it. If you also set `ARGO_VERSION` plus the Argo image references,
the sample flow includes placeholder Argo artifacts too. The sample
output lands at:

- `${TMPDIR:-/tmp}/appliance-product-sample/out/appliance-0.1.0-bundle`

## Lower-Level Targets

If you need to debug a specific stage, these low-level targets still exist:

- `make init-simple-workspace`
- `make fetch-release-input`
- `make assemble-simple-bundle`
- `make verify-bundle`
