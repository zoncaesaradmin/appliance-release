#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
CACHE_TAG="${CACHE_TAG_BASE}-${TARGET_ARCH}"
LOCAL_REF="localhost/build-cache/${CACHE_NAME}:${CACHE_TAG}"
case "${TARGET_ARCH}" in
  amd64) MINIO_SHA256="${MINIO_SHA256_AMD64}" ;;
  arm64) MINIO_SHA256="${MINIO_SHA256_ARM64}" ;;
  *)
    echo "blob-storage: unsupported architecture ${TARGET_ARCH}" >&2
    exit 2
    ;;
esac
ASSET="minio.linux-${TARGET_ARCH}.${MINIO_RELEASE}"
URL="${MINIO_BINARY_URL_BASE}/${ASSET}"
mkdir -p "${ROOT}/.staging"
echo "blob-storage: download ${URL}"
curl -fsSL -o "${ROOT}/.staging/minio" "${URL}"
echo "${MINIO_SHA256}  ${ROOT}/.staging/minio" | sha256sum -c -
chmod 0755 "${ROOT}/.staging/minio"
BUILD_CMD="$(deps_default_build_cmd)"
# shellcheck disable=SC2086
${BUILD_CMD} --pull=never \
  -f "${ROOT}/Containerfile" \
  -t "${LOCAL_REF}" \
  "${ROOT}/.staging"
printf '%s\n' "${LOCAL_REF}" > "${ROOT}/.staging/local-ref"
echo "built ${LOCAL_REF}"
