#!/usr/bin/env bash
# run-install-on-target-host.sh — Mac/devhost side.
#
# Merges role configs into a target work document, scp's it to the target,
# ensures an appliance-release checkout for the worker scripts, then SSHs and
# runs install-and-setup-on-target.sh. Target-side secrets stay on the target.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-install-on-target-host.sh \
  --config PATH \
  --build-publish-config PATH \
  --install-config PATH \
  [options]

From the Mac/devhost:
  1. Merge the three role configs (install needs release + bundle_store +
     target_host.state_dir from the other files).
  2. scp the merged work config to the target
     ($HOME/.config/appliance-release/work-config.json by default).
  3. Sync appliance-release on the target (same release_workspace as build host)
     so install-and-setup-on-target.sh is available.
  4. SSH and run the on-target worker (install + optional admin/license).
  5. Pull remote run logs/metadata into the local --run-dir when possible.

Required:
  --config PATH                 Devhost config (target_host.alias + state_dir)
  --build-publish-config PATH   release.version + bundle_store (+ release_workspace for script sync)
  --install-config PATH         install + verification (+ client_verification unused on target)

Optional:
  --remote-config-path PATH     Absolute remote work-config path
  --run-dir DIR                 Devhost run directory
  --remote-run-dir DIR          Run directory on the target (forwarded)
  --skip-repo-sync              Do not fetch/reset release_workspace on target

Target host env (already set there; not copied):
  APPLIANCE_TARGET_SUDO_PASSWORD
  DEV_REGISTRY*                 (appliance_files / image pull)
  APPLIANCE_FIRST_ADMIN_PASSWORD when install.bootstrap_admin

Example:
  bash .agents/skills/release/scripts/run-install-on-target-host.sh \
    --config ~/151-devhost.yaml \
    --build-publish-config ~/151-build-publish.yaml \
    --install-config ~/151-install.yaml
EOF
}

DEVHOST_CONFIG=""
BUILD_PUBLISH_CONFIG=""
INSTALL_CONFIG=""
REMOTE_CONFIG_PATH=""
RUN_DIR=""
REMOTE_RUN_DIR=""
SKIP_REPO_SYNC="false"

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

[[ -n "${DEVHOST_CONFIG}" ]] || fail "requires --config PATH"
[[ -n "${BUILD_PUBLISH_CONFIG}" ]] || fail "requires --build-publish-config PATH"
[[ -n "${INSTALL_CONFIG}" ]] || fail "requires --install-config PATH"

DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
BUILD_PUBLISH_CONFIG="$(require_config_path "${BUILD_PUBLISH_CONFIG}")"
INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"

require_cmd ssh
require_cmd scp
require_cmd rsync
require_cmd python3

TARGET_HOST="$(config_get "${DEVHOST_CONFIG}" "target_host.alias")"
[[ -n "${TARGET_HOST}" ]] || fail "target_host.alias is empty"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"

MERGED_CONFIG_PATH="${RUN_DIR}/metadata/target-work-config.json"
python3 "${SCRIPT_DIR}/merge-release-configs.py" \
  --devhost-config "${DEVHOST_CONFIG}" \
  --build-publish-config "${BUILD_PUBLISH_CONFIG}" \
  --install-config "${INSTALL_CONFIG}" \
  --output "${MERGED_CONFIG_PATH}" >/dev/null

REMOTE_REPO_PATH="$(config_get "${BUILD_PUBLISH_CONFIG}" "release_workspace.remote_repo_path")"
REMOTE_REPO_SOURCE="$(config_get_optional "${BUILD_PUBLISH_CONFIG}" "release_workspace.remote_repo_source" || true)"
REMOTE_REPO_REF="$(config_get "${BUILD_PUBLISH_CONFIG}" "release_workspace.remote_repo_ref")"
if [[ -z "${REMOTE_REPO_SOURCE}" ]]; then
  REMOTE_REPO_SOURCE="$(resolve_local_git_origin "$(skill_release_repo_root "${SCRIPT_DIR}")")"
fi
[[ -n "${REMOTE_REPO_SOURCE}" ]] || fail "release_workspace.remote_repo_source is required in build-publish config"
EFFECTIVE_REMOTE_REPO_SOURCE="$(normalize_readonly_git_source "${REMOTE_REPO_SOURCE}")"

transfer_log="${RUN_DIR}/logs/target-config-transfer.log"
repo_sync_log="${RUN_DIR}/logs/target-release-repo-sync.log"
worker_log="${RUN_DIR}/logs/install-and-setup-on-target.log"

REMOTE_HOME="$(ssh -q -T "${TARGET_HOST}" 'printf %s "$HOME"')"
[[ -n "${REMOTE_HOME}" ]] || fail "could not resolve remote HOME on ${TARGET_HOST}"

if [[ -z "${REMOTE_CONFIG_PATH}" ]]; then
  REMOTE_CONFIG_PATH="${REMOTE_HOME}/.config/appliance-release/work-config.json"
