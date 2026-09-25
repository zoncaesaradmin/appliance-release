#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/pins.env"
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
echo "built verified Open WebUI source seed ${UPSTREAM_COMMIT}"
