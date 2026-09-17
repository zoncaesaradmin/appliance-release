#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
mkdir -p "${ROOT}/.staging"
deps_mirror_oci "${UPSTREAM_IMAGE}" "${LOCAL_REF}" "" "${TARGET_ARCH}"
deps_mirror_oci "${VLLM_UPSTREAM_IMAGE}" "${VLLM_LOCAL_REF}" "" "amd64"
deps_mirror_oci "${VLLM_ARM64_UPSTREAM_IMAGE}" "${VLLM_ARM64_LOCAL_REF}" "" "arm64"
printf '%s\n%s\n%s\n' "${LOCAL_REF}" "${VLLM_LOCAL_REF}" "${VLLM_ARM64_LOCAL_REF}" > "${ROOT}/.staging/local-ref"
