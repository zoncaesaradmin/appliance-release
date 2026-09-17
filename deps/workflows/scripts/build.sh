#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
mkdir -p "${ROOT}/.staging"
deps_mirror_oci "${ARGOEXEC_IMAGE}" "${ARGOEXEC_LOCAL}" "" "${TARGET_ARCH}"
deps_mirror_oci "${WORKFLOW_CONTROLLER_IMAGE}" "${CONTROLLER_LOCAL}" "" "${TARGET_ARCH}"
curl -fsSL -o "${ROOT}/.staging/namespace-install.yaml" "${CRDS_URL}"
printf '%s\n' "${ARGOEXEC_LOCAL}" > "${ROOT}/.staging/argoexec-ref"
printf '%s\n' "${CONTROLLER_LOCAL}" > "${ROOT}/.staging/controller-ref"
echo "built workflows ${WORKFLOWS_VERSION}"
