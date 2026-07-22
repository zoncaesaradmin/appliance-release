#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: verify-client-access.sh [options]

Run macOS-side client/API checks against the installed appliance without
storing tokens in logs or metadata.

Options:
  --config PATH            YAML or JSON config file. Optional if
                           APPLIANCE_RELEASE_CONFIG is set or a local
                           appliance-release.config.yaml exists.
  --appliance-profile NAME Effective installed appliance profile.
  --run-dir DIR            Local run directory.
  --final-ok               Print ok when all checks pass.
EOF
}

CONFIG_PATH=""
APPLIANCE_PROFILE=""
RUN_DIR=""
FINAL_OK="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --appliance-profile)
      APPLIANCE_PROFILE="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
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
require_cmd curl
require_cmd python3

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(pwd)/.run/appliance-release/$(date -u +%Y%m%dT%H%M%SZ)"
fi
BASE_URL="$(config_get_optional "${CONFIG_PATH}" "client_verification.base_url" || true)"
USERNAME="$(config_get_optional "${CONFIG_PATH}" "client_verification.username" || true)"
BASE_URL="${BASE_URL:-https://192.168.1.101}"
USERNAME="${USERNAME:-admin}"
PASSWORD="$(resolve_secret "APPLIANCE_FIRST_ADMIN_PASSWORD" "Appliance first-admin password")"

ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"

TEMP_PAYLOAD_FILES=()
cleanup_temp_payload_files() {
  local path
  for path in "${TEMP_PAYLOAD_FILES[@]:-}"; do
    if [[ -n "${path}" ]]; then
      rm -f "${path}"
    fi
  done
}
trap cleanup_temp_payload_files EXIT

make_temp_payload_file() {
  local target_var="$1"
  local name="$2"
  local path
  path="$(mktemp "${RUN_DIR}/logs/.${name}.XXXXXX.json")"
  chmod 600 "${path}"
  TEMP_PAYLOAD_FILES+=("${path}")
  printf -v "${target_var}" '%s' "${path}"
}

http_status_code() {
  local meta_file="$1"
  awk '/^HTTP\// {code=$2} END {print code}' "${meta_file}"
}

require_http_success() {
  local name="$1"
  local meta_file="$2"
  local body_file="$3"
  local code
  code="$(http_status_code "${meta_file}")"
  if [[ -z "${code}" || ! "${code}" =~ ^[0-9]+$ || "${code}" -ge 400 ]]; then
    fail "${name} returned HTTP ${code:-unknown}; body: ${body_file}; metadata: ${meta_file}"
  fi
}

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

LOGIN_BODY_FILE="${RUN_DIR}/logs/client-login-body.json"
LOGIN_META_FILE="${RUN_DIR}/logs/client-login-meta.txt"
LOGIN_REQUEST_FILE="${RUN_DIR}/logs/client-login-request.json"
make_temp_payload_file LOGIN_PAYLOAD_FILE "client-login-payload"
SESSION_BODY_FILE="${RUN_DIR}/logs/client-session-body.json"
SESSION_META_FILE="${RUN_DIR}/logs/client-session-meta.txt"
SESSION_REQUEST_FILE="${RUN_DIR}/logs/client-session-request.json"
USERS_BODY_FILE="${RUN_DIR}/logs/client-users-body.json"
USERS_META_FILE="${RUN_DIR}/logs/client-users-meta.txt"
USERS_REQUEST_FILE="${RUN_DIR}/logs/client-users-request.json"
BUILDER_ENABLED="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.enabled" || true)"
BUILDER_EXPECT_DISABLED="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.expect_disabled" || true)"
ARTIFACT_ENABLED="$(config_get_optional "${CONFIG_PATH}" "client_verification.artifact.enabled" || true)"
ARTIFACT_OCI_SMOKE_CMD="$(config_get_optional "${CONFIG_PATH}" "client_verification.artifact.oci_smoke_command" || true)"
ARTIFACT_ORAS_SMOKE_CMD="$(config_get_optional "${CONFIG_PATH}" "client_verification.artifact.oras_smoke_command" || true)"
ARTIFACT_OFFLINE_SMOKE_CMD="$(config_get_optional "${CONFIG_PATH}" "client_verification.artifact.offline_smoke_command" || true)"
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="$(config_get_optional "${CONFIG_PATH}" "install.appliance_profile" || true)"
fi
BUILD_CATALOG_PATH="$(config_get_optional "${CONFIG_PATH}" "install.build_catalog_path" || true)"
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  ensure_file "${BUILD_CATALOG_PATH}"
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
if [[ -z "${BUILDER_EXPECT_DISABLED}" ]]; then
  if bool_true "${BUILDER_ENABLED}"; then
    BUILDER_EXPECT_DISABLED="false"
  else
    BUILDER_EXPECT_DISABLED="true"
  fi
fi
BUILDER_WORKFLOW_ENABLED="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.enabled" || true)"
BUILDER_WORKFLOW_NAME="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.workspace_name" || true)"
BUILDER_WORKFLOW_PROFILE="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.work_profile" || true)"
BUILDER_WORKFLOW_REPO="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.repo" || true)"
BUILDER_WORKFLOW_SOURCE_REF="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.source_ref" || true)"
BUILDER_WORKFLOW_TARGET="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.target_name" || true)"
BUILDER_WORKFLOW_IMAGE_TAG="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.image_tag" || true)"
BUILDER_WORKFLOW_POLL_ATTEMPTS="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.poll_attempts" || true)"
BUILDER_WORKFLOW_POLL_DELAY_SECONDS="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.poll_delay_seconds" || true)"
BUILDER_WORKFLOW_EXPECT_SUCCESS="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.expect_success" || true)"
BUILDER_WORKFLOW_DELETE_WORKSPACE="$(config_get_optional "${CONFIG_PATH}" "client_verification.builder.workflow.delete_workspace_on_success" || true)"
if [[ -z "${BUILDER_WORKFLOW_ENABLED}" ]]; then
  BUILDER_WORKFLOW_ENABLED="false"
fi
if bool_true "${BUILDER_WORKFLOW_ENABLED}" && ! bool_true "${BUILDER_ENABLED}"; then
  fail "client_verification.builder.workflow.enabled requires builder verification to be enabled"
fi
if [[ -z "${BUILDER_WORKFLOW_POLL_ATTEMPTS}" ]]; then
  BUILDER_WORKFLOW_POLL_ATTEMPTS="60"
fi
if [[ -z "${BUILDER_WORKFLOW_POLL_DELAY_SECONDS}" ]]; then
  BUILDER_WORKFLOW_POLL_DELAY_SECONDS="5"
