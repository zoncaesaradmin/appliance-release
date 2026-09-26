# Offline build-host dependencies

`appliance-release/deps/` owns every third-party / pre-cooked input the **build
host** needs to assemble a complete appliance bundle without public internet.
Target install remains air-gapped as before.

Exactly **two** packaging modes — one flag for *all* third-party inputs:

| Mode | How | Third-party sources |
|---|---|---|
| **Online** | `build_flow.mode: online` / `OFFLINE_BUILD=0` | Public internet only (GHCR tooling + GitHub/Quay/Docker Hub/get.helm.sh). No LAN files API / build-cache. |
| **Offline** | `build_flow.mode: offline` / `OFFLINE_BUILD=1` | LAN Artifact Server only, after `TARGET_ARCH=amd64 make seed-build-deps`. Fail closed on miss. |

Online packaging acquires CoreDNS from the official CoreDNS Docker Hub
repository before the expensive product-image builds. Only CoreDNS acquisition
is retried; a public-registry failure does not replay the complete no-cache
development-container build. Offline packaging uses the same ordered packaging
path with one fail-closed LAN attempt against `build-cache/coredns`. The early
step also preloads the wrapper's Alpine runtime because the wrapper is built
with `--pull-never`; it does not depend on a previous service build having
incidentally populated shared container storage.

## Unification model

Only two input families:

| Family | Role |
|---|---|
| `ONLINE_*` | Public/GHCR tooling when `mode: online` |
| `DEV_*` | LAN Artifact Server — offline tooling, publish, install download, seed |

No separate `OFFLINE_*` set: offline packaging and LAN are the same values.

The release skill does **one** early mapping:

1. Read `online_image_pull` or `offline_image_pull` based on `build_flow.mode`
2. Copy that set into **`DEV_*`** for bootstrap + `build-full-bundle.sh`
   (offline already references `DEV_*`; online copies `ONLINE_*` → `DEV_*`)
3. Resolve `bundle_store` for `publish-release.sh`: normally
   `appliance_files` (also `DEV_*`), or temporary `static_http` for the first
   appliance before its files API exists

After step 2, packaging code uses **only** `DEV_*` + `OFFLINE_BUILD`. It must
not branch on `ONLINE_*`.


**Operator shape:**

1. Optional once (offline prerequisite): `TARGET_ARCH=amd64 make seed-build-deps` → LAN
2. Bundle: online **or** offline — never a mix of LAN cache probes + public fallbacks

Product source (`appliance-code`, `appliance-ctl`) is **not** seeded here. Use
the release skill workspace sync onto the build host for offline source trees
(`OFFLINE_BUILD=1` / `USE_LOCAL_CHECKOUTS=1`).

## Auth

### Unified packaging (`DEV_*` after mapping)

| Variable | Role |
|---|---|
| `DEV_REGISTRY` | Active tooling registry host for this run |
| `DEV_IMAGE_REPO` / `DEV_IMAGE_NAME` / `DEV_IMAGE_TAG` | Tooling image path |
| `DEV_REGISTRY_USER` / `DEV_REGISTRY_TOKEN` | Login for that registry |
| `DEV_REGISTRY_TLS_VERIFY` | TLS verify for that registry |
| `OFFLINE_BUILD` | `0` online third-party policy / `1` LAN-only policy |

### Input examples (before skill mapping)

Online machine env exports `ONLINE_*` (GHCR) plus LAN `DEV_*` for publish.
Offline uses only `DEV_*` (same vars for tooling pull and publish).

Host tooling: **podman** is required on PATH. No skopeo/buildah fallback paths.

## Package → LAN path → consumer (offline)

