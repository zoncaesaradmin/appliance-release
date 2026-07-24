#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-release-flow.sh [options]

Run the common Zon appliance release flow from the appliance-release repo:
1. build and publish on the build host
2. install on the target host
3. verify on the target host
4. verify client/API access from macOS

Options:
  --config PATH              YAML or JSON config file. Optional if
                             APPLIANCE_RELEASE_CONFIG is set or a local
                             appliance-release.config.yaml exists.
  --run-dir DIR              Run directory. Default: <repo>/.run/appliance-release/<timestamp>
  --release-version VERSION  Release version override.
  --appliance-profile NAME   Install-time appliance profile override.
  --build-catalog PATH       Local build catalog JSON/YAML passed to zonctl.
  --preserve-failed-state    Pass zonctl's debug preserve-failed-state mode
                             through to install/upgrade on the target.
  --uninstall-first          Uninstall the previous appliance before install.
  --skip-bootstrap-admin     Skip explicit first-admin creation and leave
                             setup to the appliance UI or a later manual
                             bootstrap step.
  --skip-build               Skip build/publish.
  --skip-install             Skip install.
  --final-ok                 Print OK run on success.
EOF
}

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
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    --release-version)
      RELEASE_VERSION="${2:-}"
      shift 2
      ;;
    --appliance-profile)
      APPLIANCE_PROFILE="${2:-}"
      shift 2
      ;;
    --build-catalog)
      BUILD_CATALOG_PATH="${2:-}"
      shift 2
      ;;
    --preserve-failed-state)
      PRESERVE_FAILED_STATE="true"
      shift 1
      ;;
    --uninstall-first)
      UNINSTALL_FIRST="true"
      shift 1
      ;;
    --skip-bootstrap-admin)
      SKIP_BOOTSTRAP_ADMIN="true"
      shift 1
      ;;
    --skip-build)
      SKIP_BUILD="true"
      shift 1
      ;;
    --skip-install)
      SKIP_INSTALL="true"
      shift 1
      ;;
    --final-ok)
      FINAL_OK="true"
      shift 1
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

CONFIG_PATH="$(resolve_config_path "${CONFIG_PATH}" || true)"
[[ -n "${CONFIG_PATH}" ]] || fail "config not provided; use --config or APPLIANCE_RELEASE_CONFIG"
ensure_file "${CONFIG_PATH}"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="${PWD}/.run/appliance-release/$(date -u +%Y%m%dT%H%M%SZ)"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(config_get_optional "${CONFIG_PATH}" "release.version" || true)"
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="$(config_get_optional "${CONFIG_PATH}" "install.appliance_profile" || true)"
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi
if [[ -z "${BUILD_CATALOG_PATH}" ]]; then
  BUILD_CATALOG_PATH="$(config_get_optional "${CONFIG_PATH}" "install.build_catalog_path" || true)"
fi
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  ensure_file "${BUILD_CATALOG_PATH}"
fi
if [[ "${APPLIANCE_PROFILE}" == "builder" && -z "${BUILD_CATALOG_PATH}" ]]; then
  fail "builder appliance profile requires install.build_catalog_path or --build-catalog; start from .agents/skills/release/references/build-catalog.example.yaml"
fi
ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"

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
    python3 - "${RUN_DIR}/metadata/install.json" "${CONFIG_PATH}" "${RELEASE_VERSION}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" "${UNINSTALL_FIRST}" "${PRESERVE_FAILED_STATE}" "${RUN_DIR}/logs/install.log" "${exit_code}" <<'PY'
import json
import sys
from pathlib import Path

(
    out_path,
    config_path,
    release_version,
    appliance_profile,
    build_catalog_path,
    uninstall_first,
    preserve_failed_state,
    install_log,
    exit_code,
) = sys.argv[1:10]

