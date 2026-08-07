#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
mkdir -p "${ROOT}/.staging"
BUILD_CMD="$(deps_default_build_cmd)"
deps_mirror_oci "${ZOT_IMAGE}" "${ZOT_LOCAL}" ""
# shellcheck disable=SC2086
${BUILD_CMD} --build-arg "BASE_IMAGE=${DEBIAN_UPSTREAM}" \
  -f "${ROOT}/Containerfile.debian-runtime" \
  -t "${DEBIAN_LOCAL}" \
  "${ROOT}"
printf '%s\n' "${ZOT_LOCAL}" > "${ROOT}/.staging/zot-ref"
printf '%s\n' "${DEBIAN_LOCAL}" > "${ROOT}/.staging/debian-ref"
echo "built artifact-server-bases"
