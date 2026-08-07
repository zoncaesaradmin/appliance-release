#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
deps_require_var DEV_REGISTRY
zot_dest="$(deps_build_cache_ref "${ZOT_CACHE_NAME}" "${ZOT_CACHE_TAG}")"
deb_dest="$(deps_build_cache_ref "${DEBIAN_CACHE_NAME}" "${DEBIAN_CACHE_TAG}")"
deps_push_oci "${ZOT_LOCAL}" "${zot_dest}"
deps_push_oci "${DEBIAN_LOCAL}" "${deb_dest}"
echo "published ${zot_dest} and ${deb_dest}"
