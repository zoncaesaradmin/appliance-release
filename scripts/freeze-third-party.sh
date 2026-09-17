#!/usr/bin/env bash
# Produce or refresh the durable third-party packaging freeze for TARGET_ARCH.
#
# Populates THIRD_PARTY_FREEZE_ROOT/$TARGET_ARCH with upstream OCI archives and
# host-packages so later product builds (mode=auto|require) skip re-exporting
# multi-gigabyte third-party inputs. Product images are not built.
#
# Prerequisites (same as build-full-bundle):
#   1) One-time: bash ./scripts/bootstrap-build-host.sh  (passwordless sudo podman)
#   2) DEV_* (+ OFFLINE_BUILD=1 for LAN) exported in the shell
#
# Usage (offline LAN example, accelerated / vLLM freeze):
#   export OFFLINE_BUILD=1
#   export DEV_REGISTRY=192.168.1.151
#   export DEV_IMAGE_REPO=development-container
#   export DEV_IMAGE_NAME=dev-build
#   export DEV_IMAGE_TAG=latest-amd64
#   export DEV_REGISTRY_USER=...
#   export DEV_REGISTRY_TOKEN=...
#   export DEV_REGISTRY_TLS_VERIFY=false
#   export APPLIANCE_PACKS=foundation,acc-llm   # or foundation,std-llm / all
#   TARGET_ARCH=arm64 THIRD_PARTY_FREEZE_ROOT=/var/cache/zon-third-party \
#     make freeze-third-party
#
# Note: APPLIANCE_PACKS=all selects std-llm (Ollama), not acc-llm (vLLM).
# Freeze root /var/cache/zon-third-party is created (via sudo -n) if needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
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
tpf_ensure_root_writable

if [[ -z "${DEV_REGISTRY:-}" || -z "${DEV_IMAGE_REPO:-}" ]]; then
  cat >&2 <<EOF
freeze-third-party: DEV_REGISTRY and DEV_IMAGE_REPO are required (same as build-full-bundle).
freeze-third-party: export your LAN or GHCR tooling identity first, for example:
freeze-third-party:   export OFFLINE_BUILD=1
freeze-third-party:   export DEV_REGISTRY=192.168.1.151
freeze-third-party:   export DEV_IMAGE_REPO=development-container
freeze-third-party:   export DEV_IMAGE_NAME=dev-build
freeze-third-party:   export DEV_IMAGE_TAG=latest-amd64
freeze-third-party:   export DEV_REGISTRY_USER=...
freeze-third-party:   export DEV_REGISTRY_TOKEN=...
freeze-third-party:   export DEV_REGISTRY_TLS_VERIFY=false
EOF
  exit 2
fi

# Same gate as build-full-bundle: passwordless sudo that preserves DEV_*.
preflight_bootstrap() {
  local podman_path probe_user probe_tag
  if ! command -v podman >/dev/null 2>&1; then
    echo "freeze-third-party: podman is required on PATH" >&2
    return 1
  fi
  podman_path="$(command -v podman)"
  probe_user="freeze-third-party-user-probe-$$"
  probe_tag="freeze-third-party-tag-probe-$$"
  if sudo -n "${podman_path}" --version >/dev/null 2>&1 \
    && [[ "$(DEV_REGISTRY_USER="${probe_user}" sudo -n env 2>/dev/null | sed -n 's/^DEV_REGISTRY_USER=//p')" == "${probe_user}" ]] \
    && [[ "$(DEV_IMAGE_TAG="${probe_tag}" sudo -n env 2>/dev/null | sed -n 's/^DEV_IMAGE_TAG=//p')" == "${probe_tag}" ]]; then
    return 0
  fi
  cat >&2 <<EOF
freeze-third-party: appliance-code host bootstrap is missing (passwordless sudo podman).
freeze-third-party: run this once on the build host with the same DEV_* exports:
freeze-third-party:   bash ${RELEASE_REPO_DIR}/scripts/bootstrap-build-host.sh
freeze-third-party: then rerun make freeze-third-party.
EOF
  return 1
}
preflight_bootstrap

if [[ -z "${APPLIANCE_PACKS:-}" ]]; then
  echo "freeze-third-party: APPLIANCE_PACKS unset; build-full-bundle defaults to all → std-llm (Ollama), not acc-llm (vLLM)" >&2
  echo "freeze-third-party: for private-ai / vLLM set APPLIANCE_PACKS=foundation,acc-llm" >&2
fi

export FREEZE_THIRD_PARTY_ONLY=1
echo "freeze-third-party: TARGET_ARCH=${TARGET_ARCH} root=${THIRD_PARTY_FREEZE_ROOT} mode=${THIRD_PARTY_FREEZE_MODE}"
echo "freeze-third-party: OFFLINE_BUILD=${OFFLINE_BUILD:-0} DEV_REGISTRY=${DEV_REGISTRY} APPLIANCE_PACKS=${APPLIANCE_PACKS:-all}"
cd "${RELEASE_REPO_DIR}"
bash "${SCRIPT_DIR}/build-full-bundle.sh"
