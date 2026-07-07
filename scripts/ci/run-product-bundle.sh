#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: run-product-bundle.sh [options]

Bootstraps a clean CI workspace for appliance bundle creation:
1. uses the current appliance-release checkout as the driver repo
2. clones appliance-ctl
3. stages the required install inputs into WORKSPACE/inputs
4. copies configs/product-bundle.ci.env into a generated env file
5. rewrites the required values in that env file
6. runs make product-bundle from the current appliance-release repo

Required unless set in configs/product-bundle.ci.env:
  --product-version VERSION
  and either:
    --control-plane-version VERSION
    --control-plane-image-ref REF

Required unless --sample-mode 1:
  --release-input-source PATH_OR_URL
    or both:
      --release-input-version VERSION
      --release-input-fetch-template TEMPLATE
  --k3s-binary-source PATH_OR_URL
  --k3s-install-script-source PATH_OR_URL
  --k3s-airgap-images-source PATH_OR_URL

Optional:
  --workspace PATH                    Defaults to WORKDIR from
                                      configs/product-bundle.ci.env.
  --k3s-version VERSION               Defaults from
                                      configs/product-bundle.ci.env.
  --ctl-repo-source PATH_OR_URL       Defaults from
                                      configs/product-bundle.ci.env,
                                      then ../appliance-ctl.
  --ctl-repo-ref REF
  --chart-version VERSION             Defaults to PRODUCT_VERSION.
  --argo-version VERSION              Defaults to deferred.
  --os-version VERSION                Defaults to 24.04.
  --values-file-source PATH_OR_URL
  --sample-mode 0|1                   Defaults to 0.
  --keep-workspace                    Reuse existing workspace directory.

Important:
  The script always clones a fresh appliance-ctl checkout under
  WORKSPACE/repos unless --keep-workspace is set. The generated bundle config
  is written to:

    WORKSPACE/generated/product-bundle.env
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULTS_FILE="${REPO_ROOT}/configs/product-bundle.ci.env"

WORKSPACE=""
CTL_REPO_SOURCE=""
CTL_REPO_REF=""
PRODUCT_VERSION=""
K3S_VERSION=""
CONTROL_PLANE_VERSION=""
CONTROL_PLANE_IMAGE_REF=""
CONTROL_PLANE_IMAGE_REPOSITORY=""
RELEASE_INPUT_SOURCE=""
RELEASE_INPUT_VERSION=""
RELEASE_INPUT_FETCH_TEMPLATE=""
K3S_BINARY_SOURCE=""
K3S_INSTALL_SCRIPT_SOURCE=""
K3S_AIRGAP_IMAGES_SOURCE=""
VALUES_FILE_SOURCE=""
CHART_VERSION=""
ARGO_VERSION="deferred"
OS_VERSION="24.04"
SAMPLE_MODE="0"
KEEP_WORKSPACE="0"

if [[ -f "${DEFAULTS_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${DEFAULTS_FILE}"
  set +a
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --ctl-repo-source) CTL_REPO_SOURCE="${2:-}"; shift 2 ;;
    --ctl-repo-ref) CTL_REPO_REF="${2:-}"; shift 2 ;;
    --product-version) PRODUCT_VERSION="${2:-}"; shift 2 ;;
    --k3s-version) K3S_VERSION="${2:-}"; shift 2 ;;
    --control-plane-version) CONTROL_PLANE_VERSION="${2:-}"; shift 2 ;;
    --control-plane-image-ref) CONTROL_PLANE_IMAGE_REF="${2:-}"; shift 2 ;;
    --release-input-source) RELEASE_INPUT_SOURCE="${2:-}"; shift 2 ;;
    --release-input-version) RELEASE_INPUT_VERSION="${2:-}"; shift 2 ;;
    --release-input-fetch-template) RELEASE_INPUT_FETCH_TEMPLATE="${2:-}"; shift 2 ;;
    --k3s-binary-source) K3S_BINARY_SOURCE="${2:-}"; shift 2 ;;
    --k3s-install-script-source) K3S_INSTALL_SCRIPT_SOURCE="${2:-}"; shift 2 ;;
    --k3s-airgap-images-source) K3S_AIRGAP_IMAGES_SOURCE="${2:-}"; shift 2 ;;
    --values-file-source) VALUES_FILE_SOURCE="${2:-}"; shift 2 ;;
    --chart-version) CHART_VERSION="${2:-}"; shift 2 ;;
    --argo-version) ARGO_VERSION="${2:-}"; shift 2 ;;
    --os-version) OS_VERSION="${2:-}"; shift 2 ;;
    --sample-mode) SAMPLE_MODE="${2:-}"; shift 2 ;;
    --keep-workspace) KEEP_WORKSPACE="1"; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "run-product-bundle: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_arg() {
  local flag="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "run-product-bundle: missing required argument ${flag}" >&2
    usage >&2
    exit 2
  fi
}

