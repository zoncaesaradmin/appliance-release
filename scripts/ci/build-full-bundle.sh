#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: build-full-bundle.sh

Build-machine wrapper for the full appliance bundle flow.

Expected model:
1. appliance-release is already checked out
2. this script clones appliance-code and appliance-ctl
3. appliance-code produces the prepared release-input tarball
4. appliance-release assembles and verifies the final bundle

Run this from the checked-out appliance-release repo root:

  bash ./scripts/ci/build-full-bundle.sh

Configuration is taken from environment variables. The most common pattern is:

  PRODUCT_VERSION=0.1.0 \
  CODE_REPO_SOURCE=https://git.example.invalid/zon/appliance-code.git \
  CTL_REPO_SOURCE=https://git.example.invalid/zon/appliance-ctl.git \
  K3S_BINARY_SOURCE=/ci/inputs/k3s \
  K3S_INSTALL_SCRIPT_SOURCE=/ci/inputs/install.sh \
  K3S_AIRGAP_IMAGES_SOURCE=/ci/inputs/k3s-airgap-images-amd64.tar.zst \
  bash ./scripts/ci/build-full-bundle.sh

Optional overrides:
  CODE_REPO_REF=main
  CTL_REPO_REF=main
  WORK_ROOT=/private/tmp/appliance-build
  K3S_VERSION_OVERRIDE=v1.30.4+k3s1
  VALUES_FILE_SOURCE=/ci/inputs/values-minimal.yaml
  KEEP_WORK_ROOT=1   # reuse WORK_ROOT and refresh the two dependency repos
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULTS_FILE="${RELEASE_REPO_DIR}/configs/product-bundle.ci.env"

PRODUCT_VERSION="${PRODUCT_VERSION:-}"
CODE_REPO_SOURCE="${CODE_REPO_SOURCE:-}"
CODE_REPO_REF="${CODE_REPO_REF:-main}"
CTL_REPO_SOURCE="${CTL_REPO_SOURCE:-}"
CTL_REPO_REF="${CTL_REPO_REF:-main}"
K3S_BINARY_SOURCE="${K3S_BINARY_SOURCE:-}"
K3S_INSTALL_SCRIPT_SOURCE="${K3S_INSTALL_SCRIPT_SOURCE:-}"
K3S_AIRGAP_IMAGES_SOURCE="${K3S_AIRGAP_IMAGES_SOURCE:-}"
VALUES_FILE_SOURCE="${VALUES_FILE_SOURCE:-}"
WORK_ROOT="${WORK_ROOT:-/private/tmp/appliance-build}"
K3S_VERSION_OVERRIDE="${K3S_VERSION_OVERRIDE:-}"
KEEP_WORK_ROOT="${KEEP_WORK_ROOT:-0}"

set -a
# shellcheck disable=SC1090
source "${DEFAULTS_FILE}"
set +a

if [[ -n "${K3S_VERSION_OVERRIDE}" ]]; then
  K3S_VERSION="${K3S_VERSION_OVERRIDE}"
fi

REPOS_DIR="${WORK_ROOT}/repos"
ARTIFACTS_DIR="${WORK_ROOT}/artifacts"
WORKSPACE="${WORK_ROOT}/workspace"

CODE_REPO_DIR="${REPOS_DIR}/appliance-code"
CTL_REPO_DIR="${REPOS_DIR}/appliance-ctl"
RELEASE_INPUT_TAR="${ARTIFACTS_DIR}/release-input-${PRODUCT_VERSION}.tar.gz"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "build-full-bundle: ${name} is required" >&2
    usage >&2
    exit 2
  fi
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "${path}" ]]; then
    echo "build-full-bundle: missing ${label}: ${path}" >&2
    exit 1
  fi
}

normalize_clone_source() {
  local source="$1"
  if [[ -d "${source}" ]]; then
    printf 'file://%s/%s\n' "$(cd "$(dirname "${source}")" && pwd)" "$(basename "${source}")"
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

  if [[ "${KEEP_WORK_ROOT}" == "1" && -d "${dest}/.git" ]]; then
    if [[ -n "${ref}" ]]; then
      git -C "${dest}" fetch --depth 1 origin "${ref}"
      git -C "${dest}" checkout --detach FETCH_HEAD
    else
      git -C "${dest}" fetch --depth 1 origin
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

require_var PRODUCT_VERSION
require_var CODE_REPO_SOURCE
require_var CTL_REPO_SOURCE
require_var K3S_VERSION
require_var K3S_BINARY_SOURCE
require_var K3S_INSTALL_SCRIPT_SOURCE
require_var K3S_AIRGAP_IMAGES_SOURCE

require_file "${K3S_BINARY_SOURCE}" "k3s binary"
require_file "${K3S_INSTALL_SCRIPT_SOURCE}" "k3s install script"
require_file "${K3S_AIRGAP_IMAGES_SOURCE}" "k3s airgap images"
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  require_file "${VALUES_FILE_SOURCE}" "values file"
fi

if [[ "${KEEP_WORK_ROOT}" != "1" ]]; then
  rm -rf "${WORK_ROOT}"
fi
mkdir -p "${REPOS_DIR}" "${ARTIFACTS_DIR}"

clone_repo "${CODE_REPO_SOURCE}" "${CODE_REPO_REF}" "${CODE_REPO_DIR}"
clone_repo "${CTL_REPO_SOURCE}" "${CTL_REPO_REF}" "${CTL_REPO_DIR}"

make -C "${CODE_REPO_DIR}" package-release-input-tar \
  OUT_FILE="${RELEASE_INPUT_TAR}" \
  K3S_VERSION="${K3S_VERSION}"

RUN_PRODUCT_BUNDLE_CMD=(
  bash "${RELEASE_REPO_DIR}/scripts/ci/run-product-bundle.sh"
  --workspace "${WORKSPACE}"
  --product-version "${PRODUCT_VERSION}"
  --k3s-version "${K3S_VERSION}"
  --release-input-source "${RELEASE_INPUT_TAR}"
  --k3s-binary-source "${K3S_BINARY_SOURCE}"
  --k3s-install-script-source "${K3S_INSTALL_SCRIPT_SOURCE}"
  --k3s-airgap-images-source "${K3S_AIRGAP_IMAGES_SOURCE}"
  --ctl-repo-source "${CTL_REPO_DIR}"
)

if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  RUN_PRODUCT_BUNDLE_CMD+=(--values-file-source "${VALUES_FILE_SOURCE}")
fi

"${RUN_PRODUCT_BUNDLE_CMD[@]}"

echo
echo "release-input tarball:"
echo "  ${RELEASE_INPUT_TAR}"
echo
echo "final bundle:"
echo "  ${WORKSPACE}/out/appliance-${PRODUCT_VERSION}-bundle"
echo
echo "generated bundle config:"
echo "  ${WORKSPACE}/generated/product-bundle.env"
