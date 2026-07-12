#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: install-on-target.sh [options]

Install a published appliance release on the configured target host by
downloading and running the HTTP installer helper remotely.

Options:
  --config PATH              YAML or JSON config file. Optional if
                             APPLIANCE_RELEASE_CONFIG is set or a local
                             appliance-release.config.yaml exists.
  --release-version VERSION  Release version to install. Defaults to release.version.
  --base-url URL             Override artifact_registry.base_url.
  --path-prefix PATH         Override artifact_registry.release_path_prefix. Default: appliance.
  --state-dir DIR            Override target_host.state_dir.
  --node-name NAME           Optional zonctl node name override.
  --out-dir DIR              Override the target-host download/extract directory.
  --bootstrap-admin-username NAME
                             Override install.bootstrap_admin_username.
  --appliance-profile NAME   Override install.appliance_profile.
  --output FORMAT            zonctl output format. Default: text.
  --uninstall-first          Uninstall the previous appliance first.
  --use-latest               Install from the latest alias instead of a versioned path.
  --run-dir DIR              Local run directory.
EOF
}

CONFIG_PATH=""
RELEASE_VERSION=""
BASE_URL=""
PATH_PREFIX=""
STATE_DIR=""
NODE_NAME=""
OUT_DIR=""
BOOTSTRAP_ADMIN_USERNAME=""
APPLIANCE_PROFILE=""
OUTPUT_FORMAT="text"
UNINSTALL_FIRST=""
USE_LATEST="false"
RUN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --release-version)
      RELEASE_VERSION="${2:-}"
      shift 2
      ;;
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --path-prefix)
      PATH_PREFIX="${2:-}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --node-name)
      NODE_NAME="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --bootstrap-admin-username)
      BOOTSTRAP_ADMIN_USERNAME="${2:-}"
      shift 2
      ;;
    --appliance-profile)
      APPLIANCE_PROFILE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_FORMAT="${2:-}"
      shift 2
      ;;
    --uninstall-first)
      UNINSTALL_FIRST="true"
      shift 1
      ;;
    --use-latest)
      USE_LATEST="true"
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
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(config_get_optional "${CONFIG_PATH}" "release.version" || true)"
fi
if [[ -z "${BASE_URL}" ]]; then
  BASE_URL="$(config_get "${CONFIG_PATH}" "artifact_registry.base_url")"
fi
if [[ -z "${PATH_PREFIX}" ]]; then
  PATH_PREFIX="$(config_get_optional "${CONFIG_PATH}" "artifact_registry.release_path_prefix" || true)"
fi
if [[ -z "${PATH_PREFIX}" ]]; then
  PATH_PREFIX="appliance"
fi
if [[ -z "${STATE_DIR}" ]]; then
  STATE_DIR="$(config_get_optional "${CONFIG_PATH}" "target_host.state_dir" || true)"
fi
if [[ -z "${BOOTSTRAP_ADMIN_USERNAME}" ]]; then
  BOOTSTRAP_ADMIN_USERNAME="$(config_get_optional "${CONFIG_PATH}" "install.bootstrap_admin_username" || true)"
fi
if [[ -z "${BOOTSTRAP_ADMIN_USERNAME}" ]]; then
  BOOTSTRAP_ADMIN_USERNAME="$(config_get_optional "${CONFIG_PATH}" "client_verification.username" || true)"
fi
if [[ -z "${BOOTSTRAP_ADMIN_USERNAME}" ]]; then
  BOOTSTRAP_ADMIN_USERNAME="admin"
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="$(config_get_optional "${CONFIG_PATH}" "install.appliance_profile" || true)"
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi
if [[ -z "${UNINSTALL_FIRST}" ]]; then
  UNINSTALL_FIRST="$(config_get_optional "${CONFIG_PATH}" "install.uninstall_first" || true)"
fi
if [[ -z "${OUT_DIR}" ]]; then
  if [[ -n "${RELEASE_VERSION}" ]]; then
    OUT_DIR="/tmp/appliance-${RELEASE_VERSION}"
  else
    OUT_DIR="/tmp/appliance-release"
  fi
fi

TARGET_HOST="$(config_get "${CONFIG_PATH}" "target_host.alias")"
ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"

[[ -n "${RELEASE_VERSION}" ]] || fail "--release-version is required for automated install"
if bool_true "${USE_LATEST}"; then
  helper_url="${BASE_URL}/${PATH_PREFIX}/latest/install-http-release.sh"
  remote_release_dir="${BASE_URL}/${PATH_PREFIX}/latest"
else
  helper_url="${BASE_URL}/${PATH_PREFIX}/${RELEASE_VERSION}/install-http-release.sh"
  remote_release_dir="${BASE_URL}/${PATH_PREFIX}/${RELEASE_VERSION}"
fi

target_sudo_password="$(resolve_secret "APPLIANCE_TARGET_SUDO_PASSWORD" "Target host sudo password")"
first_admin_password="$(resolve_secret "APPLIANCE_FIRST_ADMIN_PASSWORD" "First administrator password")"

