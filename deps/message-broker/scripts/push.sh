#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
CACHE_TAG="${CACHE_TAG_BASE}-${TARGET_ARCH}"
LOCAL_REF="localhost/build-cache/${CACHE_NAME}:${CACHE_TAG}"
deps_require_var DEV_REGISTRY
if [[ ! -f "${ROOT}/.staging/local-ref" ]]; then
  echo "message-broker: run make build TARGET_ARCH=${TARGET_ARCH} first" >&2
  exit 1
fi
dest="$(deps_build_cache_ref "${CACHE_NAME}" "${CACHE_TAG}")"
deps_push_oci "${LOCAL_REF}" "${dest}"
echo "published ${dest}"