payload = {
    "configPath": config_path,
    "targetHost": None,
    "helperUrl": None,
    "installMethod": "direct-http-zonctl-auto",
    "releaseVersion": release_version or None,
    "baseUrl": None,
    "pathPrefix": None,
    "stateDir": None,
    "outDir": None,
    "bundleDir": f"/tmp/appliance-{release_version}/appliance-{release_version}-bundle" if release_version else None,
    "applianceProfile": appliance_profile or None,
    "buildCatalogPath": build_catalog_path or None,
    "outputFormat": "text",
    "uninstallFirst": uninstall_first == "true",
    "preserveFailedState": preserve_failed_state == "true",
    "log": install_log,
    "status": "passed" if int(exit_code) == 0 else "failed",
    "exitCode": int(exit_code),
    "inferred": True,
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
        "releaseReportJson": str(run_dir_path / "metadata" / "release-report.json"),
        "releaseReportMarkdown": str(run_dir_path / "release-report.md"),
    },
}

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "release flow metadata written to ${RUN_DIR}/metadata/run-release-flow.json"
  if python3 "${SCRIPT_DIR}/summarize-release-run.py" --run-dir "${RUN_DIR}" \
    >"${RUN_DIR}/logs/release-report.log" 2>&1; then
    log "release report written to ${RUN_DIR}/metadata/release-report.json and ${RUN_DIR}/release-report.md"
  else
    log "release report generation failed; log: ${RUN_DIR}/logs/release-report.log"
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

log "release flow run directory: ${RUN_DIR}"
log "using config: ${CONFIG_PATH}"
if [[ -n "${RELEASE_VERSION}" ]]; then
  log "release version: ${RELEASE_VERSION}"
fi
if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  log "appliance profile: ${APPLIANCE_PROFILE}"
fi
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  log "build catalog: ${BUILD_CATALOG_PATH}"
fi
if bool_true "${SKIP_BOOTSTRAP_ADMIN}"; then
  log "bootstrap-admin is skipped; client/API verification will also be skipped so first-user setup can be completed later in the UI"
fi
if [[ "${APPLIANCE_PROFILE}" == "builder" && -n "${BUILD_CATALOG_PATH}" ]]; then
  catalog_validation_log="${RUN_DIR}/logs/build-catalog-validation.json"
  if ! python3 "${SCRIPT_DIR}/validate-build-catalog.py" \
    --config "${CONFIG_PATH}" \
    --build-catalog "${BUILD_CATALOG_PATH}" \
    --output-json "${catalog_validation_log}" \
    >"${catalog_validation_log}.stdout" 2>"${catalog_validation_log}.stderr"; then
    fail "builder build catalog validation failed; see ${catalog_validation_log}"
  fi
  log "builder build catalog validation completed; log: ${catalog_validation_log}"
fi

if ! bool_true "${SKIP_BUILD}"; then
  CURRENT_STEP="buildPublish"
  build_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${RELEASE_VERSION}" ]]; then
    build_args+=(--release-version "${RELEASE_VERSION}")
  fi
  log "starting build/publish phase"
  bash "${SCRIPT_DIR}/build-and-publish.sh" "${build_args[@]}"
fi

if ! bool_true "${SKIP_INSTALL}"; then
  CURRENT_STEP="install"
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
  log "starting install phase"
  bash "${SCRIPT_DIR}/install-on-target.sh" "${install_args[@]}"
fi

if ! bool_true "${SKIP_BOOTSTRAP_ADMIN}"; then
  CURRENT_STEP="bootstrapAdmin"
  log "starting explicit first-admin bootstrap phase"
  bash "${SCRIPT_DIR}/bootstrap-admin-on-target.sh" --config "${CONFIG_PATH}" --run-dir "${RUN_DIR}"
fi

target_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  target_verify_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
fi
CURRENT_STEP="targetVerify"
log "starting target verification phase"
bash "${SCRIPT_DIR}/verify-target.sh" "${target_verify_args[@]}"

if ! bool_true "${SKIP_BOOTSTRAP_ADMIN}"; then
  CURRENT_STEP="clientVerify"
  client_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${APPLIANCE_PROFILE}" ]]; then
    client_verify_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
  fi
  log "starting client/API verification phase"
  bash "${SCRIPT_DIR}/verify-client-access.sh" "${client_verify_args[@]}"
fi

CURRENT_STEP="done"

finalize_release_flow 0
trap - EXIT
if bool_true "${FINAL_OK}"; then
  printf 'OK run\n'
fi
