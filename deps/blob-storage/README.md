# blob-storage

Mirrors the pinned S3-compatible MinIO runtime into
`$DEV_REGISTRY/build-cache/minio:RELEASE.2025-05-24T17-08-30Z` for the
foundation blob-storage image export and offline `build-full-bundle`.

Online packaging pulls the exact `UPSTREAM_IMAGE` in `pins.env`. Offline
packaging remaps it to this LAN build-cache reference after
`make seed-build-deps` (or `make -C deps/blob-storage release`).
