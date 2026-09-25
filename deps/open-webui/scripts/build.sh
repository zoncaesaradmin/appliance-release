#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/../.." && pwd)"
source "${REPO_ROOT}/scripts/deps-common.sh"
source "${REPO_ROOT}/scripts/lib/target-arch.sh"
source "${ROOT}/pins.env"
target_arch_resolve

stage="${ROOT}/.staging"
checkout="${stage}/source"

rm -rf "${stage}"
mkdir -p "${stage}"
git clone --no-checkout --depth 1 --branch "${UPSTREAM_REF}" "${UPSTREAM_URL}" "${checkout}"
git -C "${checkout}" checkout --detach "${UPSTREAM_COMMIT}"
actual="$(git -C "${checkout}" rev-parse HEAD)"
[[ "${actual}" == "${UPSTREAM_COMMIT}" ]] || { echo "open-webui: locked commit mismatch: ${actual}" >&2; exit 1; }
git -C "${checkout}" diff --quiet

# Preserve .git: the product exporter verifies the detached commit again before
# applying appliance patches. Normalize ownership and mtimes for a stable seed.
tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner \
  -C "${stage}" -czf "${stage}/${SOURCE_ARCHIVE}" source
(cd "${stage}" && sha256sum "${SOURCE_ARCHIVE}" >"${SOURCE_ARCHIVE}.sha256")
rm -rf "${checkout}"

NODE_CACHE_TAG="${NODE_CACHE_TAG_BASE}-${TARGET_ARCH}"
PYTHON_CACHE_TAG="${PYTHON_CACHE_TAG_BASE}-${TARGET_ARCH}"
NODE_LOCAL="localhost/build-cache/${NODE_CACHE_NAME}:${NODE_CACHE_TAG}"
PYTHON_LOCAL="localhost/build-cache/${PYTHON_CACHE_NAME}:${PYTHON_CACHE_TAG}"
deps_mirror_oci "${NODE_UPSTREAM}" "${NODE_LOCAL}" "" "${TARGET_ARCH}"
deps_mirror_oci "${PYTHON_UPSTREAM}" "${PYTHON_LOCAL}" "" "${TARGET_ARCH}"
printf '%s\n' "${NODE_LOCAL}" >"${stage}/node-ref"
printf '%s\n' "${PYTHON_LOCAL}" >"${stage}/python-ref"
echo "built verified Open WebUI source seed ${UPSTREAM_COMMIT} and Dockerfile bases for ${TARGET_ARCH}"
