#!/usr/bin/env bash
# run-release-from-devhost.sh — minimal Mac/devhost driver.
#
# CLI path presence decides work (no skip flags):
#   --build-publish-config  → build/publish on build host (env from this shell)
#   --install-config        → install on target (also needs --build-publish-config
#                             for release.version / bundle_store URL)
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-release-from-devhost.sh \
  --config PATH \
  [--build-publish-config PATH] \
  [--install-config PATH]

Export DEV_*, APPLIANCE_BUILD_SUDO_PASSWORD, and (for install)
APPLIANCE_TARGET_SUDO_PASSWORD on this Mac first.

  --build-publish-config  → run build/publish
  --install-config        → run install (requires --build-publish-config for
                            version / download URL; no install.skip / build_flow.skip)

Examples:
  full e2e:   … --config … --build-publish-config … --install-config …
  build only: … --config … --build-publish-config …
EOF
}

DEVHOST_CONFIG=""
BUILD_PUBLISH_CONFIG=""
INSTALL_CONFIG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      DEVHOST_CONFIG="${2:-}"
      shift 2
      ;;
    --build-publish-config)
      BUILD_PUBLISH_CONFIG="${2:-}"
      shift 2
      ;;
    --install-config)
      INSTALL_CONFIG="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (see --help)"
      ;;
  esac
done

[[ -n "${DEVHOST_CONFIG}" ]] || fail "requires --config PATH"
if [[ -z "${BUILD_PUBLISH_CONFIG}" && -z "${INSTALL_CONFIG}" ]]; then
  fail "pass at least one of --build-publish-config or --install-config"
fi
if [[ -n "${INSTALL_CONFIG}" && -z "${BUILD_PUBLISH_CONFIG}" ]]; then
  fail "install requires --build-publish-config (release.version and bundle_store URL)"
fi

DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
if [[ -n "${BUILD_PUBLISH_CONFIG}" ]]; then
  BUILD_PUBLISH_CONFIG="$(require_config_path "${BUILD_PUBLISH_CONFIG}")"
fi
if [[ -n "${INSTALL_CONFIG}" ]]; then
  INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"
fi

RUN_DIR="$(config_get_optional "${DEVHOST_CONFIG}" "report.run_dir" || true)"
if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"
log "run-dir=${RUN_DIR}"

if [[ -n "${BUILD_PUBLISH_CONFIG}" ]]; then
  log "── buildPublish"
  bash "${SCRIPT_DIR}/run-build-and-publish-on-build-host.sh" \
    --config "${DEVHOST_CONFIG}" \
    --build-publish-config "${BUILD_PUBLISH_CONFIG}" \
    --run-dir "${RUN_DIR}"
fi

if [[ -n "${INSTALL_CONFIG}" ]]; then
  log "── install (public helper on target)"
  bash "${SCRIPT_DIR}/run-install-via-public-helper-on-target.sh" \
    --config "${DEVHOST_CONFIG}" \
    --build-publish-config "${BUILD_PUBLISH_CONFIG}" \
    --install-config "${INSTALL_CONFIG}" \
    --run-dir "${RUN_DIR}"
fi

log "done"
