#!/usr/bin/env bash
# run-release-from-devhost.sh — minimal Mac/devhost end-to-end driver.
#
#   1) scp build-publish config; SSH build host with env exported from *this* shell
#   2) SSH target: curl helper URL (built on Mac) + bash with name/profile only
#
# Secrets: only on this machine. Target never receives profile env exports.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-release-from-devhost.sh \
  --config PATH \
  --build-publish-config PATH \
  --install-config PATH

One command from the Mac. Export DEV_* and APPLIANCE_BUILD_SUDO_PASSWORD here first.

  1) Build host — scp config, inject your env, run build-and-publish-on-host.sh
  2) Target — curl install-http-release.sh (URL/auth from this machine), then
     bash install-http-release.sh --appliance-name … --appliance-profile …

Skips: build_flow.skip / install.skip in the role YAMLs.
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
[[ -n "${BUILD_PUBLISH_CONFIG}" ]] || fail "requires --build-publish-config PATH"
[[ -n "${INSTALL_CONFIG}" ]] || fail "requires --install-config PATH"

DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
BUILD_PUBLISH_CONFIG="$(require_config_path "${BUILD_PUBLISH_CONFIG}")"
INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"

RUN_DIR="$(config_get_optional "${DEVHOST_CONFIG}" "report.run_dir" || true)"
if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"
log "run-dir=${RUN_DIR}"

SKIP_BUILD="$(config_get_optional "${BUILD_PUBLISH_CONFIG}" "build_flow.skip" || true)"
if [[ -z "${SKIP_BUILD}" ]]; then
  SKIP_BUILD="false"
fi
SKIP_INSTALL="$(config_get_optional "${INSTALL_CONFIG}" "install.skip" || true)"
if [[ -z "${SKIP_INSTALL}" ]]; then
  SKIP_INSTALL="false"
fi

if ! bool_true "${SKIP_BUILD}"; then
  log "── buildPublish"
  bash "${SCRIPT_DIR}/run-build-and-publish-on-build-host.sh" \
    --config "${DEVHOST_CONFIG}" \
    --build-publish-config "${BUILD_PUBLISH_CONFIG}" \
    --run-dir "${RUN_DIR}"
else
  log "── buildPublish: skipped (build_flow.skip=true)"
fi

if ! bool_true "${SKIP_INSTALL}"; then
  log "── install (public helper on target)"
  bash "${SCRIPT_DIR}/run-install-via-public-helper-on-target.sh" \
    --config "${DEVHOST_CONFIG}" \
    --build-publish-config "${BUILD_PUBLISH_CONFIG}" \
    --install-config "${INSTALL_CONFIG}" \
    --run-dir "${RUN_DIR}"
else
  log "── install: skipped (install.skip=true)"
fi

log "done"
