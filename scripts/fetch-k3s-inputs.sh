#!/usr/bin/env bash
# Compatibility wrapper: K3s (and Helm) seeds live under deps/platform-inputs.
#
# Preferred:
#   make -C deps/platform-inputs release
#   # or: make seed-build-deps
#
# Usage:
#   export RELEASE_WORK_ROOT=... DEV_REGISTRY=... DEV_REGISTRY_TOKEN=...
#   bash ./scripts/fetch-k3s-inputs.sh
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
usage: bash ./scripts/fetch-k3s-inputs.sh

Forwards to deps/platform-inputs (make release).

Required environment:
  DEV_REGISTRY, DEV_REGISTRY_TOKEN
  RELEASE_WORK_ROOT   (when SKIP_PUBLISH=1, also stages under inputs/)

Optional:
  DEV_REGISTRY_TLS_VERIFY=false
  SKIP_PUBLISH=1              stage only (build without push)
EOF
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLATFORM_DIR="${REPO_ROOT}/deps/platform-inputs"

if [[ ! -d "${PLATFORM_DIR}" ]]; then
  echo "fetch-k3s-inputs: missing ${PLATFORM_DIR}" >&2
  exit 2
fi

echo "fetch-k3s-inputs: forwarding to ${PLATFORM_DIR}" >&2
if [[ "${SKIP_PUBLISH:-}" == "1" ]]; then
  make -C "${PLATFORM_DIR}" build
  if [[ -n "${RELEASE_WORK_ROOT:-}" ]]; then
    # shellcheck disable=SC1091
    source "${PLATFORM_DIR}/pins.env"
    mkdir -p "${RELEASE_WORK_ROOT}/inputs"
    cp -f "${PLATFORM_DIR}/.staging/k3s/k3s" "${RELEASE_WORK_ROOT}/inputs/k3s"
    cp -f "${PLATFORM_DIR}/.staging/k3s/k3s-airgap-images-amd64.tar.zst" \
      "${RELEASE_WORK_ROOT}/inputs/k3s-airgap-images-amd64.tar.zst"
    chmod +x "${RELEASE_WORK_ROOT}/inputs/k3s"
  fi
  exit 0
fi

make -C "${PLATFORM_DIR}" release
