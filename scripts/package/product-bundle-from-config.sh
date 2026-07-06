#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: product-bundle-from-config.sh --config PATH

Runs the complete sample/simple product bundle flow from a single config file.
EOF
}

CONFIG_PATH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "product-bundle-from-config: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${CONFIG_PATH}" ]]; then
  echo "product-bundle-from-config: --config is required" >&2
  usage >&2
  exit 2
fi

CONFIG_PATH="$(cd "$(dirname "${CONFIG_PATH}")" && pwd)/$(basename "${CONFIG_PATH}")"
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "product-bundle-from-config: missing config: ${CONFIG_PATH}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${CONFIG_PATH}"
set +a

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "product-bundle-from-config: config must set ${name}" >&2
    exit 1
  fi
}

require_var WORKDIR
require_var CODE_REPO_SOURCE
require_var CTL_REPO_SOURCE
require_var PRODUCT_VERSION
require_var K3S_VERSION
require_var CONTROL_PLANE_IMAGE_REF

WORKDIR="$(cd "$(dirname "${WORKDIR}")" && pwd)/$(basename "${WORKDIR}")"
SAMPLE_MODE="${SAMPLE_MODE:-0}"
INPUTS_DIR="${INPUTS_DIR:-${WORKDIR}/inputs}"
CHART_VERSION="${CHART_VERSION:-${PRODUCT_VERSION}}"
ARGO_VERSION="${ARGO_VERSION:-deferred}"
OS_VERSION="${OS_VERSION:-24.04}"
CONTROL_PLANE_IMAGE="${CONTROL_PLANE_IMAGE:-${INPUTS_DIR}/control-plane-api-${PRODUCT_VERSION}.tar}"
ARGO_CRDS="${ARGO_CRDS:-${INPUTS_DIR}/argo-crds.yaml}"
K3S_BINARY="${K3S_BINARY:-${INPUTS_DIR}/k3s}"
K3S_INSTALL_SCRIPT="${K3S_INSTALL_SCRIPT:-${INPUTS_DIR}/install.sh}"
K3S_AIRGAP_IMAGES="${K3S_AIRGAP_IMAGES:-${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst}"
DOWNLOADS_DIR="${WORKDIR}/downloads"
STAGING_DIR="${WORKDIR}/staging"
RELEASE_INPUT_TAR="${DOWNLOADS_DIR}/release-input-${PRODUCT_VERSION}.tar.gz"
BUNDLE_DIR="${WORKDIR}/out/appliance-${PRODUCT_VERSION}-bundle"

mkdir -p "${WORKDIR}" "${INPUTS_DIR}" "${DOWNLOADS_DIR}"

if [[ "${SAMPLE_MODE}" == "1" ]]; then
  mkdir -p "$(dirname "${CONTROL_PLANE_IMAGE}")" "$(dirname "${ARGO_CRDS}")" "$(dirname "${K3S_BINARY}")" "$(dirname "${K3S_INSTALL_SCRIPT}")" "$(dirname "${K3S_AIRGAP_IMAGES}")"
  printf 'control-plane-image\n' > "${CONTROL_PLANE_IMAGE}"
  cat >"${ARGO_CRDS}" <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: workflows.argoproj.io
spec:
  group: argoproj.io
  scope: Namespaced
  names:
    plural: workflows
    singular: workflow
    kind: Workflow
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
EOF
  printf 'k3s-binary\n' > "${K3S_BINARY}"
  chmod +x "${K3S_BINARY}"
  printf '#!/bin/sh\necho install\n' > "${K3S_INSTALL_SCRIPT}"
  chmod +x "${K3S_INSTALL_SCRIPT}"
  printf 'k3s images\n' > "${K3S_AIRGAP_IMAGES}"
fi

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "${path}" ]]; then
    echo "product-bundle-from-config: missing ${label}: ${path}" >&2
    exit 1
  fi
}

require_file "${CONTROL_PLANE_IMAGE}" "control-plane image"
require_file "${ARGO_CRDS}" "argo CRDs"
require_file "${K3S_BINARY}" "k3s binary"
require_file "${K3S_INSTALL_SCRIPT}" "k3s install script"
require_file "${K3S_AIRGAP_IMAGES}" "k3s airgap images"
if [[ -n "${VALUES_FILE:-}" ]]; then
  require_file "${VALUES_FILE}" "values file"
fi

