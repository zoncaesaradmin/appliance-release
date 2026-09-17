#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
archive="${ROOT}/.staging/host-packages.tar.zst"
sum="${ROOT}/.staging/host-packages.tar.zst.sha256"
test -f "${archive}" || { echo "run make build TARGET_ARCH=${TARGET_ARCH} first" >&2; exit 1; }
# Arch-scoped files API path so amd64 and arm64 seeds do not overwrite each other.
prefix="host-packages/ubuntu-${OS_VERSION}/${TARGET_ARCH}/${HOST_PACKAGES_FINGERPRINT}"
deps_files_upload "${archive}" "${prefix}/host-packages.tar.zst"
deps_files_upload "${sum}" "${prefix}/host-packages.tar.zst.sha256"
echo "published files ${prefix}/"
