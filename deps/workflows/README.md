# workflows

Seeds Argo Workflows images and CRDs:

- OCI: `build-cache/argoexec:v3.5.10-${TARGET_ARCH}`
- OCI: `build-cache/workflow-controller:v3.5.10-${TARGET_ARCH}`
- files: `argo-workflows/v3.5.10/namespace-install.yaml`

```bash
TARGET_ARCH=amd64 make -C deps/workflows release
TARGET_ARCH=arm64 make -C deps/workflows release
```
