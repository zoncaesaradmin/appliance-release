#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
deps_require_var DEV_REGISTRY
local_ref="$(cat "${ROOT}/.staging/local-ref" 2>/dev/null || echo "${LOCAL_REF}")"
dest="$(deps_build_cache_ref "${CACHE_NAME}" "${CACHE_TAG}")"
tls="$(deps_skopeo_tls_flag)"
# shellcheck disable=SC2086
skopeo copy --override-os linux --override-arch amd64 ${tls} \
  "containers-storage:${local_ref}" "docker://${dest}"
echo "published ${dest}"