fi
if [[ -z "${BUILDER_WORKFLOW_EXPECT_SUCCESS}" ]]; then
  BUILDER_WORKFLOW_EXPECT_SUCCESS="true"
fi
if [[ -z "${BUILDER_WORKFLOW_DELETE_WORKSPACE}" ]]; then
  BUILDER_WORKFLOW_DELETE_WORKSPACE="false"
fi
if bool_true "${BUILDER_WORKFLOW_ENABLED}"; then
  [[ -n "${BUILDER_WORKFLOW_NAME}" ]] || fail "client_verification.builder.workflow.workspace_name is required when workflow.enabled is true"
  [[ -n "${BUILDER_WORKFLOW_PROFILE}" ]] || fail "client_verification.builder.workflow.work_profile is required when workflow.enabled is true"
  [[ -n "${BUILDER_WORKFLOW_REPO}" ]] || fail "client_verification.builder.workflow.repo is required when workflow.enabled is true"
  [[ -n "${BUILDER_WORKFLOW_SOURCE_REF}" ]] || fail "client_verification.builder.workflow.source_ref is required when workflow.enabled is true"
  [[ -n "${BUILDER_WORKFLOW_TARGET}" ]] || fail "client_verification.builder.workflow.target_name is required when workflow.enabled is true"
  is_positive_integer "${BUILDER_WORKFLOW_POLL_ATTEMPTS}" || fail "client_verification.builder.workflow.poll_attempts must be a positive integer"
  is_positive_integer "${BUILDER_WORKFLOW_POLL_DELAY_SECONDS}" || fail "client_verification.builder.workflow.poll_delay_seconds must be a positive integer"
  [[ "${BUILDER_WORKFLOW_SOURCE_REF}" =~ ^[0-9a-f]{40}$ ]] || fail "client_verification.builder.workflow.source_ref must be a 40-character lowercase commit SHA for v1 builder workflow smoke"
fi
BUILDER_PROFILES_BODY_FILE="${RUN_DIR}/logs/client-builder-work-profiles-body.json"
BUILDER_PROFILES_META_FILE="${RUN_DIR}/logs/client-builder-work-profiles-meta.txt"
BUILDER_PROFILES_REQUEST_FILE="${RUN_DIR}/logs/client-builder-work-profiles-request.json"
DISABLED_BUILD_PROFILES_BODY_FILE="${RUN_DIR}/logs/client-disabled-build-work-profiles-body.json"
DISABLED_BUILD_PROFILES_META_FILE="${RUN_DIR}/logs/client-disabled-build-work-profiles-meta.txt"
DISABLED_BUILD_PROFILES_REQUEST_FILE="${RUN_DIR}/logs/client-disabled-build-work-profiles-request.json"
DISABLED_MCP_INITIALIZE_BODY_FILE="${RUN_DIR}/logs/client-disabled-mcp-initialize-body.json"
DISABLED_MCP_INITIALIZE_META_FILE="${RUN_DIR}/logs/client-disabled-mcp-initialize-meta.txt"
DISABLED_MCP_INITIALIZE_REQUEST_FILE="${RUN_DIR}/logs/client-disabled-mcp-initialize-request.json"
DISABLED_MCP_TOOLS_BODY_FILE="${RUN_DIR}/logs/client-disabled-mcp-tools-body.json"
DISABLED_MCP_TOOLS_META_FILE="${RUN_DIR}/logs/client-disabled-mcp-tools-meta.txt"
DISABLED_MCP_TOOLS_REQUEST_FILE="${RUN_DIR}/logs/client-disabled-mcp-tools-request.json"
DISABLED_MCP_CALL_BODY_FILE="${RUN_DIR}/logs/client-disabled-mcp-call-body.json"
DISABLED_MCP_CALL_META_FILE="${RUN_DIR}/logs/client-disabled-mcp-call-meta.txt"
DISABLED_MCP_CALL_REQUEST_FILE="${RUN_DIR}/logs/client-disabled-mcp-call-request.json"
MCP_INITIALIZE_BODY_FILE="${RUN_DIR}/logs/client-mcp-initialize-body.json"
MCP_INITIALIZE_META_FILE="${RUN_DIR}/logs/client-mcp-initialize-meta.txt"
MCP_INITIALIZE_REQUEST_FILE="${RUN_DIR}/logs/client-mcp-initialize-request.json"
MCP_TOOLS_BODY_FILE="${RUN_DIR}/logs/client-mcp-tools-body.json"
MCP_TOOLS_META_FILE="${RUN_DIR}/logs/client-mcp-tools-meta.txt"
MCP_TOOLS_REQUEST_FILE="${RUN_DIR}/logs/client-mcp-tools-request.json"
WORKFLOW_CREATE_WORKSPACE_BODY_FILE="${RUN_DIR}/logs/client-builder-workflow-create-workspace-body.json"
WORKFLOW_CREATE_WORKSPACE_META_FILE="${RUN_DIR}/logs/client-builder-workflow-create-workspace-meta.txt"
WORKFLOW_CREATE_WORKSPACE_REQUEST_FILE="${RUN_DIR}/logs/client-builder-workflow-create-workspace-request.json"
make_temp_payload_file WORKFLOW_CREATE_WORKSPACE_PAYLOAD_FILE "client-builder-workflow-create-workspace-payload"
WORKFLOW_TARGETS_BODY_FILE="${RUN_DIR}/logs/client-builder-workflow-targets-body.json"
WORKFLOW_TARGETS_META_FILE="${RUN_DIR}/logs/client-builder-workflow-targets-meta.txt"
WORKFLOW_TARGETS_REQUEST_FILE="${RUN_DIR}/logs/client-builder-workflow-targets-request.json"
WORKFLOW_SUBMIT_BODY_FILE="${RUN_DIR}/logs/client-builder-workflow-submit-body.json"
WORKFLOW_SUBMIT_META_FILE="${RUN_DIR}/logs/client-builder-workflow-submit-meta.txt"
WORKFLOW_SUBMIT_REQUEST_FILE="${RUN_DIR}/logs/client-builder-workflow-submit-request.json"
make_temp_payload_file WORKFLOW_SUBMIT_PAYLOAD_FILE "client-builder-workflow-submit-payload"
WORKFLOW_JOB_BODY_FILE="${RUN_DIR}/logs/client-builder-workflow-job-body.json"
WORKFLOW_JOB_META_FILE="${RUN_DIR}/logs/client-builder-workflow-job-meta.txt"
WORKFLOW_JOB_REQUEST_FILE="${RUN_DIR}/logs/client-builder-workflow-job-request.json"
WORKFLOW_JOB_POLL_FILE="${RUN_DIR}/logs/client-builder-workflow-job-poll.jsonl"
WORKFLOW_STEPS_BODY_FILE="${RUN_DIR}/logs/client-builder-workflow-steps-body.json"
WORKFLOW_STEPS_META_FILE="${RUN_DIR}/logs/client-builder-workflow-steps-meta.txt"
WORKFLOW_STEPS_REQUEST_FILE="${RUN_DIR}/logs/client-builder-workflow-steps-request.json"
WORKFLOW_LOGS_BODY_FILE="${RUN_DIR}/logs/client-builder-workflow-logs-body.txt"
WORKFLOW_LOGS_META_FILE="${RUN_DIR}/logs/client-builder-workflow-logs-meta.txt"
WORKFLOW_LOGS_REQUEST_FILE="${RUN_DIR}/logs/client-builder-workflow-logs-request.json"
WORKFLOW_DELETE_WORKSPACE_BODY_FILE="${RUN_DIR}/logs/client-builder-workflow-delete-workspace-body.txt"
WORKFLOW_DELETE_WORKSPACE_META_FILE="${RUN_DIR}/logs/client-builder-workflow-delete-workspace-meta.txt"
WORKFLOW_DELETE_WORKSPACE_REQUEST_FILE="${RUN_DIR}/logs/client-builder-workflow-delete-workspace-request.json"
WORKFLOW_JOB_ID=""
WORKFLOW_WORKSPACE_ID=""
WORKFLOW_FINAL_STATUS=""

