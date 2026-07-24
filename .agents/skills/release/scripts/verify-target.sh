#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: verify-target.sh [options]

Run post-install verification on the configured target host. The script captures
logs for each check and, on failure, runs an optional failure-log command.

Options:
  --config PATH                  YAML or JSON config file. Optional if
                                 APPLIANCE_RELEASE_CONFIG is set or a local
                                 appliance-release.config.yaml exists.
  --status-cmd CMD               Override verification.status_command.
  --verify-cmd CMD               Override verification.verify_command.
  --service-health-cmd CMD       Override verification.service_health_command.
  --app-version-cmd CMD          Override verification.app_version_command.
  --smoke-test-cmd CMD           Override verification.smoke_test_command.
  --ui-home-cmd CMD              Override verification.ui_home_command.
  --appliance-profile NAME       Effective installed appliance profile.
  --builder-api-cmd CMD          Override verification.builder.api_command.
  --builder-source-credentials-cmd CMD
                                 Legacy override for verification.builder.source_credentials_command.
  --artifact-readiness-cmd CMD   Override verification.artifact.readiness_command.
  --failure-log-cmd CMD          Override verification.failure_log_command.
  --argo-namespaces-cmd CMD      Override verification.argo.namespaces_command.
  --argo-crds-cmd CMD            Override verification.argo.crds_command.
  --argo-controller-cmd CMD      Override verification.argo.controller_command.
  --final-ok                     Print ok when all checks pass.
  --run-dir DIR                  Local run directory.
EOF
}

CONFIG_PATH=""
STATUS_CMD=""
VERIFY_CMD=""
SERVICE_HEALTH_CMD=""
APP_VERSION_CMD=""
SMOKE_TEST_CMD=""
UI_HOME_CMD=""
APPLIANCE_PROFILE=""
BUILDER_API_CMD=""
BUILDER_SOURCE_CREDENTIALS_CMD=""
ARTIFACT_READINESS_CMD=""
FAILURE_LOG_CMD=""
ARGO_NAMESPACES_CMD=""
ARGO_CRDS_CMD=""
ARGO_CONTROLLER_CMD=""
FINAL_OK="false"
RUN_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --status-cmd)
      STATUS_CMD="${2:-}"
      shift 2
      ;;
    --verify-cmd)
      VERIFY_CMD="${2:-}"
      shift 2
      ;;
    --service-health-cmd)
      SERVICE_HEALTH_CMD="${2:-}"
      shift 2
      ;;
    --app-version-cmd)
      APP_VERSION_CMD="${2:-}"
      shift 2
      ;;
    --smoke-test-cmd)
      SMOKE_TEST_CMD="${2:-}"
      shift 2
      ;;
    --ui-home-cmd)
      UI_HOME_CMD="${2:-}"
      shift 2
      ;;
    --appliance-profile)
      APPLIANCE_PROFILE="${2:-}"
      shift 2
      ;;
    --builder-api-cmd)
      BUILDER_API_CMD="${2:-}"
      shift 2
      ;;
    --builder-source-credentials-cmd)
      BUILDER_SOURCE_CREDENTIALS_CMD="${2:-}"
      shift 2
      ;;
    --artifact-readiness-cmd)
      ARTIFACT_READINESS_CMD="${2:-}"
      shift 2
      ;;
    --failure-log-cmd)
      FAILURE_LOG_CMD="${2:-}"
      shift 2
      ;;
    --argo-namespaces-cmd)
      ARGO_NAMESPACES_CMD="${2:-}"
      shift 2
      ;;
    --argo-crds-cmd)
      ARGO_CRDS_CMD="${2:-}"
      shift 2
      ;;
    --argo-controller-cmd)
      ARGO_CONTROLLER_CMD="${2:-}"
      shift 2
      ;;
    --final-ok)
      FINAL_OK="true"
      shift 1
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
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
  RUN_DIR="$(pwd)/.run/appliance-release/$(date -u +%Y%m%dT%H%M%SZ)"
fi

