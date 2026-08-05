#!/usr/bin/env bash
# run-release-flow.sh — stage orchestrator for the appliance release path.
#
# Three host/role config files (all required):
#   --config PATH                 Devhost: build_host, target_host, report
#   --build-publish-config PATH   Build host content: workspace, release, build_flow, bundle_store
#   --install-config PATH         Target install + verify blocks
#
# The three are merged (disjoint keys) into one temporary config for stage
# workers (build-and-publish.sh, install-on-target.sh, …). See:
#   references/config.example.yaml
#
# Stages (in order; gated by staged config keys):
#   0  prepare         resolve configs / merge / run-dir / validate
#   1  buildPublish    build-and-publish.sh     (unless build_flow.skip)
#   2  install         install-on-target.sh     (unless install.skip)
#   2b bootstrapAdmin  bootstrap-admin-on-target.sh  (if install.bootstrap_admin)
#   2b2 bootstrapDefaultLicense  bootstrap-default-license-on-target.sh
#                                  (if install.enable_default_license)
#   2c targetVerify    verify-target.sh
#   2d clientVerify    verify-client-access.sh  (if install.bootstrap_admin)
#   3  report          summarize-release-run.py + run metadata
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-release-flow.sh \
  --config PATH \
  --build-publish-config PATH \
  --install-config PATH

CLI options (only these three paths, plus --help):

  --config PATH                 Devhost orchestration config.
                                Top-level keys only:
                                  build_host, target_host, report
  --build-publish-config PATH   Build + publish config.
                                Top-level keys only:
                                  release_workspace, release, build_flow, bundle_store
  --install-config PATH         Install + verify config.
                                Top-level keys only:
                                  install, verification, client_verification

Examples (schema):
  .agents/skills/release/references/config.devhost.example.yaml
  .agents/skills/release/references/config.build-publish.example.yaml
  .agents/skills/release/references/config.install.example.yaml

Stage switches live next to the stage they control, e.g.:
  build_flow.skip                 (build-publish file)
  install.skip / uninstall_first / preserve_failed_state /
    bootstrap_admin / enable_default_license   (install file)
  report.final_ok                 (devhost file)

Secrets remain shell env (e.g. APPLIANCE_*_PASSWORD, DEV_REGISTRY*), not CLI.

Example:
  bash .agents/skills/release/scripts/run-release-flow.sh \
    --config ~/lab-devhost.yaml \
    --build-publish-config ~/lab-build-publish.yaml \
    --install-config ~/lab-install.yaml
EOF
}

# ---------------------------------------------------------------------------
# Stage helpers (console progress only; keep noise low)
# ---------------------------------------------------------------------------

begin_stage() {
  # CURRENT_STEP is also used by finalize_release_flow for crash metadata.
  CURRENT_STEP="$1"
  log "── stage ${CURRENT_STEP}: $2"
}

end_stage() {
  log "── stage ${CURRENT_STEP}: done"
}

# ---------------------------------------------------------------------------
# CLI: three config paths only (plus --help)
# ---------------------------------------------------------------------------

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
      fail "run-release-flow.sh only accepts --config, --build-publish-config, and --install-config (got: $*). See --help."
      ;;
  esac
done

[[ -n "${DEVHOST_CONFIG_PATH}" ]] || fail "run-release-flow.sh requires --config PATH (Devhost orchestration config; see --help)"
[[ -n "${BUILD_PUBLISH_CONFIG_PATH}" ]] || fail "run-release-flow.sh requires --build-publish-config PATH (see --help)"
[[ -n "${INSTALL_CONFIG_PATH}" ]] || fail "run-release-flow.sh requires --install-config PATH (see --help)"

# ---------------------------------------------------------------------------
# Stage 0 — prepare
# ---------------------------------------------------------------------------

begin_stage "prepare" "resolve configs, merge, and run directory"