remote_script='set -euo pipefail
remote_dir='"$(shell_quote "${remote_release_dir}")"'
product_version='"$(shell_quote "${RELEASE_VERSION}")"'
out_dir='"$(shell_quote "${OUT_DIR}")"'
bundle_archive="appliance-${product_version}-bundle.tar.gz"
public_key_file="release-signing.pub"
checksum_file="sha256sum.txt"
bundle_dir="${out_dir}/appliance-${product_version}-bundle"
public_key="${out_dir}/${public_key_file}"
zonctl="${bundle_dir}/zonctl"
printf "%s\n" '"$(shell_quote "${target_sudo_password}")"' | sudo -S -p "" -v >/dev/null
mkdir -p "${out_dir}"
echo "[target 1/5] Downloading release files..."
curl -fLo "${out_dir}/${bundle_archive}" "${remote_dir}/${bundle_archive}"
curl -fLo "${public_key}" "${remote_dir}/${public_key_file}"
curl -fLo "${out_dir}/${checksum_file}" "${remote_dir}/${checksum_file}"
echo "[target 1/5] Release files downloaded."
echo "[target 2/5] Verifying release checksums..."
if command -v sha256sum >/dev/null 2>&1; then
  (cd "${out_dir}" && sha256sum -c "${checksum_file}" >/dev/null)
else
  if ! command -v shasum >/dev/null 2>&1; then
    echo "install-on-target: need sha256sum or shasum to verify checksums" >&2
    exit 1
  fi
  tmp_checksums="${out_dir}/.sha256sum.tmp"
  awk '"'"'{print $1 "  " $2}'"'"' "${out_dir}/${checksum_file}" > "${tmp_checksums}"
  (cd "${out_dir}" && shasum -a 256 -c "$(basename "${tmp_checksums}")" >/dev/null)
  rm -f "${tmp_checksums}"
fi
echo "[target 2/5] Release checksums verified."
echo "[target 3/5] Extracting bundle..."
rm -rf "${bundle_dir}"
tar -C "${out_dir}" -xzf "${out_dir}/${bundle_archive}"
chmod +x "${zonctl}"
echo "[target 3/5] Bundle extracted to ${bundle_dir}."
install_args=(
  --bundle-dir "${bundle_dir}"
  --public-key "${public_key}"
  --state-dir '"$(shell_quote "${STATE_DIR}")"'
  --output '"$(shell_quote "${OUTPUT_FORMAT}")"'
  --bootstrap-admin-username '"$(shell_quote "${BOOTSTRAP_ADMIN_USERNAME}")"'
  --bootstrap-password-stdin
)'

if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  remote_script+='
install_args+=(--appliance-profile '"$(shell_quote "${APPLIANCE_PROFILE}")"')'
fi

if bool_true "${USE_LATEST}"; then
  remote_script+='
echo "[target] Using latest release alias at '"$(shell_quote "${remote_release_dir}")"'."'
fi

if [[ -n "${NODE_NAME}" ]]; then
  remote_script+='
install_args+=(--node-name '"$(shell_quote "${NODE_NAME}")"')'
fi
remote_script+='
echo "[target 4/5] Running host preflight..."
sudo -n "${zonctl}" preflight --output '"$(shell_quote "${OUTPUT_FORMAT}")"'
echo "[target 4/5] Host preflight passed."'

if bool_true "${UNINSTALL_FIRST:-false}"; then
  remote_script+='
echo "[target] Uninstalling previous appliance before install..."
if command -v zonctl >/dev/null 2>&1; then
  sudo -n zonctl uninstall --confirm yes --state-dir '"$(shell_quote "${STATE_DIR:-/var/lib/zon}")"' --output text >/dev/null 2>&1 || true
fi
echo "[target] Previous appliance uninstall step completed."'
fi

remote_script+='
echo "[target 5/5] Installing appliance platform."
printf "%s\n" '"$(shell_quote "${first_admin_password}")"' | sudo -n "${zonctl}" install "${install_args[@]}"
echo "[target 5/5] Appliance installation completed."
echo "zonctl is now available at /usr/local/bin/zonctl on the target host."'

install_log="${RUN_DIR}/logs/install.log"
log "installing release on ${TARGET_HOST} using ${remote_release_dir}"
run_ssh_logged "${TARGET_HOST}" "${install_log}" "${remote_script}"

python3 - "${RUN_DIR}/metadata/install.json" "${CONFIG_PATH}" "${TARGET_HOST}" "${helper_url}" "${RELEASE_VERSION}" "${BASE_URL}" "${PATH_PREFIX}" "${STATE_DIR}" "${NODE_NAME}" "${OUT_DIR}" "${BOOTSTRAP_ADMIN_USERNAME}" "${APPLIANCE_PROFILE}" "${OUTPUT_FORMAT}" "${USE_LATEST}" "${UNINSTALL_FIRST:-false}" "${install_log}" <<'PY'
import json
import sys

(
    out_path,
    config_path,
    target_host,
    helper_url,
    release_version,
    base_url,
    path_prefix,
    state_dir,
    node_name,
    out_dir,
    bootstrap_admin_username,
    appliance_profile,
    output_format,
    use_latest,
    uninstall_first,
    install_log,
) = sys.argv[1:17]

payload = {
    "configPath": config_path,
    "targetHost": target_host,
    "helperUrl": helper_url,
    "installMethod": "direct-http-zonctl",
    "releaseVersion": release_version or None,
    "baseUrl": base_url,
    "pathPrefix": path_prefix,
    "stateDir": state_dir or None,
    "nodeName": node_name or None,
    "outDir": out_dir,
    "bundleDir": f"{out_dir}/appliance-{release_version}-bundle" if release_version else None,
    "bootstrapAdminUsername": bootstrap_admin_username,
    "applianceProfile": appliance_profile or None,
    "outputFormat": output_format,
    "useLatest": use_latest == "true",
    "uninstallFirst": uninstall_first == "true",
    "log": install_log,
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

log "install metadata written to ${RUN_DIR}/metadata/install.json"
