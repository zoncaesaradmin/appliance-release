#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
source "${ROOT}/pins.env"
target_arch_resolve
ZOT_CACHE_NAME="zot-linux-${TARGET_ARCH}"
ZOT_CACHE_TAG="${ZOT_VERSION}"
ZOT_LOCAL="localhost/build-cache/${ZOT_CACHE_NAME}:${ZOT_CACHE_TAG}"
DEBIAN_CACHE_TAG="${DEBIAN_CACHE_TAG_BASE}-${TARGET_ARCH}"
DEBIAN_LOCAL="localhost/build-cache/${DEBIAN_CACHE_NAME}:${DEBIAN_CACHE_TAG}"
deps_require_var DEV_REGISTRY
zot_dest="$(deps_build_cache_ref "${ZOT_CACHE_NAME}" "${ZOT_CACHE_TAG}")"
deb_dest="$(deps_build_cache_ref "${DEBIAN_CACHE_NAME}" "${DEBIAN_CACHE_TAG}")"
deps_push_oci "${ZOT_LOCAL}" "${zot_dest}"
deps_push_oci "${DEBIAN_LOCAL}" "${deb_dest}"
echo "published ${zot_dest} and ${deb_dest}"