python3 - "${LOGIN_REQUEST_FILE}" "${LOGIN_PAYLOAD_FILE}" "${BASE_URL}/api/v1/auth/login" "${USERNAME}" "${PASSWORD}" <<'PY'
import json
from pathlib import Path
import sys

out_path, payload_path, url, username, password = sys.argv[1:6]

payload = {
    "method": "POST",
    "url": url,
    "headers": {
        "Content-Type": "application/json",
    },
    "body": {
        "username": username,
        "password": "<redacted>",
    },
    "bodyFields": ["username", "password"],
}

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
Path(payload_path).write_text(json.dumps({"username": username, "password": password}, separators=(",", ":")) + "\n", encoding="utf-8")
PY

log "running client login check against ${BASE_URL}"
curl -skS \
  -H 'Content-Type: application/json' \
  --data-binary "@${LOGIN_PAYLOAD_FILE}" \
  -o "${LOGIN_BODY_FILE}" \
  -D "${LOGIN_META_FILE}" \
  "${BASE_URL}/api/v1/auth/login"
require_http_success "client login" "${LOGIN_META_FILE}" "${LOGIN_BODY_FILE}"

TOKEN="$(python3 - "${LOGIN_BODY_FILE}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
token = data.get("accessToken", "")
if not token:
    raise SystemExit("missing accessToken in login response")
print(token)
PY
)"

python3 - "${SESSION_REQUEST_FILE}" "${BASE_URL}/api/v1/auth/session" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]

payload = {
    "method": "GET",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
    },
}

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log "running client session check"
curl -skS \
  -H "Authorization: Bearer ${TOKEN}" \
  -o "${SESSION_BODY_FILE}" \
  -D "${SESSION_META_FILE}" \
  "${BASE_URL}/api/v1/auth/session"

python3 - "${USERS_REQUEST_FILE}" "${BASE_URL}/api/v1/users" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]

payload = {
    "method": "GET",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
    },
}

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log "running client users check"
curl -skS \
  -H "Authorization: Bearer ${TOKEN}" \
  -o "${USERS_BODY_FILE}" \
  -D "${USERS_META_FILE}" \
  "${BASE_URL}/api/v1/users"

if ! bool_true "${BUILDER_ENABLED}" && bool_true "${BUILDER_EXPECT_DISABLED}"; then
  python3 - "${DISABLED_BUILD_PROFILES_REQUEST_FILE}" "${BASE_URL}/api/v1/work-profiles" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "GET",
    "url": url,
    "headers": {"Authorization": "Bearer <redacted>"},
    "expectation": "404 when build capability is disabled",
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "running disabled build route check"
  curl -skS \
    -H "Authorization: Bearer ${TOKEN}" \
    -o "${DISABLED_BUILD_PROFILES_BODY_FILE}" \
    -D "${DISABLED_BUILD_PROFILES_META_FILE}" \
    "${BASE_URL}/api/v1/work-profiles"

  python3 - "${DISABLED_MCP_INITIALIZE_REQUEST_FILE}" "${BASE_URL}/mcp" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "POST",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
        "Content-Type": "application/json",
    },
    "body": {
        "jsonrpc": "2.0",
        "id": "disabled-1",
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "appliance-release-verify", "version": "1.0"},
        },
    },
    "expectation": "MCP remains available but build tools are absent when build capability is disabled",
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "running disabled build MCP initialize check"
  curl -skS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"disabled-1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"appliance-release-verify","version":"1.0"}}}' \
    -o "${DISABLED_MCP_INITIALIZE_BODY_FILE}" \
    -D "${DISABLED_MCP_INITIALIZE_META_FILE}" \
    "${BASE_URL}/mcp"
  require_http_success "disabled build MCP initialize" "${DISABLED_MCP_INITIALIZE_META_FILE}" "${DISABLED_MCP_INITIALIZE_BODY_FILE}"

  DISABLED_MCP_SESSION_ID="$(python3 - "${DISABLED_MCP_INITIALIZE_META_FILE}" <<'PY'
from pathlib import Path
import sys

for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    if line.lower().startswith("mcp-session-id:"):
        value = line.split(":", 1)[1].strip()
        if value:
            print(value)
            raise SystemExit(0)