TARGET_HOST="$(config_get "${CONFIG_PATH}" "target_host.alias")"
TARGET_STATE_DIR="$(config_get_optional "${CONFIG_PATH}" "target_host.state_dir" || true)"
STATUS_CMD="${STATUS_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.status_command" || true)}"
VERIFY_CMD="${VERIFY_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.verify_command" || true)}"
SERVICE_HEALTH_CMD="${SERVICE_HEALTH_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.service_health_command" || true)}"
APP_VERSION_CMD="${APP_VERSION_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.app_version_command" || true)}"
SMOKE_TEST_CMD="${SMOKE_TEST_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.smoke_test_command" || true)}"
UI_HOME_CMD="${UI_HOME_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.ui_home_command" || true)}"
BUILDER_ENABLED="$(config_get_optional "${CONFIG_PATH}" "verification.builder.enabled" || true)"
BUILDER_API_CMD="${BUILDER_API_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.builder.api_command" || true)}"
BUILDER_SOURCE_CREDENTIALS_CMD="${BUILDER_SOURCE_CREDENTIALS_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.builder.source_credentials_command" || true)}"
ARTIFACT_ENABLED="$(config_get_optional "${CONFIG_PATH}" "verification.artifact.enabled" || true)"
ARTIFACT_READINESS_CMD="${ARTIFACT_READINESS_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.artifact.readiness_command" || true)}"
FAILURE_LOG_CMD="${FAILURE_LOG_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.failure_log_command" || true)}"
SMOKE_TEST_RETRIES="${SMOKE_TEST_RETRIES:-$(config_get_optional "${CONFIG_PATH}" "verification.smoke_test_retries" || true)}"
SMOKE_TEST_RETRY_DELAY_SECONDS="${SMOKE_TEST_RETRY_DELAY_SECONDS:-$(config_get_optional "${CONFIG_PATH}" "verification.smoke_test_retry_delay_seconds" || true)}"
ARGO_ENABLED="$(config_get_optional "${CONFIG_PATH}" "verification.argo.enabled" || true)"
ARGO_NAMESPACES_CMD="${ARGO_NAMESPACES_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.argo.namespaces_command" || true)}"
ARGO_CRDS_CMD="${ARGO_CRDS_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.argo.crds_command" || true)}"
ARGO_CONTROLLER_CMD="${ARGO_CONTROLLER_CMD:-$(config_get_optional "${CONFIG_PATH}" "verification.argo.controller_command" || true)}"
ALLOW_INGRESS_WARNING="$(config_get_optional "${CONFIG_PATH}" "verification.allow_ingress_warning" || true)"
ALLOW_VERIFY_SCHEMA_BUG="$(config_get_optional "${CONFIG_PATH}" "verification.allow_verify_schema_bug" || true)"
CLIENT_BASE_URL="$(config_get_optional "${CONFIG_PATH}" "client_verification.base_url" || true)"
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="$(config_get_optional "${CONFIG_PATH}" "install.appliance_profile" || true)"
fi
STATUS_CMD="${STATUS_CMD:-sudo zonctl status --output json}"
VERIFY_CMD="${VERIFY_CMD:-sudo zonctl verify --output json}"
SERVICE_HEALTH_CMD="${SERVICE_HEALTH_CMD:-sudo kubectl get pods -A}"
APP_VERSION_CMD="${APP_VERSION_CMD:-sudo zonctl status --output json}"
FAILURE_LOG_CMD="${FAILURE_LOG_CMD:-sudo zonctl support-bundle --output json}"

profile_supports_workflows() {
  case "$1" in
    core|builder) return 0 ;;
    *) return 1 ;;
  esac
}

ARGO_SKIP_REASON=""
if [[ -z "${ARGO_ENABLED}" ]]; then
  if profile_supports_workflows "${APPLIANCE_PROFILE}"; then
    ARGO_ENABLED="true"
  else
    ARGO_ENABLED="false"
  fi
fi
if [[ -z "${BUILDER_ENABLED}" ]]; then
  if [[ "${APPLIANCE_PROFILE}" == "builder" ]]; then
    BUILDER_ENABLED="true"
  else
    BUILDER_ENABLED="false"
  fi
fi
if [[ -z "${ARTIFACT_ENABLED}" ]]; then
  case "${APPLIANCE_PROFILE}" in
    storage|builder) ARTIFACT_ENABLED="true" ;;
    *) ARTIFACT_ENABLED="false" ;;
  esac
fi
if bool_true "${ARTIFACT_ENABLED}"; then
  ARTIFACT_READINESS_CMD="${ARTIFACT_READINESS_CMD:-sudo kubectl -n registry wait --for=condition=Available deployment/appliance-registry --timeout=120s && sudo kubectl -n registry get pvc appliance-registry-data}"
fi
if [[ -z "${SMOKE_TEST_RETRIES}" ]]; then
  SMOKE_TEST_RETRIES="5"
fi
if [[ -z "${SMOKE_TEST_RETRY_DELAY_SECONDS}" ]]; then
  SMOKE_TEST_RETRY_DELAY_SECONDS="3"