require_arg --product-version "${PRODUCT_VERSION}"
WORKSPACE="${WORKSPACE:-${WORKDIR:-}}"
CTL_REPO_SOURCE="${CTL_REPO_SOURCE:-${REPO_ROOT}/../appliance-ctl}"
CTL_REPO_REF="${CTL_REPO_REF:-}"
CHART_VERSION="${CHART_VERSION:-${PRODUCT_VERSION}}"

if [[ -z "${CONTROL_PLANE_IMAGE_REF}" && -n "${CONTROL_PLANE_VERSION}" && -n "${CONTROL_PLANE_IMAGE_REPOSITORY}" ]]; then
  CONTROL_PLANE_IMAGE_REF="${CONTROL_PLANE_IMAGE_REPOSITORY}:${CONTROL_PLANE_VERSION}"
fi

require_arg --workspace "${WORKSPACE}"
require_arg --k3s-version "${K3S_VERSION}"
require_arg --control-plane-image-ref "${CONTROL_PLANE_IMAGE_REF}"
require_arg --ctl-repo-source "${CTL_REPO_SOURCE}"

if [[ "${SAMPLE_MODE}" != "1" ]]; then
  if [[ -z "${RELEASE_INPUT_SOURCE}" && ( -z "${RELEASE_INPUT_VERSION}" || -z "${RELEASE_INPUT_FETCH_TEMPLATE}" ) ]]; then
    echo "run-product-bundle: set --release-input-source or both --release-input-version and --release-input-fetch-template" >&2
    usage >&2
    exit 2
  fi
  require_arg --k3s-binary-source "${K3S_BINARY_SOURCE}"
  require_arg --k3s-install-script-source "${K3S_INSTALL_SCRIPT_SOURCE}"
  require_arg --k3s-airgap-images-source "${K3S_AIRGAP_IMAGES_SOURCE}"
fi

WORKSPACE="$(cd "$(dirname "${WORKSPACE}")" && pwd)/$(basename "${WORKSPACE}")"

REPOS_DIR="${WORKSPACE}/repos"
CTL_DIR="${REPOS_DIR}/appliance-ctl"
INPUTS_DIR="${WORKSPACE}/inputs"
GENERATED_DIR="${WORKSPACE}/generated"
CONFIG_OUT="${GENERATED_DIR}/product-bundle.env"

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

  if [[ "${KEEP_WORKSPACE}" != "1" ]]; then
    rm -rf "${dest}"
  fi
  mkdir -p "$(dirname "${dest}")"

  if [[ -d "${dest}/.git" ]]; then
    return 0
  fi

  if [[ -n "${ref}" ]]; then
    git clone --depth 1 --branch "${ref}" "${clone_source}" "${dest}"
  else
    git clone --depth 1 "${clone_source}" "${dest}"
  fi
}