raise SystemExit("missing Mcp-Session-Id in disabled MCP initialize response")
PY
)"

  python3 - "${DISABLED_MCP_TOOLS_REQUEST_FILE}" "${BASE_URL}/mcp" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "POST",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
        "Mcp-Session-Id": "<redacted>",
        "Content-Type": "application/json",
    },
    "body": {"jsonrpc": "2.0", "id": "disabled-2", "method": "tools/list"},
    "expectation": "build workflow tools are absent when build capability is disabled",
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "running disabled build MCP tools/list check"
  curl -skS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Mcp-Session-Id: ${DISABLED_MCP_SESSION_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"disabled-2","method":"tools/list"}' \
    -o "${DISABLED_MCP_TOOLS_BODY_FILE}" \
    -D "${DISABLED_MCP_TOOLS_META_FILE}" \
    "${BASE_URL}/mcp"
  require_http_success "disabled build MCP tools/list" "${DISABLED_MCP_TOOLS_META_FILE}" "${DISABLED_MCP_TOOLS_BODY_FILE}"

  python3 - "${DISABLED_MCP_CALL_REQUEST_FILE}" "${BASE_URL}/mcp" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "POST",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
        "Mcp-Session-Id": "<redacted>",
        "Content-Type": "application/json",
    },
    "body": {
        "jsonrpc": "2.0",
        "id": "disabled-3",
        "method": "tools/call",
        "params": {"name": "submit_build", "arguments": {"targetName": "app"}},
    },
    "expectation": "direct disabled build tool calls return JSON-RPC tool-not-found",
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "running disabled build MCP direct tools/call check"
  curl -skS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Mcp-Session-Id: ${DISABLED_MCP_SESSION_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"disabled-3","method":"tools/call","params":{"name":"submit_build","arguments":{"targetName":"app"}}}' \
    -o "${DISABLED_MCP_CALL_BODY_FILE}" \
    -D "${DISABLED_MCP_CALL_META_FILE}" \
    "${BASE_URL}/mcp"
  require_http_success "disabled build MCP direct tools/call" "${DISABLED_MCP_CALL_META_FILE}" "${DISABLED_MCP_CALL_BODY_FILE}"
fi

if bool_true "${BUILDER_ENABLED}"; then
  python3 - "${BUILDER_PROFILES_REQUEST_FILE}" "${BASE_URL}/api/v1/work-profiles" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "GET",
    "url": url,
    "headers": {"Authorization": "Bearer <redacted>"},
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "running client builder work-profiles check"
  curl -skS \
    -H "Authorization: Bearer ${TOKEN}" \
    -o "${BUILDER_PROFILES_BODY_FILE}" \
    -D "${BUILDER_PROFILES_META_FILE}" \
    "${BASE_URL}/api/v1/work-profiles"

  python3 - "${MCP_INITIALIZE_REQUEST_FILE}" "${BASE_URL}/mcp" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "POST",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
        "Content-Type": "application/json",
    },
    "body": {
        "jsonrpc": "2.0",
        "id": "1",
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "appliance-release-verify", "version": "1.0"},
        },
    },
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "running client MCP initialize check"
  curl -skS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"appliance-release-verify","version":"1.0"}}}' \
    -o "${MCP_INITIALIZE_BODY_FILE}" \
    -D "${MCP_INITIALIZE_META_FILE}" \
    "${BASE_URL}/mcp"
  require_http_success "client MCP initialize" "${MCP_INITIALIZE_META_FILE}" "${MCP_INITIALIZE_BODY_FILE}"

  MCP_SESSION_ID="$(python3 - "${MCP_INITIALIZE_META_FILE}" <<'PY'
from pathlib import Path
import sys

for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    if line.lower().startswith("mcp-session-id:"):
        value = line.split(":", 1)[1].strip()
        if value:
            print(value)
            raise SystemExit(0)
raise SystemExit("missing Mcp-Session-Id in MCP initialize response")
PY
)"

  python3 - "${MCP_TOOLS_REQUEST_FILE}" "${BASE_URL}/mcp" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "POST",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
        "Mcp-Session-Id": "<redacted>",
        "Content-Type": "application/json",
    },
    "body": {"jsonrpc": "2.0", "id": "2", "method": "tools/list"},
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  log "running client MCP tools/list check"
  curl -skS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Mcp-Session-Id: ${MCP_SESSION_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"2","method":"tools/list"}' \
    -o "${MCP_TOOLS_BODY_FILE}" \
    -D "${MCP_TOOLS_META_FILE}" \
    "${BASE_URL}/mcp"

  if bool_true "${BUILDER_WORKFLOW_ENABLED}"; then
    python3 - "${WORKFLOW_CREATE_WORKSPACE_REQUEST_FILE}" "${WORKFLOW_CREATE_WORKSPACE_PAYLOAD_FILE}" "${BASE_URL}/api/v1/workspaces" "${BUILDER_WORKFLOW_NAME}" "${BUILDER_WORKFLOW_PROFILE}" "${BUILDER_WORKFLOW_REPO}" "${BUILDER_WORKFLOW_SOURCE_REF}" <<'PY'
import json
from pathlib import Path
import sys

out_path, payload_path, url, name, profile, repo, source_ref = sys.argv[1:8]
body = {
    "name": name,
    "workProfile": profile,
    "repo": repo,
    "sourceRef": source_ref,
}
payload = {
    "method": "POST",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
        "Content-Type": "application/json",
    },
    "body": body,
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
Path(payload_path).write_text(json.dumps(body, separators=(",", ":")) + "\n", encoding="utf-8")
PY

    log "running builder workflow workspace creation"
    curl -skS \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' \
      --data-binary "@${WORKFLOW_CREATE_WORKSPACE_PAYLOAD_FILE}" \
      -o "${WORKFLOW_CREATE_WORKSPACE_BODY_FILE}" \
      -D "${WORKFLOW_CREATE_WORKSPACE_META_FILE}" \
      "${BASE_URL}/api/v1/workspaces"
    require_http_success "builder workflow create workspace" "${WORKFLOW_CREATE_WORKSPACE_META_FILE}" "${WORKFLOW_CREATE_WORKSPACE_BODY_FILE}"

    WORKFLOW_WORKSPACE_ID="$(python3 - "${WORKFLOW_CREATE_WORKSPACE_BODY_FILE}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
workspace_id = data.get("id", "")
if not workspace_id:
    raise SystemExit("missing workspace id in create workspace response")
print(workspace_id)
PY
)"

    python3 - "${WORKFLOW_TARGETS_REQUEST_FILE}" "${BASE_URL}/api/v1/current-workspace/build-targets" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "GET",
    "url": url,
    "headers": {"Authorization": "Bearer <redacted>"},
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

    log "running builder workflow build-target listing"
    curl -skS \
      -H "Authorization: Bearer ${TOKEN}" \
      -o "${WORKFLOW_TARGETS_BODY_FILE}" \
      -D "${WORKFLOW_TARGETS_META_FILE}" \
      "${BASE_URL}/api/v1/current-workspace/build-targets"
    require_http_success "builder workflow list build targets" "${WORKFLOW_TARGETS_META_FILE}" "${WORKFLOW_TARGETS_BODY_FILE}"

    python3 - "${WORKFLOW_TARGETS_BODY_FILE}" "${BUILDER_WORKFLOW_TARGET}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target_name = sys.argv[2]
items = data.get("items", [])
names = []
for item in items:
    if not isinstance(item, dict):
        continue
    if item.get("name"):
        names.append(item["name"])
    for alias in item.get("aliases") or []:
        names.append(alias)
if target_name not in names:
    raise SystemExit(f"build target {target_name!r} not found in current workspace targets {sorted(names)}")