fi
if [[ -n "${ARGO_NAMESPACES_CMD}" || -n "${ARGO_CRDS_CMD}" || -n "${ARGO_CONTROLLER_CMD}" ]]; then
  ARGO_ENABLED="true"
fi
if bool_true "${ARGO_ENABLED}" && ! profile_supports_workflows "${APPLIANCE_PROFILE}"; then
  ARGO_ENABLED="false"
  ARGO_SKIP_REASON="skipping Argo verification because appliance profile ${APPLIANCE_PROFILE:-unknown} does not enable workflows"
  ARGO_NAMESPACES_CMD=""
  ARGO_CRDS_CMD=""
  ARGO_CONTROLLER_CMD=""
  log "${ARGO_SKIP_REASON}"
fi
if bool_true "${ARGO_ENABLED}"; then
  ARGO_NAMESPACES_CMD="${ARGO_NAMESPACES_CMD:-sudo kubectl get namespace workflows appliance-builds}"
  ARGO_CRDS_CMD="${ARGO_CRDS_CMD:-sudo kubectl get crd workflows.argoproj.io workflowtemplates.argoproj.io cronworkflows.argoproj.io}"
  ARGO_CONTROLLER_CMD="${ARGO_CONTROLLER_CMD:-sudo kubectl -n workflows wait --for=condition=Available deployment --all --timeout=120s && sudo kubectl -n workflows get deploy,pods}"
fi

if [[ -n "${CLIENT_BASE_URL}" ]]; then
  rewritten_smoke_test="${SMOKE_TEST_CMD//https:\/\/127.0.0.1\/api\/v1\/auth\/session/${CLIENT_BASE_URL}\/api\/v1\/auth\/session}"
  rewritten_smoke_test="${rewritten_smoke_test//https:\/\/localhost\/api\/v1\/auth\/session/${CLIENT_BASE_URL}\/api\/v1\/auth\/session}"
  if [[ "${rewritten_smoke_test}" != "${SMOKE_TEST_CMD}" ]]; then
    SMOKE_TEST_CMD="${rewritten_smoke_test}"
    log "rewrote localhost smoke test to use client_verification.base_url: ${CLIENT_BASE_URL}"
  fi
  if [[ -z "${UI_HOME_CMD}" ]]; then
    UI_HOME_CMD="body=\$(curl -kfsS $(shell_quote "${CLIENT_BASE_URL}/")) && printf '%s' \"\$body\" | grep -Eiq '<!doctype html|<html' && printf '%s' \"\$body\" | grep -Eiq 'Zon Appliance|Sign in to continue|Appliance status|Create first administrator'"
  fi
  if bool_true "${BUILDER_ENABLED}" && [[ -z "${BUILDER_API_CMD}" ]]; then
    BUILDER_API_CMD="code=\$(curl -ksS -o /dev/null -w '%{http_code}' $(shell_quote "${CLIENT_BASE_URL}/api/v1/work-profiles")) && [ \"\$code\" != \"404\" ]"
  fi
fi

ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"

read_install_metadata_value() {
  local metadata_path="$1"
  local key="$2"
  python3 - "${metadata_path}" "${key}" <<'PY'
import json
import sys
from pathlib import Path

metadata_path = Path(sys.argv[1])
key = sys.argv[2]

if not metadata_path.is_file():
    raise SystemExit(1)

data = json.loads(metadata_path.read_text(encoding="utf-8"))
value = data.get(key)
if value in (None, ""):
    raise SystemExit(1)
print(value)
PY
}

INSTALL_METADATA_PATH="${RUN_DIR}/metadata/install.json"
BUNDLE_DIR=""
BUNDLE_BIN_DIR=""
TARGET_SUDO_PASSWORD="$(resolve_secret "APPLIANCE_TARGET_SUDO_PASSWORD" "Target host sudo password")"
DEFAULT_TARGET_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
RELEASE_VERSION="$(config_get_optional "${CONFIG_PATH}" "release.version" || true)"

if [[ -f "${INSTALL_METADATA_PATH}" ]]; then
  BUNDLE_DIR="$(read_install_metadata_value "${INSTALL_METADATA_PATH}" "bundleDir" || true)"
  TARGET_STATE_DIR="${TARGET_STATE_DIR:-$(read_install_metadata_value "${INSTALL_METADATA_PATH}" "stateDir" || true)}"
  if [[ -n "${BUNDLE_DIR}" ]]; then
    BUNDLE_BIN_DIR="${BUNDLE_DIR}/bin"
  fi
fi
if [[ -z "${BUNDLE_DIR}" && -n "${RELEASE_VERSION}" ]]; then
  BUNDLE_DIR="/tmp/appliance-${RELEASE_VERSION}/appliance-${RELEASE_VERSION}-bundle"
  BUNDLE_BIN_DIR="${BUNDLE_DIR}/bin"
