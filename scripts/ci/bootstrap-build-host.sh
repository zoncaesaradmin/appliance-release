#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: bootstrap-build-host.sh

One-time interactive host bootstrap for appliance-code's dev-container flow.

Run this once on each Linux build machine before using:
  bash ./scripts/ci/build-full-bundle.sh

Required environment:
  REGISTRY_USER   Registry username for appliance-code dev-registry-login
  REGISTRY_TOKEN  Registry token/PAT for appliance-code dev-registry-login

Optional environment:
  CODE_REPO_SOURCE        Source repo/URL for appliance-code
  CODE_REPO_REF           Git ref to fetch. Default: main
  WORK_ROOT               Build root. Default: ${TMPDIR:-/tmp}/appliance-build

Example:
  export REGISTRY_USER=myuser
  export REGISTRY_TOKEN=xxxxxxxx
  bash ./scripts/ci/bootstrap-build-host.sh
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULTS_FILE="${RELEASE_REPO_DIR}/configs/product-bundle.ci.env"

USER_CODE_REPO_SOURCE="${CODE_REPO_SOURCE-}"
USER_CODE_REPO_REF="${CODE_REPO_REF-}"
USER_WORK_ROOT="${WORK_ROOT-}"

set -a
# shellcheck disable=SC1090
source "${DEFAULTS_FILE}"
set +a

CODE_REPO_SOURCE="${USER_CODE_REPO_SOURCE:-${CODE_REPO_SOURCE:-}}"
CODE_REPO_REF="${USER_CODE_REPO_REF:-${CODE_REPO_REF:-main}}"
WORK_ROOT="${USER_WORK_ROOT:-${WORKDIR:-${TMPDIR:-/tmp}/appliance-build}}"

REPOS_DIR="${WORK_ROOT}/repos"
CODE_REPO_DIR="${REPOS_DIR}/appliance-code"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "bootstrap-build-host: ${name} is required" >&2
    usage >&2
    exit 2
  fi
}

normalize_clone_source() {
  local source="$1"
  if [[ -d "${source}" ]]; then
    if [[ -d "${source}/.git" ]]; then
      if git -C "${source}" remote get-url origin >/dev/null 2>&1; then
        git -C "${source}" remote get-url origin
        return 0
      fi
      echo "bootstrap-build-host: local repo source ${source} has no origin remote configured" >&2
      exit 1
    fi
    echo "bootstrap-build-host: local source ${source} is not a git checkout with an origin remote" >&2
    exit 1
  else
    printf '%s\n' "${source}"
  fi
}

clone_repo() {
  local source="$1"
  local ref="$2"
  local dest="$3"
  local clone_source

  clone_source="$(normalize_clone_source "${source}")"
  mkdir -p "$(dirname "${dest}")"

  if [[ -d "${dest}/.git" ]]; then
    git -C "${dest}" remote set-url origin "${clone_source}"
    if [[ -n "${ref}" ]]; then
      git -C "${dest}" fetch --prune --depth 1 origin "${ref}"
      git -C "${dest}" checkout --detach FETCH_HEAD
    else
      git -C "${dest}" fetch --prune --depth 1 origin
      git -C "${dest}" checkout --detach origin/HEAD
    fi
    return 0
  fi

  rm -rf "${dest}"
  if [[ -n "${ref}" ]]; then
    git clone --depth 1 --branch "${ref}" "${clone_source}" "${dest}"
  else
    git clone --depth 1 "${clone_source}" "${dest}"
  fi
}

require_var REGISTRY_USER
require_var REGISTRY_TOKEN
require_var CODE_REPO_SOURCE

mkdir -p "${REPOS_DIR}"
clone_repo "${CODE_REPO_SOURCE}" "${CODE_REPO_REF}" "${CODE_REPO_DIR}"

echo "bootstrap-build-host: using appliance-code at:"
echo "  ${CODE_REPO_DIR}"
echo "bootstrap-build-host: running one-time host bootstrap commands"

make -C "${CODE_REPO_DIR}" dev-registry-login
make -C "${CODE_REPO_DIR}" dev-sudo-setup

echo
echo "bootstrap-build-host: host bootstrap completed"
echo "bootstrap-build-host: next step:"
echo "  bash ${RELEASE_REPO_DIR}/scripts/ci/build-full-bundle.sh"