PY

    idempotency_key="appliance-release-verify-${RUN_DIR##*/}"

    python3 - "${WORKFLOW_SUBMIT_REQUEST_FILE}" "${WORKFLOW_SUBMIT_PAYLOAD_FILE}" "${BASE_URL}/api/v1/current-workspace/builds" "${BUILDER_WORKFLOW_TARGET}" "${BUILDER_WORKFLOW_IMAGE_TAG}" <<'PY'
import json
from pathlib import Path
import sys

out_path, payload_path, url, target_name, image_tag = sys.argv[1:6]
body = {"targetName": target_name}
if image_tag:
    body["imageTag"] = image_tag
payload = {
    "method": "POST",
    "url": url,
    "headers": {
        "Authorization": "Bearer <redacted>",
        "Content-Type": "application/json",
        "Idempotency-Key": "<generated>",
    },
    "body": body,
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
Path(payload_path).write_text(json.dumps(body, separators=(",", ":")) + "\n", encoding="utf-8")
PY

    log "submitting builder workflow build target ${BUILDER_WORKFLOW_TARGET}"
    curl -skS \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' \
      -H "Idempotency-Key: ${idempotency_key}" \
      --data-binary "@${WORKFLOW_SUBMIT_PAYLOAD_FILE}" \
      -o "${WORKFLOW_SUBMIT_BODY_FILE}" \
      -D "${WORKFLOW_SUBMIT_META_FILE}" \
      "${BASE_URL}/api/v1/current-workspace/builds"
    require_http_success "builder workflow submit build" "${WORKFLOW_SUBMIT_META_FILE}" "${WORKFLOW_SUBMIT_BODY_FILE}"

    WORKFLOW_JOB_ID="$(python3 - "${WORKFLOW_SUBMIT_BODY_FILE}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
job_id = data.get("id", "")
if not job_id:
    raise SystemExit("missing job id in submit build response")
print(job_id)
PY
)"

    python3 - "${WORKFLOW_JOB_REQUEST_FILE}" "${BASE_URL}/api/v1/jobs/${WORKFLOW_JOB_ID}" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "GET",
    "url": url,
    "headers": {"Authorization": "Bearer <redacted>"},
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

    : > "${WORKFLOW_JOB_POLL_FILE}"
    for ((attempt = 1; attempt <= BUILDER_WORKFLOW_POLL_ATTEMPTS; attempt++)); do
      log "polling builder workflow job ${WORKFLOW_JOB_ID} (${attempt}/${BUILDER_WORKFLOW_POLL_ATTEMPTS})"
      curl -skS \
        -H "Authorization: Bearer ${TOKEN}" \
        -o "${WORKFLOW_JOB_BODY_FILE}" \
        -D "${WORKFLOW_JOB_META_FILE}" \
        "${BASE_URL}/api/v1/jobs/${WORKFLOW_JOB_ID}"
      WORKFLOW_FINAL_STATUS="$(python3 - "${WORKFLOW_JOB_BODY_FILE}" "${WORKFLOW_JOB_POLL_FILE}" "${attempt}" <<'PY'
import json
from pathlib import Path
import sys
from datetime import datetime, timezone

body_path, poll_path, attempt = sys.argv[1:4]
data = json.load(open(body_path, "r", encoding="utf-8"))
record = {
    "attempt": int(attempt),
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "status": data.get("status", ""),
    "reasonCode": data.get("reasonCode", ""),
    "errorMessage": data.get("errorMessage", ""),
}
with open(poll_path, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, sort_keys=True) + "\n")
print(record["status"])
PY
)"
      case "${WORKFLOW_FINAL_STATUS}" in
        succeeded|failed|cancelled|timed_out)
          break
          ;;
      esac
      sleep "${BUILDER_WORKFLOW_POLL_DELAY_SECONDS}"
    done

    python3 - "${WORKFLOW_STEPS_REQUEST_FILE}" "${BASE_URL}/api/v1/jobs/${WORKFLOW_JOB_ID}/steps" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "GET",
    "url": url,
    "headers": {"Authorization": "Bearer <redacted>"},
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

    log "fetching builder workflow job steps"
    curl -skS \
      -H "Authorization: Bearer ${TOKEN}" \
      -o "${WORKFLOW_STEPS_BODY_FILE}" \
      -D "${WORKFLOW_STEPS_META_FILE}" \
      "${BASE_URL}/api/v1/jobs/${WORKFLOW_JOB_ID}/steps"

    python3 - "${WORKFLOW_LOGS_REQUEST_FILE}" "${BASE_URL}/api/v1/jobs/${WORKFLOW_JOB_ID}/logs" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "GET",
    "url": url,
    "headers": {"Authorization": "Bearer <redacted>"},
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

    log "fetching builder workflow job logs"
    curl -skS \
      -H "Authorization: Bearer ${TOKEN}" \
      -o "${WORKFLOW_LOGS_BODY_FILE}" \
      -D "${WORKFLOW_LOGS_META_FILE}" \
      "${BASE_URL}/api/v1/jobs/${WORKFLOW_JOB_ID}/logs"

    if bool_true "${BUILDER_WORKFLOW_DELETE_WORKSPACE}" && [[ "${WORKFLOW_FINAL_STATUS}" == "succeeded" ]]; then
      python3 - "${WORKFLOW_DELETE_WORKSPACE_REQUEST_FILE}" "${BASE_URL}/api/v1/workspaces/${WORKFLOW_WORKSPACE_ID}" <<'PY'
import json
from pathlib import Path
import sys

out_path, url = sys.argv[1:3]
payload = {
    "method": "DELETE",
    "url": url,
    "headers": {"Authorization": "Bearer <redacted>"},
}
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
      log "deleting successful builder workflow workspace ${WORKFLOW_WORKSPACE_ID}"
      curl -skS \
        -X DELETE \
        -H "Authorization: Bearer ${TOKEN}" \
        -o "${WORKFLOW_DELETE_WORKSPACE_BODY_FILE}" \
        -D "${WORKFLOW_DELETE_WORKSPACE_META_FILE}" \
        "${BASE_URL}/api/v1/workspaces/${WORKFLOW_WORKSPACE_ID}"
    fi
  fi
fi

