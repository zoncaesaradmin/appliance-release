#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
deps_require_var DEV_REGISTRY
push_one() {
  local local_ref="$1" name="$2" tag="$3"
  local dest
  dest="$(deps_build_cache_ref "${name}" "${tag}")"
  deps_push_oci "${local_ref}" "${dest}"
}
push_one "${GOLANG_LOCAL}" "${GOLANG_CACHE_NAME}" "${GOLANG_CACHE_TAG}"
push_one "${NODE_LOCAL}" "${NODE_CACHE_NAME}" "${NODE_CACHE_TAG}"
push_one "${ALPINE_LOCAL}" "${ALPINE_CACHE_NAME}" "${ALPINE_CACHE_TAG}"
push_one "${UI_DEPS_LOCAL}" "${UI_DEPS_CACHE_NAME}" "${UI_DEPS_CACHE_TAG}"
