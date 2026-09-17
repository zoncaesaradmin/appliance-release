# platform-inputs

Seeds K3s binary + airgap images and the Helm linux-${TARGET_ARCH} tarball onto
the appliance files API (replaces standalone `fetch-k3s-inputs.sh` for new
seeds). Set `TARGET_ARCH=amd64|arm64` (default amd64).

Arch-scoped layout (preferred):

- `/api/v1/files/k3s/v1.30.4+k3s1/${TARGET_ARCH}/k3s`
- `/api/v1/files/k3s/v1.30.4+k3s1/k3s-airgap-images-${TARGET_ARCH}.tar.zst`
- `/api/v1/files/helm/v3.21.1/helm-v3.21.1-linux-${TARGET_ARCH}.tar.gz`
- `/api/v1/files/helm/v3.21.1/helm-v3.21.1-linux-${TARGET_ARCH}.tar.gz.sha256sum`

Legacy amd64 compatibility path (still published when `TARGET_ARCH=amd64`):

- `/api/v1/files/k3s/v1.30.4+k3s1/k3s`
