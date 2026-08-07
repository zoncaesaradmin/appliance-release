# platform-inputs

Seeds K3s binary + airgap images and the Helm linux-amd64 tarball onto the
appliance files API (replaces standalone `fetch-k3s-inputs.sh` for new seeds).

- `/api/v1/files/k3s/v1.30.4+k3s1/k3s`
- `/api/v1/files/k3s/v1.30.4+k3s1/k3s-airgap-images-amd64.tar.zst`
- `/api/v1/files/helm/v3.21.1/helm-v3.21.1-linux-amd64.tar.gz`
- `/api/v1/files/helm/v3.21.1/helm-v3.21.1-linux-amd64.tar.gz.sha256sum`
