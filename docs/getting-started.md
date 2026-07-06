# Getting Started

This page is for two different audiences, because this repository is
mid-build (see [CHANGELOG.md](../CHANGELOG.md)): an **operator** who
eventually runs `zonctl install` against a real signed bundle, and a
**developer** working on this repository itself. Read the section that
matches what you're trying to do.

## For Operators: Installing Zon

On a supported Ubuntu Server host (22.04 or 24.04 LTS), installing Zon is
one command from the signed appliance bundle:

```
zonctl install --bundle-dir /path/to/extracted/bundle --public-key /path/to/release-signing.pub
```

`zonctl` verifies the signed bundle, re-checks every artifact digest,
runs host preflight, installs and starts K3s (or adopts a compatible
existing cluster), preloads the bundled images, and applies the chart —
see [install.md](install.md) for
exactly what happens at each step.

Public egress is not required during install or runtime.

## For Developers: Working On This Repository

### Prerequisites

- `make`
- `bash`
- a local `appliance-ctl` checkout if you want to assemble bundles
  locally; that repo owns the `zonctl` source and binary
- a local `appliance-code` checkout if you want to run the sample
  product-bundle flow end to end

If you want to change `zonctl` itself, work in `appliance-ctl`, not
here. This repo is now the packaging/orchestration layer.

### Day-to-day loop

```
make verify
make sample-product-bundle
make product-bundle CONFIG=/abs/path/to/product-bundle.env
make clean
```

Use `make verify` before committing. It runs the local repo checks that
do not require a real host or a full product bundle, and finishes with
`make clean`.

Use `make sample-product-bundle` when you want a fully automated local
smoke run with generated placeholder inputs. Use `make product-bundle`
when you have real artifacts and versions to package.

### Repo Boundary

- `appliance-code` owns product artifacts such as the control-plane
  chart, image handoff, schema, and release-input metadata
- `appliance-ctl` owns the `zonctl` source, tests, and binary
- `appliance-release` owns packaging automation, bundle assembly
  workspace setup, signing material generation, and final bundle
  composition

### Real-bundle targets

`assemble-bundle` and `verify-bundle` are now real targets. They use
an external `zonctl` binary for producing and verifying a signed
extracted bundle:

```bash
BUNDLE_CONFIG=/abs/path/to/bundle-assembly.json make assemble-bundle
BUNDLE_DIR=/abs/path/to/bundle PUBLIC_KEY=/abs/path/to/release-signing.pub make verify-bundle
```

By default these targets look for `../appliance-ctl/bin/zonctl`. If
your binary lives elsewhere, set `ZONCTL_BINARY=/abs/path/to/zonctl`.

### Exercising The CLI Directly

If you want to build and run `zonctl` directly, do that in
`appliance-ctl`:

```
make -C ../appliance-ctl build
../appliance-ctl/bin/zonctl --help
```

### Before merging changes

1. Run `make verify`.
2. Run `make sample-product-bundle` if you changed packaging flow and
   want a full local smoke test.
3. If you changed bundle examples or config shape, review the generated
   workspace files and JSON examples.
4. If you changed `zonctl`, validate those changes in `appliance-ctl`.
