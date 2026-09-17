#!/usr/bin/env bash
# Produce or refresh the durable third-party packaging freeze for TARGET_ARCH.
#
# Populates THIRD_PARTY_FREEZE_ROOT/$TARGET_ARCH with upstream OCI archives and
# host-packages so later product builds (mode=auto|require) skip re-exporting
# multi-gigabyte third-party inputs. Product images are not built.
#
# Usage:
#   TARGET_ARCH=arm64 \
#   THIRD_PARTY_FREEZE_ROOT=/var/cache/zon-third-party \
#   OFFLINE_BUILD=1 DEV_REGISTRY=... DEV_IMAGE_REPO=... \
#   bash ./scripts/freeze-third-party.sh
#
# Or: TARGET_ARCH=arm64 THIRD_PARTY_FREEZE_ROOT=/var/cache/zon-third-party make freeze-third-party
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/fs-link.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/third-party-freeze.sh"

TARGET_ARCH="${TARGET_ARCH:-}"
if [[ -z "${TARGET_ARCH}" ]]; then
  echo "freeze-third-party: TARGET_ARCH is required (amd64|arm64)" >&2
  exit 2
fi

THIRD_PARTY_FREEZE_ROOT="${THIRD_PARTY_FREEZE_ROOT:-/var/cache/zon-third-party}"
# Freeze producer always writes; use auto so misses package+store instead of fail.
THIRD_PARTY_FREEZE_MODE="${THIRD_PARTY_FREEZE_MODE:-auto}"
if [[ "${THIRD_PARTY_FREEZE_MODE}" == "ignore" ]]; then
  echo "freeze-third-party: refusing THIRD_PARTY_FREEZE_MODE=ignore (nothing would be stored)" >&2
  exit 2
fi
export TARGET_ARCH THIRD_PARTY_FREEZE_ROOT THIRD_PARTY_FREEZE_MODE
tpf_normalize_env

export FREEZE_THIRD_PARTY_ONLY=1
echo "freeze-third-party: TARGET_ARCH=${TARGET_ARCH} root=${THIRD_PARTY_FREEZE_ROOT} mode=${THIRD_PARTY_FREEZE_MODE}"
cd "${RELEASE_REPO_DIR}"
bash "${SCRIPT_DIR}/build-full-bundle.sh"
