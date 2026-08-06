#!/usr/bin/env bash
# run-install-via-public-helper-on-target.sh — Mac/devhost side (install only).
#
# Builds the full curl URL and auth flags on *this* machine (using config +
# devhost DEV_* env), SSHs to the target, runs a clean uninstall when zonctl
# is already present, downloads install-http-release.sh, patches stamped
# settings if needed, and runs:
#   install-http-release.sh --appliance-name … --appliance-profile …
#
# For builder* profiles, copies install.build_catalog_path onto the target and
# stamps BUILD_CATALOG_PATH into the helper so zonctl receives --build-catalog
# (chart default buildCatalog:{} fails Helm schema for build-capable profiles).
#
# Lab policy: always uninstall then fresh install (no in-place upgrade).
# Target needs no permanent env. Sudo for zonctl is non-interactive: Mac
# APPLIANCE_TARGET_SUDO_PASSWORD is injected for this SSH job only.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-install-via-public-helper-on-target.sh \
  --config PATH \
  --build-publish-config PATH \
  --install-config PATH

Devhost builds curl + name/profile; target uninstalls any owned appliance
(when zonctl is present), then fetches and runs the public install helper.

Export APPLIANCE_TARGET_SUDO_PASSWORD on the Mac (same as other install paths).
EOF
}

DEVHOST_CONFIG=""
BUILD_PUBLISH_CONFIG=""
INSTALL_CONFIG=""
RUN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      DEVHOST_CONFIG="${2:-}"
      shift 2
      ;;
    --build-publish-config)
      BUILD_PUBLISH_CONFIG="${2:-}"
      shift 2
      ;;
    --install-config)
      INSTALL_CONFIG="${2:-}"
      shift 2
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
      fail "unknown argument: $1 (see --help)"
      ;;
  esac
done

[[ -n "${DEVHOST_CONFIG}" ]] || fail "requires --config PATH"
[[ -n "${BUILD_PUBLISH_CONFIG}" ]] || fail "requires --build-publish-config PATH"
[[ -n "${INSTALL_CONFIG}" ]] || fail "requires --install-config PATH"

DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
BUILD_PUBLISH_CONFIG="$(require_config_path "${BUILD_PUBLISH_CONFIG}")"
INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"

require_cmd ssh
require_cmd scp
require_cmd python3

TARGET_HOST="$(config_get "${DEVHOST_CONFIG}" "target_host.alias")"
RELEASE_VERSION=""
if [[ -n "${PRODUCT_VERSION:-}" ]]; then
  RELEASE_VERSION="${PRODUCT_VERSION}"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(config_get_optional "${BUILD_PUBLISH_CONFIG}" "release.version" || true)"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(read_default_product_version "$(skill_release_repo_root "${SCRIPT_DIR}")")"
fi
# Matches scripts/publish-release.sh PUBLISH_PATH_PREFIX.
readonly PATH_PREFIX="appliance"
BUNDLE_MODE="$(resolve_bundle_store_mode "${BUILD_PUBLISH_CONFIG}")"
APPLIANCE_NAME="$(config_get "${INSTALL_CONFIG}" "install.appliance_name")"
APPLIANCE_PROFILE="$(config_get_optional "${INSTALL_CONFIG}" "install.appliance_profile" || true)"
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi

BASE_URL=""
BEARER_TOKEN=""
TLS_INSECURE="0"

BASE_URL="$(resolve_appliance_files_base_url "${BUILD_PUBLISH_CONFIG}")"
token_env="$(bundle_store_get_optional "${BUILD_PUBLISH_CONFIG}" "token_env" || true)"
if [[ -z "${token_env}" ]]; then
  token_env="DEV_REGISTRY_TOKEN"
fi
BEARER_TOKEN="$(resolve_secret "${token_env}" "Bundle store token (${token_env})")"
tls_env="$(bundle_store_get_optional "${BUILD_PUBLISH_CONFIG}" "tls_verify_env" || true)"
if [[ -z "${tls_env}" ]]; then
  tls_env="DEV_REGISTRY_TLS_VERIFY"
