#!/usr/bin/env bash
# run-release-flow.sh — stage orchestrator for the appliance release path.
#
# One config file today (build + install + verify). A future split into two
# configs (build/publish vs install/verify) is planned; keep stage boundaries
# sharp so that split is easy later.
#
# This script is intentionally thin: each stage is mostly a one-liner that
# calls a dedicated helper under the same directory.
#
# Stages (in order):
#   0  prepare         resolve config / run-dir / validate inputs
#   1  buildPublish    build-and-publish.sh   (--skip-build)
#   2  install         install-on-target.sh   (--skip-install)
#   2b bootstrapAdmin  bootstrap-admin-on-target.sh  (--skip-bootstrap-admin)
#   2c targetVerify    verify-target.sh
#   2d clientVerify    verify-client-access.sh  (skipped with bootstrap)
#   3  report          summarize-release-run.py + run metadata
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-release-flow.sh [options]

Thin stage runner. One config today; stages stay ordered so build/publish and
install/verify can later use separate configs without rewriting the flow.

  Stage 0  prepare         config, run-dir, catalog checks
  Stage 1  buildPublish    → build-and-publish.sh
  Stage 2  install         → install-on-target.sh
  Stage 2b bootstrapAdmin  → bootstrap-admin-on-target.sh
  Stage 2c targetVerify    → verify-target.sh
  Stage 2d clientVerify    → verify-client-access.sh
  Stage 3  report          summarize run + write metadata

Options:
  --config PATH              YAML/JSON config (or APPLIANCE_RELEASE_CONFIG /
                             local appliance-release.config.yaml).
  --run-dir DIR              Default: <cwd>/.run/appliance-release/<timestamp>
  --release-version VERSION  Override release.version
  --appliance-profile NAME   Override install.appliance_profile
  --build-catalog PATH       Local build catalog for zonctl (builder profiles)
  --preserve-failed-state    Pass through to install/upgrade
  --uninstall-first          Uninstall previous appliance before install
  --skip-bootstrap-admin     Skip first-admin bootstrap and client verify
  --skip-build               Skip stage 1 (build/publish)
  --skip-install             Skip stage 2 (install)
  --final-ok                 Print "OK run" on success
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
# Args
# ---------------------------------------------------------------------------

CONFIG_PATH=""
RUN_DIR=""
RELEASE_VERSION=""
APPLIANCE_PROFILE=""
BUILD_CATALOG_PATH=""
PRESERVE_FAILED_STATE="false"
UNINSTALL_FIRST="false"
SKIP_BOOTSTRAP_ADMIN="false"
SKIP_BUILD="false"
SKIP_INSTALL="false"
FINAL_OK="false"
CURRENT_STEP="startup"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
    --release-version) RELEASE_VERSION="${2:-}"; shift 2 ;;
    --appliance-profile) APPLIANCE_PROFILE="${2:-}"; shift 2 ;;
    --build-catalog) BUILD_CATALOG_PATH="${2:-}"; shift 2 ;;
    --preserve-failed-state) PRESERVE_FAILED_STATE="true"; shift 1 ;;
    --uninstall-first) UNINSTALL_FIRST="true"; shift 1 ;;
    --skip-bootstrap-admin) SKIP_BOOTSTRAP_ADMIN="true"; shift 1 ;;
    --skip-build) SKIP_BUILD="true"; shift 1 ;;
    --skip-install) SKIP_INSTALL="true"; shift 1 ;;
    --final-ok) FINAL_OK="true"; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Stage 0 — prepare
# ---------------------------------------------------------------------------

begin_stage "prepare" "resolve config and run directory"

CONFIG_PATH="$(require_config_path "${CONFIG_PATH}")"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(config_get_optional "${CONFIG_PATH}" "release.version" || true)"
fi
BUNDLE_STORE_MODE="$(resolve_bundle_store_mode "${CONFIG_PATH}")"
APPLIANCE_PROFILE="$(require_appliance_profile "${CONFIG_PATH}" "${APPLIANCE_PROFILE}")"
[[ -n "${RELEASE_VERSION}" ]] || fail "release.version is required in config (or pass --release-version)"
BUILD_CATALOG_PATH="$(resolve_build_catalog_path "${CONFIG_PATH}" "${BUILD_CATALOG_PATH}")"
require_builder_build_catalog_path "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}"

