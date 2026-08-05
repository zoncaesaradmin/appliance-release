#!/usr/bin/env bash
# run-build-and-publish-on-build-host.sh — Mac/devhost side.
#
# Copies a local build-publish config onto the build host and runs
# build-and-publish-on-host.sh there. Registry credentials stay on the build
# host (export DEV_* there); this script does not upload tokens.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-build-and-publish-on-build-host.sh \
  --build-publish-config PATH \
  (--config PATH | --build-host ALIAS) \
  [options]

From the Mac/devhost: scp the build-publish YAML to the build host (under
$HOME/.config/appliance-release/build-publish.yaml by default), ensure the
skill-managed appliance-release checkout matches config refs, then SSH and run
build-and-publish-on-host.sh on that host.

Required:
  --build-publish-config PATH   Local build-publish role file
                                (same as run-release-flow.sh --build-publish-config).
  --config PATH                 Devhost config with build_host.alias
  --build-host ALIAS            SSH target (alternative to --config)

Optional:
  --remote-config-path PATH     Absolute *remote* destination for the config
                                (default: $HOME/.config/appliance-release/build-publish.yaml
                                on the build host).
  --run-dir DIR                 Local (devhost) run directory for transfer logs.
  --remote-run-dir DIR          Run directory *on the build host* (forwarded).
  --skip-repo-sync              Do not fetch/reset release_workspace on the host
                                before the worker (only if you already updated it).

Build-host env (not set here — already configured on the build machine):
  DEV_REGISTRY*, DEV_IMAGE_*, APPLIANCE_BUILD_SUDO_PASSWORD

Example:
  bash .agents/skills/release/scripts/run-build-and-publish-on-build-host.sh \
    --config ~/151-devhost.yaml \
    --build-publish-config ~/151-build-publish.yaml
EOF
}

BUILD_PUBLISH_CONFIG=""
DEVHOST_CONFIG=""
BUILD_HOST=""
REMOTE_CONFIG_PATH=""
RUN_DIR=""
REMOTE_RUN_DIR=""
SKIP_REPO_SYNC="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-publish-config)
      BUILD_PUBLISH_CONFIG="${2:-}"
      shift 2
      ;;
    --config)
      DEVHOST_CONFIG="${2:-}"
      shift 2
      ;;
    --build-host)
      BUILD_HOST="${2:-}"
      shift 2
      ;;
    --remote-config-path)
      REMOTE_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    --remote-run-dir)
      REMOTE_RUN_DIR="${2:-}"
      shift 2
      ;;
    --skip-repo-sync)
      SKIP_REPO_SYNC="true"
      shift
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

[[ -n "${BUILD_PUBLISH_CONFIG}" ]] || fail "requires --build-publish-config PATH"
BUILD_PUBLISH_CONFIG="$(require_config_path "${BUILD_PUBLISH_CONFIG}")"

if [[ -z "${BUILD_HOST}" ]]; then
  [[ -n "${DEVHOST_CONFIG}" ]] || fail "requires --config PATH (devhost) or --build-host ALIAS"
  DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
  BUILD_HOST="$(config_get "${DEVHOST_CONFIG}" "build_host.alias")"
fi
[[ -n "${BUILD_HOST}" ]] || fail "build_host.alias is empty"

require_cmd ssh
require_cmd scp
require_cmd rsync
require_cmd python3

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"

REMOTE_REPO_PATH="$(config_get "${BUILD_PUBLISH_CONFIG}" "release_workspace.remote_repo_path")"
REMOTE_REPO_SOURCE="$(config_get_optional "${BUILD_PUBLISH_CONFIG}" "release_workspace.remote_repo_source" || true)"
REMOTE_REPO_REF="$(config_get "${BUILD_PUBLISH_CONFIG}" "release_workspace.remote_repo_ref")"
if [[ -z "${REMOTE_REPO_SOURCE}" ]]; then
  REMOTE_REPO_SOURCE="$(resolve_local_git_origin "$(skill_release_repo_root "${SCRIPT_DIR}")")"
