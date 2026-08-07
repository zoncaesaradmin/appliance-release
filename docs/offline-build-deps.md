# Offline build-host dependencies

`appliance-release/deps/` owns every third-party / pre-cooked input the **build
host** needs to assemble a complete appliance bundle without public internet.
Target install remains air-gapped as before.

Online seed machine → `make seed-build-deps` (or `make -C deps/<name> release`)
→ LAN Artifact Server (`DEV_REGISTRY` OCI + files API) →
`OFFLINE_BUILD=1` `scripts/build-full-bundle.sh`.

Product source (`appliance-code`, `appliance-ctl`) is **not** seeded here. Use
the release skill workspace sync onto the build host for offline source trees
(`OFFLINE_BUILD=1` / `USE_LOCAL_CHECKOUTS=1`).

## Auth

Same variables as the development-container / packaging flow:

| Variable | Role |
|---|---|
| `DEV_REGISTRY` | Artifact host FQDN |
| `DEV_REGISTRY_USER` | OCI login user |
| `DEV_REGISTRY_TOKEN` | Bearer / registry token (`artifacts.read` + `artifacts.write` for files) |
| `DEV_REGISTRY_TLS_VERIFY` | `false` for LAN until CA is trusted |
| `DEV_IMAGE_REPO` | Namespace for named images (`development-container`) |

## Package → LAN path → consumer

| Package | LAN artifact | Consumed by |
|---|---|---|
| `development-container` | `$DEV_REGISTRY/$DEV_IMAGE_REPO/dev-build:<tag>` | `make dev-run`, EXTRA_OCI `registry.local/dev-build` |
| `git-runtime-container` | `$DEV_REGISTRY/build-cache/alpine-git:2.49.0` | `build-full-bundle` → `registry.local/workspace-provisioner` |
| `workflows` | `build-cache/argoexec:v3.5.10`, `build-cache/workflow-controller:v3.5.10`; files `argo-workflows/v3.5.10/namespace-install.yaml` | executor export, workflow-controller export, CRD fetch |
| `artifact-server-bases` | `build-cache/zot-linux-amd64:v2.1.8`, `build-cache/debian-bookworm-slim-runtime:bookworm-slim` | `export-artifact-server-image-archive.sh` |
| `dns` | `build-cache/coredns:v1.14.4` | `export-dns-server-image-archive.sh` |
| `service-build-bases` | `build-cache/golang:1.26`, `node:22-alpine`, `alpine-3.24.1-runtime:3.24.1`, `controlplane-ui-web-deps:lockfile` | CP/UI/hostagent Containerfile build-args |
| `host-packages` | files `host-packages/ubuntu-24.04/<fingerprint>/host-packages.tar.zst` | host-packages offline unpack in `build-full-bundle` |
| `platform-inputs` | files `k3s/$VER/…`, `helm/$VER/…` | K3s fetch in `build-full-bundle`, Helm in `assemble-product-bundle` |

Pins live in each package’s `pins.env`. Bump the pin, then `make -C deps/<name> release`.

## Commands

```bash
# Everything
make seed-build-deps

# One package
make -C deps/platform-inputs release

# List
make list-deps
```

## OFFLINE_BUILD contract

When packaging with `OFFLINE_BUILD=1`:

1. OCI pulls must hit `$DEV_REGISTRY/build-cache/…` (or named `dev-build`) — no upstream fallback.
2. Helm, Argo CRDs, K3s, and host-packages come from the files API only.
3. Public registries, `get.helm.sh`, GitHub releases, npmjs, and public apt/apk are not contacted.
4. Product git remotes are not required if the release skill has already synced local trees.

### Egress-denied smoke (operator)

1. Seed with `make seed-build-deps` while online.
2. On the build host, deny public egress while keeping `DEV_REGISTRY` reachable.
3. Run `OFFLINE_BUILD=1` `bash scripts/build-full-bundle.sh` (with synced appliance-code/ctl trees).
4. Confirm the signed bundle assembles and `validate-release-artifacts.py` passes.

## Updating UI npm deps

When `appliance-code/services/controlplane-ui/package-lock.json` changes, copy
`package.json` and `package-lock.json` into
`deps/service-build-bases/ui-npm/` and run:

```bash
make -C deps/service-build-bases release
```

## `fetch-k3s-inputs.sh`

Legacy entrypoint; forwards to `deps/platform-inputs`. Prefer `make -C deps/platform-inputs release`.
