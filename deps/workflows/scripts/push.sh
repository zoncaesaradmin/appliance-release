#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
deps_require_var DEV_REGISTRY
CACHE_TAG="${CACHE_TAG_BASE}-${TARGET_ARCH}"
ARGOEXEC_LOCAL="localhost/build-cache/${ARGOEXEC_CACHE_NAME}:${CACHE_TAG}"
CONTROLLER_LOCAL="localhost/build-cache/${CONTROLLER_CACHE_NAME}:${CACHE_TAG}"
ae_dest="$(deps_build_cache_ref "${ARGOEXEC_CACHE_NAME}" "${CACHE_TAG}")"
wc_dest="$(deps_build_cache_ref "${CONTROLLER_CACHE_NAME}" "${CACHE_TAG}")"
deps_push_oci "${ARGOEXEC_LOCAL}" "${ae_dest}"
deps_push_oci "${CONTROLLER_LOCAL}" "${wc_dest}"
deps_files_upload "${ROOT}/.staging/namespace-install.yaml" \
  "argo-workflows/${WORKFLOWS_VERSION}/namespace-install.yaml"
echo "published workflows ${WORKFLOWS_VERSION} for ${TARGET_ARCH}"