fi
if [[ -z "${TARGET_STATE_DIR}" ]]; then
  TARGET_STATE_DIR="/var/lib/zon/state"
fi

if [[ -n "${BUNDLE_BIN_DIR}" && "${STATUS_CMD}" == "sudo zonctl status --output json" ]]; then
  STATUS_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} zonctl status --state-dir $(shell_quote "${TARGET_STATE_DIR}") --output json"
fi
if [[ -n "${BUNDLE_BIN_DIR}" && "${VERIFY_CMD}" == "sudo zonctl verify --output json" ]]; then
  VERIFY_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} zonctl verify --state-dir $(shell_quote "${TARGET_STATE_DIR}") --output json"
fi
if [[ -n "${BUNDLE_BIN_DIR}" && "${APP_VERSION_CMD}" == "sudo zonctl status --output json" ]]; then
  APP_VERSION_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} zonctl status --state-dir $(shell_quote "${TARGET_STATE_DIR}") --output json"
fi
if [[ "${APP_VERSION_CMD}" == "sudo cat /var/lib/zon/installed-state.json" ]]; then
  APP_VERSION_CMD="sudo cat $(shell_quote "${TARGET_STATE_DIR}/installed-state.json")"
fi
if [[ -n "${BUNDLE_BIN_DIR}" && "${SERVICE_HEALTH_CMD}" == "sudo kubectl get pods -A" ]]; then
  SERVICE_HEALTH_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} kubectl get pods -A"
fi
if [[ -n "${BUNDLE_BIN_DIR}" && "${FAILURE_LOG_CMD}" == "sudo zonctl support-bundle --output json" ]]; then
  FAILURE_LOG_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} zonctl support-bundle --state-dir $(shell_quote "${TARGET_STATE_DIR}") --output json"
fi
if [[ -n "${BUNDLE_BIN_DIR}" && "${ARGO_NAMESPACES_CMD}" == "sudo kubectl get namespace workflows appliance-builds" ]]; then
  ARGO_NAMESPACES_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} kubectl get namespace workflows appliance-builds"
fi
if [[ -n "${BUNDLE_BIN_DIR}" && "${ARGO_CRDS_CMD}" == "sudo kubectl get crd workflows.argoproj.io workflowtemplates.argoproj.io cronworkflows.argoproj.io" ]]; then
  ARGO_CRDS_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} kubectl get crd workflows.argoproj.io workflowtemplates.argoproj.io cronworkflows.argoproj.io"
fi
if [[ -n "${BUNDLE_BIN_DIR}" && "${ARGO_CONTROLLER_CMD}" == "sudo kubectl -n workflows wait --for=condition=Available deployment --all --timeout=120s && sudo kubectl -n workflows get deploy,pods" ]]; then
  ARGO_CONTROLLER_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} kubectl -n workflows wait --for=condition=Available deployment --all --timeout=120s && sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} kubectl -n workflows get deploy,pods"
fi
if [[ -n "${BUNDLE_BIN_DIR}" && "${ARTIFACT_READINESS_CMD}" == "sudo kubectl -n registry wait --for=condition=Available deployment/appliance-registry --timeout=120s && sudo kubectl -n registry get pvc appliance-registry-data" ]]; then
  ARTIFACT_READINESS_CMD="sudo env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} kubectl -n registry wait --for=condition=Available deployment/appliance-registry --timeout=120s && env PATH=${BUNDLE_BIN_DIR}:${DEFAULT_TARGET_PATH} kubectl -n registry get pvc appliance-registry-data"
fi

status_code="0"
verify_code="0"
service_health_code="0"
app_version_code="0"
smoke_test_code=""
ui_home_code=""
builder_api_code=""
builder_source_credentials_code=""
artifact_readiness_code=""
failure_log_code=""
argo_namespaces_code=""
argo_crds_code=""
argo_controller_code=""

wrap_command_for_target() {
  local command="$1"
  case "${command}" in
    sudo\ *)
      local command_without_sudo="${command#sudo }"
      printf "printf '%%s\\n' %s | sudo -S -p '' bash -lc %s" \
        "$(shell_quote "${TARGET_SUDO_PASSWORD}")" \
        "$(shell_quote "${command_without_sudo}")"
      ;;
    *)
      printf "%s" "${command}"
      ;;
  esac
}

