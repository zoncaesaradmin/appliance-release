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
  --appliance-profile NAME   Override install.appliance_profile.
  --build-catalog PATH       Local build catalog JSON/YAML passed to zonctl.
  --preserve-failed-state    Pass zonctl's debug preserve-failed-state mode
                             through to install/upgrade on the target.
  --uninstall-first          Uninstall the previous appliance first.
  --run-dir DIR              Local run directory.
EOF
}

CONFIG_PATH=""
RELEASE_VERSION=""
APPLIANCE_PROFILE=""
BUILD_CATALOG_PATH=""
PRESERVE_FAILED_STATE="false"
UNINSTALL_FIRST=""
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
    --appliance-profile)
      APPLIANCE_PROFILE="${2:-}"
      shift 2
      ;;
    --build-catalog)
      BUILD_CATALOG_PATH="${2:-}"
      shift 2
      ;;
    --preserve-failed-state)
      PRESERVE_FAILED_STATE="true"
      shift 1
      ;;
    --uninstall-first)
      UNINSTALL_FIRST="true"
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
BASE_URL="$(config_get "${CONFIG_PATH}" "artifact_registry.base_url")"
PATH_PREFIX="$(config_get_optional "${CONFIG_PATH}" "artifact_registry.release_path_prefix" || true)"
if [[ -z "${PATH_PREFIX}" ]]; then
  PATH_PREFIX="appliance"
fi
STATE_DIR="$(config_get_optional "${CONFIG_PATH}" "target_host.state_dir" || true)"
if [[ -z "${STATE_DIR}" ]]; then
  STATE_DIR="/var/lib/zon/state"
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="$(config_get_optional "${CONFIG_PATH}" "install.appliance_profile" || true)"
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi
if [[ -z "${BUILD_CATALOG_PATH}" ]]; then
  BUILD_CATALOG_PATH="$(config_get_optional "${CONFIG_PATH}" "install.build_catalog_path" || true)"
fi
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  ensure_file "${BUILD_CATALOG_PATH}"
fi
if [[ "${APPLIANCE_PROFILE}" == "builder" && -z "${BUILD_CATALOG_PATH}" ]]; then
  fail "builder appliance profile requires install.build_catalog_path or --build-catalog; start from .agents/skills/release/references/build-catalog.example.yaml"
fi
if [[ -z "${UNINSTALL_FIRST}" ]]; then
  UNINSTALL_FIRST="$(config_get_optional "${CONFIG_PATH}" "install.uninstall_first" || true)"
fi
if [[ -n "${RELEASE_VERSION}" ]]; then
  OUT_DIR="/tmp/appliance-${RELEASE_VERSION}"
else
  OUT_DIR="/tmp/appliance-release"
fi
OUTPUT_FORMAT="text"

TARGET_HOST="$(config_get "${CONFIG_PATH}" "target_host.alias")"
ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"

[[ -n "${RELEASE_VERSION}" ]] || fail "--release-version is required for automated install"
helper_url="${BASE_URL}/${PATH_PREFIX}/${RELEASE_VERSION}/install-http-release.sh"
remote_release_dir="${BASE_URL}/${PATH_PREFIX}/${RELEASE_VERSION}"
bundle_url="${remote_release_dir}/appliance-${RELEASE_VERSION}-bundle.tar.gz"
checksums_url="${remote_release_dir}/sha256sum.txt"

preflight_public_url() {
  local url="$1"
  local label="$2"
  local output=""
  if ! output="$(curl -fsSIL "${url}" 2>&1)"; then
    fail "published ${label} is not reachable at ${url}. Check that the HTTP server is running and serving the release root/path prefix. curl output: ${output}"
  fi
}

preflight_public_url "${helper_url}" "install helper"
preflight_public_url "${bundle_url}" "bundle archive"
preflight_public_url "${checksums_url}" "checksum file"

target_sudo_password="$(resolve_secret "APPLIANCE_TARGET_SUDO_PASSWORD" "Target host sudo password")"
build_catalog_b64=""
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  build_catalog_b64="$(python3 - "${BUILD_CATALOG_PATH}" <<'PY'
import base64
import sys
from pathlib import Path

sys.stdout.write(base64.b64encode(Path(sys.argv[1]).read_bytes()).decode("ascii"))
PY
)"
fi
remote_script='set -euo pipefail
remote_dir='"$(shell_quote "${remote_release_dir}")"'
product_version='"$(shell_quote "${RELEASE_VERSION}")"'
out_dir='"$(shell_quote "${OUT_DIR}")"'
state_dir='"$(shell_quote "${STATE_DIR}")"'
build_catalog_b64='"$(shell_quote "${build_catalog_b64}")"'
preserve_failed_state='"$(shell_quote "${PRESERVE_FAILED_STATE}")"'
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
  --state-dir "${state_dir}"
  --output '"$(shell_quote "${OUTPUT_FORMAT}")"'
)
upgrade_args=(
  --bundle-dir "${bundle_dir}"
  --public-key "${public_key}"
  --state-dir "${state_dir}"
  --output '"$(shell_quote "${OUTPUT_FORMAT}")"'
)
if [[ -n "${build_catalog_b64}" ]]; then
  build_catalog_path="${out_dir}/build-catalog.yaml"
  printf "%s" "${build_catalog_b64}" | base64 -d > "${build_catalog_path}"
  install_args+=(--build-catalog "${build_catalog_path}")
  upgrade_args+=(--build-catalog "${build_catalog_path}")