| Package | LAN artifact | Consumed by |
|---|---|---|
| `development-container` | `$DEV_REGISTRY/$DEV_IMAGE_REPO/dev-build:<tag>` | **Build-host tooling only** (online GHCR + offline LAN); also `appliance-code` local service builds. Not packaged into appliance packs. |
| `git-runtime-container` | `build-cache/alpine-git:2.49.0-${TARGET_ARCH}` | workspace-provisioner (dev-platform pack) |
| `workflows` | `build-cache/argoexec:v…-${TARGET_ARCH}` / `workflow-controller:v…-${TARGET_ARCH}`; files `argo-workflows/…` | executor + CRDs |
| `message-broker` | `build-cache/nats:2.10.26-alpine-${TARGET_ARCH}` | NATS JetStream broker image |
| `artifact-server-bases` | `build-cache/zot-linux-${TARGET_ARCH}:…`, `debian-bookworm-slim-runtime:bookworm-slim-${TARGET_ARCH}` | artifact-server wrap |
| `dns` | `build-cache/coredns:v1.14.4-${TARGET_ARCH}` | dns wrap |
| `inference` | `build-cache/ollama:…-${TARGET_ARCH}` plus arch-specific vLLM (`vllm-openai-cpu:…-x86_64` / `vllm-openai:…-arm64`) | `std-llm` / `acc-llm` |
| `open-webui` | files API `build-deps/open-webui/<locked-commit>/open-webui-source.tar.gz`; OCI `build-cache/open-webui-node:22-alpine3.20-${HOST_ARCH}` (frontend/BUILDPLATFORM), `build-cache/open-webui-python:3.11-slim-bookworm-${TARGET_ARCH}`, and `build-cache/open-webui-uv:0.12.10-${TARGET_ARCH}` | Verified upstream source + Dockerfile bases for the patched optional Web UI in `std-llm` / `acc-llm`; never foundation. Cross-arch freezes require both arch seeds. |
| `blob-storage` | `build-cache/minio:…-${TARGET_ARCH}` built from the pinned GitHub MinIO binary | foundation blob-storage wrap |
| `jellyfin` | `build-cache/jellyfin:10.10.7-amd64` | reviewed Jellyfin runtime (**amd64 only**; skipped when `TARGET_ARCH=arm64`) |
| `service-build-bases` | `golang`/`node`/`alpine-3.24.1-runtime`/`controlplane-ui-web-deps` with `-${TARGET_ARCH}` (or host-arch for compile) | CP/UI/hostagent |
| `host-packages` | files `host-packages/ubuntu-…/${TARGET_ARCH}/…` | host-packages unpack |
| `platform-inputs` | files `k3s/${TARGET_ARCH}/…`, `helm/…-linux-${TARGET_ARCH}` | K3s + Helm |

### Arch-scoped OCI build-cache tags (mandatory)

Every arch-specific OCI image seeded into `$DEV_REGISTRY/build-cache/` must
encode the architecture in the **tag** (or in the image name, as with
`zot-linux-${TARGET_ARCH}`). Shared tags across amd64/arm64 are forbidden —
the last seed wins and offline packaging pulls the wrong arch.

Contract test: `python3 scripts/test-arch-scoped-build-cache-tags.py` (run by
`make verify`). Re-seed **both** arches after changing these pins:

```bash
TARGET_ARCH=amd64 make seed-build-deps
TARGET_ARCH=arm64 make seed-build-deps
```

### Product architecture (`TARGET_ARCH`)

`TARGET_ARCH` is required everywhere (amd64|arm64). There is no default — empty
or omitted values fail closed. Seed and build for the arch you need:

```bash
TARGET_ARCH=amd64 make seed-build-deps
TARGET_ARCH=arm64 make seed-build-deps
# or minimally for one package:
TARGET_ARCH=arm64 make -C deps/artifact-server-bases release
TARGET_ARCH=arm64 make -C deps/platform-inputs release
```

`build_flow.target_arch` is likewise required in the build-publish config.

Containerfile seeds that run `apt`/`apk` (`artifact-server-bases`,
`service-build-bases`):

- **Same-arch host** (e.g. arm64 seed on arm64): run inside
  `dev-build:latest-${TARGET_ARCH}` via `scripts/run-in-dev-build.sh`.
- **Cross-arch host** (e.g. arm64 seed on amd64): run on the **host** with
  `podman build --arch` + qemu/binfmt. Nested podman inside a qemu-emulated
  tooling container fails (`Error during reexec(...): No such file or directory`).

Full-bundle packaging (`build-full-bundle` → `make DEV_RUN`) follows the same
rule: the outer tooling container is always **host-native**. Product
`TARGET_ARCH` is forwarded for `GOARCH` / `buildah --arch` / skopeo overrides.
Running nested Buildah under qemu-foreign tooling fails with
`unshare(CLONE_NEWUSER): Invalid argument`.

