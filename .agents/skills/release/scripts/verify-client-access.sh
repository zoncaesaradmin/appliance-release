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
  --install-config PATH    Install role file (client_verification.*, install.appliance_profile)
  --devhost-config PATH    Optional Mac orchestrator config (target_host.alias → connect IP).
  --connect-ip IP          Force IPv4 for curl --resolve when base_url is a landns FQDN.
  --appliance-profile NAME Effective installed appliance profile.
  --run-dir DIR            Local run directory.
  --final-ok               Print ok when all checks pass.
EOF
}

INSTALL_CONFIG=""
DEVHOST_CONFIG=""
CONNECT_IP=""
APPLIANCE_PROFILE=""
RUN_DIR=""
FINAL_OK="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-config|--config)
      INSTALL_CONFIG="${2:-}"
      shift 2
      ;;
    --devhost-config)
      DEVHOST_CONFIG="${2:-}"
      shift 2
      ;;
    --connect-ip)
      CONNECT_IP="${2:-}"
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

[[ -n "${INSTALL_CONFIG}" ]] || fail "requires --install-config PATH"
INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"
require_cmd curl
require_cmd python3

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
BASE_URL="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.base_url" || true)"
USERNAME="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.username" || true)"
if [[ -z "${BASE_URL}" ]]; then
  if BASE_URL="$(derive_client_base_url_from_install "${INSTALL_CONFIG}" 2>/dev/null)"; then
    log "derived client_verification.base_url from install.appliance_name + install.dns_zone: ${BASE_URL}"
  else
    BASE_URL="https://192.168.1.101"
  fi
fi
reject_placeholder_client_base_url "${BASE_URL}" "client_verification.base_url"
USERNAME="${USERNAME:-admin}"
PASSWORD="$(resolve_secret "APPLIANCE_FIRST_ADMIN_PASSWORD" "Appliance first-admin password")"

if [[ -z "${CONNECT_IP}" ]]; then
  CONNECT_IP="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.connect_ip" || true)"
fi
if [[ -z "${CONNECT_IP}" && -n "${DEVHOST_CONFIG}" ]]; then
  DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
  if TARGET_ALIAS="$(config_get_optional "${DEVHOST_CONFIG}" "target_host.alias" || true)" \
    && TARGET_ALIAS="$(printf '%s' "${TARGET_ALIAS}" | tr -d '[:space:]')" \
    && [[ -n "${TARGET_ALIAS}" ]]; then
    if CONNECT_IP="$(ssh_target_ipv4 "${TARGET_ALIAS}" 2>/dev/null)"; then
      :
    else
      CONNECT_IP=""
    fi
  fi
fi

setup_client_connect_resolve "${BASE_URL}" "${CONNECT_IP}"
if [[ ${#CLIENT_CURL_EXTRA[@]} -gt 0 ]]; then
  log "client verify: mapping ${CLIENT_RESOLVE_HOST} → ${CLIENT_CONNECT_IP} via curl --resolve (Mac may not use appliance landns)"
fi
client_curl() {
  # bash 3.2 + set -u: empty "${arr[@]}" is unbound.
  if [[ ${#CLIENT_CURL_EXTRA[@]} -gt 0 ]]; then
    curl -skS "${CLIENT_CURL_EXTRA[@]}" "$@"
  else
    curl -skS "$@"
  fi
}

ensure_release_run_dirs "${RUN_DIR}"

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
BUILDER_ENABLED="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.builder.enabled" || true)"
BUILDER_EXPECT_DISABLED="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.builder.expect_disabled" || true)"
if [[ -n "$(config_get_optional "${INSTALL_CONFIG}" "client_verification.builder.workflow" || true)" ]] \
  || [[ -n "$(config_get_optional "${INSTALL_CONFIG}" "client_verification.builder.workflow.enabled" || true)" ]]; then
  fail "client_verification.builder.workflow was removed; client verify only checks builder profile routes/MCP tools (no catalog upload or build smoke). Remove client_verification.builder.workflow from the install config."
fi
ARTIFACT_ENABLED="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.artifact.enabled" || true)"
ARTIFACT_EXPECT_DENIED_SCOPE="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.artifact.expect_denied_scope" || true)"
ARTIFACT_OCI_SMOKE_CMD="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.artifact.oci_smoke_command" || true)"
ARTIFACT_ORAS_SMOKE_CMD="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.artifact.oras_smoke_command" || true)"
ARTIFACT_OFFLINE_SMOKE_CMD="$(config_get_optional "${INSTALL_CONFIG}" "client_verification.artifact.offline_smoke_command" || true)"
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="$(config_get_optional "${INSTALL_CONFIG}" "install.appliance_profile" || true)"
fi
APPLIANCE_PROFILE="$(require_appliance_profile "${INSTALL_CONFIG}" "${APPLIANCE_PROFILE}")"
if [[ -z "${BUILDER_ENABLED}" ]]; then
  if profile_supports_builder "${APPLIANCE_PROFILE}"; then
    BUILDER_ENABLED="true"
  else
    BUILDER_ENABLED="false"
  fi