run_check_quiet_failure() {
  local name="$1"
  local command="$2"
  local log_file="${RUN_DIR}/logs/${name}.log"
  local effective_command

  log "running ${name} on ${TARGET_HOST}"
  effective_command="$(wrap_command_for_target "${command}")"
  if run_ssh_captured "${TARGET_HOST}" "${log_file}" "${effective_command}"; then
    log "${name} completed; log: ${log_file}"
    return 0
  fi
  return 1
}

run_check() {
  local name="$1"
  local command="$2"
  local log_file="${RUN_DIR}/logs/${name}.log"

  if run_check_quiet_failure "${name}" "${command}"; then
    return 0
  fi
  log "${name} failed; log: ${log_file}"
  return 1
}

status_is_allowed_warning() {
  local log_file="$1"
  [[ "${ALLOW_INGRESS_WARNING}" == "true" ]] || return 1
  python3 - "${log_file}" <<'PY'
import json
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
for raw_line in text.replace("\r", "\n").splitlines():
    line = raw_line.strip()
    if line.startswith("{") and line.endswith("}"):
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        health = data.get("data", {}).get("componentHealth", [])
        bad = [entry.get("name") for entry in health if isinstance(entry, dict) and not entry.get("healthy", False)]
        if bad == ["ingress"]:
            raise SystemExit(0)
raise SystemExit(1)
PY
}