ensure_release_run_dirs "${RUN_DIR}"

log "run-dir=${RUN_DIR}"
log "config=${CONFIG_PATH}"
log "release=${RELEASE_VERSION} profile=${APPLIANCE_PROFILE}"
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  log "build-catalog=${BUILD_CATALOG_PATH}"
fi
if bool_true "${SKIP_BOOTSTRAP_ADMIN}"; then
  log "bootstrap-admin + client verify skipped (--skip-bootstrap-admin)"
fi

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

  python3 - "${RUN_DIR}/metadata/run-release-flow.json" "${CONFIG_PATH}" "${RUN_DIR}" "${RELEASE_VERSION}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" "${SKIP_BUILD}" "${SKIP_INSTALL}" "${SKIP_BOOTSTRAP_ADMIN}" "${UNINSTALL_FIRST}" "${PRESERVE_FAILED_STATE}" "${exit_code}" <<'PY'
import json
from pathlib import Path
import sys

(
    out_path,
    config_path,
    run_dir,
    release_version,
    appliance_profile,
    build_catalog_path,
    skip_build,
    skip_install,
    skip_bootstrap_admin,
    uninstall_first,
    preserve_failed_state,
    exit_code,
) = sys.argv[1:13]

run_dir_path = Path(run_dir)
exit_code_int = int(exit_code)

payload = {
    "configPath": config_path,
    "runDir": run_dir,
    "releaseVersion": release_version or None,
    "applianceProfile": appliance_profile or None,
    "buildCatalogPath": build_catalog_path or None,
    "status": "passed" if exit_code_int == 0 else "failed",
    "exitCode": exit_code_int,
    "steps": {
        "buildPublishSkipped": skip_build == "true",
        "installSkipped": skip_install == "true",
        "bootstrapAdminSkipped": skip_bootstrap_admin == "true",
        "targetVerifySkipped": False,
        "clientVerifySkipped": skip_bootstrap_admin == "true",
        "uninstallFirst": uninstall_first == "true",
        "preserveFailedState": preserve_failed_state == "true",
    },
    "metadataFiles": {
        "buildPublish": str(run_dir_path / "metadata" / "build-publish.json"),
        "install": str(run_dir_path / "metadata" / "install.json"),
        "bootstrapAdmin": str(run_dir_path / "metadata" / "bootstrap-admin.json"),
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
# STEP 1 — Build & publish  (future: own config file)
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
  log "── stage buildPublish: skipped (--skip-build)"
fi

# ===========================================================================
# STEP 2 — Install & verify  (future: own config file)
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
  log "── stage install: skipped (--skip-install)"
fi

if ! bool_true "${SKIP_BOOTSTRAP_ADMIN}"; then
  begin_stage "bootstrapAdmin" "first-admin bootstrap → bootstrap-admin-on-target.sh"
  bash "${SCRIPT_DIR}/bootstrap-admin-on-target.sh" --config "${CONFIG_PATH}" --run-dir "${RUN_DIR}"
  end_stage
else
  log "── stage bootstrapAdmin: skipped (--skip-bootstrap-admin)"
fi

begin_stage "targetVerify" "target host verification → verify-target.sh"
target_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  target_verify_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
fi
bash "${SCRIPT_DIR}/verify-target.sh" "${target_verify_args[@]}"
end_stage

if ! bool_true "${SKIP_BOOTSTRAP_ADMIN}"; then
  begin_stage "clientVerify" "client/API verification from Mac → verify-client-access.sh"
  client_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${APPLIANCE_PROFILE}" ]]; then
    client_verify_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
  fi
  bash "${SCRIPT_DIR}/verify-client-access.sh" "${client_verify_args[@]}"
  end_stage
else
  log "── stage clientVerify: skipped (follows --skip-bootstrap-admin)"
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
