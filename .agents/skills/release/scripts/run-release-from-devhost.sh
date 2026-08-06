#!/usr/bin/env bash
# run-release-from-devhost.sh — minimal Mac/devhost driver.
#
# CLI path presence decides work (no skip flags):
#   --build-publish-config  → build/publish on build host (env from this shell)
#   --install-config        → public helper install, optional bootstrap, then
#                             target (+ client) verification; "OK run" only after
#                             those succeed when report.final_ok is true
#
# Every stage receives only the role config files it needs — no merge step.
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
  APPLIANCE_TARGET_SUDO_PASSWORD install + bootstrap + target verify
  APPLIANCE_FIRST_ADMIN_PASSWORD when install.bootstrap_admin is true

  --build-publish-config  → run build/publish
  --install-config        → public install → bootstrap_admin / default license
                            (when true) → targetVerify → clientVerify (if
                            bootstrap_admin) → "OK run" if report.final_ok
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
  fail "install requires --build-publish-config (product version + bundle_store URL)"
fi

DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
if [[ -n "${BUILD_PUBLISH_CONFIG}" ]]; then
  BUILD_PUBLISH_CONFIG="$(require_config_path "${BUILD_PUBLISH_CONFIG}")"
fi
if [[ -n "${INSTALL_CONFIG}" ]]; then
  INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"
  # Fail closed before install if operator still supplies product-fixed keys.
  reject_removed_install_control_plane_identity_keys "${INSTALL_CONFIG}"
fi

RUN_DIR="$(config_get_optional "${DEVHOST_CONFIG}" "report.run_dir" || true)"
if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"
log "run-dir=${RUN_DIR}"

FINAL_OK="false"
if [[ -n "$(config_get_optional "${DEVHOST_CONFIG}" "report.final_ok" || true)" ]]; then
  FINAL_OK="$(config_require_bool "${DEVHOST_CONFIG}" "report.final_ok")"
fi

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

  BOOTSTRAP_ADMIN="false"
  ENABLE_DEFAULT_LICENSE="false"
  if [[ -n "$(config_get_optional "${INSTALL_CONFIG}" "install.bootstrap_admin" || true)" ]]; then
    BOOTSTRAP_ADMIN="$(config_require_bool "${INSTALL_CONFIG}" "install.bootstrap_admin")"
  fi
  if [[ -n "$(config_get_optional "${INSTALL_CONFIG}" "install.enable_default_license" || true)" ]]; then
    ENABLE_DEFAULT_LICENSE="$(config_require_bool "${INSTALL_CONFIG}" "install.enable_default_license")"
  fi
  APPLIANCE_PROFILE="$(config_get_optional "${INSTALL_CONFIG}" "install.appliance_profile" || true)"
  if [[ -z "${APPLIANCE_PROFILE}" ]]; then
    APPLIANCE_PROFILE="core"
  fi

  if bool_true "${BOOTSTRAP_ADMIN}"; then
    log "── bootstrapAdmin (install.bootstrap_admin=true)"
    bash "${SCRIPT_DIR}/bootstrap-admin-on-target.sh" \
      --config "${DEVHOST_CONFIG}" \
      --install-config "${INSTALL_CONFIG}" \
      --run-dir "${RUN_DIR}"
  else
    log "── bootstrapAdmin: skipped (install.bootstrap_admin not true)"
  fi

  if bool_true "${ENABLE_DEFAULT_LICENSE}"; then
    log "── bootstrapDefaultLicense (install.enable_default_license=true)"
    bash "${SCRIPT_DIR}/bootstrap-default-license-on-target.sh" \
      --config "${DEVHOST_CONFIG}" \
      --install-config "${INSTALL_CONFIG}" \
      --run-dir "${RUN_DIR}"
  else
    log "── bootstrapDefaultLicense: skipped (install.enable_default_license not true)"
  fi

  log "── targetVerify"
  bash "${SCRIPT_DIR}/verify-target.sh" \
    --config "${DEVHOST_CONFIG}" \
    --install-config "${INSTALL_CONFIG}" \
    --build-publish-config "${BUILD_PUBLISH_CONFIG}" \
    --run-dir "${RUN_DIR}" \
    --appliance-profile "${APPLIANCE_PROFILE}"

  if bool_true "${BOOTSTRAP_ADMIN}"; then
    log "── clientVerify (install.bootstrap_admin=true)"
    bash "${SCRIPT_DIR}/verify-client-access.sh" \
      --install-config "${INSTALL_CONFIG}" \
      --devhost-config "${DEVHOST_CONFIG}" \
      --run-dir "${RUN_DIR}" \
      --appliance-profile "${APPLIANCE_PROFILE}"
  else
    log "── clientVerify: skipped (install.bootstrap_admin not true)"
  fi

  log "── report"
  python3 "${SCRIPT_DIR}/summarize-release-run.py" \
    --run-dir "${RUN_DIR}" \
    --exit-code 0 \
    >"${RUN_DIR}/logs/release-report.log" 2>&1 \
    || fail "report failed; see ${RUN_DIR}/logs/release-report.log"
  log "report → ${RUN_DIR}/release-report.md"
fi

log "done"
if bool_true "${FINAL_OK}"; then
  printf 'OK run\n'
fi
