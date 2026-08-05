#!/usr/bin/env bash
# run-release-from-devhost.sh — minimal Mac/devhost driver.
#
# CLI path presence decides work (no skip flags):
#   --build-publish-config  → build/publish on build host (env from this shell)
#   --install-config        → public helper install on target, then optional
#                             bootstrap_admin / enable_default_license from that
#                             install YAML (SSH from this Mac; secrets from shell)
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

Export on this Mac as needed:
  DEV_*                          build/publish + bundle download URLs
  APPLIANCE_BUILD_SUDO_PASSWORD  build host
  APPLIANCE_TARGET_SUDO_PASSWORD install + bootstrap on target
  APPLIANCE_FIRST_ADMIN_PASSWORD when install.bootstrap_admin is true

  --build-publish-config  → run build/publish
  --install-config        → public install, then first-admin / default license
                            when install.bootstrap_admin /
                            install.enable_default_license are true
                            (also requires --build-publish-config)

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

  # Public helper only runs zonctl install. Post-install bootstrap is
  # orchestrator-owned (same as run-release-flow.sh stages).
  MERGED_CONFIG_PATH="${RUN_DIR}/metadata/merged-release-config.json"
  python3 "${SCRIPT_DIR}/merge-release-configs.py" \
    --devhost-config "${DEVHOST_CONFIG}" \
    --build-publish-config "${BUILD_PUBLISH_CONFIG}" \
    --install-config "${INSTALL_CONFIG}" \
    --output "${MERGED_CONFIG_PATH}" >/dev/null

  BOOTSTRAP_ADMIN="false"
  ENABLE_DEFAULT_LICENSE="false"
  if [[ -n "$(config_get_optional "${MERGED_CONFIG_PATH}" "install.bootstrap_admin" || true)" ]]; then
    BOOTSTRAP_ADMIN="$(config_require_bool "${MERGED_CONFIG_PATH}" "install.bootstrap_admin")"
  fi
  if [[ -n "$(config_get_optional "${MERGED_CONFIG_PATH}" "install.enable_default_license" || true)" ]]; then
    ENABLE_DEFAULT_LICENSE="$(config_require_bool "${MERGED_CONFIG_PATH}" "install.enable_default_license")"
  fi

  if bool_true "${BOOTSTRAP_ADMIN}"; then
    log "── bootstrapAdmin (install.bootstrap_admin=true)"
    bash "${SCRIPT_DIR}/bootstrap-admin-on-target.sh" \
      --config "${MERGED_CONFIG_PATH}" \
      --run-dir "${RUN_DIR}"
  else
    log "── bootstrapAdmin: skipped (install.bootstrap_admin not true)"
  fi

  if bool_true "${ENABLE_DEFAULT_LICENSE}"; then
    log "── bootstrapDefaultLicense (install.enable_default_license=true)"
    bash "${SCRIPT_DIR}/bootstrap-default-license-on-target.sh" \
      --config "${MERGED_CONFIG_PATH}" \
      --run-dir "${RUN_DIR}"
  else
    log "── bootstrapDefaultLicense: skipped (install.enable_default_license not true)"
  fi
fi

log "done"
