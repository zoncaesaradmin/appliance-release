#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
deps_require_var DEV_REGISTRY
tls="$(deps_skopeo_tls_flag)"
zot_dest="$(deps_build_cache_ref "${ZOT_CACHE_NAME}" "${ZOT_CACHE_TAG}")"
deb_dest="$(deps_build_cache_ref "${DEBIAN_CACHE_NAME}" "${DEBIAN_CACHE_TAG}")"
# shellcheck disable=SC2086
skopeo copy --override-os linux --override-arch amd64 ${tls} \
  "containers-storage:${ZOT_LOCAL}" "docker://${zot_dest}"
# shellcheck disable=SC2086
skopeo copy --override-os linux --override-arch amd64 ${tls} \
  "containers-storage:${DEBIAN_LOCAL}" "docker://${deb_dest}"
echo "published ${zot_dest} and ${deb_dest}"