python3 - "${RUN_DIR}/metadata/client-verify.json" "${SCRIPT_DIR}" "${CONFIG_PATH}" "${BASE_URL}" "${USERNAME}" "${BUILDER_ENABLED}" "${BUILDER_EXPECT_DISABLED}" "${BUILDER_WORKFLOW_ENABLED}" "${BUILDER_WORKFLOW_EXPECT_SUCCESS}" "${BUILD_CATALOG_PATH}" "${WORKFLOW_WORKSPACE_ID}" "${WORKFLOW_JOB_ID}" "${WORKFLOW_FINAL_STATUS}" "${LOGIN_BODY_FILE}" "${LOGIN_META_FILE}" "${LOGIN_REQUEST_FILE}" "${SESSION_BODY_FILE}" "${SESSION_META_FILE}" "${SESSION_REQUEST_FILE}" "${USERS_BODY_FILE}" "${USERS_META_FILE}" "${USERS_REQUEST_FILE}" "${DISABLED_BUILD_PROFILES_BODY_FILE}" "${DISABLED_BUILD_PROFILES_META_FILE}" "${DISABLED_BUILD_PROFILES_REQUEST_FILE}" "${DISABLED_MCP_INITIALIZE_BODY_FILE}" "${DISABLED_MCP_INITIALIZE_META_FILE}" "${DISABLED_MCP_INITIALIZE_REQUEST_FILE}" "${DISABLED_MCP_TOOLS_BODY_FILE}" "${DISABLED_MCP_TOOLS_META_FILE}" "${DISABLED_MCP_TOOLS_REQUEST_FILE}" "${DISABLED_MCP_CALL_BODY_FILE}" "${DISABLED_MCP_CALL_META_FILE}" "${DISABLED_MCP_CALL_REQUEST_FILE}" "${BUILDER_PROFILES_BODY_FILE}" "${BUILDER_PROFILES_META_FILE}" "${BUILDER_PROFILES_REQUEST_FILE}" "${MCP_INITIALIZE_BODY_FILE}" "${MCP_INITIALIZE_META_FILE}" "${MCP_INITIALIZE_REQUEST_FILE}" "${MCP_TOOLS_BODY_FILE}" "${MCP_TOOLS_META_FILE}" "${MCP_TOOLS_REQUEST_FILE}" "${WORKFLOW_CREATE_WORKSPACE_BODY_FILE}" "${WORKFLOW_CREATE_WORKSPACE_META_FILE}" "${WORKFLOW_CREATE_WORKSPACE_REQUEST_FILE}" "${WORKFLOW_TARGETS_BODY_FILE}" "${WORKFLOW_TARGETS_META_FILE}" "${WORKFLOW_TARGETS_REQUEST_FILE}" "${WORKFLOW_SUBMIT_BODY_FILE}" "${WORKFLOW_SUBMIT_META_FILE}" "${WORKFLOW_SUBMIT_REQUEST_FILE}" "${WORKFLOW_JOB_BODY_FILE}" "${WORKFLOW_JOB_META_FILE}" "${WORKFLOW_JOB_REQUEST_FILE}" "${WORKFLOW_JOB_POLL_FILE}" "${WORKFLOW_STEPS_BODY_FILE}" "${WORKFLOW_STEPS_META_FILE}" "${WORKFLOW_STEPS_REQUEST_FILE}" "${WORKFLOW_LOGS_BODY_FILE}" "${WORKFLOW_LOGS_META_FILE}" "${WORKFLOW_LOGS_REQUEST_FILE}" "${WORKFLOW_DELETE_WORKSPACE_BODY_FILE}" "${WORKFLOW_DELETE_WORKSPACE_META_FILE}" "${WORKFLOW_DELETE_WORKSPACE_REQUEST_FILE}" <<'PY'
import json
from pathlib import Path
import sys

(
    out_path,
    scripts_dir,
    config_path,
    base_url,
    username,
    builder_enabled,
    builder_expect_disabled,
    builder_workflow_enabled,
    builder_workflow_expect_success,
    build_catalog_path,
    workflow_workspace_id,
    workflow_job_id,
    workflow_final_status,
    login_body,
    login_meta,
    login_request,
    session_body,
    session_meta,
    session_request,
    users_body,
    users_meta,
    users_request,
    disabled_build_profiles_body,
    disabled_build_profiles_meta,
    disabled_build_profiles_request,
    disabled_mcp_initialize_body,
    disabled_mcp_initialize_meta,
    disabled_mcp_initialize_request,
    disabled_mcp_tools_body,
    disabled_mcp_tools_meta,
    disabled_mcp_tools_request,
    disabled_mcp_call_body,
    disabled_mcp_call_meta,
    disabled_mcp_call_request,
    builder_profiles_body,
    builder_profiles_meta,
    builder_profiles_request,
    mcp_initialize_body,
    mcp_initialize_meta,
    mcp_initialize_request,
    mcp_tools_body,
    mcp_tools_meta,
    mcp_tools_request,
    workflow_create_workspace_body,
    workflow_create_workspace_meta,
    workflow_create_workspace_request,
    workflow_targets_body,
    workflow_targets_meta,
    workflow_targets_request,
    workflow_submit_body,
    workflow_submit_meta,
    workflow_submit_request,
    workflow_job_body,
    workflow_job_meta,
    workflow_job_request,
    workflow_job_poll,
    workflow_steps_body,
    workflow_steps_meta,
    workflow_steps_request,
    workflow_logs_body,
    workflow_logs_meta,
    workflow_logs_request,
    workflow_delete_workspace_body,
    workflow_delete_workspace_meta,
    workflow_delete_workspace_request,
) = sys.argv[1:66]
sys.path.insert(0, scripts_dir)

def status_code(path: str):
    code = None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.startswith("HTTP/"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                code = int(parts[1])
    return code

def summarize_json(path: str):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(data, dict):
      summary = {"keys": sorted(data.keys())}
      if "accessToken" in data:
        summary["hasAccessToken"] = True
      if "users" in data and isinstance(data["users"], list):
        summary["userCount"] = len(data["users"])
      if "tools" in data and isinstance(data["tools"], list):
        summary["toolNames"] = sorted(item.get("name", "") for item in data["tools"] if isinstance(item, dict))
      result = data.get("result")
      if isinstance(result, dict) and "tools" in result and isinstance(result["tools"], list):
        summary["toolNames"] = sorted(item.get("name", "") for item in result["tools"] if isinstance(item, dict))
      return summary
    if isinstance(data, list):
      return {"type": "list", "count": len(data)}
    return {"type": type(data).__name__}

def load_json_object(path: str):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"{path} did not contain a JSON object")
    return data

def load_request(path: str):
    return json.loads(Path(path).read_text(encoding="utf-8"))

def summarize_text(path: str):
    p = Path(path)
    if not p.is_file():
        return {"present": False}
    text = p.read_text(encoding="utf-8", errors="replace")
    return {
        "present": True,
        "bytes": len(text.encode("utf-8")),
        "lines": 0 if text == "" else len(text.splitlines()),
    }

