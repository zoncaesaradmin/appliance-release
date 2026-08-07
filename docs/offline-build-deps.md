# Offline build-host dependencies

`appliance-release/deps/` owns every third-party / pre-cooked input the **build
host** needs to assemble a complete appliance bundle without public internet.
Target install remains air-gapped as before.

Exactly **two** packaging modes — one flag for *all* third-party inputs:

| Mode | How | Third-party sources |
|---|---|---|
| **Online** | `build_flow.mode: online` / `OFFLINE_BUILD=0` | Public internet only (GHCR tooling + GitHub/Quay/Docker Hub/get.helm.sh). No LAN files API / build-cache. |
| **Offline** | `build_flow.mode: offline` / `OFFLINE_BUILD=1` | LAN Artifact Server only, after `make seed-build-deps`. Fail closed on miss. |

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
3. Remap `bundle_store` (also `DEV_*`) for `publish-release.sh`

After step 2, packaging code uses **only** `DEV_*` + `OFFLINE_BUILD`. It must
not branch on `ONLINE_*`.


**Operator shape:**

1. Optional once (offline prerequisite): `make seed-build-deps` → LAN
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
| `development-container` | `$DEV_REGISTRY/$DEV_IMAGE_REPO/dev-build:<tag>` | EXTRA_OCI `registry.local/dev-build` |
| `git-runtime-container` | `$DEV_REGISTRY/build-cache/alpine-git:2.49.0` | workspace-provisioner |
| `workflows` | `build-cache/argoexec` / `workflow-controller`; files `argo-workflows/…` | executor + CRDs |
| `artifact-server-bases` | `build-cache/zot-…`, `debian-bookworm-slim-runtime` | artifact-server wrap |
| `dns` | `build-cache/coredns:…` | dns wrap |
| `service-build-bases` | golang/node/alpine/ui-npm cache images | CP/UI/hostagent build-args |
| `host-packages` | files `host-packages/ubuntu-…` | host-packages unpack |
| `platform-inputs` | files `k3s/…`, `helm/…` | K3s + Helm |

Pins live in each package’s `pins.env`. Bump the pin, then `make -C deps/<name> release`.

## Commands

```bash
make seed-build-deps
make -C deps/platform-inputs release
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

### Egress-denied smoke (operator)

1. Seed with `make seed-build-deps` while online.
2. Deny public egress; keep LAN registry reachable.
3. `OFFLINE_BUILD=1` with unified `DEV_*=LAN` → `bash scripts/build-full-bundle.sh` (synced trees).
4. Confirm signed bundle assembles.

## Updating UI npm deps

When `appliance-code/services/controlplane-ui/package-lock.json` changes, copy
`package.json` and `package-lock.json` into
`deps/service-build-bases/ui-npm/` and run:

```bash
make -C deps/service-build-bases release
```

## `fetch-k3s-inputs.sh`

Legacy entrypoint; forwards to `deps/platform-inputs`. Prefer `make -C deps/platform-inputs release`.
