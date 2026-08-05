#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
usage: bootstrap-default-license-on-target.sh [options]

Accept the base/free entitlement on the configured target host.
Safe to rerun when licensing is already resolved.

Required:
  --install-config PATH    install.kubernetes_namespace, control_plane_deployment

When not using --local:
  --config PATH            Devhost config (target_host.alias)

Options:
  --local
  --run-dir DIR
  --namespace NAME
  --deployment NAME
EOF
}

DEVHOST_CONFIG=""
INSTALL_CONFIG=""
LOCAL_MODE="false"
RUN_DIR=""
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

remote_script='set -euo pipefail
printf "%s\n" '"$(shell_quote "${target_sudo_password}")"' | sudo -S -p "" -v >/dev/null
echo "[target license] Waiting for control-plane rollout..."
sudo -n kubectl -n '"$(shell_quote "${NAMESPACE}")"' rollout status deploy/'"$(shell_quote "${DEPLOYMENT}")"' --timeout=180s >/dev/null
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
if sudo -n kubectl -n '"$(shell_quote "${NAMESPACE}")"' exec deploy/'"$(shell_quote "${DEPLOYMENT}")"' -- /appliance-server licensing accept-base >"${stdout_file}" 2>"${stderr_file}"; then
  cat "${stdout_file}"
  rm -f "${stdout_file}" "${stderr_file}"
  exit 0
fi
combined="$(cat "${stdout_file}" "${stderr_file}")"
rm -f "${stdout_file}" "${stderr_file}"
printf "%s\n" "${combined}" >&2
exit 1'

license_log="${RUN_DIR}/logs/bootstrap-default-license.log"
if bool_true "${LOCAL_MODE}"; then
  log "accepting default (base) license on this host"
else
  log "accepting default (base) license on ${TARGET_HOST}"
fi
set +e
if bool_true "${LOCAL_MODE}"; then
  run_local_logged "${license_log}" "${remote_script}"
else
  run_ssh_logged "${TARGET_HOST}" "${license_log}" "${remote_script}"
fi
license_status=$?
set -e
if [[ "${license_status}" -ne 0 ]]; then
  if [[ -f "${license_log}" ]] && grep -Eq 'licensing: accepted base entitlement|licensing: already resolved' "${license_log}"; then
    log "bootstrap-default-license command returned non-zero after a successful target-side result; accepting based on ${license_log}"
  else
    fail "bootstrap-default-license failed; see ${license_log}"
  fi
fi

python3 - "${RUN_DIR}/metadata/bootstrap-default-license.json" \
  "${INSTALL_CONFIG}" \
  "${DEVHOST_CONFIG:-}" \
  "${TARGET_HOST}" \
  "${NAMESPACE}" \
  "${DEPLOYMENT}" \
  "${license_log}" <<'PY'
import json
import sys

(
    out_path,
    install_config,
    devhost_config,
    target_host,
    namespace,
    deployment,
    license_log,
) = sys.argv[1:8]

payload = {
    "installConfigPath": install_config,
    "devhostConfigPath": devhost_config or None,
    "targetHost": target_host,
    "namespace": namespace,
    "deployment": deployment,
    "log": license_log,
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

log "bootstrap-default-license metadata written to ${RUN_DIR}/metadata/bootstrap-default-license.json"
