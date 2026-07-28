#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: install-on-target.sh [options]

Install a published appliance release on the configured target host.

For bundle_store.mode=static_http or appliance_files the target downloads the package
over HTTP(S) from bundle_store.base_url. In appliance_files mode this is the
appliance-managed authenticated file API path, typically
https://<artifact-fqdn>/api/v1/files. The Mac only orchestrates SSH; published
artifact reachability is checked from the target (LAN DNS), not the Mac.

Options:
  --config PATH              YAML or JSON config file. Optional if
                             APPLIANCE_RELEASE_CONFIG is set or a local
                             appliance-release.config.yaml exists.
  --release-version VERSION  Release version to install. Defaults to release.version.
  --appliance-profile NAME   Override install.appliance_profile.
  --build-catalog PATH       Local build catalog JSON/YAML passed to zonctl.
  --appliance-name NAME      Product LAN instance label (single DNS label).
                             FQDN becomes <name>.<dns-zone> for TLS,
                             canonicalOrigin, and registry realm.
  --dns-zone ZONE            LAN DNS zone (default appliance.internal).
  --tls-san SAN              Additional TLS SAN to include on the appliance
                             certificate. Repeatable.
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
APPLIANCE_NAME=""
DNS_ZONE=""
TLS_SANS=()
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
    --appliance-name)
      APPLIANCE_NAME="${2:-}"
      shift 2
      ;;
    --dns-zone)
      DNS_ZONE="${2:-}"
      shift 2
      ;;
    --tls-san)
      TLS_SANS+=("${2:-}")
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
BUNDLE_STORE_MODE="$(resolve_bundle_store_mode "${CONFIG_PATH}")"
BASE_URL="$(bundle_store_get_optional "${CONFIG_PATH}" "base_url" || true)"
PATH_PREFIX="$(bundle_store_get_optional "${CONFIG_PATH}" "release_path_prefix" || true)"
[[ -n "${PATH_PREFIX}" ]] || fail "bundle_store.release_path_prefix is required in config"
STATE_DIR="$(config_get_optional "${CONFIG_PATH}" "target_host.state_dir" || true)"
[[ -n "${STATE_DIR}" ]] || fail "target_host.state_dir is required in config"
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="$(config_get_optional "${CONFIG_PATH}" "install.appliance_profile" || true)"
fi
[[ -n "${APPLIANCE_PROFILE}" ]] || fail "install.appliance_profile is required in config"
if [[ -z "${BUILD_CATALOG_PATH}" ]]; then
  BUILD_CATALOG_PATH="$(config_get_optional "${CONFIG_PATH}" "install.build_catalog_path" || true)"
fi
if [[ -z "${APPLIANCE_NAME}" ]]; then
  APPLIANCE_NAME="$(config_get_optional "${CONFIG_PATH}" "install.appliance_name" || true)"
fi
[[ -n "${APPLIANCE_NAME}" ]] || fail "install.appliance_name (or --appliance-name) is required; FQDN becomes <name>.<dns_zone>"
if [[ -z "${DNS_ZONE}" ]]; then
  DNS_ZONE="$(config_get_optional "${CONFIG_PATH}" "install.dns_zone" || true)"