DEVHOST_CONFIG_PATH="$(require_config_path "${DEVHOST_CONFIG_PATH}")"
BUILD_PUBLISH_CONFIG_PATH="$(require_config_path "${BUILD_PUBLISH_CONFIG_PATH}")"
INSTALL_CONFIG_PATH="$(require_config_path "${INSTALL_CONFIG_PATH}")"

# Provisional run-dir from devhost report (before merge) so merge output can live under it.
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
  fail "config key 'flow' was removed; use build_flow.skip, install.skip / install.uninstall_first / install.preserve_failed_state / install.bootstrap_admin / install.enable_default_license, and report.final_ok"
fi

SKIP_BUILD="$(config_require_bool "${CONFIG_PATH}" "build_flow.skip")"
SKIP_INSTALL="$(config_require_bool "${CONFIG_PATH}" "install.skip")"
UNINSTALL_FIRST="$(config_require_bool "${CONFIG_PATH}" "install.uninstall_first")"
PRESERVE_FAILED_STATE="$(config_require_bool "${CONFIG_PATH}" "install.preserve_failed_state")"
BOOTSTRAP_ADMIN="$(config_require_bool "${CONFIG_PATH}" "install.bootstrap_admin")"
ENABLE_DEFAULT_LICENSE="$(config_require_bool "${CONFIG_PATH}" "install.enable_default_license")"
FINAL_OK="$(config_require_bool "${CONFIG_PATH}" "report.final_ok")"

# Prefer report.run_dir after merge (same key path).
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
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  log "build-catalog=${BUILD_CATALOG_PATH}"
fi
log "stages: build_flow.skip=${SKIP_BUILD} install.skip=${SKIP_INSTALL} uninstall_first=${UNINSTALL_FIRST} preserve_failed_state=${PRESERVE_FAILED_STATE} bootstrap_admin=${BOOTSTRAP_ADMIN} enable_default_license=${ENABLE_DEFAULT_LICENSE} report.final_ok=${FINAL_OK}"

validate_builder_build_catalog "${SCRIPT_DIR}" "${CONFIG_PATH}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" "${RUN_DIR}" "build-catalog validation ok"

end_stage

# ---------------------------------------------------------------------------
# Finalize helpers (trap writes metadata if a stage fails mid-flow)
# ---------------------------------------------------------------------------

