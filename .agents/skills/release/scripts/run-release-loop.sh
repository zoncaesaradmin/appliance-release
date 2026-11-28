#!/usr/bin/env bash
# Run the complete three-repository commit -> build/publish -> install loop.
#
# This is an orchestration wrapper.  The product release path remains
# run-release-from-devhost.sh; this script only adds repeatable commit,
# optional dependency seeding, failure-hook, and retry handling around it.
set -Eeuo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_QUERY="${SCRIPT_DIR}/config_query.py"
DEFAULT_RELEASE_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

usage() {
  cat <<'EOF'
usage: run-release-loop.sh --workflow-config PATH [--message MESSAGE]

Run the configured workflow on the current devhost:
  1. commit and push aligned appliance-release/appliance-ctl/appliance-code
  2. optionally seed dependency images on the build host
  3. run run-release-from-devhost.sh (build/publish/install/verify)
  4. on failure, invoke the configured repair hook and retry from step 1

The workflow config is YAML or JSON.  See:
  .agents/skills/release-loop/references/workflow-config.example.yaml

This command never edits a remote host except through the configured release
runner and optional dependency command.  The repair hook is intentionally
explicit: it receives the failure log and must make local source fixes only;
the commit helper performs the subsequent push.
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

cfg_optional() {
  python3 "$CONFIG_QUERY" "$WORKFLOW_CONFIG" "$1" 2>/dev/null || true
}

cfg_required() {
  local key=$1 value
  value=$(cfg_optional "$key")
  [[ -n "$value" ]] || die "missing workflow config key: $key"
  printf '%s\n' "$value"
}

cfg_bool() {
  local key=$1 default=$2 value
  value=$(cfg_optional "$key")
  [[ -n "$value" ]] || value=$default
  case "$value" in
    true|TRUE|True|yes|YES|Yes|on|ON|On|1) printf 'true\n' ;;
    false|FALSE|False|no|NO|No|off|OFF|Off|0) printf 'false\n' ;;
    *) die "$key must be true or false (got '$value')" ;;
  esac
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

run_shell_logged() {
  local log_path=$1 workdir=$2 command=$3
  local payload="cd $(shell_quote "$workdir") && ${command}"
  run_logged "$log_path" bash -lc "$payload"
}

run_deps() {
  local log_path=$1
  if [[ -n "$DEPS_HOST" ]]; then
    local payload="cd $(shell_quote "$DEPS_WORKDIR") && bash -lc $(shell_quote "$DEPS_COMMAND")"
    run_logged "$log_path" ssh "$DEPS_HOST" "$payload"
  else
    run_shell_logged "$log_path" "$DEPS_WORKDIR" "$DEPS_COMMAND"
  fi
}

run_commit() {
  local log_path=$1
  local args=(--root "$REPO_ROOT" --message "$COMMIT_MESSAGE")
  [[ -n "$COMMIT_BRANCH" ]] && args+=(--branch "$COMMIT_BRANCH")
  run_logged "$log_path" bash "$COMMIT_SCRIPT" "${args[@]}"
}

run_release() {
  local log_path=$1
  run_logged "$log_path" bash "$RELEASE_RUNNER" \
    --config "$DEVHOST_CONFIG" \
    --build-publish-config "$BUILD_PUBLISH_CONFIG" \
    --install-config "$INSTALL_CONFIG"
}

run_repair() {
  local log_path=$1 attempt_dir=$2 release_log=$3
  local payload="cd $(shell_quote "$REPAIR_WORKDIR") && ${REPAIR_COMMAND}"
  RELEASE_LOOP_ATTEMPT="$ATTEMPT" \
    RELEASE_LOOP_RUN_DIR="$attempt_dir" \
    RELEASE_LOOP_RELEASE_LOG="$release_log" \
    RELEASE_LOOP_REPO_ROOT="$REPO_ROOT" \
    RELEASE_LOOP_DEVHOST_CONFIG="$DEVHOST_CONFIG" \
    RELEASE_LOOP_BUILD_PUBLISH_CONFIG="$BUILD_PUBLISH_CONFIG" \
    RELEASE_LOOP_INSTALL_CONFIG="$INSTALL_CONFIG" \
      run_logged "$log_path" bash -lc "$payload"
}

