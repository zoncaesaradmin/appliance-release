#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
STAGE="${ROOT}/.staging"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/k3s" "${STAGE}/helm"

ver_enc="${K3S_VERSION//+/%2B}"
k3s_base="https://github.com/k3s-io/k3s/releases/download/${ver_enc}"
echo "downloading K3s ${K3S_VERSION}"
curl -fsSL -o "${STAGE}/k3s/k3s" "${k3s_base}/k3s"
chmod +x "${STAGE}/k3s/k3s"
curl -fsSL -o "${STAGE}/k3s/k3s-airgap-images-amd64.tar.zst" \
  "${k3s_base}/k3s-airgap-images-amd64.tar.zst"

echo "downloading Helm ${HELM_VERSION}"
curl -fsSL -o "${STAGE}/helm/${HELM_ARCHIVE}" "${HELM_URL}"
curl -fsSL -o "${STAGE}/helm/${HELM_ARCHIVE}.sha256sum" "${HELM_SHA_URL}"
(
  cd "${STAGE}/helm"
  sha256sum -c "${HELM_ARCHIVE}.sha256sum"
)
echo "built platform-inputs"
