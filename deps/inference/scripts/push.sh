#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
deps_require_var DEV_REGISTRY
dest="$(deps_build_cache_ref "${CACHE_NAME}" "${CACHE_TAG}")"
deps_push_oci "${LOCAL_REF}" "${dest}"
echo "published ${dest}"
vllm_dest="$(deps_build_cache_ref "${VLLM_CACHE_NAME}" "${VLLM_CACHE_TAG}")"
deps_push_oci "${VLLM_LOCAL_REF}" "${vllm_dest}"
echo "published ${vllm_dest}"
vllm_arm64_dest="$(deps_build_cache_ref "${VLLM_ARM64_CACHE_NAME}" "${VLLM_ARM64_CACHE_TAG}")"
deps_push_oci "${VLLM_ARM64_LOCAL_REF}" "${vllm_arm64_dest}"
echo "published ${vllm_arm64_dest}"