verify_is_allowed_warning() {
  local log_file="$1"
  python3 - "${log_file}" <<'PY'
import json
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
if "entriesFailed" in text and "expected array, but got null" in text:
    raise SystemExit(10)

for raw_line in text.replace("\r", "\n").splitlines():
    line = raw_line.strip()
    if not (line.startswith("{") and line.endswith("}")):
        continue
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        continue
    payload = data.get("data")
    if not isinstance(payload, dict):
        continue
    manifest_valid = payload.get("manifestValid")
    entries_failed = payload.get("entriesFailed")
    if manifest_valid is True and entries_failed == []:
        raise SystemExit(20)
raise SystemExit(1)
PY
  case "$?" in
    10)
      [[ "${ALLOW_VERIFY_SCHEMA_BUG}" == "true" ]]
      return
      ;;
    20)
      [[ "${ALLOW_INGRESS_WARNING}" == "true" ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

verify_warning_label() {
  local log_file="$1"
  python3 - "${log_file}" <<'PY'
import json
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
if "entriesFailed" in text and "expected array, but got null" in text:
    print("allowed schema warning")
    raise SystemExit(0)

for raw_line in text.replace("\r", "\n").splitlines():
    line = raw_line.strip()
    if not (line.startswith("{") and line.endswith("}")):
        continue
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        continue
    payload = data.get("data")
    if not isinstance(payload, dict):
        continue
    manifest_valid = payload.get("manifestValid")
    entries_failed = payload.get("entriesFailed")
    if manifest_valid is True and entries_failed == []:
        print("allowed ingress warning")
        raise SystemExit(0)

print("allowed warning")
PY
}

if run_check_quiet_failure "status" "${STATUS_CMD}"; then
  status_code="0"
else
  status_code="$?"
  if status_is_allowed_warning "${RUN_DIR}/logs/status.log"; then
    status_code="0"
    log "status completed with allowed ingress warning; log: ${RUN_DIR}/logs/status.log"
  else
    log "status failed; log: ${RUN_DIR}/logs/status.log"
  fi
fi
if run_check_quiet_failure "verify" "${VERIFY_CMD}"; then
  verify_code="0"
else
  verify_code="$?"
  if verify_is_allowed_warning "${RUN_DIR}/logs/verify.log"; then
    verify_code="0"
    log "verify completed with $(verify_warning_label "${RUN_DIR}/logs/verify.log"); log: ${RUN_DIR}/logs/verify.log"
  else
    log "verify failed; log: ${RUN_DIR}/logs/verify.log"
  fi
fi
if run_check "service-health" "${SERVICE_HEALTH_CMD}"; then
  service_health_code="0"
else
  service_health_code="$?"
fi
if run_check "app-version" "${APP_VERSION_CMD}"; then
  app_version_code="0"
else
  app_version_code="$?"
fi

if [[ -n "${SMOKE_TEST_CMD}" ]]; then
  smoke_attempt=1
  smoke_max_attempts="${SMOKE_TEST_RETRIES}"
  while true; do
    if run_check "smoke-test" "${SMOKE_TEST_CMD}"; then
      smoke_test_code="0"
      break
    fi
    smoke_test_code="$?"
    if (( smoke_attempt >= smoke_max_attempts )); then
      break
    fi
    log "smoke-test attempt ${smoke_attempt}/${smoke_max_attempts} failed; retrying in ${SMOKE_TEST_RETRY_DELAY_SECONDS}s"
    sleep "${SMOKE_TEST_RETRY_DELAY_SECONDS}"
    smoke_attempt=$((smoke_attempt + 1))
  done
fi

if [[ -n "${UI_HOME_CMD}" ]]; then
  if run_check "ui-home" "${UI_HOME_CMD}"; then
    ui_home_code="0"
  else
    ui_home_code="$?"
  fi
fi

if bool_true "${BUILDER_ENABLED}" && [[ -n "${BUILDER_API_CMD}" ]]; then
  if run_check "builder-api" "${BUILDER_API_CMD}"; then
    builder_api_code="0"
  else
    builder_api_code="$?"
  fi
fi

if bool_true "${BUILDER_ENABLED}" && [[ -n "${BUILDER_SOURCE_CREDENTIALS_CMD}" ]]; then
  if run_check "builder-source-credentials" "${BUILDER_SOURCE_CREDENTIALS_CMD}"; then
    builder_source_credentials_code="0"
  else
    builder_source_credentials_code="$?"
  fi
fi

if bool_true "${ARTIFACT_ENABLED}" && [[ -n "${ARTIFACT_READINESS_CMD}" ]]; then
  if run_check "artifact-readiness" "${ARTIFACT_READINESS_CMD}"; then
    artifact_readiness_code="0"
  else
    artifact_readiness_code="$?"
  fi
fi

if bool_true "${ARGO_ENABLED}"; then
  if run_check "argo-namespaces" "${ARGO_NAMESPACES_CMD}"; then
    argo_namespaces_code="0"
  else
    argo_namespaces_code="$?"
  fi
  if run_check "argo-crds" "${ARGO_CRDS_CMD}"; then
    argo_crds_code="0"
  else
    argo_crds_code="$?"
  fi
  if run_check "argo-controller" "${ARGO_CONTROLLER_CMD}"; then
    argo_controller_code="0"
  else
    argo_controller_code="$?"
  fi
fi

overall_failed="false"
for code in "${status_code}" "${verify_code}" "${service_health_code}" "${app_version_code}"; do
  if [[ "${code}" != "0" ]]; then
    overall_failed="true"
  fi
done
if [[ -n "${smoke_test_code}" && "${smoke_test_code}" != "0" ]]; then
  overall_failed="true"
fi
if [[ -n "${ui_home_code}" && "${ui_home_code}" != "0" ]]; then
  overall_failed="true"
fi
if [[ -n "${builder_api_code}" && "${builder_api_code}" != "0" ]]; then
  overall_failed="true"
fi
if [[ -n "${builder_source_credentials_code}" && "${builder_source_credentials_code}" != "0" ]]; then
  overall_failed="true"
fi
if [[ -n "${artifact_readiness_code}" && "${artifact_readiness_code}" != "0" ]]; then
  overall_failed="true"
fi
for code in "${argo_namespaces_code}" "${argo_crds_code}" "${argo_controller_code}"; do
  if [[ -n "${code}" && "${code}" != "0" ]]; then
    overall_failed="true"
  fi
done

final_failed="$(python3 - "${RUN_DIR}/metadata/verify.json" "${CONFIG_PATH}" "${TARGET_HOST}" "${STATUS_CMD}" "${VERIFY_CMD}" "${SERVICE_HEALTH_CMD}" "${APP_VERSION_CMD}" "${SMOKE_TEST_CMD}" "${UI_HOME_CMD}" "${BUILDER_ENABLED}" "${BUILDER_API_CMD}" "${BUILDER_SOURCE_CREDENTIALS_CMD}" "${FAILURE_LOG_CMD}" "${ARGO_ENABLED}" "${ARGO_SKIP_REASON}" "${ARGO_NAMESPACES_CMD}" "${ARGO_CRDS_CMD}" "${ARGO_CONTROLLER_CMD}" "${status_code}" "${verify_code}" "${service_health_code}" "${app_version_code}" "${smoke_test_code}" "${ui_home_code}" "${builder_api_code}" "${builder_source_credentials_code}" "${failure_log_code}" "${argo_namespaces_code}" "${argo_crds_code}" "${argo_controller_code}" "${overall_failed}" "${RUN_DIR}" "${ALLOW_INGRESS_WARNING}" "${ALLOW_VERIFY_SCHEMA_BUG}" <<'PY'
import json
from pathlib import Path
import sys

(
    out_path,
    config_path,
    target_host,
    status_cmd,
    verify_cmd,
    service_health_cmd,
    app_version_cmd,
    smoke_test_cmd,
    ui_home_cmd,
    builder_enabled,
    builder_api_cmd,
    builder_source_credentials_cmd,
    failure_log_cmd,
    argo_enabled,
    argo_skip_reason,
    argo_namespaces_cmd,
    argo_crds_cmd,
    argo_controller_cmd,
    status_code,
    verify_code,
    service_health_code,
    app_version_code,
    smoke_test_code,
    ui_home_code,
    builder_api_code,
    builder_source_credentials_code,
    failure_log_code,
    argo_namespaces_code,
    argo_crds_code,
    argo_controller_code,
    overall_failed,
    run_dir,
    allow_ingress_warning,
    allow_verify_schema_bug,
) = sys.argv[1:35]

run_dir_path = Path(run_dir)
warnings = []
known_issues = []
final_failed = overall_failed == "true"

def read_log(name: str) -> str:
    path = run_dir_path / "logs" / name
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")

def parse_json_line(text: str):
    for raw_line in text.replace("\r", "\n").splitlines():
        line = raw_line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None

status_log_text = read_log("status.log")
verify_log_text = read_log("verify.log")
status_json = parse_json_line(status_log_text)
status_unhealthy = []
if status_json and isinstance(status_json.get("data"), dict):
    component_health = status_json["data"].get("componentHealth")
    if isinstance(component_health, list):
        for entry in component_health:
            if isinstance(entry, dict) and not entry.get("healthy", False):
                name = entry.get("name")
                if name:
                    status_unhealthy.append(name)

if status_unhealthy:
    if allow_ingress_warning == "true" and status_unhealthy == ["ingress"]:
        warnings.append("zonctl status reports ingress unhealthy because no Kubernetes Ingress object was found, but this is treated as a warning for this flow.")
        known_issues.append("status-ingress-warning")
        if final_failed and int(status_code) != 0:
            final_failed = False
    else:
        final_failed = True
elif int(status_code) != 0:
    final_failed = True

known_verify_schema_bug = (
    "entriesFailed" in verify_log_text
    and "expected array, but got null" in verify_log_text
)
verify_json = parse_json_line(verify_log_text)
verify_ingress_only_warning = False
if verify_json and isinstance(verify_json.get("data"), dict):
    payload = verify_json["data"]
    if payload.get("manifestValid") is True and payload.get("entriesFailed") == []:
        verify_ingress_only_warning = True

if known_verify_schema_bug and allow_verify_schema_bug == "true":
    warnings.append("zonctl verify hit the known entriesFailed schema bug; the wrapper records it as a warning and relies on the other install and API checks.")
    known_issues.append("verify-entriesFailed-schema-bug")
elif verify_ingress_only_warning and allow_ingress_warning == "true":
    warnings.append("zonctl verify reports only the known ingress condition; the wrapper records it as a warning for this flow.")
    known_issues.append("verify-ingress-warning")
else:
    if int(verify_code) != 0:
        final_failed = True

if argo_skip_reason:
    warnings.append(argo_skip_reason)
    known_issues.append("argo-verification-skipped-for-profile")

if int(service_health_code) != 0 or int(app_version_code) != 0:
    final_failed = True
if smoke_test_code and int(smoke_test_code) != 0:
    final_failed = True
if builder_enabled == "true" and builder_api_cmd and builder_api_code and int(builder_api_code) != 0:
    final_failed = True
if builder_enabled == "true" and builder_source_credentials_cmd and builder_source_credentials_code and int(builder_source_credentials_code) != 0:
    final_failed = True
if argo_enabled == "true":
    for code in (argo_namespaces_code, argo_crds_code, argo_controller_code):
        if code and int(code) != 0:
            final_failed = True

payload = {
    "configPath": config_path,
    "targetHost": target_host,
    "failed": final_failed,
    "warnings": warnings,
    "knownIssues": known_issues,
    "checks": {
        "status": {
            "command": status_cmd,
            "exitCode": int(status_code),
            "log": str(run_dir_path / "logs" / "status.log"),
            "unhealthyComponents": status_unhealthy,
        },
        "verify": {
            "command": verify_cmd,
            "exitCode": int(verify_code),
            "log": str(run_dir_path / "logs" / "verify.log"),
            "knownSchemaBug": known_verify_schema_bug,
            "ingressOnlyWarning": verify_ingress_only_warning,
        },
        "serviceHealth": {
            "command": service_health_cmd,
            "exitCode": int(service_health_code),
            "log": str(run_dir_path / "logs" / "service-health.log"),
        },
        "appVersion": {
            "command": app_version_cmd,
            "exitCode": int(app_version_code),
            "log": str(run_dir_path / "logs" / "app-version.log"),
        },
    },
}

if smoke_test_cmd:
    payload["checks"]["smokeTest"] = {
        "command": smoke_test_cmd,
        "exitCode": int(smoke_test_code or 0),
        "log": str(run_dir_path / "logs" / "smoke-test.log"),
    }

if ui_home_cmd:
    payload["checks"]["uiHome"] = {
        "command": ui_home_cmd,
        "exitCode": int(ui_home_code or 0),
        "log": str(run_dir_path / "logs" / "ui-home.log"),
    }

if builder_enabled == "true":
    payload["checks"]["builder"] = {
        "api": {
            "command": builder_api_cmd,
            "exitCode": int(builder_api_code or 0),
            "log": str(run_dir_path / "logs" / "builder-api.log"),
        },
    }
    if builder_source_credentials_cmd:
        payload["checks"]["builder"]["sourceCredentials"] = {
            "command": builder_source_credentials_cmd,
            "exitCode": int(builder_source_credentials_code or 0),
            "log": str(run_dir_path / "logs" / "builder-source-credentials.log"),
        }

payload["checks"]["argo"] = {
    "enabled": argo_enabled == "true",
    "skipReason": argo_skip_reason or None,
}

if argo_enabled == "true":
    payload["checks"]["argo"].update({
        "namespaces": {
            "command": argo_namespaces_cmd,
            "exitCode": int(argo_namespaces_code or 0),
            "log": str(run_dir_path / "logs" / "argo-namespaces.log"),
        },
        "crds": {
            "command": argo_crds_cmd,
            "exitCode": int(argo_crds_code or 0),
            "log": str(run_dir_path / "logs" / "argo-crds.log"),
        },
        "controller": {
            "command": argo_controller_cmd,
            "exitCode": int(argo_controller_code or 0),
            "log": str(run_dir_path / "logs" / "argo-controller.log"),
        },
    })

if failure_log_cmd:
    payload["failureLogs"] = {
        "command": failure_log_cmd,
        "exitCode": int(failure_log_code or 0) if failure_log_code else None,
        "log": str(run_dir_path / "logs" / "failure-logs.log"),
    }

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("true" if final_failed else "false")
PY
)"

python3 - "${RUN_DIR}/metadata/verify.json" "${ARTIFACT_ENABLED}" "${ARTIFACT_READINESS_CMD}" "${artifact_readiness_code}" "${RUN_DIR}" <<'PY'
import json
from pathlib import Path
import sys

out_path, enabled, command, exit_code, run_dir = sys.argv[1:6]
payload = json.loads(Path(out_path).read_text(encoding="utf-8"))
payload.setdefault("checks", {})["artifact"] = {
    "enabled": enabled == "true",
    "readiness": {
        "command": command,
        "exitCode": int(exit_code or 0) if command else None,
        "log": str(Path(run_dir) / "logs" / "artifact-readiness.log"),
    },
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

if bool_true "${final_failed}" && [[ -n "${FAILURE_LOG_CMD}" ]]; then
  failure_log_log="${RUN_DIR}/logs/failure-logs.log"
  log "verification failed; collecting failure logs from ${TARGET_HOST}"
  failure_log_command="$(wrap_command_for_target "${FAILURE_LOG_CMD}")"
  if run_ssh_captured "${TARGET_HOST}" "${failure_log_log}" "${failure_log_command}"; then
    failure_log_code="0"
    log "failure log collection completed; log: ${failure_log_log}"
  else
    failure_log_code="$?"
    log "failure log collection failed; log: ${failure_log_log}"
  fi

  final_failed="$(python3 - "${RUN_DIR}/metadata/verify.json" "${FAILURE_LOG_CMD}" "${failure_log_code}" "${RUN_DIR}" <<'PY'
import json
from pathlib import Path
import sys

(
    out_path,
    failure_log_cmd,
    failure_log_code,
    run_dir,
) = sys.argv[1:5]

run_dir_path = Path(run_dir)
payload = json.loads(Path(out_path).read_text(encoding="utf-8"))
payload["failureLogs"] = {
    "command": failure_log_cmd,
    "exitCode": int(failure_log_code or 0) if failure_log_code else None,
    "log": str(run_dir_path / "logs" / "failure-logs.log"),
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("true" if payload.get("failed") else "false")
PY
  )"
fi

if bool_true "${final_failed}"; then
  fail "verification failed; see ${RUN_DIR}/metadata/verify.json"
fi

log "verification metadata written to ${RUN_DIR}/metadata/verify.json"
if bool_true "${FINAL_OK}"; then
  printf 'ok\n'
fi
