# git-runtime-container

Seeds `alpine/git` for the workspace-provisioner image. LAN tags are
**arch-suffixed**:

`build-cache/alpine-git:2.49.0-${TARGET_ARCH}`

```bash
TARGET_ARCH=amd64 make -C deps/git-runtime-container release
TARGET_ARCH=arm64 make -C deps/git-runtime-container release
```
