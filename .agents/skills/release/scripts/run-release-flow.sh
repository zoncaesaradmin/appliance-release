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
  --uninstall-first          Uninstall the previous appliance before install.
  --skip-build               Skip build/publish.
  --skip-install             Skip install.
  --skip-target-verify       Skip target-host verification.
  --skip-client-verify       Skip macOS-side API verification.
  --final-ok                 Print OK run on success.
EOF
}

CONFIG_PATH=""
RUN_DIR=""
RELEASE_VERSION=""
UNINSTALL_FIRST="false"
SKIP_BUILD="false"
SKIP_INSTALL="false"
SKIP_TARGET_VERIFY="false"
SKIP_CLIENT_VERIFY="false"
FINAL_OK="false"

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
    --uninstall-first)
      UNINSTALL_FIRST="true"
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
    --skip-target-verify)
      SKIP_TARGET_VERIFY="true"
      shift 1
      ;;
    --skip-client-verify)
      SKIP_CLIENT_VERIFY="true"
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

ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"

log "release flow run directory: ${RUN_DIR}"
log "using config: ${CONFIG_PATH}"
if [[ -n "${RELEASE_VERSION}" ]]; then
  log "release version: ${RELEASE_VERSION}"
fi

if ! bool_true "${SKIP_BUILD}"; then
  build_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${RELEASE_VERSION}" ]]; then
    build_args+=(--release-version "${RELEASE_VERSION}")
  fi
  log "starting build/publish phase"
  bash "${SCRIPT_DIR}/build-and-publish.sh" "${build_args[@]}"
fi

if ! bool_true "${SKIP_INSTALL}"; then
  install_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  if [[ -n "${RELEASE_VERSION}" ]]; then
    install_args+=(--release-version "${RELEASE_VERSION}")
  fi
  if bool_true "${UNINSTALL_FIRST}"; then
    install_args+=(--uninstall-first)
  fi
  log "starting install phase"
  bash "${SCRIPT_DIR}/install-on-target.sh" "${install_args[@]}"
fi

if ! bool_true "${SKIP_TARGET_VERIFY}"; then
  target_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  log "starting target verification phase"
  bash "${SCRIPT_DIR}/verify-target.sh" "${target_verify_args[@]}"
fi

if ! bool_true "${SKIP_CLIENT_VERIFY}"; then
  client_verify_args=(--config "${CONFIG_PATH}" --run-dir "${RUN_DIR}")
  log "starting client/API verification phase"
  bash "${SCRIPT_DIR}/verify-client-access.sh" "${client_verify_args[@]}"
fi

python3 - "${RUN_DIR}/metadata/run-release-flow.json" "${CONFIG_PATH}" "${RUN_DIR}" "${RELEASE_VERSION}" "${SKIP_BUILD}" "${SKIP_INSTALL}" "${SKIP_TARGET_VERIFY}" "${SKIP_CLIENT_VERIFY}" "${UNINSTALL_FIRST}" <<'PY'
import json
from pathlib import Path
import sys

(
    out_path,
    config_path,
    run_dir,
    release_version,
    skip_build,
    skip_install,
    skip_target_verify,
    skip_client_verify,
    uninstall_first,
) = sys.argv[1:10]

run_dir_path = Path(run_dir)

payload = {
    "configPath": config_path,
    "runDir": run_dir,
    "releaseVersion": release_version or None,
    "steps": {
        "buildPublishSkipped": skip_build == "true",
        "installSkipped": skip_install == "true",
        "targetVerifySkipped": skip_target_verify == "true",
        "clientVerifySkipped": skip_client_verify == "true",
        "uninstallFirst": uninstall_first == "true",
    },
    "metadataFiles": {
        "buildPublish": str(run_dir_path / "metadata" / "build-publish.json"),
        "install": str(run_dir_path / "metadata" / "install.json"),
        "targetVerify": str(run_dir_path / "metadata" / "verify.json"),
        "clientVerify": str(run_dir_path / "metadata" / "client-verify.json"),
    },
}

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log "release flow metadata written to ${RUN_DIR}/metadata/run-release-flow.json"
if bool_true "${FINAL_OK}"; then
  printf 'OK run\n'
fi