clone_repo() {
  local source="$1"
  local ref="$2"
  local dest="$3"
  local clone_source="${source}"
  if [[ -d "${source}" ]]; then
    clone_source="file://$(cd "$(dirname "${source}")" && pwd)/$(basename "${source}")"
  fi
  rm -rf "${dest}"
  mkdir -p "$(dirname "${dest}")"
  if [[ -n "${ref}" ]]; then
    git clone --depth 1 --branch "${ref}" "${clone_source}" "${dest}"
  else
    git clone --depth 1 "${clone_source}" "${dest}"
  fi
}

CLONE_DIR="${WORKDIR}/sources/appliance-code"
CTL_CLONE_DIR="${WORKDIR}/sources/appliance-ctl"

if [[ -d "${CODE_REPO_SOURCE}" && -z "${CODE_REPO_REF:-}" ]]; then
  CLONE_DIR="$(cd "${CODE_REPO_SOURCE}" && pwd)"
else
  clone_repo "${CODE_REPO_SOURCE}" "${CODE_REPO_REF:-}" "${CLONE_DIR}"
fi

if [[ -d "${CTL_REPO_SOURCE}" && -z "${CTL_REPO_REF:-}" ]]; then
  make -C "${CTL_REPO_SOURCE}" build
  ZONCTL_BINARY="$(cd "${CTL_REPO_SOURCE}" && pwd)/bin/zonctl"
else
  clone_repo "${CTL_REPO_SOURCE}" "${CTL_REPO_REF:-}" "${CTL_CLONE_DIR}"
  make -C "${CTL_CLONE_DIR}" build
  ZONCTL_BINARY="${CTL_CLONE_DIR}/bin/zonctl"
fi
require_file "${ZONCTL_BINARY}" "zonctl binary"

make -C "${CLONE_DIR}" package-release-input-tar \
  OUT_FILE="${RELEASE_INPUT_TAR}" \
  PRODUCT_VERSION="${PRODUCT_VERSION}" \
  CONTROL_PLANE_IMAGE="${CONTROL_PLANE_IMAGE}" \
  ARGO_CRDS="${ARGO_CRDS}" \
  K3S_VERSION="${K3S_VERSION}" \
  CHART_VERSION="${CHART_VERSION}" \
  ARGO_VERSION="${ARGO_VERSION}" \
  ${SUPPORTED_UPGRADE_SOURCE:+SUPPORTED_UPGRADE_SOURCE="${SUPPORTED_UPGRADE_SOURCE}"} \
  ${SBOM_DIR:+SBOM_DIR="${SBOM_DIR}"} \
  ${PROVENANCE_DIR:+PROVENANCE_DIR="${PROVENANCE_DIR}"} \
  ${NOTICES_DIR:+NOTICES_DIR="${NOTICES_DIR}"} \
  ${TESTS_DIR:+TESTS_DIR="${TESTS_DIR}"}

make -C "${REPO_ROOT}" prepare-simple-workspace \
  WORKDIR="${WORKDIR}" \
  ZONCTL_BINARY="${ZONCTL_BINARY}" \
  RELEASE_INPUT_SOURCE="${RELEASE_INPUT_TAR}" \
  PRODUCT_VERSION="${PRODUCT_VERSION}" \
  CONTROL_PLANE_IMAGE_REF="${CONTROL_PLANE_IMAGE_REF}" \
  OS_VERSION="${OS_VERSION}"

mkdir -p "${STAGING_DIR}"
cp "${K3S_BINARY}" "${STAGING_DIR}/k3s"
chmod +x "${STAGING_DIR}/k3s"
cp "${K3S_INSTALL_SCRIPT}" "${STAGING_DIR}/install.sh"
chmod +x "${STAGING_DIR}/install.sh"
cp "${K3S_AIRGAP_IMAGES}" "${STAGING_DIR}/k3s-airgap-images-amd64.tar.zst"
cp "${CONTROL_PLANE_IMAGE}" "${STAGING_DIR}/control-plane-api-${PRODUCT_VERSION}.tar"
cp "${ARGO_CRDS}" "${STAGING_DIR}/argo-crds.yaml"
if [[ -n "${VALUES_FILE:-}" ]]; then
  cp "${VALUES_FILE}" "${STAGING_DIR}/values-minimal.yaml"
fi

rm -rf "${BUNDLE_DIR}"

make -C "${REPO_ROOT}" assemble-simple-bundle \
  WORKDIR="${WORKDIR}" \
  ZONCTL_BINARY="${ZONCTL_BINARY}"
make -C "${REPO_ROOT}" verify-bundle \
  ZONCTL_BINARY="${ZONCTL_BINARY}" \
  BUNDLE_DIR="${BUNDLE_DIR}" \
  PUBLIC_KEY="${WORKDIR}/keys/release-signing.pub"

echo "bundle ready:"
echo "  ${BUNDLE_DIR}"
