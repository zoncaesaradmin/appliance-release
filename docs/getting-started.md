# Developer Getting Started

Audience: developer machine only.

This page is for working on `appliance-release` itself. If you are operating a
target Ubuntu host, use [target-host-operations.md](target-host-operations.md)
instead. If you are running CI or a release build machine, start with
[automation.md](automation.md).

## What This Repo Owns

- bundle assembly
- final release signing
- publish/distribution helpers
- packaging automation that consumes `appliance-code` and `appliance-ctl`

If you need to change the `zonctl` source, work in `appliance-ctl`, not here.

## Prerequisites

- `make`
- `bash`
- a local `appliance-ctl` checkout if you want to assemble bundles
  locally; that repo owns the `zonctl` source and binary

## Day-To-Day Loop

```
make verify
bash ./scripts/ci/build-full-bundle.sh
make product-bundle CONFIG=/abs/path/to/product-bundle.env
make clean
```

Use `make verify` before committing. It runs the local repo checks that
do not require a real host or a full product bundle, and finishes with
`make clean`.

Use the sample flow when you want a local smoke run with generated placeholder
inputs:

```bash
make product-bundle CONFIG="$(pwd)/configs/product-bundle.sample.env"
```

## Which Workflow To Use

- Normal CI/build-machine path:
  [automation.md](automation.md)
- Manual low-level bundle debugging:
  [real-setup.md](real-setup.md)
- HTTP publish step:
  [distribution-http.md](distribution-http.md)
- Target-host install / upgrade / reset:
  [target-host-operations.md](target-host-operations.md)

## Repo Boundary

- `appliance-code` owns product artifacts such as the control-plane
  chart, schema, and signed `release-input` handoff
- `appliance-ctl` owns the `zonctl` source, tests, and binary
- `appliance-release` owns packaging automation, bundle assembly
  workspace setup, signing material generation, and final bundle
  composition

## Real-Bundle Targets

`assemble-bundle` and `verify-bundle` are now real targets. They use
an external `zonctl` binary for producing and verifying a signed
extracted bundle:

```bash
BUNDLE_CONFIG=/abs/path/to/bundle-assembly.json make assemble-bundle
BUNDLE_DIR=/abs/path/to/bundle PUBLIC_KEY=/abs/path/to/release-signing.pub make verify-bundle
```

By default these targets look for `../appliance-ctl/bin/zonctl`. If
your binary lives elsewhere, set `ZONCTL_BINARY=/abs/path/to/zonctl`.

## Exercising `zonctl` Directly

If you want to build and run `zonctl` directly, do that in
`appliance-ctl`:

```
make -C ../appliance-ctl build
../appliance-ctl/bin/zonctl --help
```

## Before Merging Changes

1. Run `make verify`.
2. Run `make product-bundle CONFIG="$(pwd)/configs/product-bundle.sample.env"`
   if you changed packaging flow and want a full local smoke test.
3. If you changed bundle examples or config shape, review the generated
   workspace files and JSON examples.
4. If you changed `zonctl`, validate those changes in `appliance-ctl`.
