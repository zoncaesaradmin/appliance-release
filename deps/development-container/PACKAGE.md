# development-container

Canonical sources for the appliance shared tooling image `dev-build`
(vendored into `appliance-release/deps/`; there is no separate git repo required).

Publish path:

`$DEV_REGISTRY/$DEV_IMAGE_REPO/dev-build:$(VERSION)` and `:latest`

## Dual publish is mandatory (LAN + GHCR)

`dev-build` is used in **more than** full-bundle packaging:

| Consumer | Typical pull source |
|---|---|
| Offline `build-full-bundle` / `make seed-build-deps` | LAN Artifact Server |
| Online `build-full-bundle` (`ONLINE_*` → unified `DEV_*`) | GHCR |
| Local / day-2 image builds in `appliance-code` (`make dev-shell`, control-plane image, control-plane UI image, host-agent image, …) | GHCR by default |

`make seed-build-deps` only publishes to the **LAN** registry configured in
`DEV_*`. That is **not** enough. After changing this package (Containerfiles,
pins, toolchain versions), also publish the same image to **GHCR** so online
and local service builds keep working.

Do not treat LAN seed alone as “dev-build is updated.”

### 1) LAN (offline seed / Artifact Server)

```bash
# usually covered by: make seed-build-deps
# or explicitly:
cd deps/development-container
export DEV_REGISTRY=<lan-artifact-host>
export DEV_IMAGE_REPO=development-container
export DEV_IMAGE_NAME=dev-build
export DEV_REGISTRY_USER=...
export DEV_REGISTRY_TOKEN=...
export DEV_REGISTRY_TLS_VERIFY=false
make VERSION=<tag> release
```

Example: `artifact-dns-1.appliance.internal/development-container/dev-build:latest`

### 2) GHCR (online bundle + local service builds) — manual

```bash
cd deps/development-container
export DEV_REGISTRY=ghcr.io
export DEV_REGISTRY_USER=<github-username>   # e.g. zoncaesaradmin
export DEV_IMAGE_REPO=$DEV_REGISTRY_USER/development-container
export DEV_IMAGE_NAME=dev-build
export DEV_REGISTRY_TOKEN=<PAT with write:packages>
export DEV_REGISTRY_TLS_VERIFY=true
make VERSION=<tag> release
```

Example: `ghcr.io/zoncaesaradmin/development-container/dev-build:v0.1.0`
(and `:latest`)

Auth details: [docs/PUBLISHING_AUTH.md](docs/PUBLISHING_AUTH.md).

## Commands

```bash
make build      # alias for build-dev
make test
make publish    # login + push-dev (uses current DEV_*)
make release    # build-dev + publish
```

Pins: [pins.env](pins.env). Full docs: [README.md](README.md) in this directory.
Also see AGENTS.md (“Shared `dev-build` tooling image”) and
[docs/offline-build-deps.md](../../docs/offline-build-deps.md).
