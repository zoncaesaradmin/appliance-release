#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
source "${ROOT}/pins.env"
target_arch_resolve
deps_require_build_arch_runnable "${TARGET_ARCH}"

ZOT_CACHE_NAME="zot-linux-${TARGET_ARCH}"
ZOT_CACHE_TAG="${ZOT_VERSION}"
ZOT_IMAGE="ghcr.io/project-zot/${ZOT_CACHE_NAME}:${ZOT_CACHE_TAG}"
ZOT_LOCAL="localhost/build-cache/${ZOT_CACHE_NAME}:${ZOT_CACHE_TAG}"
# Prefetch the matching-arch debian base into an explicit local tag so the
# Containerfile never reuses a wrong-arch cached docker.io/...:bookworm-slim.
DEBIAN_SRC_LOCAL="localhost/build-cache/debian-bookworm-slim:bookworm-slim-${TARGET_ARCH}"

mkdir -p "${ROOT}/.staging"
BUILD_CMD="$(deps_default_build_cmd)"
deps_mirror_oci "${ZOT_IMAGE}" "${ZOT_LOCAL}" "" "${TARGET_ARCH}"
deps_mirror_oci "${DEBIAN_UPSTREAM}" "${DEBIAN_SRC_LOCAL}" "" "${TARGET_ARCH}"
# shellcheck disable=SC2086
${BUILD_CMD} --pull=never --build-arg "BASE_IMAGE=${DEBIAN_SRC_LOCAL}" \
  -f "${ROOT}/Containerfile.debian-runtime" \
  -t "${DEBIAN_LOCAL}" \
  "${ROOT}"
printf '%s\n' "${ZOT_LOCAL}" > "${ROOT}/.staging/zot-ref"
printf '%s\n' "${DEBIAN_LOCAL}" > "${ROOT}/.staging/debian-ref"
echo "built artifact-server-bases for ${TARGET_ARCH}"