fi
if [[ -z "${REMOTE_RUN_DIR}" ]]; then
  REMOTE_RUN_DIR="${REMOTE_HOME}/.run/appliance-release/on-target"
fi

log "target-host=${TARGET_HOST}"
log "merged work-config=${MERGED_CONFIG_PATH}"
log "remote work-config=${REMOTE_CONFIG_PATH}"
log "remote appliance-release=${REMOTE_REPO_PATH} (ref ${REMOTE_REPO_REF})"
log "remote run-dir=${REMOTE_RUN_DIR}"
log "devhost run-dir=${RUN_DIR}"

log "creating remote config directory"
ssh -q -T "${TARGET_HOST}" "mkdir -p $(shell_quote "$(dirname "${REMOTE_CONFIG_PATH}")") $(shell_quote "${REMOTE_RUN_DIR}")"

log "copying work config to ${TARGET_HOST}:${REMOTE_CONFIG_PATH}"
scp -q "${MERGED_CONFIG_PATH}" "${TARGET_HOST}:${REMOTE_CONFIG_PATH}"
{
  echo "copied ${MERGED_CONFIG_PATH} → ${TARGET_HOST}:${REMOTE_CONFIG_PATH}"
  date -u +"%Y-%m-%dT%H:%M:%SZ"
} | tee "${transfer_log}" >/dev/null

if ! bool_true "${SKIP_REPO_SYNC}"; then
  release_repo_sync_remote_cmd="$(render_ensure_remote_release_repo_cmd "${REMOTE_REPO_PATH}" "${EFFECTIVE_REMOTE_REPO_SOURCE}" "${REMOTE_REPO_REF}")"
  log "ensuring appliance-release checkout on ${TARGET_HOST}"
  if ! run_ssh_logged "${TARGET_HOST}" "${repo_sync_log}" "${release_repo_sync_remote_cmd}"; then
    fail "failed to sync appliance-release on ${TARGET_HOST}; see ${repo_sync_log}"
  fi
else
  log "skipping release repo sync on target (--skip-repo-sync)"
fi

remote_worker="${REMOTE_REPO_PATH}/.agents/skills/release/scripts/install-and-setup-on-target.sh"
remote_cmd="set -euo pipefail
if [[ ! -f $(shell_quote "${remote_worker}") ]]; then
  echo \"install-and-setup-on-target.sh not found at ${remote_worker}; sync remote_repo_ref on the target\" >&2
  exit 1
fi
bash $(shell_quote "${remote_worker}") \
  --config $(shell_quote "${REMOTE_CONFIG_PATH}") \
  --run-dir $(shell_quote "${REMOTE_RUN_DIR}")
"

log "running install-and-setup-on-target.sh on ${TARGET_HOST}"
if ! run_ssh_logged "${TARGET_HOST}" "${worker_log}" "${remote_cmd}"; then
  # Best-effort pull of remote logs for debugging
  rsync -az \
    "${TARGET_HOST}:${REMOTE_RUN_DIR}/logs/" "${RUN_DIR}/logs/target-remote/" 2>/dev/null || true
  rsync -az \
    "${TARGET_HOST}:${REMOTE_RUN_DIR}/metadata/" "${RUN_DIR}/metadata/target-remote/" 2>/dev/null || true
  fail "install/setup on ${TARGET_HOST} failed; see ${worker_log}"
fi

log "pulling remote install logs/metadata to ${RUN_DIR}"
mkdir -p "${RUN_DIR}/logs/target-remote" "${RUN_DIR}/metadata/target-remote"
rsync -az \
  "${TARGET_HOST}:${REMOTE_RUN_DIR}/logs/" "${RUN_DIR}/logs/target-remote/" 2>/dev/null || true
rsync -az \
  "${TARGET_HOST}:${REMOTE_RUN_DIR}/metadata/" "${RUN_DIR}/metadata/target-remote/" 2>/dev/null || true

# Promote key metadata files into the standard paths when present so reporting can find them.
for name in install.json bootstrap-admin.json bootstrap-default-license.json; do
  if [[ -f "${RUN_DIR}/metadata/target-remote/${name}" && ! -f "${RUN_DIR}/metadata/${name}" ]]; then
    cp -f "${RUN_DIR}/metadata/target-remote/${name}" "${RUN_DIR}/metadata/${name}"
  fi
done
for name in install.log bootstrap-admin.log bootstrap-default-license.log; do
  if [[ -f "${RUN_DIR}/logs/target-remote/${name}" && ! -f "${RUN_DIR}/logs/${name}" ]]; then
    cp -f "${RUN_DIR}/logs/target-remote/${name}" "${RUN_DIR}/logs/${name}"
  fi
done

log "install/setup on ${TARGET_HOST} finished"
log "worker log on devhost: ${worker_log}"