FLOW_FINALIZED="false"
finalize_release_flow() {
  local exit_code="${1:-0}"
  if bool_true "${FLOW_FINALIZED}"; then
    return 0
  fi
  FLOW_FINALIZED="true"

  if [[ "${CURRENT_STEP}" == "install" ]] \
    && ! bool_true "${SKIP_INSTALL}" \
    && [[ ! -f "${RUN_DIR}/metadata/install.json" ]] \
    && [[ -f "${RUN_DIR}/logs/install.log" ]]; then
    local install_mode="install"
    if grep -Fq "Existing owned appliance detected. Switching to in-place upgrade/reconcile." "${RUN_DIR}/logs/install.log"; then
      install_mode="upgrade"
    fi
    python3 - "${RUN_DIR}/metadata/install.json" "${CONFIG_PATH}" "${RELEASE_VERSION}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" "${BUNDLE_STORE_MODE}" "${install_mode}" "${UNINSTALL_FIRST}" "${PRESERVE_FAILED_STATE}" "${RUN_DIR}/logs/install.log" "${exit_code}" <<'PY'
import json
import sys
from pathlib import Path

(
    out_path,
    config_path,
    release_version,
    appliance_profile,
    build_catalog_path,
    distribution_mode,
    install_mode,
    uninstall_first,
    preserve_failed_state,
    install_log,
    exit_code,
) = sys.argv[1:12]

install_method = {
    "static_http": "direct-static_http-zonctl-auto",
    "appliance_files": "direct-appliance_files-zonctl-auto",
}.get(distribution_mode, f"direct-{distribution_mode}-zonctl-auto")

payload = {
    "configPath": config_path,
    "targetHost": None,
    "helperUrl": None,
    "installMethod": install_method,
    "distributionMode": distribution_mode,
    "releaseVersion": release_version or None,
    "baseUrl": None,
    "pathPrefix": None,
    "stateDir": None,
    "outDir": None,
    "bundleDir": f"/tmp/appliance-{release_version}/appliance-{release_version}-bundle" if release_version else None,
    "applianceProfile": appliance_profile or None,
    "buildCatalogPath": build_catalog_path or None,
    "installMode": install_mode,
    "outputFormat": "text",
    "uninstallFirst": uninstall_first == "true",
    "preserveFailedState": preserve_failed_state == "true",
    "log": install_log,
    "status": "passed" if int(exit_code) == 0 else "failed",
    "exitCode": int(exit_code),
}

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  fi

  python3 - "${RUN_DIR}/metadata/run-release-flow.json" \
    "${DEVHOST_CONFIG_PATH}" "${BUILD_PUBLISH_CONFIG_PATH}" "${INSTALL_CONFIG_PATH}" "${CONFIG_PATH}" \
    "${RUN_DIR}" "${RELEASE_VERSION}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" \
    "${SKIP_BUILD}" "${SKIP_INSTALL}" "${BOOTSTRAP_ADMIN}" "${ENABLE_DEFAULT_LICENSE}" \
    "${UNINSTALL_FIRST}" "${PRESERVE_FAILED_STATE}" "${exit_code}" <<'PY'
import json
from pathlib import Path
import sys

(
    out_path,
    devhost_config_path,
    build_publish_config_path,
    install_config_path,
    merged_config_path,
    run_dir,
    release_version,
    appliance_profile,
    build_catalog_path,
    skip_build,
    skip_install,
    bootstrap_admin,
    enable_default_license,
    uninstall_first,
    preserve_failed_state,
    exit_code,
) = sys.argv[1:17]

run_dir_path = Path(run_dir)
exit_code_int = int(exit_code)
bootstrap_admin_enabled = bootstrap_admin.lower() in ("1", "true", "yes", "on")
default_license_enabled = enable_default_license.lower() in ("1", "true", "yes", "on")

payload = {
    "devhostConfigPath": devhost_config_path,
    "buildPublishConfigPath": build_publish_config_path,
    "installConfigPath": install_config_path,
    "configPath": merged_config_path,
    "runDir": run_dir,
    "releaseVersion": release_version or None,
    "applianceProfile": appliance_profile or None,
    "buildCatalogPath": build_catalog_path or None,
    "status": "passed" if exit_code_int == 0 else "failed",
    "exitCode": exit_code_int,
    "steps": {
        "buildPublishSkipped": skip_build == "true",
        "installSkipped": skip_install == "true",
        "bootstrapAdminSkipped": not bootstrap_admin_enabled,
        "bootstrapDefaultLicenseSkipped": not default_license_enabled,
        "targetVerifySkipped": False,
        "clientVerifySkipped": not bootstrap_admin_enabled,
        "uninstallFirst": uninstall_first == "true",
        "preserveFailedState": preserve_failed_state == "true",
    },
    "metadataFiles": {
        "buildPublish": str(run_dir_path / "metadata" / "build-publish.json"),
        "install": str(run_dir_path / "metadata" / "install.json"),
        "bootstrapAdmin": str(run_dir_path / "metadata" / "bootstrap-admin.json"),
        "bootstrapDefaultLicense": str(run_dir_path / "metadata" / "bootstrap-default-license.json"),
        "targetVerify": str(run_dir_path / "metadata" / "verify.json"),
        "clientVerify": str(run_dir_path / "metadata" / "client-verify.json"),
    },
}

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "flow metadata → ${RUN_DIR}/metadata/run-release-flow.json"
  if python3 "${SCRIPT_DIR}/summarize-release-run.py" --run-dir "${RUN_DIR}" \
    >"${RUN_DIR}/logs/release-report.log" 2>&1; then
    log "report → ${RUN_DIR}/release-report.md"
  else
    log "report generation failed; see ${RUN_DIR}/logs/release-report.log"
  fi
}