def poll_history(path: str):
    p = Path(path)
    if not p.is_file():
        return []
    out = []
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        out.append(json.loads(line))
    return out

def load_source_secret_names(path: str):
    return []

def scan_for_secret_leaks(paths, source_secret_names):
    markers = [
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",
        "ssh-privatekey",
    ]
    findings = []
    for label, path in paths:
        p = Path(path)
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        for marker in markers:
            if marker in text:
                findings.append({"log": str(p), "kind": "private-key-marker", "value": marker})
        for name in source_secret_names:
            if name and name in text:
                findings.append({"log": str(p), "kind": "source-secret-name", "value": name})
    return findings

payload = {
    "configPath": config_path,
    "baseUrl": base_url,
    "username": username,
    "checks": {
        "login": {
            "request": load_request(login_request),
            "requestLog": login_request,
            "statusCode": status_code(login_meta),
            "summary": summarize_json(login_body),
            "bodyLog": login_body,
            "metaLog": login_meta,
        },
        "session": {
            "request": load_request(session_request),
            "requestLog": session_request,
            "statusCode": status_code(session_meta),
            "summary": summarize_json(session_body),
            "bodyLog": session_body,
            "metaLog": session_meta,
        },
        "users": {
            "request": load_request(users_request),
            "requestLog": users_request,
            "statusCode": status_code(users_meta),
            "summary": summarize_json(users_body),
            "bodyLog": users_body,
            "metaLog": users_meta,
        },
    },
}

for key in ("login", "session", "users"):
    code = payload["checks"][key]["statusCode"]
    if code is not None and code >= 400:
        raise SystemExit(f"{key} returned HTTP {code}")

expected_build_tools = [
    "cancel_job",
    "get_job_logs",
    "get_job_status",
    "get_job_steps",
    "get_workspace",
    "list_build_targets",
    "list_jobs",
    "list_work_profiles",
    "set_workspace",
    "submit_build",
]

if builder_enabled != "true" and builder_expect_disabled == "true":
    payload["checks"]["disabledBuildRoutes"] = {
        "workProfiles": {
            "request": load_request(disabled_build_profiles_request),
            "requestLog": disabled_build_profiles_request,
            "statusCode": status_code(disabled_build_profiles_meta),
            "expectedStatusCode": 404,
            "summary": summarize_text(disabled_build_profiles_body),
            "bodyLog": disabled_build_profiles_body,
            "metaLog": disabled_build_profiles_meta,
        },
        "mcpInitialize": {
            "request": load_request(disabled_mcp_initialize_request),
            "requestLog": disabled_mcp_initialize_request,
            "statusCode": status_code(disabled_mcp_initialize_meta),
            "summary": summarize_json(disabled_mcp_initialize_body),
            "bodyLog": disabled_mcp_initialize_body,
            "metaLog": disabled_mcp_initialize_meta,
        },
        "mcpToolsList": {
            "request": load_request(disabled_mcp_tools_request),
            "requestLog": disabled_mcp_tools_request,
            "statusCode": status_code(disabled_mcp_tools_meta),
            "summary": summarize_json(disabled_mcp_tools_body),
            "unexpectedToolNames": [],
            "expectedAbsentToolNames": expected_build_tools,
            "bodyLog": disabled_mcp_tools_body,
            "metaLog": disabled_mcp_tools_meta,
        },
        "mcpDirectToolCall": {
            "request": load_request(disabled_mcp_call_request),
            "requestLog": disabled_mcp_call_request,
            "statusCode": status_code(disabled_mcp_call_meta),
            "expectedJSONRPCError": {"code": -32601, "message": "Tool not found"},
            "summary": summarize_json(disabled_mcp_call_body),
            "bodyLog": disabled_mcp_call_body,
            "metaLog": disabled_mcp_call_meta,
        },
    }
    code = payload["checks"]["disabledBuildRoutes"]["workProfiles"]["statusCode"]
    if code != 404:
        raise SystemExit(f"disabled build route /api/v1/work-profiles returned HTTP {code}; want 404")
    for key in ("mcpInitialize", "mcpToolsList", "mcpDirectToolCall"):
        code = payload["checks"]["disabledBuildRoutes"][key]["statusCode"]
        if code is not None and code >= 400:
            raise SystemExit(f"disabled build {key} returned HTTP {code}")
    tools = payload["checks"]["disabledBuildRoutes"]["mcpToolsList"]["summary"].get("toolNames", [])
    unexpected = sorted(set(expected_build_tools) & set(tools))
    payload["checks"]["disabledBuildRoutes"]["mcpToolsList"]["unexpectedToolNames"] = unexpected
    if unexpected:
        raise SystemExit(f"disabled build MCP tools/list exposed build tools {unexpected}; got {tools}")
    direct_call = load_json_object(disabled_mcp_call_body)
    direct_error = direct_call.get("error")
    if not isinstance(direct_error, dict):
        raise SystemExit(f"disabled build direct MCP tools/call did not return a JSON-RPC error: {direct_call}")
    if direct_error.get("code") != -32601 or direct_error.get("message") != "Tool not found":
        raise SystemExit(f"disabled build direct MCP tools/call error = {direct_error}; want code -32601 message 'Tool not found'")

