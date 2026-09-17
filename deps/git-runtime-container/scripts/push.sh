#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
deps_require_var DEV_REGISTRY
CACHE_TAG="${CACHE_TAG_BASE}-${TARGET_ARCH}"
LOCAL_REF="localhost/build-cache/${CACHE_NAME}:${CACHE_TAG}"
local_ref="$(cat "${ROOT}/.staging/local-ref" 2>/dev/null || echo "${LOCAL_REF}")"
dest="$(deps_build_cache_ref "${CACHE_NAME}" "${CACHE_TAG}")"
deps_push_oci "${local_ref}" "${dest}"
echo "published ${dest}"
