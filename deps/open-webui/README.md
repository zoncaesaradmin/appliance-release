# open-webui

Seeds the locked Open WebUI source tree (files API) plus the exact Dockerfile
base images used by `v0.11.4` / `USE_SLIM=true`:

- files: `build-deps/open-webui/<commit>/open-webui-source.tar.gz`
- OCI: `build-cache/open-webui-node:22-alpine3.20-${TARGET_ARCH}`
- OCI: `build-cache/open-webui-python:3.11-slim-bookworm-${TARGET_ARCH}`
- OCI: `build-cache/open-webui-uv:0.12.10-${TARGET_ARCH}`

Offline packaging remaps those OCI tags into the exporter; the product image
is still built from the patched source (never an unreviewed upstream WebUI
image).

```bash
TARGET_ARCH=amd64 make -C deps/open-webui release
TARGET_ARCH=arm64 make -C deps/open-webui release
```
