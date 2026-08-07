# Automation Base Image Project

This repository now has two layers of content:

1. A local copy of the `devcontainers/images` implementation under the existing upstream-style layout (`build/`, `src/`, and related files) so we can keep their structure and ideas close at hand.
2. A simpler top-level image build path for our own automation-focused developer images built around open-source OCI tooling.

The copied upstream tree is preserved intentionally. The top-level `Containerfile.*`, `scripts/`, and `Makefile` files are the primary implementation for this project.

## Current focus

The combined development image is intentionally limited to:

- Go
- Python
- Node.js and npm for React/TypeScript UI builds
- OCI container tooling (`podman`, `buildah`, `skopeo`)
- Common developer and native build utilities needed for Git workflows and CGO-enabled builds

This keeps the dev image smaller and easier to maintain while still covering current usage.

## Tooling requirements (who needs what)

- **Build machine** (builds these `Containerfile.*` into images): needs **Buildah** only. Podman is not required to build.
- **Run machine** (runs the resulting `dev-build` container, e.g. via `make shell-dev` / `make test-dev`): needs **Podman**.
- **Skopeo** ships inside the built image itself, for developers to use from within their devcontainer. It is not a host/build-machine dependency.

These can be the same machine or different ones — the point is the build step itself only depends on Buildah.

## Current image set

- `Containerfile.base`
  Installs the shared base toolchain: Git, shell utilities, native build dependencies, and `podman` / `buildah` / `skopeo`.
- `Containerfile.go`
  Builds on `automation-base` and adds the Go toolchain.
- `Containerfile.python`
  Builds on `automation-base` and adds Python and common Python packaging tools.
- `Containerfile.dev`
  Builds a self-contained combined dev image for Go + Python + Node.js work so the dev container can build directly without relying on locally pre-built intermediate images.

## Build strategy

The default build path uses fully open-source OCI tooling, split by responsibility:

- **`buildah bud`** — builds the images (default `BUILD` command in the `Makefile`). This is the only tool required on a machine that just needs to *build* these images, e.g. a CI/build server. Podman is not required there.
- **`podman run`** — runs/tests a built image (default `RUN` command, used by `test-dev` and `shell-dev`). This is only needed on a machine that needs to *run* the resulting container.
- **`skopeo`** — bundled inside the built images (via `scripts/install-common.sh`) so developers can inspect/copy images from within their devcontainer. It is not required on the build machine itself.

If you prefer Podman for builds instead, override `BUILD`: `make BUILD="podman build" build-all`.

## Quick start

Build the full stack with the default Buildah flow (only `buildah` is required on the build machine):

```bash
make build-all
```

Build only the combined dev image:

```bash
make build-dev
```

Switch to `podman build` without changing files:

```bash
make BUILD="podman build" build-all
```

Open a shell in the combined dev image:

```bash
make shell-dev
```

Verify the core toolchain versions inside the combined image:

```bash
make test-dev
```

Remove local cache and log files that are not useful to keep in Git:

```bash
make clean
```

## Image tags

By default, images are tagged locally as:

- `localhost/automation-base:latest`
- `localhost/automation-go:latest`
- `localhost/automation-python:latest`
- `localhost/dev-build:latest`

You can override the tag:

```bash
make TAG=dev build-all
```

## Build and publish (two complete ways)

Build locally, then publish with the same targets every time: `login`, `publish`, or `release` (build + publish). Destination is only env values.

**Important — dual publish:** this image is not only a full-bundle packaging
input. `appliance-code` also pulls it for local / day-2 builds (`make
dev-shell`, control-plane image, control-plane UI image, and related service
images). `make seed-build-deps` updates the **LAN Artifact Server only**.
Whenever you rebuild `dev-build`, publish to **both**:

1. **LAN** (offline packaging / seed) — covered by `make seed-build-deps` or Way 2 below.
2. **GHCR** (online packaging + local service builds) — Way 1 below; this is a **manual** second publish.

Shipping only the LAN copy leaves online/`make dev-shell` on a stale GHCR tag.
See [PACKAGE.md](PACKAGE.md) for the short operator checklist.