finalize_on_exit() {
  local exit_code="$?"
  if [[ "${exit_code}" -ne 0 ]]; then
    finalize_release_flow "${exit_code}" || true
  fi
  exit "${exit_code}"
}
trap finalize_on_exit EXIT

# ===========================================================================
# STEP 1 — Build & publish
# ===========================================================================

if ! bool_true "${SKIP_BUILD}"; then
  begin_stage "buildPublish" "build and publish on build host → build-and-publish.sh"
  build_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${RELEASE_VERSION}" ]]; then
    build_args+=(--release-version "${RELEASE_VERSION}")
  fi
  bash "${SCRIPT_DIR}/build-and-publish.sh" "${build_args[@]}"
  end_stage
else
  log "── stage buildPublish: skipped (build_flow.skip=true)"
fi

# ===========================================================================
# STEP 2 — Install & verify
# ===========================================================================

if ! bool_true "${SKIP_INSTALL}"; then
  begin_stage "install" "install on target → install-on-target.sh"
  install_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${RELEASE_VERSION}" ]]; then
    install_args+=(--release-version "${RELEASE_VERSION}")
  fi
  if [[ -n "${APPLIANCE_PROFILE}" ]]; then
    install_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
  fi
  if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
    install_args+=(--build-catalog "${BUILD_CATALOG_PATH}")
  fi
  if bool_true "${PRESERVE_FAILED_STATE}"; then
    install_args+=(--preserve-failed-state)
  fi
  if bool_true "${UNINSTALL_FIRST}"; then
    install_args+=(--uninstall-first)
  fi
  bash "${SCRIPT_DIR}/install-on-target.sh" "${install_args[@]}"
  end_stage
else
  log "── stage install: skipped (install.skip=true)"
fi

if bool_true "${BOOTSTRAP_ADMIN}"; then
  begin_stage "bootstrapAdmin" "first-admin bootstrap → bootstrap-admin-on-target.sh"
  bash "${SCRIPT_DIR}/bootstrap-admin-on-target.sh" --config "${CONFIG_PATH}" --run-dir "${RUN_DIR}"
  end_stage
else
  log "── stage bootstrapAdmin: skipped (install.bootstrap_admin=false)"
fi

if bool_true "${ENABLE_DEFAULT_LICENSE}"; then
  begin_stage "bootstrapDefaultLicense" "default/base license → bootstrap-default-license-on-target.sh"
  bash "${SCRIPT_DIR}/bootstrap-default-license-on-target.sh" --config "${CONFIG_PATH}" --run-dir "${RUN_DIR}"
  end_stage
else
  log "── stage bootstrapDefaultLicense: skipped (install.enable_default_license=false)"
fi

begin_stage "targetVerify" "target host verification → verify-target.sh"
target_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  target_verify_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
fi
bash "${SCRIPT_DIR}/verify-target.sh" "${target_verify_args[@]}"
end_stage

if bool_true "${BOOTSTRAP_ADMIN}"; then
  begin_stage "clientVerify" "client/API verification from Mac → verify-client-access.sh"
  client_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${APPLIANCE_PROFILE}" ]]; then
    client_verify_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
  fi
  bash "${SCRIPT_DIR}/verify-client-access.sh" "${client_verify_args[@]}"
  end_stage
else
  log "── stage clientVerify: skipped (install.bootstrap_admin=false)"
fi

# ===========================================================================
# STEP 3 — Report
# ===========================================================================

begin_stage "report" "write flow metadata and release report"
finalize_release_flow 0
end_stage
CURRENT_STEP="done"

trap - EXIT
if bool_true "${FINAL_OK}"; then
  printf 'OK run\n'
fi
