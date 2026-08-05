#!/usr/bin/env bash
# run-release-from-devhost.sh — split orchestration from the Mac/devhost.
#
# Devhost work is intentional and minimal: merge/copy configs, SSH to each
# machine, run host-local workers, then verify + report back on the devhost.
#
# Stages:
#   0 prepare        merge configs / run-dir
#   1 buildPublish   run-build-and-publish-on-build-host.sh  (unless build_flow.skip)
#   2 installSetup   run-install-on-target-host.sh           (unless install.skip)
#   3 targetVerify   verify-target.sh from devhost (SSH checks)
#   4 clientVerify   verify-client-access.sh from devhost
#                      (if install.bootstrap_admin; needs password env on devhost)
#   5 report         summarize-release-run.py
#
# Host-local secrets (not copied):
#   build host:  DEV_*, APPLIANCE_BUILD_SUDO_PASSWORD
#   target:      DEV_*, APPLIANCE_TARGET_SUDO_PASSWORD, APPLIANCE_FIRST_ADMIN_PASSWORD
#   devhost:     APPLIANCE_TARGET_SUDO_PASSWORD (for verify-target SSH),
#                APPLIANCE_FIRST_ADMIN_PASSWORD (for client API checks)
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

Split release path (preferred for host-local secrets):

  1) Copy build-publish config → build host; run build-and-publish-on-host.sh
  2) Merge + copy work config → target; run install-and-setup-on-target.sh
     (download published artifacts, zonctl install, optional admin/license)
  3) Back on the devhost: verify-target + client verify + report

Host-local scripts can also be run manually after configs are scp'd:
  # on build host
  bash …/build-and-publish-on-host.sh --build-publish-config ~/.config/appliance-release/build-publish.yaml
  # on target
  bash …/install-and-setup-on-target.sh --config ~/.config/appliance-release/work-config.json

CLI (same three paths as run-release-flow.sh):
  --config PATH                 Devhost: build_host, target_host, report
  --build-publish-config PATH
  --install-config PATH

Stage switches (in the role YAMLs):
  build_flow.skip
  install.skip / uninstall_first / preserve_failed_state /
    bootstrap_admin / enable_default_license
  report.final_ok
EOF
}

DEVHOST_CONFIG_PATH=""
BUILD_PUBLISH_CONFIG_PATH=""
INSTALL_CONFIG_PATH=""
CONFIG_PATH=""
RUN_DIR=""
RELEASE_VERSION=""
APPLIANCE_PROFILE=""
BUILD_CATALOG_PATH=""
PRESERVE_FAILED_STATE="false"
UNINSTALL_FIRST="false"
BOOTSTRAP_ADMIN="false"
ENABLE_DEFAULT_LICENSE="false"
SKIP_BUILD="false"
SKIP_INSTALL="false"
FINAL_OK="false"
CURRENT_STEP="startup"
BUNDLE_STORE_MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      DEVHOST_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --build-publish-config)
      BUILD_PUBLISH_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --install-config)
      INSTALL_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "run-release-from-devhost.sh only accepts --config, --build-publish-config, and --install-config (got: $*). See --help."
      ;;
  esac
done

[[ -n "${DEVHOST_CONFIG_PATH}" ]] || fail "requires --config PATH"
[[ -n "${BUILD_PUBLISH_CONFIG_PATH}" ]] || fail "requires --build-publish-config PATH"
[[ -n "${INSTALL_CONFIG_PATH}" ]] || fail "requires --install-config PATH"

begin_stage() {
  CURRENT_STEP="$1"
  log "── stage ${CURRENT_STEP}: $2"
}

end_stage() {
  log "── stage ${CURRENT_STEP}: done"
}

begin_stage "prepare" "resolve configs, merge, and run directory"

DEVHOST_CONFIG_PATH="$(require_config_path "${DEVHOST_CONFIG_PATH}")"
BUILD_PUBLISH_CONFIG_PATH="$(require_config_path "${BUILD_PUBLISH_CONFIG_PATH}")"
INSTALL_CONFIG_PATH="$(require_config_path "${INSTALL_CONFIG_PATH}")"

RUN_DIR="$(config_get_optional "${DEVHOST_CONFIG_PATH}" "report.run_dir" || true)"
if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"

MERGED_CONFIG_PATH="${RUN_DIR}/metadata/merged-release-config.json"
python3 "${SCRIPT_DIR}/merge-release-configs.py" \
  --devhost-config "${DEVHOST_CONFIG_PATH}" \
  --build-publish-config "${BUILD_PUBLISH_CONFIG_PATH}" \
  --install-config "${INSTALL_CONFIG_PATH}" \
  --output "${MERGED_CONFIG_PATH}" >/dev/null