if builder_enabled == "true":
    payload["checks"]["builder"] = {
        "workProfiles": {
            "request": load_request(builder_profiles_request),
            "requestLog": builder_profiles_request,
            "statusCode": status_code(builder_profiles_meta),
            "summary": summarize_json(builder_profiles_body),
            "bodyLog": builder_profiles_body,
            "metaLog": builder_profiles_meta,
        },
        "mcpInitialize": {
            "request": load_request(mcp_initialize_request),
            "requestLog": mcp_initialize_request,
            "statusCode": status_code(mcp_initialize_meta),
            "summary": summarize_json(mcp_initialize_body),
            "bodyLog": mcp_initialize_body,
            "metaLog": mcp_initialize_meta,
        },
        "mcpToolsList": {
            "request": load_request(mcp_tools_request),
            "requestLog": mcp_tools_request,
            "statusCode": status_code(mcp_tools_meta),
            "summary": summarize_json(mcp_tools_body),
            "bodyLog": mcp_tools_body,
            "metaLog": mcp_tools_meta,
        },
    }
    for key in ("workProfiles", "mcpInitialize", "mcpToolsList"):
        code = payload["checks"]["builder"][key]["statusCode"]
        if code is not None and code >= 400:
            raise SystemExit(f"builder {key} returned HTTP {code}")
    expected_tools = expected_build_tools
    payload["checks"]["builder"]["mcpToolsList"]["expectedToolNames"] = expected_tools
    tools = payload["checks"]["builder"]["mcpToolsList"]["summary"].get("toolNames", [])
    missing = sorted(set(expected_tools) - set(tools))
    if missing:
        raise SystemExit(f"builder MCP tools/list missing expected tools {missing}; got {tools}")

    if builder_workflow_enabled == "true":
        workflow_payload = {
            "workspaceId": workflow_workspace_id,
            "jobId": workflow_job_id,
            "finalStatus": workflow_final_status,
            "expectSuccess": builder_workflow_expect_success == "true",
            "createWorkspace": {
                "request": load_request(workflow_create_workspace_request),
                "requestLog": workflow_create_workspace_request,
                "statusCode": status_code(workflow_create_workspace_meta),
                "summary": summarize_json(workflow_create_workspace_body),
                "bodyLog": workflow_create_workspace_body,
                "metaLog": workflow_create_workspace_meta,
            },
            "buildTargets": {
                "request": load_request(workflow_targets_request),
                "requestLog": workflow_targets_request,
                "statusCode": status_code(workflow_targets_meta),
                "summary": summarize_json(workflow_targets_body),
                "bodyLog": workflow_targets_body,
                "metaLog": workflow_targets_meta,
            },
            "submitBuild": {
                "request": load_request(workflow_submit_request),
                "requestLog": workflow_submit_request,
                "statusCode": status_code(workflow_submit_meta),
                "summary": summarize_json(workflow_submit_body),
                "bodyLog": workflow_submit_body,
                "metaLog": workflow_submit_meta,
            },
            "job": {
                "request": load_request(workflow_job_request),
                "requestLog": workflow_job_request,
                "statusCode": status_code(workflow_job_meta),
                "summary": summarize_json(workflow_job_body),
                "bodyLog": workflow_job_body,
                "metaLog": workflow_job_meta,
                "pollHistoryLog": workflow_job_poll,
                "pollHistory": poll_history(workflow_job_poll),
            },
            "steps": {
                "request": load_request(workflow_steps_request),
                "requestLog": workflow_steps_request,
                "statusCode": status_code(workflow_steps_meta),
                "summary": summarize_json(workflow_steps_body),
                "bodyLog": workflow_steps_body,
                "metaLog": workflow_steps_meta,
            },
            "logs": {
                "request": load_request(workflow_logs_request),
                "requestLog": workflow_logs_request,
                "statusCode": status_code(workflow_logs_meta),
                "summary": summarize_text(workflow_logs_body),
                "bodyLog": workflow_logs_body,
                "metaLog": workflow_logs_meta,
            },
        }
        delete_request_path = Path(workflow_delete_workspace_request)
        if delete_request_path.is_file():
            workflow_payload["deleteWorkspace"] = {
                "request": load_request(workflow_delete_workspace_request),
                "requestLog": workflow_delete_workspace_request,
                "statusCode": status_code(workflow_delete_workspace_meta),
                "summary": summarize_text(workflow_delete_workspace_body),
                "bodyLog": workflow_delete_workspace_body,
                "metaLog": workflow_delete_workspace_meta,
            }
        source_secret_names = load_source_secret_names(build_catalog_path)
        submit_body = load_json_object(workflow_submit_body)
        job_body = load_json_object(workflow_job_body)
        submit_artifact_ref = str(submit_body.get("artifactRef") or "").strip()
        job_artifact_ref = str(job_body.get("artifactRef") or "").strip()
        workflow_payload["artifactRef"] = {
            "submitBuild": submit_artifact_ref,
            "job": job_artifact_ref,
            "matched": bool(submit_artifact_ref and job_artifact_ref and submit_artifact_ref == job_artifact_ref),
        }
        leak_findings = scan_for_secret_leaks(
            [
                ("job", workflow_job_body),
                ("steps", workflow_steps_body),
                ("logs", workflow_logs_body),
            ],
            source_secret_names,
        )
        workflow_payload["secretLeakCheck"] = {
            "scannedLogs": [workflow_job_body, workflow_steps_body, workflow_logs_body],
            "sourceSecretNamesChecked": source_secret_names,
            "privateKeyMarkersChecked": True,
            "findings": leak_findings,
            "passed": len(leak_findings) == 0,
        }
        payload["checks"]["builder"]["workflow"] = workflow_payload
        for key in ("createWorkspace", "buildTargets", "submitBuild", "job", "steps", "logs"):
            code = workflow_payload[key]["statusCode"]
            if code is not None and code >= 400:
                raise SystemExit(f"builder workflow {key} returned HTTP {code}")
        if not submit_artifact_ref:
            raise SystemExit("builder workflow submitBuild response did not include artifactRef")
        if not job_artifact_ref:
            raise SystemExit("builder workflow job response did not include artifactRef")
        if submit_artifact_ref != job_artifact_ref:
            raise SystemExit(
                f"builder workflow artifactRef mismatch: submitBuild={submit_artifact_ref!r} job={job_artifact_ref!r}"
            )
        if leak_findings:
            raise SystemExit(f"builder workflow evidence contains possible secret material: {leak_findings}")
        if builder_workflow_expect_success == "true" and workflow_final_status != "succeeded":
            raise SystemExit(f"builder workflow final status = {workflow_final_status!r}, want 'succeeded'")

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

artifact_args=(
  --base-url "${BASE_URL}"
  --username "${USERNAME}"
  --run-dir "${RUN_DIR}"
  --oci-smoke-command "${ARTIFACT_OCI_SMOKE_CMD}"
  --oras-smoke-command "${ARTIFACT_ORAS_SMOKE_CMD}"
  --offline-smoke-command "${ARTIFACT_OFFLINE_SMOKE_CMD}"
)
if bool_true "${ARTIFACT_ENABLED}"; then
  artifact_args+=(--enabled)
fi
APPLIANCE_ACCESS_TOKEN="${TOKEN}" python3 "${SCRIPT_DIR}/verify-artifact-access.py" \
  "${artifact_args[@]}" >"${RUN_DIR}/logs/client-artifact-verification.json"
python3 - "${RUN_DIR}/metadata/client-verify.json" "${RUN_DIR}/metadata/artifact-client-verify.json" <<'PY'
import json
from pathlib import Path
import sys

client_path, artifact_path = map(Path, sys.argv[1:3])
client = json.loads(client_path.read_text(encoding="utf-8"))
client.setdefault("checks", {})["artifact"] = json.loads(
    artifact_path.read_text(encoding="utf-8")
)
client_path.write_text(json.dumps(client, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log "client verification metadata written to ${RUN_DIR}/metadata/client-verify.json"
if bool_true "${FINAL_OK}"; then
  printf 'ok\n'
fi
