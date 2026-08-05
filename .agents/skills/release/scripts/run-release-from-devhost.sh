#!/usr/bin/env bash
# run-release-from-devhost.sh — minimal Mac/devhost end-to-end driver.
#
#   1) scp build-publish config → build host; run build-and-publish-on-host.sh
#   2) on target: curl published install-http-release.sh; run with name + profile
#
# No install YAML merge on target, no skill clone on target. Verify/report can
# be run separately (verify-target.sh / verify-client-access.sh).
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

Minimal end-to-end from the Mac/devhost:

  1) Build host
       scp build-publish YAML
       run build-and-publish-on-host.sh  (DEV_* already on build host)

  2) Target host
       curl …/install-http-release.sh for release.version
       bash install-http-release.sh \
         --appliance-name <install.appliance_name> \
         --appliance-profile <install.appliance_profile or core>

Skips when config says so:
  build_flow.skip: true
  install.skip: true

Example:
  bash .agents/skills/release/scripts/run-release-from-devhost.sh \
    --config ~/151-devhost.yaml \
    --build-publish-config ~/151-build-publish.yaml \
    --install-config ~/151-install.yaml
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

log "done (host-local secrets on build/target; public install used --appliance-name/--appliance-profile only)"
log "optional next: verify-target.sh / verify-client-access.sh with a merged config if needed"
