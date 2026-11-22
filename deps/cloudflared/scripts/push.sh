#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "${REPO_ROOT}/scripts/deps-common.sh"
source "${REPO_ROOT}/scripts/lib/target-arch.sh"
source "${ROOT}/pins.env"
target_arch_resolve

binary="${ROOT}/.staging/cloudflared/cloudflared"
test -x "${binary}" || { echo "cloudflared: run make build first" >&2; exit 1; }
deps_files_upload "${binary}" "cloudflared/${CLOUDFLARED_VERSION}/${TARGET_ARCH}/cloudflared"
echo "published cloudflared ${CLOUDFLARED_VERSION} for ${TARGET_ARCH}"