fi
[[ -n "${REMOTE_REPO_SOURCE}" ]] || fail "release_workspace.remote_repo_source is required in build-publish config"
EFFECTIVE_REMOTE_REPO_SOURCE="$(normalize_readonly_git_source "${REMOTE_REPO_SOURCE}")"

transfer_log="${RUN_DIR}/logs/build-host-config-transfer.log"
repo_sync_log="${RUN_DIR}/logs/release-repo-sync.log"
worker_log="${RUN_DIR}/logs/build-and-publish-on-host.log"

REMOTE_HOME="$(ssh -q -T "${BUILD_HOST}" 'printf %s "$HOME"')"
[[ -n "${REMOTE_HOME}" ]] || fail "could not resolve remote HOME on ${BUILD_HOST}"

if [[ -z "${REMOTE_CONFIG_PATH}" ]]; then
  REMOTE_CONFIG_PATH="${REMOTE_HOME}/.config/appliance-release/build-publish.yaml"
fi

log "build-host=${BUILD_HOST}"
log "local build-publish-config=${BUILD_PUBLISH_CONFIG}"
log "remote build-publish-config=${REMOTE_CONFIG_PATH}"
log "remote appliance-release=${REMOTE_REPO_PATH} (ref ${REMOTE_REPO_REF})"
log "devhost run-dir=${RUN_DIR}"

log "creating remote config directory"
ssh -q -T "${BUILD_HOST}" "mkdir -p $(shell_quote "$(dirname "${REMOTE_CONFIG_PATH}")")"

log "copying build-publish config to ${BUILD_HOST}:${REMOTE_CONFIG_PATH}"
scp -q "${BUILD_PUBLISH_CONFIG}" "${BUILD_HOST}:${REMOTE_CONFIG_PATH}"
{
  echo "copied ${BUILD_PUBLISH_CONFIG} → ${BUILD_HOST}:${REMOTE_CONFIG_PATH}"
  date -u +"%Y-%m-%dT%H:%M:%SZ"
} | tee "${transfer_log}" >/dev/null

if ! bool_true "${SKIP_REPO_SYNC}"; then
  release_repo_sync_remote_cmd="$(render_ensure_remote_release_repo_cmd "${REMOTE_REPO_PATH}" "${EFFECTIVE_REMOTE_REPO_SOURCE}" "${REMOTE_REPO_REF}")"
  log "ensuring remote appliance-release checkout on ${BUILD_HOST}"
  if ! run_ssh_logged "${BUILD_HOST}" "${repo_sync_log}" "${release_repo_sync_remote_cmd}"; then
    fail "failed to sync appliance-release on ${BUILD_HOST}; see ${repo_sync_log}"
  fi
else
  log "skipping release repo sync (--skip-repo-sync)"
fi

remote_worker="${REMOTE_REPO_PATH}/.agents/skills/release/scripts/build-and-publish-on-host.sh"
remote_cmd="set -euo pipefail
if [[ ! -f $(shell_quote "${remote_worker}") ]]; then
  echo \"build-and-publish-on-host.sh not found at ${remote_worker}; pull remote_repo_ref on the build host\" >&2
  exit 1
fi
args=(--build-publish-config $(shell_quote "${REMOTE_CONFIG_PATH}"))
"
if [[ -n "${REMOTE_RUN_DIR}" ]]; then
  remote_cmd+="args+=(--run-dir $(shell_quote "${REMOTE_RUN_DIR}"))
"
fi
remote_cmd+="bash $(shell_quote "${remote_worker}") \"\${args[@]}\""

log "running build-and-publish-on-host.sh on ${BUILD_HOST}"
if ! run_ssh_logged "${BUILD_HOST}" "${worker_log}" "${remote_cmd}"; then
  fail "build/publish on ${BUILD_HOST} failed; see ${worker_log}"
fi

log "build/publish on ${BUILD_HOST} finished"
log "worker log on devhost: ${worker_log}"
log "config transfer log: ${transfer_log}"
