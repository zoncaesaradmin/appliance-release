#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
mkdir -p "${ROOT}/.staging"
deps_mirror_oci "${UPSTREAM_IMAGE}" "${LOCAL_REF}" "" "${TARGET_ARCH}"
printf '%s\n' "${LOCAL_REF}" >"${ROOT}/.staging/local-ref"
