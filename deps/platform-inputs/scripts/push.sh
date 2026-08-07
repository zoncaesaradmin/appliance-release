#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
STAGE="${ROOT}/.staging"
test -f "${STAGE}/k3s/k3s" || { echo "run make build first" >&2; exit 1; }
deps_files_upload "${STAGE}/k3s/k3s" "k3s/${K3S_VERSION}/k3s"
deps_files_upload "${STAGE}/k3s/k3s-airgap-images-amd64.tar.zst" \
  "k3s/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst"
deps_files_upload "${STAGE}/helm/${HELM_ARCHIVE}" "helm/${HELM_VERSION}/${HELM_ARCHIVE}"
deps_files_upload "${STAGE}/helm/${HELM_ARCHIVE}.sha256sum" \
  "helm/${HELM_VERSION}/${HELM_ARCHIVE}.sha256sum"
echo "published platform-inputs"
