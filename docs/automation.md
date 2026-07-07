# Bundle Automation

This repo exposes one primary CI entrypoint and two lower-level wrappers:

```bash
bash ./scripts/ci/run-product-bundle.sh ...
make ci-product-bundle ...
make product-bundle CONFIG=/abs/path/to/product-bundle.env
```

The supported model is:

- `appliance-code` produces a prepared `release-input` artifact
- `appliance-ctl` provides the `zonctl` source and binary
- `appliance-release` consumes that `release-input`, stages the remaining
  K3s installer artifacts, and assembles the final signed bundle

## Single CI Command

After CI checks out `appliance-release`, the single command to run is:

```bash
bash ./scripts/ci/run-product-bundle.sh \
  --product-version 0.1.0 \
  --release-input-source /ci/inputs/release-input-0.1.0.tar.gz \
  --k3s-binary-source /ci/inputs/k3s \
  --k3s-install-script-source /ci/inputs/install.sh \
  --k3s-airgap-images-source /ci/inputs/k3s-airgap-images-amd64.tar.zst
```

That command will:

- clone `appliance-ctl` into `WORKSPACE/repos/appliance-ctl`
- stage the install-side inputs into `WORKSPACE/inputs`
- write `${WORKSPACE}/generated/product-bundle.env`
- build `zonctl`
- import the prepared `release-input`
- assemble the final signed extracted bundle
- verify the bundle

The single CI defaults file is
[configs/product-bundle.ci.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.ci.env).
That file carries the stable values like the pinned K3s version, the control
plane image repository, the default workspace, and the default `appliance-ctl`
source. The outer script is the one thing that should drive runtime inputs.

The generated config file is left on disk as rerun/audit evidence:

- `${WORKSPACE}/generated/product-bundle.env`

## Real Inputs

Real bundle builds still need these inputs:

- `release-input-${PRODUCT_VERSION}.tar.gz` or an unpacked `release-input/`
- `k3s`
- `install.sh`
- `k3s-airgap-images-amd64.tar.zst`

By default, the control-plane image is taken from the prepared `release-input`.
Only override the control-plane image if you are intentionally substituting a
different local file for debugging.

The outer CI script can take the `release-input` either as:

- `--release-input-source /path/or/url`
- `--release-input-version VERSION --release-input-fetch-template 'https://example.invalid/release-input-{version}.tar.gz'`

The other staged files can be overridden in the config-driven flow with:

- `CONTROL_PLANE_IMAGE`
- `K3S_BINARY`
- `K3S_INSTALL_SCRIPT`
- `K3S_AIRGAP_IMAGES`

## Config-Driven Flow

If you want to drive the lower-level wrapper directly:

```bash
make ci-product-bundle \
  WORKDIR=/private/tmp/appliance-product-ci \
  PRODUCT_VERSION=0.1.0 \
  K3S_VERSION=v1.30.4+k3s1 \
  CTL_REPO_SOURCE=/abs/path/to/appliance-ctl \
  RELEASE_INPUT_SOURCE=/ci/inputs/release-input-0.1.0.tar.gz
```

If you already have a fully written env file, run:

```bash
make product-bundle CONFIG=/path/to/product-bundle.env
```

Start from these templates if you want examples:

- [configs/product-bundle.ci.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.ci.env)
- [configs/product-bundle.sample.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.sample.env)

## Local Smoke Run

For a completely local non-production smoke run with generated placeholders:

```bash
make product-bundle CONFIG="$(pwd)/configs/product-bundle.sample.env"
```

That flow auto-generates a placeholder `release-input`, placeholder control
plane/K3s artifacts, assembles a sample bundle, and verifies it. The sample
output lands at:

- `/private/tmp/appliance-product-sample/out/appliance-0.1.0-bundle`

## Lower-Level Targets

If you need to debug a specific stage, these lower-level targets still exist:

- `make init-simple-workspace`
- `make fetch-release-input`
- `make assemble-simple-bundle`
- `make verify-bundle`