fi
[[ -n "${DNS_ZONE}" ]] || fail "install.dns_zone is required in config"
ADDITIONAL_TLS_SANS_CSV="$(config_get_optional "${CONFIG_PATH}" "install.additional_tls_sans_csv" || true)"
if [[ -n "${ADDITIONAL_TLS_SANS_CSV}" ]]; then
  IFS=',' read -r -a configured_tls_sans <<<"${ADDITIONAL_TLS_SANS_CSV}"
  for configured_san in "${configured_tls_sans[@]}"; do
    configured_san="${configured_san#"${configured_san%%[![:space:]]*}"}"
    configured_san="${configured_san%"${configured_san##*[![:space:]]}"}"
    if [[ -n "${configured_san}" ]]; then
      TLS_SANS+=("${configured_san}")
    fi
  done
fi
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  ensure_file "${BUILD_CATALOG_PATH}"
fi
if [[ "${APPLIANCE_PROFILE}" == "builder" || "${APPLIANCE_PROFILE}" == "builder-landns" || "${APPLIANCE_PROFILE}" == "builder-storage-landns" ]] && [[ -z "${BUILD_CATALOG_PATH}" ]]; then
  fail "builder appliance profile requires install.build_catalog_path or --build-catalog; start from .agents/skills/release/references/build-catalog.example.yaml"
fi
if [[ -z "${UNINSTALL_FIRST}" ]]; then
  UNINSTALL_FIRST="$(config_get_optional "${CONFIG_PATH}" "install.uninstall_first" || true)"
fi
[[ -n "${UNINSTALL_FIRST}" ]] || fail "install.uninstall_first is required in config (true|false)"
[[ -n "${RELEASE_VERSION}" ]] || fail "release.version is required in config (or pass --release-version)"
OUT_DIR="$(config_get_optional "${CONFIG_PATH}" "install.bundle_download_dir" || true)"
[[ -n "${OUT_DIR}" ]] || fail "install.bundle_download_dir is required in config"
OUTPUT_FORMAT="text"

TARGET_HOST="$(config_get "${CONFIG_PATH}" "target_host.alias")"
ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/metadata"
ensure_dir "${RUN_DIR}/artifacts"

[[ -n "${RELEASE_VERSION}" ]] || fail "--release-version is required for automated install"

# static_http and appliance_files both fetch over HTTP(S). appliance_files uses
# the appliance-managed authenticated file API path.
BUNDLE_STORE_CURL_TLS_ARGS=()
case "${BUNDLE_STORE_MODE}" in
  static_http|appliance_files)
    [[ -n "${BASE_URL}" ]] || fail "bundle_store.mode=${BUNDLE_STORE_MODE} requires bundle_store.base_url"
    bundle_store_bearer_token=""
    if [[ "${BUNDLE_STORE_MODE}" == "appliance_files" ]]; then
      require_appliance_files_base_url "${BASE_URL}"
      bundle_store_bearer_token="$(resolve_appliance_files_bearer_token "${CONFIG_PATH}" "${BASE_URL}")"
      bundle_store_fill_curl_tls_args "${CONFIG_PATH}"
    fi
    helper_url="${BASE_URL}/${PATH_PREFIX}/${RELEASE_VERSION}/install-http-release.sh"
    remote_release_dir="${BASE_URL}/${PATH_PREFIX}/${RELEASE_VERSION}"
    bundle_url="${remote_release_dir}/appliance-${RELEASE_VERSION}-bundle.tar.gz"
    checksums_url="${remote_release_dir}/sha256sum.txt"

    # Preflight on the target (not the Mac). appliance_files base_url often uses
    # LAN DNS (*.appliance.internal) that the orchestrating Mac cannot resolve,
    # and /etc/hosts on the target must not map that distributor FQDN to itself.
    preflight_log="${RUN_DIR}/logs/bundle-store-preflight.log"
    : >"${preflight_log}"
    preflight_public_url_on_target() {
      local url="$1"
      local label="$2"
      local step_log="${preflight_log}.${label// /_}"
      local remote_curl_init=""
      local auth_header="" remote_cmd output="" url_host=""
      url_host="$(python3 -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).hostname or "")' "${url}")"
      [[ -n "${url_host}" ]] || fail "could not parse host from published ${label} url ${url}"
      remote_curl_init="$(bundle_store_remote_curl_array_init curl_args -fsSIL)"
      if [[ -n "${bundle_store_bearer_token}" ]]; then
        auth_header="Authorization: Bearer ${bundle_store_bearer_token}"
      fi
      remote_cmd="set -euo pipefail
${remote_curl_init}
url=$(shell_quote "${url}")
host=$(shell_quote "${url_host}")
resolved=\$(getent ahostsv4 \"\${host}\" 2>/dev/null | awk '{print \$1; exit}' || true)
my_ips=\$(hostname -I 2>/dev/null || true)
for ip in \${my_ips}; do
  if [[ -n \"\${resolved}\" && \"\${resolved}\" == \"\${ip}\" ]]; then
    echo \"bundle_store host \${host} resolves to this target (\${resolved}) via local name resolution (often /etc/hosts from a prior zonctl install). install.appliance_name must be distinct from the distributor FQDN in bundle_store.base_url; remove the '# BEGIN zon-appliance-dns' … '# END zon-appliance-dns' block from /etc/hosts on this host, set a unique appliance_name, then retry.\" >&2
    exit 1
  fi
done"
      if [[ -n "${auth_header}" ]]; then
        remote_cmd+="
curl \"\${curl_args[@]}\" -H $(shell_quote "${auth_header}") \"\${url}\" >/dev/null"
      else
        remote_cmd+="
curl \"\${curl_args[@]}\" \"\${url}\" >/dev/null"
      fi
      if ! run_ssh_captured "${TARGET_HOST}" "${step_log}" "${remote_cmd}"; then
        output="$(cat "${step_log}" 2>/dev/null || true)"
        {
          echo "=== ${label} ${url} ==="
          printf '%s\n' "${output}"
        } >>"${preflight_log}"
        fail "published ${label} is not reachable from target ${TARGET_HOST} at ${url}. The Mac does not need to resolve LAN DNS; the target must. Check distributor uptime, LAN DNS, TLS (-k/cacert), and that install.appliance_name is not the distributor FQDN. curl output: ${output}"
      fi
      {
        echo "=== ${label} ${url} ==="
        echo "ok"
      } >>"${preflight_log}"
    }

    log "preflight: checking published artifacts from target ${TARGET_HOST}"
    preflight_public_url_on_target "${helper_url}" "install helper"
    preflight_public_url_on_target "${bundle_url}" "bundle archive"
    preflight_public_url_on_target "${checksums_url}" "checksum file"
    INSTALL_SOURCE_LABEL="${remote_release_dir}"
    ;;
  *)
    fail "unsupported bundle_store.mode: ${BUNDLE_STORE_MODE}"
    ;;
esac
if [[ "${APPLIANCE_PROFILE}" == "builder" || "${APPLIANCE_PROFILE}" == "builder-landns" || "${APPLIANCE_PROFILE}" == "builder-storage-landns" ]] && [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  catalog_validation_log="${RUN_DIR}/logs/build-catalog-validation.json"
  if ! python3 "${SCRIPT_DIR}/validate-build-catalog.py" \
    --config "${CONFIG_PATH}" \
    --build-catalog "${BUILD_CATALOG_PATH}" \
    --output-json "${catalog_validation_log}" \
    >"${catalog_validation_log}.stdout" 2>"${catalog_validation_log}.stderr"; then
    fail "builder build catalog validation failed; see ${catalog_validation_log}"
  fi
  log "builder build catalog validation completed; log: ${catalog_validation_log}"
fi

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

# Serialize TLS curl flags for the remote target script. Prefer -k over
# shipping a Mac-local cacert path that may not exist on the target.
if [[ "${BUNDLE_STORE_CURL_TLS_ARGS[*]:-}" == *"--cacert"* ]]; then
  log "appliance_files: bundle_store.cacert_path is Mac-local; target download uses -k unless the target already trusts the distributor CA"
fi
remote_curl_tls_init="$(bundle_store_remote_curl_array_init curl_tls_args)"

remote_script='set -euo pipefail
remote_dir='"$(shell_quote "${remote_release_dir}")"'
product_version='"$(shell_quote "${RELEASE_VERSION}")"'
out_dir='"$(shell_quote "${OUT_DIR}")"'
state_dir='"$(shell_quote "${STATE_DIR}")"'
build_catalog_b64='"$(shell_quote "${build_catalog_b64}")"'
preserve_failed_state='"$(shell_quote "${PRESERVE_FAILED_STATE}")"'
artifact_bearer_token='"$(shell_quote "${bundle_store_bearer_token:-}")"'
bundle_archive="appliance-${product_version}-bundle.tar.gz"
public_key_file="release-signing.pub"
checksum_file="sha256sum.txt"
bundle_dir="${out_dir}/appliance-${product_version}-bundle"
public_key="${out_dir}/${public_key_file}"
zonctl="${bundle_dir}/zonctl"
'"${remote_curl_tls_init}"'
curl_auth_args=()
if [[ -n "${artifact_bearer_token}" ]]; then
  curl_auth_args=(-H "Authorization: Bearer ${artifact_bearer_token}")
fi
printf "%s\n" '"$(shell_quote "${target_sudo_password}")"' | sudo -S -p "" -v >/dev/null
mkdir -p "${out_dir}"
echo "[target 1/5] Downloading release files..."
curl "${curl_tls_args[@]}" "${curl_auth_args[@]}" -fLo "${out_dir}/${bundle_archive}" "${remote_dir}/${bundle_archive}"
curl "${curl_tls_args[@]}" "${curl_auth_args[@]}" -fLo "${public_key}" "${remote_dir}/${public_key_file}"
curl "${curl_tls_args[@]}" "${curl_auth_args[@]}" -fLo "${out_dir}/${checksum_file}" "${remote_dir}/${checksum_file}"
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
'
remote_script+='
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
if [[ -n '"$(shell_quote "${APPLIANCE_NAME}")"' ]]; then
  install_args+=(--appliance-name '"$(shell_quote "${APPLIANCE_NAME}")"')
  upgrade_args+=(--appliance-name '"$(shell_quote "${APPLIANCE_NAME}")"')
fi
if [[ -n '"$(shell_quote "${DNS_ZONE}")"' ]]; then
  install_args+=(--dns-zone '"$(shell_quote "${DNS_ZONE}")"')
  upgrade_args+=(--dns-zone '"$(shell_quote "${DNS_ZONE}")"')
fi
'
if ((${#TLS_SANS[@]} > 0)); then
  for tls_san in "${TLS_SANS[@]}"; do
    remote_script+='
install_args+=(--tls-san '"$(shell_quote "${tls_san}")"')
upgrade_args+=(--tls-san '"$(shell_quote "${tls_san}")"')'
  done
fi
remote_script+='
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
# Also clear hosts left mid-install (--preserve-failed-state / crash): those
# keep transaction.json in-progress even when installed-state is absent.
if [[ -f "${state_dir}/installed-state.json" ]] || [[ -f "${state_dir}/transaction.json" ]] || systemctl list-unit-files k3s.service 2>/dev/null | grep -q "^k3s.service"; then
  uninstall_stdout="$(mktemp "${out_dir}/.zonctl-uninstall-stdout.XXXXXX")"
  uninstall_stderr="$(mktemp "${out_dir}/.zonctl-uninstall-stderr.XXXXXX")"
  if capture_zonctl_step "${uninstall_stdout}" "${uninstall_stderr}" "" sudo -n "${zonctl}" uninstall --confirm yes --state-dir "${state_dir}" --output text; then
    sudo -n systemctl daemon-reload
    if [[ -f "${state_dir}/installed-state.json" ]]; then
      echo "[target] zonctl uninstall returned success but left ${state_dir}/installed-state.json; removing stale ownership record before reinstall." >&2
      sudo -n rm -f "${state_dir}/installed-state.json"
    fi
    if [[ -f "${state_dir}/installed-state.json" ]]; then
      print_captured_failure "[target] Previous appliance uninstall did not remove installed-state." "${uninstall_stdout}" "${uninstall_stderr}"
      rm -f "${uninstall_stdout}" "${uninstall_stderr}"
      exit 1
    fi
    if systemctl list-unit-files k3s.service 2>/dev/null | grep -q "^k3s.service"; then
      print_captured_failure "[target] Previous appliance uninstall did not remove k3s.service." "${uninstall_stdout}" "${uninstall_stderr}"
      rm -f "${uninstall_stdout}" "${uninstall_stderr}"
      exit 1
    fi
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
log "installing release on ${TARGET_HOST} using ${INSTALL_SOURCE_LABEL} (mode=${BUNDLE_STORE_MODE})"
set +e
run_ssh_logged "${TARGET_HOST}" "${install_log}" "${remote_script}"
install_exit_code=$?
set -e

python3 - "${RUN_DIR}/metadata/install.json" "${CONFIG_PATH}" "${TARGET_HOST}" "${helper_url}" "${RELEASE_VERSION}" "${BUNDLE_STORE_MODE}" "${BASE_URL:-}" "${PATH_PREFIX}" "${STATE_DIR}" "${OUT_DIR}" "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}" "${APPLIANCE_NAME}" "${DNS_ZONE}" "${ADDITIONAL_TLS_SANS_CSV}" "${OUTPUT_FORMAT}" "${UNINSTALL_FIRST:-false}" "${PRESERVE_FAILED_STATE}" "${install_log}" "${install_exit_code}" <<'PY'
import json
import sys

(
    out_path,
    config_path,
    target_host,
    helper_url,
    release_version,
    distribution_mode,
    base_url,
    path_prefix,
    state_dir,
    out_dir,
    appliance_profile,
    build_catalog_path,
    appliance_name,
    dns_zone,
    additional_tls_sans_csv,
    output_format,
    uninstall_first,
    preserve_failed_state,
    install_log,
    install_exit_code,
) = sys.argv[1:21]

install_method = {
    "static_http": "direct-static_http-zonctl-auto",
    "appliance_files": "direct-appliance_files-zonctl-auto",
}.get(distribution_mode, f"direct-{distribution_mode}-zonctl-auto")

payload = {
    "configPath": config_path,
    "targetHost": target_host,
    "helperUrl": helper_url,
    "installMethod": install_method,
    "distributionMode": distribution_mode,
    "releaseVersion": release_version or None,
    "baseUrl": base_url or None,
    "pathPrefix": path_prefix or None,
    "stateDir": state_dir or None,
    "outDir": out_dir,
    "bundleDir": f"{out_dir}/appliance-{release_version}-bundle" if release_version else None,
    "applianceProfile": appliance_profile or None,
    "buildCatalogPath": build_catalog_path or None,
    "applianceName": appliance_name or None,
    "dnsZone": dns_zone or None,
    "additionalTLSSANsCSV": additional_tls_sans_csv or None,
    "outputFormat": output_format,
    "uninstallFirst": uninstall_first == "true",
    "preserveFailedState": preserve_failed_state == "true",
    "log": install_log,
    "status": "passed" if int(install_exit_code) == 0 else "failed",
    "exitCode": int(install_exit_code),
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

log "install metadata written to ${RUN_DIR}/metadata/install.json"

if [[ "${install_exit_code}" -ne 0 ]]; then
  exit "${install_exit_code}"
fi
