#!/usr/bin/env bash
# run-install-via-public-helper-on-target.sh — Mac/devhost side (install only).
#
# Builds the full curl URL and auth flags on *this* machine (using config +
# devhost DEV_* env), SSHs to the target, runs a clean uninstall when zonctl
# is already present, scp's the local scripts/install-release.sh, patches
# stamped settings + optional lab install knobs (dns_zone, TLS SANs, image-pull
# registry, out dir), and runs:
#   install-release.sh --appliance-name … --appliance-profile …
#
# Bundle/charts/images still download from the distributor; only the helper
# script itself comes from the local release checkout so lab wiring cannot
# silently lag a stale published copy.
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

Devhost builds curl + name/profile + optional install.image_pull_registry /
dns_zone / additional_tls_sans_csv / bundle_download_dir; target uninstalls
any owned appliance (when zonctl is present), then fetches and runs the
public install helper.

Export APPLIANCE_TARGET_SUDO_PASSWORD on the Mac (same as other install paths).
When install.image_pull_registry is set, also export the named DEV_REGISTRY*
credential env vars.
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

DNS_ZONE="$(config_get_optional "${INSTALL_CONFIG}" "install.dns_zone" || true)"
DNS_ZONE="$(printf '%s' "${DNS_ZONE}" | tr -d '[:space:]')"
[[ -n "${DNS_ZONE}" ]] || fail "install.dns_zone is required in install config"

resolve_install_extra_tls_sans "${INSTALL_CONFIG}"
resolve_install_image_pull_registry "${INSTALL_CONFIG}"

OUT_DIR="$(config_get_optional "${INSTALL_CONFIG}" "install.bundle_download_dir" || true)"
OUT_DIR="$(printf '%s' "${OUT_DIR}" | tr -d '[:space:]')"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="/tmp/appliance-${RELEASE_VERSION}"
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

HELPER_URL="${BASE_URL}/${PATH_PREFIX}/${RELEASE_VERSION}/install-release.sh"
SCRIPT_PATH="/tmp/install-release-${RELEASE_VERSION}.sh"
LOCAL_HELPER="$(skill_release_repo_root "${SCRIPT_DIR}")/scripts/install-release.sh"
[[ -f "${LOCAL_HELPER}" ]] || fail "local install helper missing: ${LOCAL_HELPER}"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"
install_log="${RUN_DIR}/logs/target-public-install.log"

log "target-host=${TARGET_HOST}"
log "helper-url=${HELPER_URL} (bundle artifacts); lab uses local helper ${LOCAL_HELPER}"
log "appliance-name=${APPLIANCE_NAME} profile=${APPLIANCE_PROFILE} dns-zone=${DNS_ZONE}"
if [[ -n "${IMAGE_PULL_REGISTRY}" ]]; then
  log "image-pull-registry=${IMAGE_PULL_REGISTRY}"
fi
if [[ -n "${EXTRA_TLS_SANS}" ]]; then
  log "extra-tls-sans=${EXTRA_TLS_SANS}"
fi

target_sudo_password="$(resolve_secret "APPLIANCE_TARGET_SUDO_PASSWORD" "Target host sudo password")"
quoted_sudo_password="$(shell_quote "${target_sudo_password}")"

# Fully concrete remote command: no permanent target env; sudo auth from this job only.
image_pull_exports=""
sudo_preserve=""
if [[ -n "${IMAGE_PULL_REGISTRY}" ]]; then
  # Env *names* must be bare identifiers; only values are shell-quoted.
  image_pull_exports+="${IMAGE_PULL_USERNAME_ENV}=$(shell_quote "${IMAGE_PULL_USERNAME}") export ${IMAGE_PULL_USERNAME_ENV}; "
  image_pull_exports+="${IMAGE_PULL_TOKEN_ENV}=$(shell_quote "${IMAGE_PULL_TOKEN}") export ${IMAGE_PULL_TOKEN_ENV}; "
  if [[ -n "${IMAGE_PULL_TLS_VERIFY_ENV}" ]]; then
    image_pull_exports+="${IMAGE_PULL_TLS_VERIFY_ENV}=$(shell_quote "${IMAGE_PULL_TLS_VERIFY}") export ${IMAGE_PULL_TLS_VERIFY_ENV}; "
  fi
  sudo_preserve=" --preserve-env=$(shell_quote "${IMAGE_PULL_PRESERVE_ENV}")"
fi

log "uploading local install helper to ${TARGET_HOST}:${SCRIPT_PATH}"
scp -q "${LOCAL_HELPER}" "${TARGET_HOST}:${SCRIPT_PATH}"

