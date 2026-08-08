# Manual Bundle Assembly

Audience: developer machine or build machine only.

This is the low-level path to build an installable extracted appliance bundle
from local staged artifacts, verify it, copy it to a supported Ubuntu host,
and install it there with `zonctl`.

Use this only when debugging the lower-level bundle assembly flow. For the
normal one-command build path, see [developer-guide.md](developer-guide.md).

## What You Need

On the build workstation:

- this repository checked out locally
- the `appliance-ctl` repository checked out locally, or another built
  `zonctl` binary available on disk
- a release-input directory from `appliance-code`
- staged install-ready artifacts for the final bundle
- an Ed25519 signing key pair for the final release manifest

## 1. Build `zonctl`

```bash
make -C ../appliance-ctl build
```

## 2. Prepare The Inputs

You need two classes of input:

1. the immutable `release-input/` handoff from `appliance-code`
2. the final install-ready artifacts this repo will package into the bundle

At minimum, stage these install-ready artifacts somewhere local:

- `zonctl` Linux binary
- `k3s` Linux binary
- K3s air-gap image archive
- application/dependency OCI image archives
- chart archive
- installable Helm values file, usually `values.yaml`
- optional scanner database archive

Important notes:

- the `release-input` chart archive is already bundle-ready
- appliance-profile selection is not a bundle split in v1
- keep one portable `values.yaml` in the bundle and pass the chosen
  product-facing profile at install time

## 3. Create A Release-Signing Key Pair

If you do not already have a release-signing key pair:

```bash
mkdir -p ./keys
openssl genpkey -algorithm Ed25519 -out ./keys/release-signing.key
openssl pkey -in ./keys/release-signing.key -pubout -out ./keys/release-signing.pub
```

## 4. Create The Bundle Assembly Config

Start from one of these examples:

- [examples/bundle-assembly.example.json](examples/bundle-assembly.example.json)
- [examples/bundle-assembly.simple-amd64.example.json](examples/bundle-assembly.simple-amd64.example.json)

For the simplified path:

```bash
cp docs/examples/bundle-assembly.simple-amd64.example.json /tmp/bundle-assembly.json
```

Then replace every placeholder path with your real local paths.

The required install components are:

- one `appliance` entry
- one `k3s-binary` entry
- at least one `k3s-images` entry
- at least one `oci-images` entry
- one `chart` entry
- one `configuration` entry for `values.yaml`

## 5. Assemble The Extracted Bundle

```bash
BUNDLE_CONFIG=/tmp/bundle-assembly.json make assemble-bundle
```

Or directly:

```bash
../appliance-ctl/bin/zonctl assemble-bundle --config /tmp/bundle-assembly.json
```

## 6. Verify The Bundle Before Transfer

```bash
BUNDLE_DIR=/absolute/path/to/out/appliance-2.4.0-foundation \
PUBLIC_KEY=./keys/release-signing.pub \
make verify-bundle
```

Or directly:

```bash
../appliance-ctl/bin/zonctl verify-bundle \
  --bundle-dir /absolute/path/to/out/appliance-2.4.0-foundation \
  --public-key ./keys/release-signing.pub
```

## 7. Transfer To The Target Host

Copy these to the target Ubuntu host:

- the extracted bundle directory
- `release-signing.pub`
- either the bundled `zonctl` binary or a separately copied `zonctl`

Example:

```bash
scp -r /absolute/path/to/out/appliance-2.4.0-foundation user@host:/tmp/
scp ./keys/release-signing.pub user@host:/tmp/
```

After transfer, use [operator-guide.md](operator-guide.md) for the target-host
install, upgrade, repair, uninstall, or reset steps.
