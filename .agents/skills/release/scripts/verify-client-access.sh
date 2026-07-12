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
  --host URL_OR_IP         Override client_verification.base_url.
  --username NAME          Override client_verification.username.
  --password-env VAR       Environment variable holding the admin password.
                           Default: APPLIANCE_FIRST_ADMIN_PASSWORD
  --run-dir DIR            Local run directory.
  --final-ok               Print ok when all checks pass.
EOF
}

CONFIG_PATH=""
BASE_URL=""
USERNAME=""
PASSWORD_ENV="APPLIANCE_FIRST_ADMIN_PASSWORD"
RUN_DIR=""
FINAL_OK="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --host)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --username)
      USERNAME="${2:-}"
      shift 2
      ;;
    --password-env)
      PASSWORD_ENV="${2:-}"
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
if [[ -z "${BASE_URL}" ]]; then
  BASE_URL="$(config_get_optional "${CONFIG_PATH}" "client_verification.base_url" || true)"
fi
if [[ -z "${USERNAME}" ]]; then
  USERNAME="$(config_get_optional "${CONFIG_PATH}" "client_verification.username" || true)"
fi

BASE_URL="${BASE_URL:-https://192.168.1.101}"
USERNAME="${USERNAME:-admin}"
PASSWORD="$(resolve_secret "${PASSWORD_ENV}" "Appliance first-admin password")"

ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"

LOGIN_BODY_FILE="${RUN_DIR}/logs/client-login-body.json"
LOGIN_META_FILE="${RUN_DIR}/logs/client-login-meta.txt"
LOGIN_REQUEST_FILE="${RUN_DIR}/logs/client-login-request.json"
SESSION_BODY_FILE="${RUN_DIR}/logs/client-session-body.json"
SESSION_META_FILE="${RUN_DIR}/logs/client-session-meta.txt"
SESSION_REQUEST_FILE="${RUN_DIR}/logs/client-session-request.json"
USERS_BODY_FILE="${RUN_DIR}/logs/client-users-body.json"
USERS_META_FILE="${RUN_DIR}/logs/client-users-meta.txt"
USERS_REQUEST_FILE="${RUN_DIR}/logs/client-users-request.json"

python3 - "${LOGIN_REQUEST_FILE}" "${BASE_URL}/api/v1/auth/login" "${USERNAME}" <<'PY'
import json
from pathlib import Path
import sys

out_path, url, username = sys.argv[1:4]

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
PY

log "running client login check against ${BASE_URL}"
curl -skS \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}" \
  -o "${LOGIN_BODY_FILE}" \
  -D "${LOGIN_META_FILE}" \
  "${BASE_URL}/api/v1/auth/login"

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

python3 - "${RUN_DIR}/metadata/client-verify.json" "${CONFIG_PATH}" "${BASE_URL}" "${USERNAME}" "${LOGIN_BODY_FILE}" "${LOGIN_META_FILE}" "${LOGIN_REQUEST_FILE}" "${SESSION_BODY_FILE}" "${SESSION_META_FILE}" "${SESSION_REQUEST_FILE}" "${USERS_BODY_FILE}" "${USERS_META_FILE}" "${USERS_REQUEST_FILE}" <<'PY'
import json
from pathlib import Path
import sys

(
    out_path,
    config_path,
    base_url,
    username,
    login_body,
    login_meta,
    login_request,
    session_body,
    session_meta,
    session_request,
    users_body,
    users_meta,
    users_request,
) = sys.argv[1:14]

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
      return summary
    if isinstance(data, list):
      return {"type": "list", "count": len(data)}
    return {"type": type(data).__name__}

def load_request(path: str):
    return json.loads(Path(path).read_text(encoding="utf-8"))

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

Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log "client verification metadata written to ${RUN_DIR}/metadata/client-verify.json"
if bool_true "${FINAL_OK}"; then
  printf 'ok\n'
fi
