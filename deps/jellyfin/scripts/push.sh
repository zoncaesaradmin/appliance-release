#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve

if [[ -f "${ROOT}/.staging/skipped" ]]; then
  echo "jellyfin: push skipped (build was skipped for TARGET_ARCH=${TARGET_ARCH})" >&2
  exit 0
fi
if [[ "${TARGET_ARCH}" != "amd64" ]]; then
  echo "jellyfin: push requires TARGET_ARCH=amd64 (got ${TARGET_ARCH})" >&2
  exit 2
fi

deps_require_var DEV_REGISTRY
dest="$(deps_build_cache_ref "${CACHE_NAME}" "${CACHE_TAG}")"
deps_push_oci "${LOCAL_REF}" "${dest}"
echo "published ${dest}"
