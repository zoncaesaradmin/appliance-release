# open-webui

Seeds the locked Open WebUI source tree (files API) plus the exact Dockerfile
base images used by `v0.11.4` / `USE_SLIM=true`. Each `TARGET_ARCH=… make release`
publishes one architecture's OCI tags (seed both when packaging cross-arch):

- files: `build-deps/open-webui/<commit>/open-webui-source.tar.gz`
- OCI: `build-cache/open-webui-node:22-alpine3.20-${TARGET_ARCH}` (frontend/BUILDPLATFORM when that arch is the build host)
- OCI: `build-cache/open-webui-python:3.11-slim-bookworm-${TARGET_ARCH}` (runtime)
- OCI: `build-cache/open-webui-uv:0.12.10-${TARGET_ARCH}` (runtime)

Offline packaging remaps those OCI tags into the exporter; the product image
is still built from the patched source (never an unreviewed upstream WebUI
image).

Cross-arch freezes (e.g. amd64 build host, `TARGET_ARCH=arm64`) always use the
same packaging path: Node frontend on `HOST_ARCH`, Python runtime on
`TARGET_ARCH`, frontend artifacts copied via a directory `--build-context`
(not `COPY --from=<image>`). Seed **both** arches:

```bash
TARGET_ARCH=amd64 make -C deps/open-webui release
TARGET_ARCH=arm64 make -C deps/open-webui release
```
