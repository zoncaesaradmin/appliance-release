#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: build-full-bundle.sh

Single build-machine entrypoint for the full appliance bundle flow.

Expected model:
1. appliance-release is already checked out
2. this script clones appliance-code and appliance-ctl
3. appliance-code produces the prepared release-input tarball
4. this script writes the resolved bundle config
5. appliance-release assembles and verifies the final bundle

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
INPUTS_DIR="${WORKSPACE}/inputs"
GENERATED_DIR="${WORKSPACE}/generated"
CONFIG_OUT="${GENERATED_DIR}/product-bundle.env"

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

stage_file() {
  local source="$1"
  local dest="$2"
  local label="$3"

  mkdir -p "$(dirname "${dest}")"

  if [[ -f "${source}" ]]; then
    cp "${source}" "${dest}"
    return 0
  fi

  case "${source}" in
    http://*|https://*)
      curl -fsSL "${source}" -o "${dest}"
      return 0
      ;;
    file://*)
      cp "${source#file://}" "${dest}"
      return 0
      ;;
  esac

  echo "build-full-bundle: unsupported ${label} source: ${source}" >&2
  exit 1
}

set_env_var() {
  local file="$1"
  local name="$2"
  local value="$3"
  local escaped
  local tmp

  printf -v escaped '%q' "${value}"
  tmp="${file}.tmp"
  awk -v key="${name}" -v val="${escaped}" '
    BEGIN { done = 0 }
    $0 ~ ("^" key "=") { print key "=" val; done = 1; next }
    { print }
    END {
      if (!done) {
        print key "=" val
      }
    }
  ' "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
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
mkdir -p "${REPOS_DIR}" "${ARTIFACTS_DIR}" "${INPUTS_DIR}" "${GENERATED_DIR}"

clone_repo "${CODE_REPO_SOURCE}" "${CODE_REPO_REF}" "${CODE_REPO_DIR}"
clone_repo "${CTL_REPO_SOURCE}" "${CTL_REPO_REF}" "${CTL_REPO_DIR}"

make -C "${CODE_REPO_DIR}" package-release-input-tar \
  OUT_FILE="${RELEASE_INPUT_TAR}" \
  K3S_VERSION="${K3S_VERSION}"

stage_file "${K3S_BINARY_SOURCE}" "${INPUTS_DIR}/k3s" "k3s binary"
stage_file "${K3S_INSTALL_SCRIPT_SOURCE}" "${INPUTS_DIR}/install.sh" "k3s install script"
stage_file "${K3S_AIRGAP_IMAGES_SOURCE}" "${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst" "k3s airgap images"
chmod +x "${INPUTS_DIR}/k3s" "${INPUTS_DIR}/install.sh" 2>/dev/null || true
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  stage_file "${VALUES_FILE_SOURCE}" "${INPUTS_DIR}/values-minimal.yaml" "values file"
fi

cp "${DEFAULTS_FILE}" "${CONFIG_OUT}"
set_env_var "${CONFIG_OUT}" WORKDIR "${WORKSPACE}"
set_env_var "${CONFIG_OUT}" PRODUCT_VERSION "${PRODUCT_VERSION}"
set_env_var "${CONFIG_OUT}" K3S_VERSION "${K3S_VERSION}"
set_env_var "${CONFIG_OUT}" RELEASE_INPUT_SOURCE "${RELEASE_INPUT_TAR}"
set_env_var "${CONFIG_OUT}" RELEASE_INPUT_VERSION ""
set_env_var "${CONFIG_OUT}" RELEASE_INPUT_FETCH_TEMPLATE ""
set_env_var "${CONFIG_OUT}" CTL_REPO_SOURCE "${CTL_REPO_DIR}"
set_env_var "${CONFIG_OUT}" CTL_REPO_REF ""
set_env_var "${CONFIG_OUT}" INPUTS_DIR "${INPUTS_DIR}"
set_env_var "${CONFIG_OUT}" SAMPLE_MODE "0"
set_env_var "${CONFIG_OUT}" K3S_BINARY "${INPUTS_DIR}/k3s"
set_env_var "${CONFIG_OUT}" K3S_INSTALL_SCRIPT "${INPUTS_DIR}/install.sh"
set_env_var "${CONFIG_OUT}" K3S_AIRGAP_IMAGES "${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst"
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  set_env_var "${CONFIG_OUT}" VALUES_FILE "${INPUTS_DIR}/values-minimal.yaml"
else
  set_env_var "${CONFIG_OUT}" VALUES_FILE ""
fi

echo "generated bundle config:"
echo "  ${CONFIG_OUT}"

make -C "${RELEASE_REPO_DIR}" product-bundle CONFIG="${CONFIG_OUT}"

echo
echo "release-input tarball:"
echo "  ${RELEASE_INPUT_TAR}"
echo
echo "final bundle:"
echo "  ${WORKSPACE}/out/appliance-${PRODUCT_VERSION}-bundle"
echo
echo "generated bundle config:"
echo "  ${WORKSPACE}/generated/product-bundle.env"
