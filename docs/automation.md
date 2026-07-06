# Bundle Automation

This repo now has one primary product-bundle workflow:

```bash
make product-bundle CONFIG=/abs/path/to/product-bundle.env
```

Everything else in this file is either a sample entrypoint or a lower-level
building block underneath that main command.

## Fastest Way To See It Work

Run:

```bash
make sample-product-bundle
```

That one command will:

- clone the configured `appliance-code` source into a temporary workspace
- use the configured `appliance-ctl` source to build `zonctl`
- create a minimal product-side `release-input` tarball
- build `zonctl` from `appliance-ctl`
- create the bundle workspace and signing keys
- stage sample K3s and control-plane inputs
- assemble the final extracted bundle
- verify the signed bundle

The sample output lands at:

- `/private/tmp/appliance-product-sample/out/appliance-0.1.0-bundle`

## Real Automated Run

Copy [product-bundle.sample.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.sample.env)
to your own file and change only the small set of inputs:

- `WORKDIR`
- `CODE_REPO_SOURCE`
- `CODE_REPO_REF` if you want a specific branch or tag
- `CTL_REPO_SOURCE`
- `CTL_REPO_REF` if you want a specific branch or tag
- `PRODUCT_VERSION`
- `K3S_VERSION`
- `CONTROL_PLANE_IMAGE_REF`
- the file paths under `INPUTS_DIR`, or point them somewhere else

Then run:

```bash
make product-bundle CONFIG=/path/to/product-bundle.env
```

The command will:

- use local repo paths directly when you point `CODE_REPO_SOURCE` or
  `CTL_REPO_SOURCE` at a checkout without a pinned ref
- clone a repo when you provide a remote source or a specific ref
- read the appliance chart and schema from that checkout
- package a versioned `release-input` tarball
- build a standalone `zonctl` binary from `appliance-ctl`
- prepare the release workspace
- stage K3s and install-side artifacts
- assemble the final bundle
- verify the bundle

## Sample Config Meaning

The sample config is at
[configs/product-bundle.sample.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.sample.env).

Important values:

- `SAMPLE_MODE=1` tells the workflow to generate placeholder inputs so the
  whole flow is runnable without real product artifacts
- `CODE_REPO_SOURCE` can be a local path or a git URL
- `CODE_REPO_REF` is optional; set it to a tag or branch if you want the
  cloned code repo pinned
- `CTL_REPO_SOURCE` can be a local path or a git URL
- `CTL_REPO_REF` is optional; set it to a tag or branch if you want the
  cloned CLI repo pinned
- `CONTROL_PLANE_IMAGE_REF` is the image reference written into the bundle
  manifest and install values
- `VALUES_FILE` is optional; if omitted, the generated minimal values file is
  used

For a real run, set `SAMPLE_MODE=0` or remove it and point the input paths at:

- a real control-plane image tar
- a real `argo-crds.yaml`
- the pinned `k3s` binary
- the matching K3s `install.sh`
- the matching K3s air-gap image archive

## Lower-Level Building Blocks

These targets still exist underneath the main automation and are useful if you
need to debug one stage:

- `make prepare-simple-workspace`
- `make assemble-simple-bundle`
- `make verify-bundle`

Those are advanced/internal entrypoints now. They expect a built `zonctl`
binary, usually from `../appliance-ctl/bin/zonctl`, or from an explicit
`ZONCTL_BINARY=/abs/path/to/zonctl` override.

The supported top-level path for a full product bundle is the config-driven
`product-bundle` target above.
