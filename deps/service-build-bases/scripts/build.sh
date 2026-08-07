#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
mkdir -p "${ROOT}/.staging"
BUILD_CMD="$(deps_default_build_cmd)"
deps_mirror_oci "${GOLANG_UPSTREAM}" "${GOLANG_LOCAL}" ""
deps_mirror_oci "${NODE_UPSTREAM}" "${NODE_LOCAL}" ""
# shellcheck disable=SC2086
${BUILD_CMD} --build-arg "BASE_IMAGE=${ALPINE_UPSTREAM}" \
  -f "${ROOT}/Containerfile.alpine-runtime" -t "${ALPINE_LOCAL}" "${ROOT}"
# shellcheck disable=SC2086
${BUILD_CMD} --build-arg "BASE_IMAGE=${NODE_UPSTREAM}" \
  -f "${ROOT}/Containerfile.ui-npm-deps" -t "${UI_DEPS_LOCAL}" "${ROOT}"
printf '%s\n' "${GOLANG_LOCAL}" > "${ROOT}/.staging/golang-ref"
printf '%s\n' "${NODE_LOCAL}" > "${ROOT}/.staging/node-ref"
printf '%s\n' "${ALPINE_LOCAL}" > "${ROOT}/.staging/alpine-ref"
printf '%s\n' "${UI_DEPS_LOCAL}" > "${ROOT}/.staging/ui-deps-ref"
echo "built service-build-bases"
