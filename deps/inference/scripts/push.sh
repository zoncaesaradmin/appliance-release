#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
deps_require_var DEV_REGISTRY

CACHE_TAG="${CACHE_TAG_BASE}-${TARGET_ARCH}"
LOCAL_REF="localhost/build-cache/${CACHE_NAME}:${CACHE_TAG}"

dest="$(deps_build_cache_ref "${CACHE_NAME}" "${CACHE_TAG}")"
deps_push_oci "${LOCAL_REF}" "${dest}"
echo "published ${dest}"

case "${TARGET_ARCH}" in
  amd64)
    if [[ ! -f "${ROOT}/.staging/vllm-ref" ]]; then
      echo "inference: missing .staging/vllm-ref; run make build TARGET_ARCH=amd64 first" >&2
      exit 2
    fi
    vllm_dest="$(deps_build_cache_ref "${VLLM_CACHE_NAME}" "${VLLM_CACHE_TAG}")"
    deps_push_oci "${VLLM_LOCAL_REF}" "${vllm_dest}"
    echo "published ${vllm_dest}"
    ;;
  arm64)
    if [[ ! -f "${ROOT}/.staging/vllm-arm64-ref" ]]; then
      echo "inference: missing .staging/vllm-arm64-ref; run make build TARGET_ARCH=arm64 first" >&2
      exit 2
    fi
    vllm_arm64_dest="$(deps_build_cache_ref "${VLLM_ARM64_CACHE_NAME}" "${VLLM_ARM64_CACHE_TAG}")"
    deps_push_oci "${VLLM_ARM64_LOCAL_REF}" "${vllm_arm64_dest}"
    echo "published ${vllm_arm64_dest}"
    ;;
esac
