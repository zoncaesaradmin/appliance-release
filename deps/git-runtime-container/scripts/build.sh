#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../../../scripts/deps-common.sh
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
# shellcheck disable=SC1091
source "${ROOT}/pins.env"
mkdir -p "${ROOT}/.staging"
deps_mirror_oci "${UPSTREAM_IMAGE}" "${LOCAL_REF}" ""
printf '%s\n' "${LOCAL_REF}" > "${ROOT}/.staging/local-ref"
echo "built ${LOCAL_REF}"