Service image Containerfiles compile on `$BUILDPLATFORM` (host golang/node)
and only the final runtime stage uses the product arch. Offline remap pulls
`golang`/`node`/`ui-deps` for **host** arch and `alpine-*-runtime` for
**TARGET_ARCH**. Cross-arch therefore needs both seeds:

```bash
TARGET_ARCH=amd64 make -C deps/service-build-bases release
TARGET_ARCH=arm64 make -C deps/service-build-bases release
```

Bootstrap the tooling image first (host build of `deps/development-container`).

Cross-arch on an amd64 host (product `TARGET_ARCH=arm64`):

```bash
# One-time: qemu/binfmt for host podman build --arch arm64 (tooling + RUN-heavy seeds)
sudo apt-get install -y qemu-user-static binfmt-support
sudo systemctl restart systemd-binfmt || true
test -e /proc/sys/fs/binfmt_misc/qemu-aarch64 && grep enabled /proc/sys/fs/binfmt_misc/qemu-aarch64
TARGET_ARCH=arm64 make -C deps/development-container release
TARGET_ARCH=arm64 make seed-build-deps
```

Or seed on a matching-arch host (RUN-heavy deps then use in-tooling). Without
binfmt, cross-arch host builds fail closed via `deps_require_build_arch_runnable`.

### Special case: `development-container` / `dev-build` (LAN + GHCR)

Unlike most `deps/*` packages (LAN seed is enough for offline packaging, while
online pulls public upstream), `dev-build` is also the shared tooling image for
**local** `appliance-code` builds (`make dev-shell`, control-plane / UI /
host-agent images) and for seed packages that `RUN` apt/apk. Publish **per
`TARGET_ARCH`** as `…/dev-build:<version>-<arch>` and `…:latest-<arch>`.

So after changing `deps/development-container`:

1. Publish to **LAN** via `TARGET_ARCH=amd64 make seed-build-deps` (or
   `TARGET_ARCH=amd64 make -C deps/development-container release` with LAN `DEV_*`).
   Repeat with `TARGET_ARCH=arm64` when you need arm64 tooling.
2. Separately publish the **same arch** image(s) to **GHCR** (manual — seed does
   not do this). See [`deps/development-container/PACKAGE.md`](../deps/development-container/PACKAGE.md).

Skipping GHCR leaves online packaging and day-2 local builds on a stale image.

## Adding a new packaging dependency

Whenever packaging gains a new third-party image or file input:

1. Add `deps/<name>/` (`pins.env`, `scripts/build.sh`, `scripts/push.sh`, Makefile, README).
2. Remap the input in the offline branch of `scripts/build-full-bundle.sh` (or the shared consumer) via `lan_cache_ref` / files API.
3. Keep online packaging on the same pinned public upstream.
4. Document the row in this table and mention the seed in example configs / AGENTS.md invariants.

`TARGET_ARCH=amd64 make seed-build-deps` auto-discovers every `deps/*` directory (`TARGET_ARCH` required). A new package that is only wired for online pulls is incomplete.

## Commands

```bash
TARGET_ARCH=amd64 make seed-build-deps
TARGET_ARCH=amd64 make -C deps/platform-inputs release
make list-deps
```

## Contracts

### Online (`OFFLINE_BUILD=0`)

1. Tooling image from unified `DEV_*` (skill mapped from `ONLINE_*`).
2. K3s from GitHub releases; Helm from `get.helm.sh`; Argo CRDs from GitHub.
3. No LAN build-cache probe, no files API packaging pulls.

### Offline (`OFFLINE_BUILD=1`)

1. Tooling image + OCI build-cache + files API from unified `DEV_*` (LAN) only.
2. Misses fail closed; no public upstream fallback.

## Third-party freeze (product vs upstream)

Seed populates the LAN Artifact Server. That alone is **not** enough for a fast
product rebuild: packaging still turns LAN/upstream images into the **final**
release-input OCI archives (`registry.local/<name>:bundled` tar + `.reference`)
and host-packages trees. Those steps (skopeo/buildah, often multi-GB) are what
freeze is for.