| Variable | Role |
| --- | --- |
| `DEV_REGISTRY` | Registry host (`ghcr.io` or LAN OCI FQDN) |
| `DEV_IMAGE_REPO` | Repository path after host (include owner/namespace when needed) |
| `DEV_REGISTRY_USER` | Login username |
| `DEV_REGISTRY_TOKEN` | Auth token (env only; never commit) |
| `DEV_REGISTRY_TLS_VERIFY` | `true` (default) or `false` to pass `--tls-verify=false` on login/push |

The combined image also accepts `NODE_VERSION` at build time. It defaults to
Node.js `22.19.0`, which satisfies the Vite 8 engine requirement used by the
appliance control-plane UI.

Path: `$(DEV_REGISTRY)/$(DEV_IMAGE_REPO)/$(DEV_IMAGE_NAME)`

Set `VERSION` explicitly for real releases (also pushes `:latest`). After publish, set appliance-release online tooling (`ONLINE_*` / `online_image_pull`) and any local `appliance-code` `DEV_*` defaults to this same image reference.

### Way 1 — GHCR (required for online + local service builds)

```bash
export DEV_REGISTRY=ghcr.io
export DEV_REGISTRY_USER=<github-username>
export DEV_IMAGE_REPO=$DEV_REGISTRY_USER/development-container
export DEV_REGISTRY_TOKEN=<PAT with write:packages>

make build-dev
make test-dev
make login
make VERSION=v0.1.0 publish
```

Or: `make VERSION=v0.1.0 release`

→ `ghcr.io/<github-username>/development-container/dev-build:v0.1.0`

Auth details: [docs/PUBLISHING_AUTH.md](docs/PUBLISHING_AUTH.md).

### Way 2 — LAN OCI registry (required for offline seed / packaging)

Until the appliance CA is trusted on the build host, skip TLS verify:

```bash
export DEV_REGISTRY=artifact-dns-1.appliance.internal
export DEV_REGISTRY_USER=<lan-user>
export DEV_IMAGE_REPO=development-container
export DEV_REGISTRY_TOKEN=<lan-token>
export DEV_REGISTRY_TLS_VERIFY=false

make build-dev
make test-dev
make login
make VERSION=v0.1.0 publish
```

Or: `make DEV_REGISTRY_TLS_VERIFY=false VERSION=v0.1.0 release`

→ `artifact-dns-1.appliance.internal/development-container/dev-build:v0.1.0`

`make seed-build-deps` from the repo root runs this LAN publish as part of seeding every `deps/*` package. It does **not** push GHCR — run Way 1 after (or before) when the image content changed.

## Dev container config

A ready-to-use dev container definition for the combined image lives at:

- `.devcontainer/devcontainer.json`

An additional copy also exists at `.devcontainer/automation-base/devcontainer.json`.

Both are configured for nested OCI image builds with the combined Go + Python toolchain.

## Keeping the image lean

The combined dev image intentionally does not include extra language runtimes such as Java, Rust, Ruby, or .NET yet. Node.js is included because the appliance control-plane UI is now built from React and TypeScript sources. The shared base still keeps the common developer packages and C/C++ build toolchain needed by many Go and Python projects, including CGO-backed builds.

## Adding another language later

To add another language stack later, follow the same pattern:

1. Add a new installer script under `scripts/`, for example `scripts/install-rust.sh`.
2. Add a dedicated image definition, for example `Containerfile.rust`, that starts from `Containerfile.base`.
3. If the combined dev image should include that language too, add the installer to `Containerfile.dev`.
4. Add matching `make` targets in `Makefile`.

The safest places to extend are:

- shared packages: `scripts/install-common.sh`
- Go toolchain: `scripts/install-go.sh`
- Python toolchain: `scripts/install-python.sh`
- Node.js toolchain: `scripts/install-node.sh`
- combined dev image contents: `Containerfile.dev`
- build commands and tags: `Makefile`

## Notes

- The container storage driver is set to `vfs` by default for better compatibility when building images inside another container.
- The upstream copied tree is left in place on purpose so we can keep borrowing patterns for future language images without having to re-clone or re-study it.
- No upstream files were removed as part of this bootstrap. New project-specific files live alongside the copied implementation.
