# artifact-server-bases

- `$DEV_REGISTRY/build-cache/zot-linux-${TARGET_ARCH}:v2.1.8` (`amd64` or `arm64`)
- `$DEV_REGISTRY/build-cache/debian-bookworm-slim-runtime:bookworm-slim` (bash + ca-certificates preinstalled)

Used by `export-artifact-server-image-archive.sh`. Seed with
`TARGET_ARCH=amd64|arm64 make -C deps/artifact-server-bases release`.