CONFIG_PATH="${MERGED_CONFIG_PATH}"

if python3 "${CONFIG_QUERY}" --keys "${CONFIG_PATH}" "flow" >/dev/null 2>&1; then
  fail "config key 'flow' was removed; use build_flow.skip, install.*, and report.final_ok"
fi

SKIP_BUILD="$(config_require_bool "${CONFIG_PATH}" "build_flow.skip")"
SKIP_INSTALL="$(config_require_bool "${CONFIG_PATH}" "install.skip")"
UNINSTALL_FIRST="$(config_require_bool "${CONFIG_PATH}" "install.uninstall_first")"
PRESERVE_FAILED_STATE="$(config_require_bool "${CONFIG_PATH}" "install.preserve_failed_state")"
BOOTSTRAP_ADMIN="$(config_require_bool "${CONFIG_PATH}" "install.bootstrap_admin")"
ENABLE_DEFAULT_LICENSE="$(config_require_bool "${CONFIG_PATH}" "install.enable_default_license")"
FINAL_OK="$(config_require_bool "${CONFIG_PATH}" "report.final_ok")"

MERGED_RUN_DIR="$(config_get_optional "${CONFIG_PATH}" "report.run_dir" || true)"
if [[ -n "${MERGED_RUN_DIR}" ]]; then
  RUN_DIR="${MERGED_RUN_DIR}"
  ensure_release_run_dirs "${RUN_DIR}"
fi

RELEASE_VERSION="$(config_get_optional "${CONFIG_PATH}" "release.version" || true)"
BUNDLE_STORE_MODE="$(resolve_bundle_store_mode "${CONFIG_PATH}")"
APPLIANCE_PROFILE="$(require_appliance_profile "${CONFIG_PATH}" "")"
[[ -n "${RELEASE_VERSION}" ]] || fail "release.version is required in the build-publish config"
BUILD_CATALOG_PATH="$(resolve_build_catalog_path "${CONFIG_PATH}" "")"
require_builder_build_catalog_path "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}"

log "run-dir=${RUN_DIR}"
log "devhost-config=${DEVHOST_CONFIG_PATH}"
log "build-publish-config=${BUILD_PUBLISH_CONFIG_PATH}"
log "install-config=${INSTALL_CONFIG_PATH}"
log "merged-config=${CONFIG_PATH}"
log "release=${RELEASE_VERSION} profile=${APPLIANCE_PROFILE}"
log "stages: build_flow.skip=${SKIP_BUILD} install.skip=${SKIP_INSTALL} uninstall_first=${UNINSTALL_FIRST} preserve_failed_state=${PRESERVE_FAILED_STATE} bootstrap_admin=${BOOTSTRAP_ADMIN} enable_default_license=${ENABLE_DEFAULT_LICENSE} report.final_ok=${FINAL_OK}"

validate_builder_build_catalog "${SCRIPT_DIR}" "${CONFIG_PATH}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" "${RUN_DIR}" "build-catalog validation ok"
end_stage