fi
tls_verify="$(resolve_env_value "${tls_env}" "Bundle store TLS verify (${tls_env})")"
case "$(printf '%s' "${tls_verify}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) TLS_INSECURE="1" ;;
  *) TLS_INSECURE="0" ;;
esac

HELPER_URL="${BASE_URL}/${PATH_PREFIX}/${RELEASE_VERSION}/install-http-release.sh"
SCRIPT_PATH="/tmp/install-http-release-${RELEASE_VERSION}.sh"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"
install_log="${RUN_DIR}/logs/target-public-install.log"

# Builder profiles require a real catalog; chart default buildCatalog:{} fails Helm schema.
BUILD_CATALOG_PATH="$(resolve_build_catalog_path "${INSTALL_CONFIG}" "")"
require_builder_build_catalog_path "${APPLIANCE_PROFILE}" "${BUILD_CATALOG_PATH}"
validate_builder_build_catalog \
  "${SCRIPT_DIR}" \
  "${INSTALL_CONFIG}" \
  "${APPLIANCE_PROFILE}" \
  "${BUILD_CATALOG_PATH}" \
  "${RUN_DIR}" \
  "build-catalog validation ok"
TARGET_BUILD_CATALOG_PATH=""
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  # Keep outside OUT_DIR (/tmp/appliance-<version>/) so extract/cleanup cannot remove it.
  TARGET_BUILD_CATALOG_PATH="/tmp/appliance-${RELEASE_VERSION}-build-catalog.yaml"
fi

log "target-host=${TARGET_HOST}"
log "helper-url=${HELPER_URL}"
log "appliance-name=${APPLIANCE_NAME} profile=${APPLIANCE_PROFILE}"
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  log "build-catalog=${BUILD_CATALOG_PATH} -> ${TARGET_HOST}:${TARGET_BUILD_CATALOG_PATH}"
fi

target_sudo_password="$(resolve_secret "APPLIANCE_TARGET_SUDO_PASSWORD" "Target host sudo password")"
quoted_sudo_password="$(shell_quote "${target_sudo_password}")"

# Fully concrete remote command: no permanent target env; sudo auth from this job only.
curl_extra=""
if [[ -n "${BEARER_TOKEN}" ]]; then
  curl_extra+=" -H $(shell_quote "Authorization: Bearer ${BEARER_TOKEN}")"
fi
if [[ "${TLS_INSECURE}" == "1" ]]; then
  curl_extra+=" -k"
fi

# Lab policy: clean uninstall then fresh public install (no in-place upgrade).
# Nested sudo under one non-interactive sudo so zonctl does not wait on a TTY.
if [[ -n "${TARGET_BUILD_CATALOG_PATH}" ]]; then
  log "copying build catalog to ${TARGET_HOST}:${TARGET_BUILD_CATALOG_PATH}"
  if ! scp -q "${BUILD_CATALOG_PATH}" "${TARGET_HOST}:${TARGET_BUILD_CATALOG_PATH}"; then
    fail "failed to copy build catalog to ${TARGET_HOST}:${TARGET_BUILD_CATALOG_PATH}"
  fi
fi

remote_cmd="set -euo pipefail
helper_url=$(shell_quote "${HELPER_URL}")
script_path=$(shell_quote "${SCRIPT_PATH}")
base_url=$(shell_quote "${BASE_URL}")
bearer=$(shell_quote "${BEARER_TOKEN}")
tls_insecure=$(shell_quote "${TLS_INSECURE}")
version=$(shell_quote "${RELEASE_VERSION}")
prefix=$(shell_quote "${PATH_PREFIX}")
name=$(shell_quote "${APPLIANCE_NAME}")
profile=$(shell_quote "${APPLIANCE_PROFILE}")
build_catalog_path=$(shell_quote "${TARGET_BUILD_CATALOG_PATH}")

if command -v zonctl >/dev/null 2>&1; then
  echo \"uninstalling existing appliance before reinstall (lab clean install)\"
  printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' zonctl uninstall --confirm yes
elif [[ -x /usr/local/bin/zonctl ]]; then
  echo \"uninstalling existing appliance before reinstall (lab clean install)\"
  printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' /usr/local/bin/zonctl uninstall --confirm yes
else
  echo \"no zonctl on target; skipping uninstall (fresh host)\"
fi

