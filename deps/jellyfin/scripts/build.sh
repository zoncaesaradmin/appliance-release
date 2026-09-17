#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve

# Reviewed Jellyfin runtime is Linux/amd64 only. Do not pull other arches.
if [[ "${TARGET_ARCH}" != "amd64" ]]; then
  echo "jellyfin: skipping seed for TARGET_ARCH=${TARGET_ARCH} (amd64-only pin)" >&2
  mkdir -p "${ROOT}/.staging"
  : > "${ROOT}/.staging/skipped"
  exit 0
fi

mkdir -p "${ROOT}/.staging"
rm -f "${ROOT}/.staging/skipped"
deps_mirror_oci "${UPSTREAM_IMAGE}" "${LOCAL_REF}" "" "amd64"
printf '%s\n' "${LOCAL_REF}" > "${ROOT}/.staging/local-ref"