FLOW_FINALIZED="false"
finalize_release_flow() {
  local exit_code="${1:-0}"
  if bool_true "${FLOW_FINALIZED}"; then
    return 0
  fi
  FLOW_FINALIZED="true"

  python3 - "${RUN_DIR}" "${CONFIG_PATH}" "${DEVHOST_CONFIG_PATH}" "${BUILD_PUBLISH_CONFIG_PATH}" "${INSTALL_CONFIG_PATH}" "${RELEASE_VERSION}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" "${SKIP_BUILD}" "${SKIP_INSTALL}" "${UNINSTALL_FIRST}" "${PRESERVE_FAILED_STATE}" "${BOOTSTRAP_ADMIN}" "${ENABLE_DEFAULT_LICENSE}" "${exit_code}" <<'PY'
import json
import sys
from pathlib import Path

(
    run_dir,
    config_path,
    devhost_config_path,
    build_publish_config_path,
    install_config_path,
    release_version,
    appliance_profile,
    build_catalog_path,
    skip_build,
    skip_install,
    uninstall_first,
    preserve_failed_state,
    bootstrap_admin,
    enable_default_license,
    exit_code,
) = sys.argv[1:16]

run_dir_path = Path(run_dir)
bootstrap_admin_enabled = bootstrap_admin.lower() in ("1", "true", "yes", "on")
payload = {
    "applianceProfile": appliance_profile or None,
    "buildCatalogPath": build_catalog_path or None,
    "buildPublishConfigPath": build_publish_config_path,
    "configPath": config_path,
    "devhostConfigPath": devhost_config_path,
    "exitCode": int(exit_code),
    "installConfigPath": install_config_path,
    "metadataFiles": {
        "bootstrapAdmin": str(run_dir_path / "metadata" / "bootstrap-admin.json"),
        "bootstrapDefaultLicense": str(run_dir_path / "metadata" / "bootstrap-default-license.json"),
        "buildPublish": str(run_dir_path / "metadata" / "build-publish.json"),
        "clientVerify": str(run_dir_path / "metadata" / "client-verify.json"),
        "install": str(run_dir_path / "metadata" / "install.json"),
        "targetVerify": str(run_dir_path / "metadata" / "verify.json"),
    },
    "orchestrator": "run-release-from-devhost.sh",
    "releaseVersion": release_version or None,
    "runDir": str(run_dir_path),
    "status": "passed" if int(exit_code) == 0 else "failed",
    "steps": {
        "bootstrapAdminSkipped": not bootstrap_admin_enabled,
        "bootstrapDefaultLicenseSkipped": enable_default_license.lower() not in ("1", "true", "yes", "on"),
        "buildPublishSkipped": skip_build.lower() in ("1", "true", "yes", "on"),
        "clientVerifySkipped": not bootstrap_admin_enabled,
        "installSkipped": skip_install.lower() in ("1", "true", "yes", "on"),
        "preserveFailedState": preserve_failed_state.lower() in ("1", "true", "yes", "on"),
        "targetVerifySkipped": False,
        "uninstallFirst": uninstall_first.lower() in ("1", "true", "yes", "on"),
    },
}
out = run_dir_path / "metadata" / "run-release-flow.json"
out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"flow metadata → {out}", file=sys.stderr)
PY

  if [[ -f "${SCRIPT_DIR}/summarize-release-run.py" ]]; then
    if python3 "${SCRIPT_DIR}/summarize-release-run.py" \
      --run-dir "${RUN_DIR}" \
      --config "${CONFIG_PATH}" \
      >"${RUN_DIR}/logs/release-report.log" 2>&1; then
      log "report → ${RUN_DIR}/release-report.md"
    else
      log "warning: summarize-release-run.py failed; see ${RUN_DIR}/logs/release-report.log"
    fi
  fi
}

finalize_on_exit() {
  local exit_code="$?"
  if [[ "${CURRENT_STEP}" != "done" ]]; then
    finalize_release_flow "${exit_code}" || true
  fi
  exit "${exit_code}"
}
trap finalize_on_exit EXIT

# ---------------------------------------------------------------------------
# Stage 1 — build + publish on build host
# ---------------------------------------------------------------------------

if ! bool_true "${SKIP_BUILD}"; then
  begin_stage "buildPublish" "build host worker → run-build-and-publish-on-build-host.sh"
  bash "${SCRIPT_DIR}/run-build-and-publish-on-build-host.sh" \
    --config "${DEVHOST_CONFIG_PATH}" \
    --build-publish-config "${BUILD_PUBLISH_CONFIG_PATH}" \
    --run-dir "${RUN_DIR}"
  end_stage
else
  log "── stage buildPublish: skipped (build_flow.skip=true)"
fi

# ---------------------------------------------------------------------------
# Stage 2 — install + admin/license on target host
# ---------------------------------------------------------------------------

if ! bool_true "${SKIP_INSTALL}"; then
  begin_stage "installSetup" "target host worker → run-install-on-target-host.sh"
  bash "${SCRIPT_DIR}/run-install-on-target-host.sh" \
    --config "${DEVHOST_CONFIG_PATH}" \
    --build-publish-config "${BUILD_PUBLISH_CONFIG_PATH}" \
    --install-config "${INSTALL_CONFIG_PATH}" \
    --run-dir "${RUN_DIR}"
  end_stage
else
  log "── stage installSetup: skipped (install.skip=true)"
fi

# ---------------------------------------------------------------------------
# Stages 3–4 — verification from the devhost
# ---------------------------------------------------------------------------

begin_stage "targetVerify" "target host checks from devhost → verify-target.sh"
target_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  target_verify_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
fi
bash "${SCRIPT_DIR}/verify-target.sh" "${target_verify_args[@]}"
end_stage

if bool_true "${BOOTSTRAP_ADMIN}"; then
  begin_stage "clientVerify" "client/API checks from devhost → verify-client-access.sh"
  client_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${APPLIANCE_PROFILE}" ]]; then
    client_verify_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
  fi
  bash "${SCRIPT_DIR}/verify-client-access.sh" "${client_verify_args[@]}"
  end_stage
else
  log "── stage clientVerify: skipped (install.bootstrap_admin=false)"
fi

begin_stage "report" "write flow metadata and release report"
finalize_release_flow 0
end_stage
CURRENT_STEP="done"

trap - EXIT
if bool_true "${FINAL_OK}"; then
  printf 'OK run\n'
fi
