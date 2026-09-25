#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/../.." && pwd)"
source "${REPO_ROOT}/scripts/deps-common.sh"
source "${ROOT}/pins.env"

archive="${ROOT}/.staging/${SOURCE_ARCHIVE}"
checksum="${archive}.sha256"
[[ -s "${archive}" && -s "${checksum}" ]] || { echo "open-webui: run make build first" >&2; exit 2; }
prefix="build-deps/open-webui/${UPSTREAM_COMMIT}"
deps_files_upload "${archive}" "${prefix}/${SOURCE_ARCHIVE}"
deps_files_upload "${checksum}" "${prefix}/${SOURCE_ARCHIVE}.sha256"
