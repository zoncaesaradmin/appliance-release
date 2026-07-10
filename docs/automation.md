# Bundle Automation

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

## Single Build-Machine Command

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

If `helm` is not already on the build-machine `PATH`, also set:

```bash
HELM_BINARY=/abs/path/to/helm
```

That script will:

- source the stable defaults from [configs/product-bundle.ci.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.ci.env)
- use the current `appliance-release` checkout as the driver repo
- clone `appliance-code` and `appliance-ctl` on the first run, then refresh those same clones under `WORK_ROOT/repos` on later runs
- ask `appliance-code` to build `release-input-${PRODUCT_VERSION}.tar.gz` from inside its dev container
- write the resolved bundle config into `WORK_ROOT/workspace/generated`
- assemble and verify the final signed bundle
- export the customer delivery files into `EXPORT_DIR` or `WORK_ROOT/export`

On every run, the script rebuilds the generated state from scratch. The repo
clones are reused and refreshed, while the workspace, artifacts, and exported
delivery files are cleared and recreated so reruns do not inherit stale bundle
outputs.

The final extracted bundle lands at:

- `${WORK_ROOT}/workspace/out/appliance-${PRODUCT_VERSION}-bundle`

The customer-facing handoff files land at:

- `${WORK_ROOT}/export/appliance-${PRODUCT_VERSION}-bundle.tar.gz`
- `${WORK_ROOT}/export/release-signing.pub`

The single CI defaults file is
[configs/product-bundle.ci.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.ci.env).
That file carries the stable values like the pinned K3s version, the control
plane image repository, the default workspace, and the default `appliance-ctl`
source. The outer script is the one thing that should drive runtime inputs.

Because the `release-input` producer path in `appliance-code` builds the
control-plane image inside that repo's shared dev container, the Linux build
host needs the prerequisites documented by `appliance-code` for `make dev-run`
to work, especially Podman plus the one-time dev-container registry auth/bootstrap.
The build host also needs a local Helm binary available on `PATH`, or passed
explicitly as `HELM_BINARY=/abs/path/to/helm`, so the final bundle can include
the bundle-local Helm launcher used during target-host install.

This CI script is intentionally non-interactive. If the Linux build host has
not yet been bootstrapped for `appliance-code`'s rootful Podman flow, the
script now fails with a clear message instead of pausing on a sudo password
prompt. Prepare the host once, outside CI:

```bash
export REGISTRY_USER=<github-username>
export REGISTRY_TOKEN=<PAT with read:packages>
bash ./scripts/ci/bootstrap-build-host.sh
```

After that one-time host bootstrap, later CI runs should stay non-interactive.

That helper reuses or refreshes the `appliance-code` clone under the normal
build root, then runs `make dev-registry-login` and `make dev-sudo-setup`
for you in the right place. The only interactive step should be the one-time
sudo authentication inside that bootstrap helper.

The generated config file is left on disk as rerun/audit evidence:

- `${WORKSPACE}/generated/product-bundle.env`

What to publish to a customer or downstream deployment team:

- the exported bundle archive
- the exported `release-signing.pub`

The customer does not need any of the three source repos. They only need those
two exported files on the target Ubuntu host.

For the current simple distribution model, see
[HTTP Distribution](distribution-http.md). That page shows how to put the
exported files onto a separate HTTP/HTTPS download server with the new
publish script.

## Real Inputs

The primary CI script, `scripts/ci/build-full-bundle.sh`, now expects these
external inputs:

- `k3s`
- `k3s-airgap-images-amd64.tar.zst`
- a local Helm binary on the build machine

It does **not** expect you to provide `release-input-${PRODUCT_VERSION}.tar.gz`
from outside. That artifact is produced during the run by the cloned
`appliance-code` repo.

By default, the control-plane image path is taken from the prepared
`release-input`. Only override the control-plane image in the lower-level
config-driven flow if you are intentionally substituting a different local file
for debugging.

The lower-level config-driven flow still supports:

- `RELEASE_INPUT_SOURCE=/path/or/url`
- or `RELEASE_INPUT_VERSION=...` together with `RELEASE_INPUT_FETCH_TEMPLATE=...`

and these staging overrides:

- `CONTROL_PLANE_IMAGE`
- `K3S_BINARY`
- `K3S_AIRGAP_IMAGES`
- `HELM_BINARY`

## Config-Driven Flow

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
plane/K3s artifacts, assembles a sample bundle, and verifies it. It still
expects a local Helm binary on `PATH` unless you set `HELM_BINARY` in the
sample env file or shell. The sample
output lands at:

- `${TMPDIR:-/tmp}/appliance-product-sample/out/appliance-0.1.0-bundle`

## Lower-Level Targets

If you need to debug a specific stage, these low-level targets still exist:

- `make init-simple-workspace`
- `make fetch-release-input`
- `make assemble-simple-bundle`
- `make verify-bundle`
