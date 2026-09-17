#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "${REPO_ROOT}/scripts/deps-common.sh"
source "${REPO_ROOT}/scripts/lib/target-arch.sh"
source "${ROOT}/pins.env"
target_arch_resolve

STAGE="${ROOT}/.staging"
HELM_ARCHIVE="helm-${HELM_VERSION}-linux-${TARGET_ARCH}.tar.gz"
K3S_AIRGAP="k3s-airgap-images-${TARGET_ARCH}.tar.zst"
test -f "${STAGE}/k3s/k3s" || { echo "run make build first" >&2; exit 1; }
test -f "${STAGE}/k3s/${K3S_AIRGAP}" || { echo "missing ${K3S_AIRGAP}; run make build with TARGET_ARCH=${TARGET_ARCH}" >&2; exit 1; }
test -f "${STAGE}/helm/${HELM_ARCHIVE}" || { echo "missing ${HELM_ARCHIVE}; run make build with TARGET_ARCH=${TARGET_ARCH}" >&2; exit 1; }

deps_files_upload "${STAGE}/k3s/k3s" "k3s/${K3S_VERSION}/${TARGET_ARCH}/k3s"
# Keep the legacy unscoped path for amd64 so existing offline builds keep
# working until every LAN seed is republished under the arch-scoped layout.
if [[ "${TARGET_ARCH}" == "amd64" ]]; then
  deps_files_upload "${STAGE}/k3s/k3s" "k3s/${K3S_VERSION}/k3s"
fi
deps_files_upload "${STAGE}/k3s/${K3S_AIRGAP}" \
  "k3s/${K3S_VERSION}/${K3S_AIRGAP}"
deps_files_upload "${STAGE}/helm/${HELM_ARCHIVE}" "helm/${HELM_VERSION}/${HELM_ARCHIVE}"
deps_files_upload "${STAGE}/helm/${HELM_ARCHIVE}.sha256sum" \
  "helm/${HELM_VERSION}/${HELM_ARCHIVE}.sha256sum"
echo "published platform-inputs for ${TARGET_ARCH}"
