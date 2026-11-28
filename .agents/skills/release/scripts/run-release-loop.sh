#!/usr/bin/env bash
# Run the complete three-repository commit -> build/publish -> install loop.
#
# This is an orchestration wrapper.  The product release path remains
# run-release-from-devhost.sh; this script only adds repeatable commit,
# automatic dependency seeding and retry handling around it.
set -Eeuo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_RELEASE_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: run-release-loop.sh \
  --config PATH \
  --build-publish-config PATH \
  --install-config PATH

Run the configured workflow on the current devhost:
  1. commit and push aligned appliance-release/appliance-ctl/appliance-code
  2. seed dependency images automatically when an offline build misses inputs
  3. run run-release-from-devhost.sh (build/publish/install/verify)
  4. retry the release after dependency recovery

The three paths are the existing role configs. The wrapper derives the local
repository, commit helper, commit message, build host, remote checkout path,
architecture, and dependency seed command itself. In offline mode, a failed
build that looks like a missing build input automatically seeds dependencies on
the build host before retrying.

This command never edits a remote host except through the existing release
runner and the automatic dependency seed. Other failures stop with preserved
logs for the agent/operator to inspect and fix before rerunning the same
three-config command.
EOF
}

die() {
  echo "run-release-loop: $*" >&2
  exit 2
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

shell_quote() {
  local value=${1-}
  printf "'%s'" "${value//\'/\'\"\'\"\'}"
}

resolve_path() {
  local value=${1-} base=${2-"$PWD"}
  [[ -n "$value" ]] || { printf '\n'; return; }
  case "$value" in
    "~") value="$HOME" ;;
    "~/"*) value="$HOME/${value#~/}" ;;
  esac
  if [[ "$value" != /* ]]; then
    value="$base/$value"
  fi
  printf '%s\n' "$value"
}

run_logged() {
  local log_path=$1
  shift
  set +e
  "$@" 2>&1 | tee "$log_path"
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

run_commit() {
  local log_path=$1
  local args=(--root "$REPO_ROOT" --message "$COMMIT_MESSAGE")
  run_logged "$log_path" bash "$COMMIT_SCRIPT" "${args[@]}"
}

run_release() {
  local log_path=$1
  run_logged "$log_path" bash "$RELEASE_RUNNER" \
    --config "$DEVHOST_CONFIG" \
    --build-publish-config "$BUILD_PUBLISH_CONFIG" \
    --install-config "$INSTALL_CONFIG"
}

is_seedable_failure() {
  local log_path=$1
  [[ "$BUILD_FLOW_MODE" == offline ]] || return 1
  grep -Eiq \
    'build-and-publish|seed-build-deps|build-cache|dependency|OCI image|image source|not found|make: \*\*|npm source' \
    "$log_path"
}

run_seed_deps() {
  local log_path=$1
  local remote_exports=""
  remote_exports="$(render_export_assignments_from_current_env "${DEPS_ENV_NAMES[@]}")"
  local remote_command="set -euo pipefail
${remote_exports}
cd $(shell_quote "$REMOTE_REPO_PATH")
TARGET_ARCH=$(shell_quote "$TARGET_ARCH") make seed-build-deps"
  run_logged "$log_path" ssh "$BUILD_HOST" "$remote_command"
}

DEVHOST_CONFIG=""
BUILD_PUBLISH_CONFIG=""
INSTALL_CONFIG=""
while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || die "$1 requires a path"
      DEVHOST_CONFIG=$2
      shift 2
      ;;
    --build-publish-config)
      (($# >= 2)) || die "$1 requires a path"
      BUILD_PUBLISH_CONFIG=$2
      shift 2
      ;;
    --install-config)
      (($# >= 2)) || die "$1 requires a path"
      INSTALL_CONFIG=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

[[ -n "$DEVHOST_CONFIG" ]] || die "requires --config PATH"
[[ -n "$BUILD_PUBLISH_CONFIG" ]] || die "requires --build-publish-config PATH"
[[ -n "$INSTALL_CONFIG" ]] || die "requires --install-config PATH"
DEVHOST_CONFIG=$(resolve_path "$DEVHOST_CONFIG")
BUILD_PUBLISH_CONFIG=$(resolve_path "$BUILD_PUBLISH_CONFIG")
INSTALL_CONFIG=$(resolve_path "$INSTALL_CONFIG")
for path in "$DEVHOST_CONFIG" "$BUILD_PUBLISH_CONFIG" "$INSTALL_CONFIG"; do
  [[ -f "$path" ]] || die "release config not found: $path"
done

REPO_ROOT=$(dirname "$DEFAULT_RELEASE_ROOT")
[[ -d "$REPO_ROOT" ]] || die "repo_root does not exist: $REPO_ROOT"
RELEASE_ROOT="$DEFAULT_RELEASE_ROOT"
[[ -d "$RELEASE_ROOT" ]] || die "release_root does not exist: $RELEASE_ROOT"

COMMIT_SCRIPT="$HOME/.codex/skills/appliance-three-repo-commit/scripts/three-repo-commit.sh"
[[ -f "$COMMIT_SCRIPT" ]] || die "three-repo commit script not found: $COMMIT_SCRIPT"

COMMIT_MESSAGE="chore: automated appliance release"
RELEASE_RUNNER="$RELEASE_ROOT/.agents/skills/release/scripts/run-release-from-devhost.sh"
[[ -f "$RELEASE_RUNNER" ]] || die "release runner not found: $RELEASE_RUNNER"

BUILD_HOST=$(config_get "$DEVHOST_CONFIG" "build_host.alias")
BUILD_FLOW_MODE=$(resolve_build_flow_mode "$BUILD_PUBLISH_CONFIG")
TARGET_ARCH=$(resolve_target_arch_from_config "$BUILD_PUBLISH_CONFIG")
REMOTE_BUILD_ROOT=$(resolve_build_publish_remote_build_root "$BUILD_PUBLISH_CONFIG")
REMOTE_REPO_PATH=$(derive_remote_repo_path_from_build_root "$REMOTE_BUILD_ROOT")
DEPS_ENV_NAMES=()
while IFS= read -r env_name; do
  [[ -n "$env_name" ]] && DEPS_ENV_NAMES+=("$env_name")
done < <(collect_build_publish_env_names "$BUILD_PUBLISH_CONFIG")

MAX_ATTEMPTS=3
SEED_ATTEMPTED=false
RUN_ROOT="$HOME/.run/appliance-release-loop"
[[ -d "$RELEASE_ROOT" ]] || die "release_root does not exist: $RELEASE_ROOT"
case "$RUN_ROOT/" in
  "$RELEASE_ROOT/.run/"*)
    die "run_root must not be under release_root/.run because the three-repo commit helper cleans that directory"
    ;;
esac
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$RUN_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

log "devhost-config=$DEVHOST_CONFIG"
log "build-publish-config=$BUILD_PUBLISH_CONFIG"
log "install-config=$INSTALL_CONFIG"
log "run-dir=$RUN_DIR"
log "repo-root=$REPO_ROOT"
log "build-host=$BUILD_HOST build-mode=$BUILD_FLOW_MODE target-arch=$TARGET_ARCH"

cat >"$RUN_DIR/inputs.env" <<EOF
REPO_ROOT=$(shell_quote "$REPO_ROOT")
RELEASE_RUNNER=$(shell_quote "$RELEASE_RUNNER")
DEVHOST_CONFIG=$(shell_quote "$DEVHOST_CONFIG")
BUILD_PUBLISH_CONFIG=$(shell_quote "$BUILD_PUBLISH_CONFIG")
INSTALL_CONFIG=$(shell_quote "$INSTALL_CONFIG")
EOF

for ((ATTEMPT=1; ATTEMPT<=MAX_ATTEMPTS; ATTEMPT++)); do
  ATTEMPT_DIR="$RUN_DIR/attempt-$ATTEMPT"
  mkdir -p "$ATTEMPT_DIR"
  log "attempt $ATTEMPT/$MAX_ATTEMPTS: commit and push"
  if ! run_commit "$ATTEMPT_DIR/commit.log"; then
    echo "attempt=$ATTEMPT stage=commit status=failed" >"$ATTEMPT_DIR/status"
    die "commit/push failed; see $ATTEMPT_DIR/commit.log"
  fi

  log "attempt $ATTEMPT: build, publish, install, verify"
  RELEASE_LOG="$ATTEMPT_DIR/release.log"
  if run_release "$RELEASE_LOG"; then
    echo "attempt=$ATTEMPT stage=release status=success" >"$ATTEMPT_DIR/status"
    printf 'RELEASE_LOOP_OK\nrun_dir=%s\nattempt=%s\n' "$RUN_DIR" "$ATTEMPT"
    exit 0
  fi

  echo "attempt=$ATTEMPT stage=release status=failed" >"$ATTEMPT_DIR/status"
  log "attempt $ATTEMPT failed; release log=$RELEASE_LOG"
  if ((ATTEMPT == MAX_ATTEMPTS)); then
    die "release failed on final attempt; inspect $RELEASE_LOG"
  fi

  if [[ "$SEED_ATTEMPTED" == false ]] && is_seedable_failure "$RELEASE_LOG"; then
    log "attempt $ATTEMPT: offline dependency inputs look incomplete; running seed-build-deps on $BUILD_HOST"
    if ! run_seed_deps "$ATTEMPT_DIR/deps.log"; then
      echo "attempt=$ATTEMPT stage=deps status=failed" >>"$ATTEMPT_DIR/status"
      die "automatic dependency seeding failed; see $ATTEMPT_DIR/deps.log"
    fi
    SEED_ATTEMPTED=true
    continue
  fi

  die "release failed; inspect $RELEASE_LOG, fix the source/config issue, and rerun the same three-config command"
done

die "workflow ended without a successful release"
