#!/usr/bin/env bash
# run-install-via-public-helper-on-target.sh — Mac/devhost side (install only).
#
# SSHs to the target and:
#   1) curls published install-http-release.sh for release.version
#   2) runs it with --appliance-name and optional --appliance-profile
#
# No appliance-release repo clone on the target. Secrets (DEV_REGISTRY*) stay
# on the target shell profile. Devhost only supplies name/profile/version/
# path-prefix from config.
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

SSH to target_host.alias and run the public two-step install:
  curl install-http-release.sh → bash with --appliance-name [ --appliance-profile ]

Reads:
  --config                  target_host.alias
  --build-publish-config    release.version, bundle_store (mode / path prefix / files_path)
  --install-config          install.appliance_name, install.appliance_profile

Example:
  bash .agents/skills/release/scripts/run-install-via-public-helper-on-target.sh \
    --config ~/151-devhost.yaml \
    --build-publish-config ~/151-build-publish.yaml \
    --install-config ~/151-install.yaml
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
require_cmd python3

TARGET_HOST="$(config_get "${DEVHOST_CONFIG}" "target_host.alias")"
RELEASE_VERSION="$(config_get "${BUILD_PUBLISH_CONFIG}" "release.version")"
PATH_PREFIX="$(bundle_store_get_optional "${BUILD_PUBLISH_CONFIG}" "release_path_prefix" || true)"
[[ -n "${PATH_PREFIX}" ]] || fail "bundle_store.release_path_prefix is required"
BUNDLE_MODE="$(resolve_bundle_store_mode "${BUILD_PUBLISH_CONFIG}")"
APPLIANCE_NAME="$(config_get "${INSTALL_CONFIG}" "install.appliance_name")"
APPLIANCE_PROFILE="$(config_get_optional "${INSTALL_CONFIG}" "install.appliance_profile" || true)"
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi
FILES_PATH="$(resolve_appliance_files_files_path "${BUILD_PUBLISH_CONFIG}")"
STATIC_BASE_URL="$(bundle_store_get_optional "${BUILD_PUBLISH_CONFIG}" "base_url" || true)"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"
install_log="${RUN_DIR}/logs/target-public-install.log"

log "target-host=${TARGET_HOST}"
log "release=${RELEASE_VERSION} name=${APPLIANCE_NAME} profile=${APPLIANCE_PROFILE} mode=${BUNDLE_MODE}"

# Remote: form helper URL from target env (appliance_files) or stamped static base.
# shellcheck disable=SC2016
remote_cmd="$(
  cat <<EOF
set -euo pipefail
if [[ -f "\${HOME}/.profile" ]]; then source "\${HOME}/.profile" 2>/dev/null || true; fi
if [[ -f "\${HOME}/.bashrc" ]]; then source "\${HOME}/.bashrc" 2>/dev/null || true; fi

version=$(shell_quote "${RELEASE_VERSION}")
prefix=$(shell_quote "${PATH_PREFIX}")
name=$(shell_quote "${APPLIANCE_NAME}")
profile=$(shell_quote "${APPLIANCE_PROFILE}")
mode=$(shell_quote "${BUNDLE_MODE}")
files_path=$(shell_quote "${FILES_PATH}")
static_base=$(shell_quote "${STATIC_BASE_URL}")

if [[ "\${mode}" == "static_http" ]]; then
  base="\${static_base}"
  if [[ -z "\${base}" ]]; then
    echo "install: bundle_store.base_url is required for static_http" >&2
    exit 2
  fi
else
  reg="\${DEV_REGISTRY:-}"
  if [[ -z "\${reg}" ]]; then
    echo "install: DEV_REGISTRY is not set on the target (needed for appliance_files)" >&2
    exit 2
  fi
  reg="\${reg#https://}"
  reg="\${reg#http://}"
  reg="\${reg%/}"
  base="https://\${reg}\${files_path}"
fi
base="\${base%/}"
helper_url="\${base}/\${prefix}/\${version}/install-http-release.sh"
script_path="/tmp/install-http-release-\${version}.sh"

curl_args=(-fsSL -o "\${script_path}")
if [[ -n "\${DEV_REGISTRY_TOKEN:-}" ]]; then
  curl_args+=(-H "Authorization: Bearer \${DEV_REGISTRY_TOKEN}")
fi
tls_verify="\$(printf '%s' "\${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')"
case "\${tls_verify}" in
  0|false|no|off) curl_args+=(-k) ;;
esac

echo "downloading \${helper_url}"
curl "\${curl_args[@]}" "\${helper_url}"
chmod +x "\${script_path}"

echo "running install-http-release.sh --appliance-name \${name} --appliance-profile \${profile}"
bash "\${script_path}" --appliance-name "\${name}" --appliance-profile "\${profile}"
EOF
)"

log "running public install helper on ${TARGET_HOST}"
if ! run_ssh_logged "${TARGET_HOST}" "${install_log}" "${remote_cmd}"; then
  fail "target public install failed; see ${install_log}"
fi
log "target public install finished; log: ${install_log}"
