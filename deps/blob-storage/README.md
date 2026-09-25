# blob-storage

Seeds the pinned MinIO server used by the foundation blob-storage wrap.
`quay.io/minio/minio` and `docker.io/minio/minio` no longer allow anonymous
pulls, so the seed downloads the official GitHub release binary, checks its
sha256, and builds a single-arch image. LAN tags stay arch-suffixed:

`build-cache/minio:RELEASE.2025-05-24T17-08-30Z-${TARGET_ARCH}`

```bash
TARGET_ARCH=amd64 make -C deps/blob-storage release
TARGET_ARCH=arm64 make -C deps/blob-storage release
```
