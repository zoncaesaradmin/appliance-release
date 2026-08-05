#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
usage: bootstrap-default-license-on-target.sh [options]

Accept the base/free (default) entitlement on the configured target host as an
explicit post-install step. Use this for simple installations so operators do
not need to complete licensing after first UI login. Safe to rerun: if
licensing is already resolved, acceptance is skipped successfully.

run-release-flow.sh invokes this only when install.enable_default_license is true.

Options:
  --config PATH              YAML or JSON config file (or a local appliance-release.config.yaml).
  --run-dir DIR              Local run directory.
  --namespace NAME           Override install.kubernetes_namespace.
  --deployment NAME          Control-plane deployment name.
                             Override install.control_plane_deployment.
EOF
}

CONFIG_PATH=""
RUN_DIR=""
NAMESPACE=""
DEPLOYMENT=""

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

CONFIG_PATH="$(require_config_path "${CONFIG_PATH}")"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"

if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="$(config_get_optional "${CONFIG_PATH}" "install.kubernetes_namespace" || true)"
fi
[[ -n "${NAMESPACE}" ]] || fail "install.kubernetes_namespace is required in config"
if [[ -z "${DEPLOYMENT}" ]]; then
  DEPLOYMENT="$(config_get_optional "${CONFIG_PATH}" "install.control_plane_deployment" || true)"
fi
[[ -n "${DEPLOYMENT}" ]] || fail "install.control_plane_deployment is required in config"

TARGET_HOST="$(config_get "${CONFIG_PATH}" "target_host.alias")"
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
log "accepting default (base) license on ${TARGET_HOST}"
if ! run_ssh_logged "${TARGET_HOST}" "${license_log}" "${remote_script}"; then
  if [[ -f "${license_log}" ]] && grep -Eq 'licensing: accepted base entitlement|licensing: already resolved' "${license_log}"; then
    log "bootstrap-default-license command returned non-zero after a successful target-side result; accepting based on ${license_log}"
  else
    fail "bootstrap-default-license failed; see ${license_log}"
  fi
fi

python3 - "${RUN_DIR}/metadata/bootstrap-default-license.json" "${CONFIG_PATH}" "${TARGET_HOST}" "${NAMESPACE}" "${DEPLOYMENT}" "${license_log}" <<'PY'
import json
import sys

(
    out_path,
    config_path,
    target_host,
    namespace,
    deployment,
    license_log,
) = sys.argv[1:7]

payload = {
    "configPath": config_path,
    "targetHost": target_host,
    "namespace": namespace,
    "deployment": deployment,
    "log": license_log,
    "action": "accept-base",
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

log "bootstrap-default-license metadata written to ${RUN_DIR}/metadata/bootstrap-default-license.json"
