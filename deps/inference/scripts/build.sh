#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
mkdir -p "${ROOT}/.staging"

CACHE_TAG="${CACHE_TAG_BASE}-${TARGET_ARCH}"
LOCAL_REF="localhost/build-cache/${CACHE_NAME}:${CACHE_TAG}"

# One TARGET_ARCH → seed only that arch's inputs (never both).
# Ollama (std-llm) is multi-arch upstream; vLLM pins differ per arch.
deps_mirror_oci "${UPSTREAM_IMAGE}" "${LOCAL_REF}" "" "${TARGET_ARCH}"
printf '%s\n' "${LOCAL_REF}" > "${ROOT}/.staging/local-ref"

case "${TARGET_ARCH}" in
  amd64)
    deps_mirror_oci "${VLLM_UPSTREAM_IMAGE}" "${VLLM_LOCAL_REF}" "" "amd64"
    printf '%s\n' "${VLLM_LOCAL_REF}" >> "${ROOT}/.staging/local-ref"
    printf '%s\n' "${VLLM_LOCAL_REF}" > "${ROOT}/.staging/vllm-ref"
    rm -f "${ROOT}/.staging/vllm-arm64-ref"
    ;;
  arm64)
    deps_mirror_oci "${VLLM_ARM64_UPSTREAM_IMAGE}" "${VLLM_ARM64_LOCAL_REF}" "" "arm64"
    printf '%s\n' "${VLLM_ARM64_LOCAL_REF}" >> "${ROOT}/.staging/local-ref"
    printf '%s\n' "${VLLM_ARM64_LOCAL_REF}" > "${ROOT}/.staging/vllm-arm64-ref"
    rm -f "${ROOT}/.staging/vllm-ref"
    ;;
esac

echo "built inference seeds for TARGET_ARCH=${TARGET_ARCH}"
