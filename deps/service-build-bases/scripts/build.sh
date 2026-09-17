#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
deps_require_build_arch_runnable "${TARGET_ARCH}"

GOLANG_CACHE_TAG="${GOLANG_CACHE_TAG_BASE}-${TARGET_ARCH}"
NODE_CACHE_TAG="${NODE_CACHE_TAG_BASE}-${TARGET_ARCH}"
ALPINE_CACHE_TAG="${ALPINE_CACHE_TAG_BASE}-${TARGET_ARCH}"
UI_DEPS_CACHE_TAG="${UI_DEPS_CACHE_TAG_BASE}-${TARGET_ARCH}"
GOLANG_LOCAL="localhost/build-cache/${GOLANG_CACHE_NAME}:${GOLANG_CACHE_TAG}"
NODE_LOCAL="localhost/build-cache/${NODE_CACHE_NAME}:${NODE_CACHE_TAG}"
ALPINE_LOCAL="localhost/build-cache/${ALPINE_CACHE_NAME}:${ALPINE_CACHE_TAG}"
UI_DEPS_LOCAL="localhost/build-cache/${UI_DEPS_CACHE_NAME}:${UI_DEPS_CACHE_TAG}"

mkdir -p "${ROOT}/.staging"
BUILD_CMD="$(deps_default_build_cmd)"
ALPINE_SRC_LOCAL="localhost/build-cache/alpine:3.24.1-${TARGET_ARCH}"

deps_mirror_oci "${GOLANG_UPSTREAM}" "${GOLANG_LOCAL}" "" "${TARGET_ARCH}"
deps_mirror_oci "${NODE_UPSTREAM}" "${NODE_LOCAL}" "" "${TARGET_ARCH}"
deps_mirror_oci "${ALPINE_UPSTREAM}" "${ALPINE_SRC_LOCAL}" "" "${TARGET_ARCH}"
# shellcheck disable=SC2086
${BUILD_CMD} --pull=never --build-arg "BASE_IMAGE=${ALPINE_SRC_LOCAL}" \
  -f "${ROOT}/Containerfile.alpine-runtime" -t "${ALPINE_LOCAL}" "${ROOT}"
# shellcheck disable=SC2086
${BUILD_CMD} --pull=never --build-arg "BASE_IMAGE=${NODE_LOCAL}" \
  -f "${ROOT}/Containerfile.ui-npm-deps" -t "${UI_DEPS_LOCAL}" "${ROOT}"
printf '%s\n' "${GOLANG_LOCAL}" > "${ROOT}/.staging/golang-ref"
printf '%s\n' "${NODE_LOCAL}" > "${ROOT}/.staging/node-ref"
printf '%s\n' "${ALPINE_LOCAL}" > "${ROOT}/.staging/alpine-ref"
printf '%s\n' "${UI_DEPS_LOCAL}" > "${ROOT}/.staging/ui-deps-ref"
echo "built service-build-bases for ${TARGET_ARCH}"
