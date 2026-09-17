#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
deps_require_var DEV_REGISTRY

GOLANG_CACHE_TAG="${GOLANG_CACHE_TAG_BASE}-${TARGET_ARCH}"
NODE_CACHE_TAG="${NODE_CACHE_TAG_BASE}-${TARGET_ARCH}"
ALPINE_CACHE_TAG="${ALPINE_CACHE_TAG_BASE}-${TARGET_ARCH}"
UI_DEPS_CACHE_TAG="${UI_DEPS_CACHE_TAG_BASE}-${TARGET_ARCH}"
GOLANG_LOCAL="localhost/build-cache/${GOLANG_CACHE_NAME}:${GOLANG_CACHE_TAG}"
NODE_LOCAL="localhost/build-cache/${NODE_CACHE_NAME}:${NODE_CACHE_TAG}"
ALPINE_LOCAL="localhost/build-cache/${ALPINE_CACHE_NAME}:${ALPINE_CACHE_TAG}"
UI_DEPS_LOCAL="localhost/build-cache/${UI_DEPS_CACHE_NAME}:${UI_DEPS_CACHE_TAG}"

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
