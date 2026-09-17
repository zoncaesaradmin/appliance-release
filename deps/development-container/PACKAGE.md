# development-container

Canonical sources for the appliance shared tooling image `dev-build`
(vendored into `appliance-release/deps/`; there is no separate git repo required).

**One recipe, one published arch per build.** `TARGET_ARCH` is required
(`amd64|arm64`). Published tags are arch-suffixed:

`$DEV_REGISTRY/$DEV_IMAGE_REPO/dev-build:$(VERSION)-$(TARGET_ARCH)`
and `:latest-$(TARGET_ARCH)`

Examples: `…/dev-build:v0.1.0-arm64`, `…/dev-build:latest-amd64`.

## Dual publish is mandatory (LAN + GHCR)

`dev-build` is used in **more than** full-bundle packaging:

| Consumer | Typical pull source |
|---|---|
| Offline `build-full-bundle` / `TARGET_ARCH=… make seed-build-deps` | LAN Artifact Server (`latest-${TARGET_ARCH}`) |
| Online `build-full-bundle` (`ONLINE_*` → unified `DEV_*`) | GHCR (`latest-${TARGET_ARCH}`) |
| Local / day-2 image builds in `appliance-code` (`make dev-shell`, control-plane image, …) | GHCR by default (`latest-<host-or-TARGET_ARCH>`) |

`TARGET_ARCH=… make seed-build-deps` only publishes to the **LAN** registry configured in
`DEV_*`. That is **not** enough. After changing this package (Containerfiles,
pins, toolchain versions), also publish the **same arch** to **GHCR** so online
and local service builds keep working.

Do not treat LAN seed alone as “dev-build is updated.”

### 1) LAN (offline seed / Artifact Server)

```bash
# usually covered by: TARGET_ARCH=amd64 make seed-build-deps
# or explicitly:
cd deps/development-container
export DEV_REGISTRY=<lan-artifact-host>
export DEV_IMAGE_REPO=development-container
export DEV_IMAGE_NAME=dev-build
export DEV_REGISTRY_USER=...
export DEV_REGISTRY_TOKEN=...
export DEV_REGISTRY_TLS_VERIFY=false
TARGET_ARCH=amd64 make VERSION=<tag> release
# First arm64 tooling image on an amd64 host (one-time qemu/binfmt):
#   sudo apt-get install -y qemu-user-static binfmt-support
#   sudo systemctl restart systemd-binfmt || true
#   test -e /proc/sys/fs/binfmt_misc/qemu-aarch64 && grep enabled /proc/sys/fs/binfmt_misc/qemu-aarch64
TARGET_ARCH=arm64 make VERSION=<tag> release
```

Without binfmt, `podman build --arch arm64` fails at the first `RUN` with
`Exec format error`. The Makefile fails closed via `deps_require_build_arch_runnable`
before that opaque error.


Example: `artifact-dns-1.appliance.internal/development-container/dev-build:latest-amd64`

### 2) GHCR (online bundle + local service builds) — manual

```bash
cd deps/development-container
export DEV_REGISTRY=ghcr.io
export DEV_REGISTRY_USER=<github-username>   # e.g. zoncaesaradmin
export DEV_IMAGE_REPO=$DEV_REGISTRY_USER/development-container
export DEV_IMAGE_NAME=dev-build
export DEV_REGISTRY_TOKEN=<PAT with write:packages>
export DEV_REGISTRY_TLS_VERIFY=true
TARGET_ARCH=amd64 make VERSION=<tag> release
TARGET_ARCH=arm64 make VERSION=<tag> release
```

Example: `ghcr.io/zoncaesaradmin/development-container/dev-build:v0.1.0-amd64`
(and `:latest-amd64`)

Auth details: [docs/PUBLISHING_AUTH.md](docs/PUBLISHING_AUTH.md).

## Commands

```bash
TARGET_ARCH=amd64 make build      # alias for build-dev
TARGET_ARCH=amd64 make test
TARGET_ARCH=amd64 make publish    # login + push-dev (uses current DEV_*)
TARGET_ARCH=amd64 make release    # build-dev + publish
```

Pins: [pins.env](pins.env). Full docs: [README.md](README.md) in this directory.
Also see AGENTS.md (“Shared `dev-build` tooling image”) and
[docs/offline-build-deps.md](../../docs/offline-build-deps.md).