# Lab policy: clean uninstall then fresh public install (no in-place upgrade).
# Nested sudo under one non-interactive sudo so zonctl does not wait on a TTY.
# Lab installs use the local repo helper (scp above) so skill-side wiring
# (image-pull, dns_zone, TLS SANs) cannot silently lag a stale published copy.
# Bundle/charts/images still download from HELPER_URL's distributor base.
remote_cmd="set -euo pipefail
script_path=$(shell_quote "${SCRIPT_PATH}")
base_url=$(shell_quote "${BASE_URL}")
bearer=$(shell_quote "${BEARER_TOKEN}")
tls_insecure=$(shell_quote "${TLS_INSECURE}")
version=$(shell_quote "${RELEASE_VERSION}")
prefix=$(shell_quote "${PATH_PREFIX}")
name=$(shell_quote "${APPLIANCE_NAME}")
profile=$(shell_quote "${APPLIANCE_PROFILE}")
dns_zone=$(shell_quote "${DNS_ZONE}")
extra_tls_sans=$(shell_quote "${EXTRA_TLS_SANS}")
out_dir=$(shell_quote "${OUT_DIR}")
image_pull_registry=$(shell_quote "${IMAGE_PULL_REGISTRY}")
image_pull_username_env=$(shell_quote "${IMAGE_PULL_USERNAME_ENV}")
image_pull_token_env=$(shell_quote "${IMAGE_PULL_TOKEN_ENV}")
image_pull_tls_verify_env=$(shell_quote "${IMAGE_PULL_TLS_VERIFY_ENV}")
${image_pull_exports}

if command -v zonctl >/dev/null 2>&1; then
  echo \"uninstalling existing appliance before reinstall (lab clean install)\"
  printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' zonctl uninstall --confirm yes
elif [[ -x /usr/local/bin/zonctl ]]; then
  echo \"uninstalling existing appliance before reinstall (lab clean install)\"
  printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' /usr/local/bin/zonctl uninstall --confirm yes
else
  echo \"no zonctl on target; skipping uninstall (fresh host)\"
fi

chmod +x \"\${script_path}\"

python3 - \"\${script_path}\" \"\${base_url}\" \"\${bearer}\" \"\${tls_insecure}\" \"\${version}\" \"\${prefix}\" \"\${dns_zone}\" \"\${extra_tls_sans}\" \"\${out_dir}\" \"\${image_pull_registry}\" \"\${image_pull_username_env}\" \"\${image_pull_token_env}\" \"\${image_pull_tls_verify_env}\" <<'PY'
from pathlib import Path
import json
import re
import sys

(
    path,
    base_url,
    bearer,
    tls_insecure,
    version,
    prefix,
    dns_zone,
    extra_tls_sans,
    out_dir,
    image_pull_registry,
    image_pull_username_env,
    image_pull_token_env,
    image_pull_tls_verify_env,
) = sys.argv[1:14]
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
text = set_assign(text, \"DNS_ZONE\", dns_zone)
text = set_assign(text, \"EXTRA_TLS_SANS\", extra_tls_sans)
text = set_assign(text, \"OUT_DIR\", out_dir)
text = set_assign(text, \"IMAGE_PULL_REGISTRY\", image_pull_registry)
text = set_assign(text, \"IMAGE_PULL_USERNAME_ENV\", image_pull_username_env)
text = set_assign(text, \"IMAGE_PULL_TOKEN_ENV\", image_pull_token_env)
text = set_assign(text, \"IMAGE_PULL_TLS_VERIFY_ENV\", image_pull_tls_verify_env)
Path(path).write_text(text, encoding=\"utf-8\")
PY

echo \"running install-release.sh --appliance-name \${name} --appliance-profile \${profile} (via non-interactive sudo)\"
printf '%s\\n' ${quoted_sudo_password} | sudo -S -p ''${sudo_preserve} bash \"\${script_path}\" --appliance-name \"\${name}\" --appliance-profile \"\${profile}\"
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
  "${OUT_DIR}" \
  "${APPLIANCE_PROFILE}" \
  "${APPLIANCE_NAME}" \
  "${DNS_ZONE}" \
  "${IMAGE_PULL_REGISTRY}" \
  "${EXTRA_TLS_SANS}" \
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
    out_dir,
    appliance_profile,
    appliance_name,
    dns_zone,
    image_pull_registry,
    extra_tls_sans,
    install_log,
) = sys.argv[1:17]

payload = {
    "configPath": config_path,
    "targetHost": target_host,
    "helperUrl": helper_url,
    "releaseVersion": release_version,
    "distributionMode": distribution_mode,
    "baseUrl": base_url or None,
    "pathPrefix": path_prefix,
    "stateDir": state_dir,
    "outDir": out_dir,
    "bundleDir": f"{out_dir.rstrip('/')}/appliance-{release_version}-bundle",
    "applianceProfile": appliance_profile,
    "applianceName": appliance_name,
    "dnsZone": dns_zone,
    "imagePullRegistry": image_pull_registry or None,
    "extraTlsSans": extra_tls_sans or None,
    "installMode": "public-helper",
    "log": install_log,
    "status": "passed",
    "exitCode": 0,
}
Path(out_path).parent.mkdir(parents=True, exist_ok=True)
Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY


log "target public install finished; log: ${install_log}"
