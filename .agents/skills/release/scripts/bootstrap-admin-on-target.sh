#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
usage: bootstrap-admin-on-target.sh [options]

Create the first appliance administrator on the configured target host as an
explicit post-install step. Safe to rerun: if already initialized, skip OK.

Required:
  --install-config PATH    install.bootstrap_admin_username, kubernetes, deployment

When not using --local:
  --config PATH            Devhost config (target_host.alias)

Options:
  --local                  Run on this host (no SSH).
  --run-dir DIR
  --admin-username NAME    Override install.bootstrap_admin_username
  --namespace NAME         Override install.kubernetes_namespace
  --deployment NAME        Override install.control_plane_deployment
EOF
}

DEVHOST_CONFIG=""
INSTALL_CONFIG=""
LOCAL_MODE="false"
RUN_DIR=""
ADMIN_USERNAME=""
NAMESPACE=""
DEPLOYMENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      DEVHOST_CONFIG="${2:-}"
      shift 2
      ;;
    --install-config)
      INSTALL_CONFIG="${2:-}"
      shift 2
      ;;
    --local)
      LOCAL_MODE="true"
      shift
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

[[ -n "${INSTALL_CONFIG}" ]] || fail "requires --install-config PATH"
INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"
if ! bool_true "${LOCAL_MODE}"; then
  [[ -n "${DEVHOST_CONFIG}" ]] || fail "requires --config PATH (devhost) unless --local"
  DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
fi

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"

if [[ -z "${ADMIN_USERNAME}" ]]; then
  ADMIN_USERNAME="$(config_get_optional "${INSTALL_CONFIG}" "install.bootstrap_admin_username" || true)"
fi
[[ -n "${ADMIN_USERNAME}" ]] || fail "install.bootstrap_admin_username is required in install config"
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="$(config_get_optional "${INSTALL_CONFIG}" "install.kubernetes_namespace" || true)"
fi
[[ -n "${NAMESPACE}" ]] || fail "install.kubernetes_namespace is required in install config"
if [[ -z "${DEPLOYMENT}" ]]; then
  DEPLOYMENT="$(config_get_optional "${INSTALL_CONFIG}" "install.control_plane_deployment" || true)"
fi
[[ -n "${DEPLOYMENT}" ]] || fail "install.control_plane_deployment is required in install config"

TARGET_HOST=""
if bool_true "${LOCAL_MODE}"; then
  if [[ -n "${DEVHOST_CONFIG}" ]]; then
    TARGET_HOST="$(config_get_optional "${DEVHOST_CONFIG}" "target_host.alias" || true)"
  fi
  if [[ -z "${TARGET_HOST}" ]]; then
    TARGET_HOST="local@$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo target-host)"
  fi
else
  TARGET_HOST="$(config_get "${DEVHOST_CONFIG}" "target_host.alias")"
fi
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
if bool_true "${LOCAL_MODE}"; then
  log "bootstrapping first administrator on this host"
else
  log "bootstrapping first administrator on ${TARGET_HOST}"
fi
set +e
if bool_true "${LOCAL_MODE}"; then
  run_local_logged "${bootstrap_log}" "${remote_script}"
else
  run_ssh_logged "${TARGET_HOST}" "${bootstrap_log}" "${remote_script}"
fi
bootstrap_status=$?
set -e
if [[ "${bootstrap_status}" -ne 0 ]]; then
  if [[ -f "${bootstrap_log}" ]] && grep -Eq 'bootstrap: created administrator|already initialized' "${bootstrap_log}"; then
    log "bootstrap-admin command returned non-zero after a successful target-side result; accepting based on ${bootstrap_log}"
  else
    fail "bootstrap-admin failed; see ${bootstrap_log}"
  fi
fi

python3 - "${RUN_DIR}/metadata/bootstrap-admin.json" \
  "${INSTALL_CONFIG}" \
  "${DEVHOST_CONFIG:-}" \
  "${TARGET_HOST}" \
  "${ADMIN_USERNAME}" \
  "${NAMESPACE}" \
  "${DEPLOYMENT}" \
  "${bootstrap_log}" <<'PY'
import json
import sys

(
    out_path,
    install_config,
    devhost_config,
    target_host,
    admin_username,
    namespace,
    deployment,
    bootstrap_log,
) = sys.argv[1:9]

payload = {
    "installConfigPath": install_config,
    "devhostConfigPath": devhost_config or None,
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
log "bootstrap-admin stage complete"
