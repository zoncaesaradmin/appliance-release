# blob-storage

Seeds the pinned MinIO image used by the foundation blob-storage wrap. LAN
tags are **arch-suffixed**:

`build-cache/minio:RELEASE.2025-05-24T17-08-30Z-${TARGET_ARCH}`

```bash
TARGET_ARCH=amd64 make -C deps/blob-storage release
TARGET_ARCH=arm64 make -C deps/blob-storage release
```
