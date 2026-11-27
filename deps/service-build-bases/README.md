# service-build-bases

LAN build bases for control-plane / UI / hostagent image builds. Tags are
**arch-suffixed** so amd64 and arm64 seeds do not overwrite each other:

- `build-cache/golang:1.26-${TARGET_ARCH}`
- `build-cache/node:22-alpine-${TARGET_ARCH}`
- `build-cache/alpine-3.24.1-runtime:3.24.1-${TARGET_ARCH}`
- `build-cache/controlplane-ui-web-deps:lockfile-<package-lock-sha12>-${TARGET_ARCH}`

Cross-arch packaging (e.g. amd64 build host → `TARGET_ARCH=arm64`) uses
host-arch golang/node/ui-deps for `BUILDPLATFORM` compile stages and
target-arch alpine for the runtime stage. Seed **both** arches when you
cross-build:

```bash
TARGET_ARCH=amd64 make -C deps/service-build-bases release
TARGET_ARCH=arm64 make -C deps/service-build-bases release
```

The image tag is derived from the synchronized
`appliance-code/services/controlplane-ui/package-lock.json`, so each lockfile
gets a lockfile-specific cache entry. The seed discovers appliance-code using
`APPLIANCE_CODE_DIR`, `RELEASE_WORK_ROOT/repos/appliance-code`, a sibling
checkout, or the standard `appliance-build/repos/appliance-code` layout.
Set `APPLIANCE_CODE_DIR` for another layout. The selected checkout must match
the release input. Re-run `make release` when the lockfile changes.