stage_file() {
  local source="$1"
  local dest="$2"
  local label="$3"

  mkdir -p "$(dirname "${dest}")"

  if [[ "${SAMPLE_MODE}" == "1" && -z "${source}" ]]; then
    return 0
  fi

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

  echo "run-product-bundle: unsupported ${label} source: ${source}" >&2
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

if [[ "${KEEP_WORKSPACE}" != "1" ]]; then
  rm -rf "${WORKSPACE}"
fi
mkdir -p "${REPOS_DIR}" "${INPUTS_DIR}" "${GENERATED_DIR}"

clone_repo "${CTL_REPO_SOURCE}" "${CTL_REPO_REF}" "${CTL_DIR}"

stage_file "${K3S_BINARY_SOURCE}" "${INPUTS_DIR}/k3s" "k3s binary"
stage_file "${K3S_INSTALL_SCRIPT_SOURCE}" "${INPUTS_DIR}/install.sh" "k3s install script"
stage_file "${K3S_AIRGAP_IMAGES_SOURCE}" "${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst" "k3s airgap images"
chmod +x "${INPUTS_DIR}/k3s" "${INPUTS_DIR}/install.sh" 2>/dev/null || true

if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  stage_file "${VALUES_FILE_SOURCE}" "${INPUTS_DIR}/values-minimal.yaml" "values file"
fi

cp "${REPO_ROOT}/configs/product-bundle.ci.env" "${CONFIG_OUT}"

set_env_var "${CONFIG_OUT}" WORKDIR "${WORKSPACE}"
set_env_var "${CONFIG_OUT}" PRODUCT_VERSION "${PRODUCT_VERSION}"
set_env_var "${CONFIG_OUT}" K3S_VERSION "${K3S_VERSION}"
set_env_var "${CONFIG_OUT}" CONTROL_PLANE_VERSION "${CONTROL_PLANE_VERSION}"
set_env_var "${CONFIG_OUT}" CONTROL_PLANE_IMAGE_REF "${CONTROL_PLANE_IMAGE_REF}"
if [[ -n "${RELEASE_INPUT_SOURCE}" ]]; then
  set_env_var "${CONFIG_OUT}" RELEASE_INPUT_SOURCE "${RELEASE_INPUT_SOURCE}"
else
  set_env_var "${CONFIG_OUT}" RELEASE_INPUT_SOURCE ""
  set_env_var "${CONFIG_OUT}" RELEASE_INPUT_VERSION "${RELEASE_INPUT_VERSION}"
  set_env_var "${CONFIG_OUT}" RELEASE_INPUT_FETCH_TEMPLATE "${RELEASE_INPUT_FETCH_TEMPLATE}"
fi
set_env_var "${CONFIG_OUT}" CTL_REPO_SOURCE "${CTL_DIR}"
set_env_var "${CONFIG_OUT}" SAMPLE_MODE "${SAMPLE_MODE}"
set_env_var "${CONFIG_OUT}" INPUTS_DIR "${INPUTS_DIR}"
set_env_var "${CONFIG_OUT}" CTL_REPO_REF ""
set_env_var "${CONFIG_OUT}" CHART_VERSION "${CHART_VERSION}"
set_env_var "${CONFIG_OUT}" ARGO_VERSION "${ARGO_VERSION}"
set_env_var "${CONFIG_OUT}" OS_VERSION "${OS_VERSION}"

if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  set_env_var "${CONFIG_OUT}" VALUES_FILE "${INPUTS_DIR}/values-minimal.yaml"
fi

echo "generated bundle config:"
echo "  ${CONFIG_OUT}"

make -C "${REPO_ROOT}" product-bundle CONFIG="${CONFIG_OUT}"

echo "bundle build completed:"
echo "  workspace: ${WORKSPACE}"
echo "  release repo driver: ${REPO_ROOT}"
echo "  bundle dir: ${WORKSPACE}/out/appliance-${PRODUCT_VERSION}-bundle"
