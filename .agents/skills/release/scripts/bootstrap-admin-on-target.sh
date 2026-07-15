#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: bootstrap-admin-on-target.sh [options]

Create the first appliance administrator on the configured target host as an
explicit post-install step. This is safe to rerun: if the appliance is already
initialized, the bootstrap is skipped successfully.

Options:
  --config PATH              YAML or JSON config file. Optional if
                             APPLIANCE_RELEASE_CONFIG is set or a local
                             appliance-release.config.yaml exists.
  --run-dir DIR              Local run directory.
  --admin-username NAME      Override install.bootstrap_admin_username.
  --namespace NAME           Kubernetes namespace. Default: zon
  --deployment NAME          Control-plane deployment name.
                             Default: zon-appliance-control-plane
EOF
}

CONFIG_PATH=""
RUN_DIR=""
ADMIN_USERNAME=""
NAMESPACE="zon"
DEPLOYMENT="zon-appliance-control-plane"

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
    --admin-username)
      ADMIN_USERNAME="${2:-}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --deployment)
      DEPLOYMENT="${2:-}"
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
ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"

if [[ -z "${ADMIN_USERNAME}" ]]; then
  ADMIN_USERNAME="$(config_get_optional "${CONFIG_PATH}" "install.bootstrap_admin_username" || true)"
fi
if [[ -z "${ADMIN_USERNAME}" ]]; then
  ADMIN_USERNAME="$(config_get_optional "${CONFIG_PATH}" "client_verification.username" || true)"
fi
if [[ -z "${ADMIN_USERNAME}" ]]; then
  ADMIN_USERNAME="admin"
fi

TARGET_HOST="$(config_get "${CONFIG_PATH}" "target_host.alias")"
target_sudo_password="$(resolve_secret "APPLIANCE_TARGET_SUDO_PASSWORD" "Target host sudo password")"
first_admin_password="$(resolve_secret "APPLIANCE_FIRST_ADMIN_PASSWORD" "First administrator password")"

remote_script='set -euo pipefail
printf "%s\n" '"$(shell_quote "${target_sudo_password}")"' | sudo -S -p "" -v >/dev/null
echo "[target bootstrap] Waiting for control-plane rollout..."
sudo -n kubectl -n '"$(shell_quote "${NAMESPACE}")"' rollout status deploy/'"$(shell_quote "${DEPLOYMENT}")"' --timeout=180s >/dev/null
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
if printf "%s" '"$(shell_quote "${first_admin_password}")"' | sudo -n kubectl -n '"$(shell_quote "${NAMESPACE}")"' exec -i deploy/'"$(shell_quote "${DEPLOYMENT}")"' -- /appliance-server bootstrap init --admin-username '"$(shell_quote "${ADMIN_USERNAME}")"' --admin-password-file /dev/stdin >"${stdout_file}" 2>"${stderr_file}"; then
  cat "${stdout_file}"
  rm -f "${stdout_file}" "${stderr_file}"
  exit 0
fi
combined="$(cat "${stdout_file}" "${stderr_file}")"
rm -f "${stdout_file}" "${stderr_file}"
if [[ "${combined}" == *"already initialized"* ]]; then
  printf "%s\n" "${combined}"
  exit 0
fi
printf "%s\n" "${combined}" >&2
exit 1'

bootstrap_log="${RUN_DIR}/logs/bootstrap-admin.log"
log "bootstrapping first administrator on ${TARGET_HOST}"
run_ssh_logged "${TARGET_HOST}" "${bootstrap_log}" "${remote_script}"

python3 - "${RUN_DIR}/metadata/bootstrap-admin.json" "${CONFIG_PATH}" "${TARGET_HOST}" "${ADMIN_USERNAME}" "${NAMESPACE}" "${DEPLOYMENT}" "${bootstrap_log}" <<'PY'
import json
import sys

(
    out_path,
    config_path,
    target_host,
    admin_username,
    namespace,
    deployment,
    bootstrap_log,
) = sys.argv[1:8]

payload = {
    "configPath": config_path,
    "targetHost": target_host,
    "adminUsername": admin_username,
    "namespace": namespace,
    "deployment": deployment,
    "log": bootstrap_log,
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

log "bootstrap-admin metadata written to ${RUN_DIR}/metadata/bootstrap-admin.json"