WORKFLOW_CONFIG=""
MESSAGE_OVERRIDE=""
while (($#)); do
  case "$1" in
    --workflow-config|--config)
      (($# >= 2)) || die "$1 requires a path"
      WORKFLOW_CONFIG=$2
      shift 2
      ;;
    --message|-m)
      (($# >= 2)) || die "$1 requires a message"
      MESSAGE_OVERRIDE=$2
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

[[ -n "$WORKFLOW_CONFIG" ]] || die "requires --workflow-config PATH"
WORKFLOW_CONFIG=$(resolve_path "$WORKFLOW_CONFIG")
[[ -f "$WORKFLOW_CONFIG" ]] || die "workflow config not found: $WORKFLOW_CONFIG"
[[ -f "$CONFIG_QUERY" ]] || die "missing config reader: $CONFIG_QUERY"
CONFIG_DIR=$(cd "$(dirname "$WORKFLOW_CONFIG")" && pwd)

REPO_ROOT_VALUE=$(cfg_optional repo_root)
if [[ -n "$REPO_ROOT_VALUE" ]]; then
  REPO_ROOT=$(resolve_path "$REPO_ROOT_VALUE" "$CONFIG_DIR")
else
  REPO_ROOT=$(dirname "$DEFAULT_RELEASE_ROOT")
fi
[[ -d "$REPO_ROOT" ]] || die "repo_root does not exist: $REPO_ROOT"
RELEASE_ROOT=$(resolve_path "$(cfg_optional release_root)" "$CONFIG_DIR")
[[ -n "$RELEASE_ROOT" ]] || RELEASE_ROOT="$DEFAULT_RELEASE_ROOT"
[[ -d "$RELEASE_ROOT" ]] || die "release_root does not exist: $RELEASE_ROOT"

COMMIT_SCRIPT=$(resolve_path "$(cfg_optional commit.script)" "$CONFIG_DIR")
if [[ -z "$COMMIT_SCRIPT" || ! -f "$COMMIT_SCRIPT" ]]; then
  COMMIT_SCRIPT="$HOME/.codex/skills/appliance-three-repo-commit/scripts/three-repo-commit.sh"
fi
[[ -f "$COMMIT_SCRIPT" ]] || die "three-repo commit script not found; set commit.script"

COMMIT_MESSAGE=${MESSAGE_OVERRIDE:-$(cfg_required commit.message)}
[[ "$COMMIT_MESSAGE" != *$'\n'* && "$COMMIT_MESSAGE" != *$'\r'* ]] || die "commit message must be one line"
COMMIT_BRANCH=$(cfg_optional commit.branch)

RELEASE_RUNNER=$(resolve_path "$(cfg_optional release.runner)" "$RELEASE_ROOT")
[[ -n "$RELEASE_RUNNER" ]] || RELEASE_RUNNER="$RELEASE_ROOT/.agents/skills/release/scripts/run-release-from-devhost.sh"
[[ -f "$RELEASE_RUNNER" ]] || die "release runner not found: $RELEASE_RUNNER"

DEVHOST_CONFIG=$(resolve_path "$(cfg_required release.devhost_config)" "$CONFIG_DIR")
BUILD_PUBLISH_CONFIG=$(resolve_path "$(cfg_required release.build_publish_config)" "$CONFIG_DIR")
INSTALL_CONFIG=$(resolve_path "$(cfg_required release.install_config)" "$CONFIG_DIR")
for path in "$DEVHOST_CONFIG" "$BUILD_PUBLISH_CONFIG" "$INSTALL_CONFIG"; do
  [[ -f "$path" ]] || die "release config not found: $path"
done

DEPS_ENABLED=$(cfg_bool deps.enabled false)
DEPS_HOST=$(cfg_optional deps.host)
DEPS_WORKDIR=$(resolve_path "$(cfg_optional deps.workdir)" "$RELEASE_ROOT")
[[ -n "$DEPS_WORKDIR" ]] || DEPS_WORKDIR="$RELEASE_ROOT"
DEPS_COMMAND=$(cfg_optional deps.command)
DEPS_BEFORE_EACH=$(cfg_bool deps.before_each_attempt false)
if [[ "$DEPS_ENABLED" == true ]]; then
  [[ -n "$DEPS_COMMAND" ]] || die "deps.command is required when deps.enabled=true"
fi

REPAIR_COMMAND=${REPAIR_COMMAND:-$(cfg_optional repair.command)}
REPAIR_WORKDIR=$(resolve_path "$(cfg_optional repair.workdir)" "$REPO_ROOT")
[[ -n "$REPAIR_WORKDIR" ]] || REPAIR_WORKDIR="$REPO_ROOT"
[[ -n "$REPAIR_COMMAND" ]] || REPAIR_WORKDIR="$REPO_ROOT"
[[ -d "$REPAIR_WORKDIR" ]] || die "repair.workdir does not exist: $REPAIR_WORKDIR"

MAX_ATTEMPTS=$(cfg_optional retry.max_attempts)
[[ -n "$MAX_ATTEMPTS" ]] || MAX_ATTEMPTS=3
[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "retry.max_attempts must be a positive integer"
((MAX_ATTEMPTS <= 20)) || die "retry.max_attempts must not exceed 20"

RUN_ROOT=$(resolve_path "$(cfg_optional run_root)" "$HOME/.run/appliance-release-loop")
[[ -n "$RUN_ROOT" ]] || RUN_ROOT="$HOME/.run/appliance-release-loop"
case "$RUN_ROOT/" in
  "$RELEASE_ROOT/.run/"*)
    die "run_root must not be under release_root/.run because the three-repo commit helper cleans that directory"
    ;;
esac
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$RUN_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

log "workflow-config=$WORKFLOW_CONFIG"
log "run-dir=$RUN_DIR"
log "repo-root=$REPO_ROOT"
log "max-attempts=$MAX_ATTEMPTS deps-enabled=$DEPS_ENABLED repair-hook=$([[ -n "$REPAIR_COMMAND" ]] && echo enabled || echo disabled)"

cat >"$RUN_DIR/workflow.env" <<EOF
WORKFLOW_CONFIG=$(shell_quote "$WORKFLOW_CONFIG")
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

  if [[ "$DEPS_ENABLED" == true ]] && { ((ATTEMPT == 1)) || [[ "$DEPS_BEFORE_EACH" == true ]]; }; then
    log "attempt $ATTEMPT: seed dependencies${DEPS_HOST:+ on $DEPS_HOST}"
    if ! run_deps "$ATTEMPT_DIR/deps.log"; then
      echo "attempt=$ATTEMPT stage=deps status=failed" >"$ATTEMPT_DIR/status"
      die "dependency seeding failed; see $ATTEMPT_DIR/deps.log"
    fi
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
  if [[ -z "$REPAIR_COMMAND" ]]; then
    die "release failed and no repair.command is configured; inspect $RELEASE_LOG"
  fi
  if ((ATTEMPT == MAX_ATTEMPTS)); then
    die "release failed on final attempt; inspect $RELEASE_LOG"
  fi

  log "attempt $ATTEMPT: invoke repair hook"
  if ! run_repair "$ATTEMPT_DIR/repair.log" "$ATTEMPT_DIR" "$RELEASE_LOG"; then
    echo "attempt=$ATTEMPT stage=repair status=failed" >>"$ATTEMPT_DIR/status"
    die "repair hook failed; see $ATTEMPT_DIR/repair.log"
  fi
done

die "workflow ended without a successful release"