fi
if [[ "${preserve_failed_state}" == "true" ]]; then
  install_args+=(--preserve-failed-state)
  upgrade_args+=(--preserve-failed-state)
fi
capture_zonctl_step() {
  local stdout_file="$1"
  local stderr_file="$2"
  local stdin_payload="$3"
  shift 3
  if [[ -n "${stdin_payload}" ]]; then
    printf "%s" "${stdin_payload}" | "$@" >"${stdout_file}" 2>"${stderr_file}"
    return $?
  fi
  "$@" >"${stdout_file}" 2>"${stderr_file}"
}
print_captured_failure() {
  local failure_message="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  echo "${failure_message}" >&2
  if [[ -s "${stdout_file}" ]]; then
    sed "s/^/  /" "${stdout_file}" >&2
  fi
  if [[ -s "${stderr_file}" ]]; then
    echo "  details:" >&2
    sed "s/^/    /" "${stderr_file}" >&2
  fi
}'

if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  remote_script+='
install_args+=(--appliance-profile '"$(shell_quote "${APPLIANCE_PROFILE}")"')
upgrade_args+=(--appliance-profile '"$(shell_quote "${APPLIANCE_PROFILE}")"')'
fi

remote_script+='
echo "[target 4/5] Running host preflight..."
sudo -n "${zonctl}" preflight --output '"$(shell_quote "${OUTPUT_FORMAT}")"'
echo "[target 4/5] Host preflight passed."'

if bool_true "${UNINSTALL_FIRST:-false}"; then
  remote_script+='
echo "[target] Uninstalling previous appliance before install..."
if [[ -f "${state_dir}/installed-state.json" ]] || systemctl list-unit-files k3s.service 2>/dev/null | grep -q "^k3s.service"; then
  uninstall_stdout="$(mktemp "${out_dir}/.zonctl-uninstall-stdout.XXXXXX")"
  uninstall_stderr="$(mktemp "${out_dir}/.zonctl-uninstall-stderr.XXXXXX")"
  if capture_zonctl_step "${uninstall_stdout}" "${uninstall_stderr}" "" sudo -n "${zonctl}" uninstall --confirm yes --state-dir "${state_dir}" --output text; then
    rm -f "${uninstall_stdout}" "${uninstall_stderr}"
  else
    print_captured_failure "[target] Previous appliance uninstall failed." "${uninstall_stdout}" "${uninstall_stderr}"
    rm -f "${uninstall_stdout}" "${uninstall_stderr}"
    exit 1
  fi
fi
echo "[target] Previous appliance uninstall step completed."'
fi

remote_script+='
echo "[target 5/5] Installing appliance platform."
install_stdout="$(mktemp "${out_dir}/.zonctl-install-stdout.XXXXXX")"
install_stderr="$(mktemp "${out_dir}/.zonctl-install-stderr.XXXXXX")"
if capture_zonctl_step "${install_stdout}" "${install_stderr}" "" sudo -n "${zonctl}" install "${install_args[@]}"; then
  rm -f "${install_stdout}" "${install_stderr}"
  echo "[target 5/5] Appliance installation completed."
else
  install_output="$(cat "${install_stdout}" "${install_stderr}")"
  if [[ "${install_output}" == *"refusing to install (reuse-owned)"* || "${install_output}" == *"refusing to install (upgrade-owned)"* ]]; then
    rm -f "${install_stdout}" "${install_stderr}"
    echo "[target 5/5] Existing owned appliance detected. Switching to in-place upgrade/reconcile."
    sudo -n "${zonctl}" upgrade "${upgrade_args[@]}"
    echo "[target 5/5] Appliance upgrade/reconcile completed."
  else
    print_captured_failure "[target 5/5] Appliance installation failed." "${install_stdout}" "${install_stderr}"
    rm -f "${install_stdout}" "${install_stderr}"
    exit 1
  fi
fi
echo "zonctl is now available at /usr/local/bin/zonctl on the target host."'

install_log="${RUN_DIR}/logs/install.log"
log "installing release on ${TARGET_HOST} using ${remote_release_dir}"
run_ssh_logged "${TARGET_HOST}" "${install_log}" "${remote_script}"

python3 - "${RUN_DIR}/metadata/install.json" "${CONFIG_PATH}" "${TARGET_HOST}" "${helper_url}" "${RELEASE_VERSION}" "${BASE_URL}" "${PATH_PREFIX}" "${STATE_DIR}" "${OUT_DIR}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" "${OUTPUT_FORMAT}" "${UNINSTALL_FIRST:-false}" "${PRESERVE_FAILED_STATE}" "${install_log}" <<'PY'
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
    out_dir,
    appliance_profile,
    build_catalog_path,
    output_format,
    uninstall_first,
    preserve_failed_state,
    install_log,
) = sys.argv[1:16]

payload = {
    "configPath": config_path,
    "targetHost": target_host,
    "helperUrl": helper_url,
    "installMethod": "direct-http-zonctl-auto",
    "releaseVersion": release_version or None,
    "baseUrl": base_url,
    "pathPrefix": path_prefix,
    "stateDir": state_dir or None,
    "outDir": out_dir,
    "bundleDir": f"{out_dir}/appliance-{release_version}-bundle" if release_version else None,
    "applianceProfile": appliance_profile or None,
    "buildCatalogPath": build_catalog_path or None,
    "outputFormat": output_format,
    "uninstallFirst": uninstall_first == "true",
    "preserveFailedState": preserve_failed_state == "true",
    "log": install_log,
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

log "install metadata written to ${RUN_DIR}/metadata/install.json"
