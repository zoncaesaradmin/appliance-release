#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
archive="${ROOT}/.staging/host-packages.tar.zst"
sum="${ROOT}/.staging/host-packages.tar.zst.sha256"
test -f "${archive}" || { echo "run make build first" >&2; exit 1; }
prefix="host-packages/ubuntu-${OS_VERSION}/${HOST_PACKAGES_FINGERPRINT}"
deps_files_upload "${archive}" "${prefix}/host-packages.tar.zst"
deps_files_upload "${sum}" "${prefix}/host-packages.tar.zst.sha256"
echo "published files ${prefix}/"