| Layer | What | Command |
|---|---|---|
| Seed | Upstream → LAN build-cache / files API | `TARGET_ARCH=… make seed-build-deps` |
| Freeze | LAN/online → **final** packaging archives under freeze root | `TARGET_ARCH=… make freeze-third-party` |
| Product | Rebuild only product images (CP/UI/host-agent/manager/…); **restore** third-party finals | `build-full-bundle` / release skill with `mode: auto\|require` |

**Design rule:** freeze does the expensive third-party work once (infrequent).
A later product build with freeze `auto`/`require` must restore those finals and
**skip** re-export. If a product build still runs skopeo/buildah for a frozen
artifact, that is a bug (store without restore, or fingerprint mismatch).

**Open WebUI specifically:** `deps/open-webui` seed is only the locked source
tarball plus node/python/uv *base* images. It does **not** include the Node
frontend build or `uv pip install` of requirements-slim (~170 packages). That
work happens when packaging `registry.local/open-webui`. Product builds with
`third_party_freeze.mode` left at the default `ignore` always redo it, even if
`make freeze-third-party` already stored an archive under
`/var/cache/zon-third-party`. Enable `mode: auto` (or `require`) + `root` in
the build-publish config so normal releases restore the frozen OCI instead.

### Local assemble I/O (avoid double-packing)

Freeze restore and product export write OCI archives under `appliance-code/.run/`.
`archive-release-input` **hardlinks** those into a durable
`.run/release-input-<version>/` directory. `build-full-bundle` then:

1. Passes `--skip-tarball` by default so it does **not** gzip that tree into a
   multi-GB `release-input-*.tar.gz` (set `ARCHIVE_RELEASE_INPUT_WRITE_TARBALL=1`
   only when a remote/fetchable intermediate is required).
2. Assembles packs from the directory; `zonctl`/`releasebundle.Assemble`
   hardlinks OCI files into pack trees (same filesystem).
3. Creates delivery pack `.tar.gz` once via `create_gzip_tarball` (`PACK_GZIP_LEVEL`
   defaults to `1` for speed on LAN publish; raise to `6` for smaller archives).

Hardlink chain on one filesystem: freeze → `.run/*.tar` → release-input dir →
pack dir → one gzip for customer delivery. Do not re-tar the vLLM/inference
OCI into an intermediate release-input tarball when assembling locally.

Freeze layout: `$THIRD_PARTY_FREEZE_ROOT/$TARGET_ARCH/artifacts/<id>/<fingerprint>/`
plus `manifest.yaml`. Fingerprints include upstream pull refs + arch (+ version).

Build-publish config (`build_flow.third_party_freeze`):

```yaml
third_party_freeze:
  mode: auto          # ignore | auto | require
  root: /var/cache/zon-third-party
```

- `ignore` (default): freeze unused
- `auto`: restore on hit; package + store on miss
- `require`: restore on hit; fail closed on miss (run `make freeze-third-party`)

Frozen today (final `.run/` archives / trees): inference-runtime, dns-server,
workspace-provisioner / jellyfin / workflow-executor (bundled/plain OCI helpers),
workflow-controller wrap, host-packages, blob-storage, message-broker.
On a fingerprint hit, packaging restores into `.run/` and **skips** the
skopeo/buildah export for that artifact.
Product-owned images (artifact-server, inference-manager, control-plane, UI,
host-agent) stay out of the freeze and always rebuild.

After a freeze restore, packaging always rewrites `<archive>.reference` from the
archive `index.json` digest so a stale sidecar cannot disagree with the tar
(`archive-release-input` fail-closes on mismatch).

### Egress-denied smoke (operator)

1. Seed with `TARGET_ARCH=amd64 make seed-build-deps` while online.
2. Deny public egress; keep LAN registry reachable.
3. `OFFLINE_BUILD=1` with unified `DEV_*=LAN` → `bash scripts/build-full-bundle.sh` (synced trees).
4. Confirm signed bundle assembles.

## Updating UI npm deps

When `appliance-code/services/controlplane-ui/package-lock.json` changes, copy
`package.json` and `package-lock.json` into
`deps/service-build-bases/ui-npm/` and run:

```bash
TARGET_ARCH=amd64 make -C deps/service-build-bases release
```

## `fetch-k3s-inputs.sh`

Legacy entrypoint; forwards to `deps/platform-inputs`. Prefer `make -C deps/platform-inputs release`.
