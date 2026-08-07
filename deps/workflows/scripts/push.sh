#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
deps_require_var DEV_REGISTRY
tls="$(deps_skopeo_tls_flag)"
ae_dest="$(deps_build_cache_ref "${ARGOEXEC_CACHE_NAME}" "${CACHE_TAG}")"
wc_dest="$(deps_build_cache_ref "${CONTROLLER_CACHE_NAME}" "${CACHE_TAG}")"
# shellcheck disable=SC2086
skopeo copy --override-os linux --override-arch amd64 ${tls} \
  "containers-storage:${ARGOEXEC_LOCAL}" "docker://${ae_dest}"
# shellcheck disable=SC2086
skopeo copy --override-os linux --override-arch amd64 ${tls} \
  "containers-storage:${CONTROLLER_LOCAL}" "docker://${wc_dest}"
deps_files_upload "${ROOT}/.staging/namespace-install.yaml" \
  "argo-workflows/${WORKFLOWS_VERSION}/namespace-install.yaml"
echo "published workflows ${WORKFLOWS_VERSION}"
