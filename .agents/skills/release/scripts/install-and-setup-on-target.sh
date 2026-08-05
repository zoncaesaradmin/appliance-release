#!/usr/bin/env bash
# install-and-setup-on-target.sh — run install (+ optional admin/license) on this host.
#
# Intended to run *on the target appliance host* with secrets already exported:
#   APPLIANCE_TARGET_SUDO_PASSWORD
#   DEV_REGISTRY* (when using appliance_files / image pull)
#   APPLIANCE_FIRST_ADMIN_PASSWORD (when install.bootstrap_admin is true)
#
# Config is a *merged work document* (install + release + bundle_store +
# target_host), normally produced on the Mac and scp'd by
# run-install-on-target-host.sh.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: install-and-setup-on-target.sh --config PATH [options]

On-target worker: download published bundle, zonctl install/upgrade, then
optional first-admin bootstrap and default-license accept. All steps run on
*this* host (no outbound SSH).

Required:
  --config PATH     Merged work config (JSON/YAML) with at least:
                      install.*, release.version, bundle_store.*, target_host.state_dir

Optional:
  --run-dir DIR     Local run directory for logs/metadata
  --skip-install    Only run post-install bootstrap stages
  --skip-bootstrap  Skip admin + default license even if install.* says true

Environment (already on this host; not copied by the orchestrator):
  APPLIANCE_TARGET_SUDO_PASSWORD
  DEV_REGISTRY, DEV_REGISTRY_USER, DEV_REGISTRY_TOKEN, DEV_REGISTRY_TLS_VERIFY
  APPLIANCE_FIRST_ADMIN_PASSWORD   (if install.bootstrap_admin)

From Mac/devhost:
  bash …/run-install-on-target-host.sh \
    --config ~/151-devhost.yaml \
    --build-publish-config ~/151-build-publish.yaml \
    --install-config ~/151-install.yaml
EOF
}

CONFIG_PATH=""
RUN_DIR=""
SKIP_INSTALL="false"
SKIP_BOOTSTRAP="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    --skip-install)
      SKIP_INSTALL="true"
      shift
      ;;
    --skip-bootstrap)
      SKIP_BOOTSTRAP="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "${CONFIG_PATH}" ]] || fail "requires --config PATH"
CONFIG_PATH="$(require_config_path "${CONFIG_PATH}")"

if [[ -f "${HOME}/.profile" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.profile" 2>/dev/null || true
fi
if [[ -f "${HOME}/.bashrc" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.bashrc" 2>/dev/null || true
fi

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"

BOOTSTRAP_ADMIN="false"
ENABLE_DEFAULT_LICENSE="false"
if [[ -n "$(config_get_optional "${CONFIG_PATH}" "install.bootstrap_admin" || true)" ]]; then
  BOOTSTRAP_ADMIN="$(config_require_bool "${CONFIG_PATH}" "install.bootstrap_admin")"
fi
if [[ -n "$(config_get_optional "${CONFIG_PATH}" "install.enable_default_license" || true)" ]]; then
  ENABLE_DEFAULT_LICENSE="$(config_require_bool "${CONFIG_PATH}" "install.enable_default_license")"
fi

if ! bool_true "${SKIP_INSTALL}"; then
  if [[ -n "$(config_get_optional "${CONFIG_PATH}" "install.skip" || true)" ]] \
    && bool_true "$(config_require_bool "${CONFIG_PATH}" "install.skip")"; then
    log "install.skip=true; skipping install-on-target"
  else
    log "── on-target install → install-on-target.sh --local"
    bash "${SCRIPT_DIR}/install-on-target.sh" \
      --local \
      --config "${CONFIG_PATH}" \
      --run-dir "${RUN_DIR}"
  fi
else
  log "── on-target install: skipped (--skip-install)"
fi

if bool_true "${SKIP_BOOTSTRAP}"; then
  log "── on-target bootstrap stages: skipped (--skip-bootstrap)"
  exit 0
fi

if bool_true "${BOOTSTRAP_ADMIN}"; then
  log "── on-target first-admin → bootstrap-admin-on-target.sh --local"
  bash "${SCRIPT_DIR}/bootstrap-admin-on-target.sh" \
    --local \
    --config "${CONFIG_PATH}" \
    --run-dir "${RUN_DIR}"
else
  log "── on-target first-admin: skipped (install.bootstrap_admin=false)"
fi

if bool_true "${ENABLE_DEFAULT_LICENSE}"; then
  log "── on-target default license → bootstrap-default-license-on-target.sh --local"
  bash "${SCRIPT_DIR}/bootstrap-default-license-on-target.sh" \
    --local \
    --config "${CONFIG_PATH}" \
    --run-dir "${RUN_DIR}"
else
  log "── on-target default license: skipped (install.enable_default_license=false)"
fi

log "on-target install/setup finished; logs under ${RUN_DIR}"