echo \"downloading \${helper_url}\"
curl -fsSL -o \"\${script_path}\"${curl_extra} \"\${helper_url}\"
chmod +x \"\${script_path}\"

python3 - \"\${script_path}\" \"\${base_url}\" \"\${bearer}\" \"\${tls_insecure}\" \"\${version}\" \"\${prefix}\" \"\${build_catalog_path}\" <<'PY'
from pathlib import Path
import json
import re
import sys

path, base_url, bearer, tls_insecure, version, prefix, build_catalog_path = sys.argv[1:8]
text = Path(path).read_text(encoding=\"utf-8\")

def set_assign(text, name, value):
    pat = re.compile(r\"^\" + re.escape(name) + r\"=.*$\", re.M)
    repl = f\"{name}={json.dumps(value)}\"
    if pat.search(text):
        return pat.sub(repl, text, count=1)
    return text + (\"\" if text.endswith(\"\\n\") else \"\\n\") + repl + \"\\n\"

text = set_assign(text, \"BASE_URL_EMBEDDED\", base_url)
text = set_assign(text, \"BASE_URL\", base_url)
text = set_assign(text, \"PRODUCT_VERSION_EMBEDDED\", version)
text = set_assign(text, \"PRODUCT_VERSION\", version)
text = set_assign(text, \"PATH_PREFIX_EMBEDDED\", prefix)
text = set_assign(text, \"PATH_PREFIX\", prefix)
text = set_assign(text, \"BEARER_TOKEN\", bearer)
text = set_assign(text, \"TLS_INSECURE\", tls_insecure)
text = set_assign(text, \"BUILD_CATALOG_PATH\", build_catalog_path)
if build_catalog_path:
    expected = f\"BUILD_CATALOG_PATH={json.dumps(build_catalog_path)}\"
    if expected not in text.splitlines():
        raise SystemExit(\"failed to stamp BUILD_CATALOG_PATH into install-http-release.sh\")
Path(path).write_text(text, encoding=\"utf-8\")
PY

echo \"running install-http-release.sh --appliance-name \${name} --appliance-profile \${profile} (via non-interactive sudo)\"
printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' bash \"\${script_path}\" --appliance-name \"\${name}\" --appliance-profile \"\${profile}\"
"

log "running public install helper on ${TARGET_HOST}"
if ! run_ssh_logged "${TARGET_HOST}" "${install_log}" "${remote_cmd}"; then
  fail "target public install failed; see ${install_log}"
fi

python3 - "${RUN_DIR}/metadata/install.json" \
  "${DEVHOST_CONFIG}" \
  "${TARGET_HOST}" \
  "${HELPER_URL}" \
  "${RELEASE_VERSION}" \
  "${BUNDLE_MODE}" \
  "${BASE_URL}" \
  "${PATH_PREFIX}" \
  "$(default_appliance_state_dir)" \
  "${APPLIANCE_PROFILE}" \
  "${APPLIANCE_NAME}" \
  "${BUILD_CATALOG_PATH}" \
  "${TARGET_BUILD_CATALOG_PATH}" \
  "${install_log}" <<'PY'
import json
import sys
from pathlib import Path

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
    appliance_profile,
    appliance_name,
    build_catalog_path,
    target_build_catalog_path,
    install_log,
) = sys.argv[1:15]

payload = {
    "configPath": config_path,
    "targetHost": target_host,
    "helperUrl": helper_url,
    "releaseVersion": release_version,
    "distributionMode": distribution_mode,
    "baseUrl": base_url or None,
    "pathPrefix": path_prefix,
    "stateDir": state_dir,
    "outDir": f"/tmp/appliance-{release_version}",
    "bundleDir": f"/tmp/appliance-{release_version}/appliance-{release_version}-bundle",
    "applianceProfile": appliance_profile,
    "applianceName": appliance_name,
    "buildCatalogPath": build_catalog_path or None,
    "targetBuildCatalogPath": target_build_catalog_path or None,
    "installMode": "public-helper",
    "log": install_log,
    "status": "passed",
    "exitCode": 0,
}
Path(out_path).parent.mkdir(parents=True, exist_ok=True)
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log "target public install finished; log: ${install_log}"