fi
if [[ -z "${ARTIFACT_ENABLED}" ]]; then
  if profile_supports_artifacts "${APPLIANCE_PROFILE}"; then
    ARTIFACT_ENABLED="true"
  else
    ARTIFACT_ENABLED="false"
  fi
fi
if [[ -z "${ARTIFACT_EXPECT_DENIED_SCOPE}" ]]; then
  if [[ "${USERNAME}" == "admin" ]]; then
    ARTIFACT_EXPECT_DENIED_SCOPE="false"
  else
    ARTIFACT_EXPECT_DENIED_SCOPE="true"
  fi
fi
if [[ -z "${BUILDER_EXPECT_DISABLED}" ]]; then
  if bool_true "${BUILDER_ENABLED}"; then
    BUILDER_EXPECT_DISABLED="false"
  else
    BUILDER_EXPECT_DISABLED="true"
  fi
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
client_curl \
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
client_curl \
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
client_curl \
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
  client_curl \
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
  client_curl \
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
  client_curl \
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
  client_curl \
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
  client_curl \
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
  client_curl \
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
  client_curl \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Mcp-Session-Id: ${MCP_SESSION_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"2","method":"tools/list"}' \
    -o "${MCP_TOOLS_BODY_FILE}" \
    -D "${MCP_TOOLS_META_FILE}" \
    "${BASE_URL}/mcp"

fi

python3 - "${RUN_DIR}/metadata/client-verify.json" "${SCRIPT_DIR}" "${INSTALL_CONFIG}" "${BASE_URL}" "${USERNAME}" "${BUILDER_ENABLED}" "${BUILDER_EXPECT_DISABLED}" "${LOGIN_BODY_FILE}" "${LOGIN_META_FILE}" "${LOGIN_REQUEST_FILE}" "${SESSION_BODY_FILE}" "${SESSION_META_FILE}" "${SESSION_REQUEST_FILE}" "${USERS_BODY_FILE}" "${USERS_META_FILE}" "${USERS_REQUEST_FILE}" "${DISABLED_BUILD_PROFILES_BODY_FILE}" "${DISABLED_BUILD_PROFILES_META_FILE}" "${DISABLED_BUILD_PROFILES_REQUEST_FILE}" "${DISABLED_MCP_INITIALIZE_BODY_FILE}" "${DISABLED_MCP_INITIALIZE_META_FILE}" "${DISABLED_MCP_INITIALIZE_REQUEST_FILE}" "${DISABLED_MCP_TOOLS_BODY_FILE}" "${DISABLED_MCP_TOOLS_META_FILE}" "${DISABLED_MCP_TOOLS_REQUEST_FILE}" "${DISABLED_MCP_CALL_BODY_FILE}" "${DISABLED_MCP_CALL_META_FILE}" "${DISABLED_MCP_CALL_REQUEST_FILE}" "${BUILDER_PROFILES_BODY_FILE}" "${BUILDER_PROFILES_META_FILE}" "${BUILDER_PROFILES_REQUEST_FILE}" "${MCP_INITIALIZE_BODY_FILE}" "${MCP_INITIALIZE_META_FILE}" "${MCP_INITIALIZE_REQUEST_FILE}" "${MCP_TOOLS_BODY_FILE}" "${MCP_TOOLS_META_FILE}" "${MCP_TOOLS_REQUEST_FILE}" <<'PY'
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
) = sys.argv[1:38]
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

payload = {
    "installConfigPath": config_path,
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
    # Builder appliance-profile smoke only: routes and MCP tools are registered.
    # Does not upload or require a runtime build catalog.
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
if [[ -n "${CLIENT_CONNECT_IP}" ]] && ! is_ipv4_literal "${CLIENT_RESOLVE_HOST}"; then
  artifact_args+=(--connect-ip "${CLIENT_CONNECT_IP}")
fi
if bool_true "${ARTIFACT_ENABLED}"; then
  artifact_args+=(--enabled)
fi
if bool_true "${ARTIFACT_EXPECT_DENIED_SCOPE}"; then
  artifact_args+=(--expect-denied-scope)
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
