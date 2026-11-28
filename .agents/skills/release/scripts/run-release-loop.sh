#!/usr/bin/env bash
# Run the complete three-repository commit -> build/publish -> install loop.
#
# This is an orchestration wrapper.  The product release path remains
# run-release-from-devhost.sh; this script only adds repeatable commit,
# optional dependency seeding, failure-hook, and retry handling around it.
set -Eeuo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_RELEASE_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

usage() {
  cat <<'EOF'
usage: run-release-loop.sh \
  --config PATH \
  --build-publish-config PATH \
  --install-config PATH \
  [options]

Run the configured workflow on the current devhost:
  1. commit and push aligned appliance-release/appliance-ctl/appliance-code
  2. optionally seed dependency images on the build host
  3. run run-release-from-devhost.sh (build/publish/install/verify)
  4. on failure, invoke the configured repair hook and retry from step 1

The three required paths are the same role configs accepted by
run-release-from-devhost.sh.  Optional controls:
  --repo-root PATH                 parent of the three Git repositories
  --release-root PATH              appliance-release checkout (default: local)
  --runner PATH                    release runner override
  --commit-script PATH             three-repo commit helper override
  --message MESSAGE                commit message
  --branch BRANCH                  commit/push branch (default: helper default)
  --seed-deps                      run dependency seed before the first attempt
  --deps-host SSH                  run the dependency command over SSH
  --deps-workdir PATH              dependency checkout directory
  --deps-command COMMAND            dependency seed command
  --deps-before-each-attempt       seed dependencies before every attempt
  --repair-command COMMAND         local repair hook after a failed attempt
  --repair-workdir PATH             working directory for the repair hook
  --max-attempts N                 bounded retry count (default: 3)
  --run-root PATH                  log base directory

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

DEVHOST_CONFIG=""
BUILD_PUBLISH_CONFIG=""
INSTALL_CONFIG=""
REPO_ROOT="${RELEASE_LOOP_REPO_ROOT:-}"
RELEASE_ROOT="${RELEASE_LOOP_RELEASE_ROOT:-$DEFAULT_RELEASE_ROOT}"
RELEASE_RUNNER="${RELEASE_LOOP_RUNNER:-}"
COMMIT_SCRIPT="${RELEASE_LOOP_COMMIT_SCRIPT:-}"
COMMIT_MESSAGE="${RELEASE_LOOP_COMMIT_MESSAGE:-chore: run automated appliance release}"
COMMIT_BRANCH="${RELEASE_LOOP_COMMIT_BRANCH:-}"
DEPS_ENABLED="${RELEASE_LOOP_SEED_DEPS:-false}"
DEPS_HOST="${RELEASE_LOOP_DEPS_HOST:-}"
DEPS_WORKDIR="${RELEASE_LOOP_DEPS_WORKDIR:-}"
DEPS_COMMAND="${RELEASE_LOOP_DEPS_COMMAND:-TARGET_ARCH=amd64 make seed-build-deps}"
DEPS_BEFORE_EACH="${RELEASE_LOOP_DEPS_BEFORE_EACH:-false}"
REPAIR_COMMAND="${RELEASE_LOOP_REPAIR_COMMAND:-}"
REPAIR_WORKDIR="${RELEASE_LOOP_REPAIR_WORKDIR:-}"
MAX_ATTEMPTS="${RELEASE_LOOP_MAX_ATTEMPTS:-3}"
RUN_ROOT="${RELEASE_LOOP_RUN_ROOT:-$HOME/.run/appliance-release-loop}"
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
    --repo-root)
      (($# >= 2)) || die "$1 requires a path"
      REPO_ROOT=$2
      shift 2
      ;;
    --release-root)
      (($# >= 2)) || die "$1 requires a path"
      RELEASE_ROOT=$2
      shift 2
      ;;
    --runner)
      (($# >= 2)) || die "$1 requires a path"
      RELEASE_RUNNER=$2
      shift 2
      ;;
    --commit-script)
      (($# >= 2)) || die "$1 requires a path"
      COMMIT_SCRIPT=$2
      shift 2
      ;;
    --message|-m)
      (($# >= 2)) || die "$1 requires a message"
      COMMIT_MESSAGE=$2
      shift 2
      ;;
    --branch)
      (($# >= 2)) || die "$1 requires a branch"
      COMMIT_BRANCH=$2
      shift 2
      ;;
    --seed-deps)
      DEPS_ENABLED=true
      shift
      ;;
    --deps-host)
      (($# >= 2)) || die "$1 requires an SSH target"
      DEPS_HOST=$2
      shift 2
      ;;
    --deps-workdir)
      (($# >= 2)) || die "$1 requires a path"
      DEPS_WORKDIR=$2
      shift 2
      ;;
    --deps-command)
      (($# >= 2)) || die "$1 requires a command"
      DEPS_COMMAND=$2
      shift 2
      ;;
    --deps-before-each-attempt)
      DEPS_BEFORE_EACH=true
      shift
      ;;
    --repair-command)
      (($# >= 2)) || die "$1 requires a command"
      REPAIR_COMMAND=$2
      shift 2
      ;;
    --repair-workdir)
      (($# >= 2)) || die "$1 requires a path"
      REPAIR_WORKDIR=$2
      shift 2
      ;;
    --max-attempts)
      (($# >= 2)) || die "$1 requires a number"
      MAX_ATTEMPTS=$2
      shift 2
      ;;
    --run-root)
      (($# >= 2)) || die "$1 requires a path"
      RUN_ROOT=$2
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

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT=$(dirname "$DEFAULT_RELEASE_ROOT")
fi
REPO_ROOT=$(resolve_path "$REPO_ROOT")
[[ -d "$REPO_ROOT" ]] || die "repo_root does not exist: $REPO_ROOT"
RELEASE_ROOT=$(resolve_path "$RELEASE_ROOT")
[[ -d "$RELEASE_ROOT" ]] || die "release_root does not exist: $RELEASE_ROOT"

if [[ -n "$COMMIT_SCRIPT" ]]; then
  COMMIT_SCRIPT=$(resolve_path "$COMMIT_SCRIPT")
fi
if [[ -z "$COMMIT_SCRIPT" || ! -f "$COMMIT_SCRIPT" ]]; then
  COMMIT_SCRIPT="$HOME/.codex/skills/appliance-three-repo-commit/scripts/three-repo-commit.sh"
fi
[[ -f "$COMMIT_SCRIPT" ]] || die "three-repo commit script not found; pass --commit-script PATH"

[[ "$COMMIT_MESSAGE" != *$'\n'* && "$COMMIT_MESSAGE" != *$'\r'* ]] || die "commit message must be one line"

if [[ -n "$RELEASE_RUNNER" ]]; then
  RELEASE_RUNNER=$(resolve_path "$RELEASE_RUNNER")
else
  RELEASE_RUNNER="$RELEASE_ROOT/.agents/skills/release/scripts/run-release-from-devhost.sh"
fi
[[ -f "$RELEASE_RUNNER" ]] || die "release runner not found: $RELEASE_RUNNER"

DEPS_WORKDIR=${DEPS_WORKDIR:-$RELEASE_ROOT}
DEPS_WORKDIR=$(resolve_path "$DEPS_WORKDIR")
REPAIR_WORKDIR=${REPAIR_WORKDIR:-$REPO_ROOT}
REPAIR_WORKDIR=$(resolve_path "$REPAIR_WORKDIR")
[[ -d "$REPAIR_WORKDIR" ]] || die "repair.workdir does not exist: $REPAIR_WORKDIR"

[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "retry.max_attempts must be a positive integer"
((MAX_ATTEMPTS <= 20)) || die "retry.max_attempts must not exceed 20"

RUN_ROOT=$(resolve_path "$RUN_ROOT")
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
log "max-attempts=$MAX_ATTEMPTS deps-enabled=$DEPS_ENABLED repair-hook=$([[ -n "$REPAIR_COMMAND" ]] && echo enabled || echo disabled)"

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
