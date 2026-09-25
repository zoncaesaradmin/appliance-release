#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/../.." && pwd)"
source "${REPO_ROOT}/scripts/deps-common.sh"
source "${REPO_ROOT}/scripts/lib/target-arch.sh"
source "${ROOT}/pins.env"
target_arch_resolve
deps_require_var DEV_REGISTRY

archive="${ROOT}/.staging/${SOURCE_ARCHIVE}"
checksum="${archive}.sha256"
[[ -s "${archive}" && -s "${checksum}" ]] || { echo "open-webui: run make build first" >&2; exit 2; }
prefix="build-deps/open-webui/${UPSTREAM_COMMIT}"
deps_files_upload "${archive}" "${prefix}/${SOURCE_ARCHIVE}"
deps_files_upload "${checksum}" "${prefix}/${SOURCE_ARCHIVE}.sha256"

NODE_CACHE_TAG="${NODE_CACHE_TAG_BASE}-${TARGET_ARCH}"
PYTHON_CACHE_TAG="${PYTHON_CACHE_TAG_BASE}-${TARGET_ARCH}"
UV_CACHE_TAG="${UV_CACHE_TAG_BASE}-${TARGET_ARCH}"
NODE_LOCAL="localhost/build-cache/${NODE_CACHE_NAME}:${NODE_CACHE_TAG}"
PYTHON_LOCAL="localhost/build-cache/${PYTHON_CACHE_NAME}:${PYTHON_CACHE_TAG}"
UV_LOCAL="localhost/build-cache/${UV_CACHE_NAME}:${UV_CACHE_TAG}"
deps_push_oci "${NODE_LOCAL}" "$(deps_build_cache_ref "${NODE_CACHE_NAME}" "${NODE_CACHE_TAG}")"
deps_push_oci "${PYTHON_LOCAL}" "$(deps_build_cache_ref "${PYTHON_CACHE_NAME}" "${PYTHON_CACHE_TAG}")"
deps_push_oci "${UV_LOCAL}" "$(deps_build_cache_ref "${UV_CACHE_NAME}" "${UV_CACHE_TAG}")"
echo "published Open WebUI source + Dockerfile bases for ${TARGET_ARCH}"
