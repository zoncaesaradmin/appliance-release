#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/target-arch.sh"
source "${ROOT}/pins.env"
target_arch_resolve

case "${TARGET_ARCH}" in
  amd64) asset_arch=amd64; expected="${CLOUDFLARED_SHA256_AMD64}" ;;
  arm64) asset_arch=arm64; expected="${CLOUDFLARED_SHA256_ARM64}" ;;
  *) echo "cloudflared: unsupported TARGET_ARCH=${TARGET_ARCH}" >&2; exit 2 ;;
esac

stage="${ROOT}/.staging/cloudflared"
rm -rf "${ROOT}/.staging"
mkdir -p "${stage}"
url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${asset_arch}"
echo "downloading cloudflared ${CLOUDFLARED_VERSION} (${TARGET_ARCH})"
curl -fsSL -o "${stage}/cloudflared" "${url}"
printf '%s  %s\n' "${expected}" "${stage}/cloudflared" | sha256sum -c -
chmod 0755 "${stage}/cloudflared"
