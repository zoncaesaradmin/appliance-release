#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "${REPO_ROOT}/scripts/deps-common.sh"
source "${REPO_ROOT}/scripts/lib/target-arch.sh"
source "${ROOT}/pins.env"
target_arch_resolve

STAGE="${ROOT}/.staging"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/k3s" "${STAGE}/helm"

HELM_ARCHIVE="helm-${HELM_VERSION}-linux-${TARGET_ARCH}.tar.gz"
HELM_URL="https://get.helm.sh/${HELM_ARCHIVE}"
HELM_SHA_URL="${HELM_URL}.sha256sum"
K3S_BIN_ASSET="$(k3s_binary_asset_name)"
K3S_AIRGAP="k3s-airgap-images-${TARGET_ARCH}.tar.zst"

ver_enc="${K3S_VERSION//+/%2B}"
k3s_base="https://github.com/k3s-io/k3s/releases/download/${ver_enc}"
echo "downloading K3s ${K3S_VERSION} (${TARGET_ARCH})"
curl -fsSL -o "${STAGE}/k3s/k3s" "${k3s_base}/${K3S_BIN_ASSET}"
chmod +x "${STAGE}/k3s/k3s"
curl -fsSL -o "${STAGE}/k3s/${K3S_AIRGAP}" \
  "${k3s_base}/${K3S_AIRGAP}"

echo "downloading Helm ${HELM_VERSION} (${TARGET_ARCH})"
curl -fsSL -o "${STAGE}/helm/${HELM_ARCHIVE}" "${HELM_URL}"
curl -fsSL -o "${STAGE}/helm/${HELM_ARCHIVE}.sha256sum" "${HELM_SHA_URL}"
(
  cd "${STAGE}/helm"
  sha256sum -c "${HELM_ARCHIVE}.sha256sum"
)
echo "built platform-inputs for ${TARGET_ARCH}"
