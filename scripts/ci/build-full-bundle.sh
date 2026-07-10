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
6. this script exports the customer-facing delivery files

Run this from the checked-out appliance-release repo root:

  bash ./scripts/ci/build-full-bundle.sh

Configuration is taken from environment variables. The most common pattern is:

  PRODUCT_VERSION=0.1.0 \
  CODE_REPO_SOURCE=https://git.example.invalid/zon/appliance-code.git \
  CTL_REPO_SOURCE=https://git.example.invalid/zon/appliance-ctl.git \
  K3S_BINARY_SOURCE=/ci/inputs/k3s \
  K3S_AIRGAP_IMAGES_SOURCE=/ci/inputs/k3s-airgap-images-amd64.tar.zst \
  HELM_BINARY=/usr/local/bin/helm \
  bash ./scripts/ci/build-full-bundle.sh

Optional overrides:
  CODE_REPO_REF=main
  CTL_REPO_REF=main
  WORK_ROOT=${TMPDIR:-/tmp}/appliance-build
  EXPORT_DIR=\$WORK_ROOT/export
  K3S_VERSION_OVERRIDE=v1.30.4+k3s1
  VALUES_FILE_SOURCE=/ci/inputs/values-minimal.yaml
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEFAULTS_FILE="${RELEASE_REPO_DIR}/configs/product-bundle.ci.env"

USER_PRODUCT_VERSION="${PRODUCT_VERSION-}"
USER_CODE_REPO_SOURCE="${CODE_REPO_SOURCE-}"
USER_CODE_REPO_REF="${CODE_REPO_REF-}"
USER_CTL_REPO_SOURCE="${CTL_REPO_SOURCE-}"
USER_CTL_REPO_REF="${CTL_REPO_REF-}"
USER_K3S_BINARY_SOURCE="${K3S_BINARY_SOURCE-}"
USER_K3S_AIRGAP_IMAGES_SOURCE="${K3S_AIRGAP_IMAGES_SOURCE-}"
USER_HELM_BINARY="${HELM_BINARY-}"
USER_VALUES_FILE_SOURCE="${VALUES_FILE_SOURCE-}"
USER_WORK_ROOT="${WORK_ROOT-}"
USER_EXPORT_DIR="${EXPORT_DIR-}"
USER_K3S_VERSION_OVERRIDE="${K3S_VERSION_OVERRIDE-}"

set -a
# shellcheck disable=SC1090
source "${DEFAULTS_FILE}"
set +a

PRODUCT_VERSION="${USER_PRODUCT_VERSION:-${PRODUCT_VERSION:-}}"
CODE_REPO_SOURCE="${USER_CODE_REPO_SOURCE:-${CODE_REPO_SOURCE:-}}"
CODE_REPO_REF="${USER_CODE_REPO_REF:-${CODE_REPO_REF:-main}}"
CTL_REPO_SOURCE="${USER_CTL_REPO_SOURCE:-${CTL_REPO_SOURCE:-}}"
CTL_REPO_REF="${USER_CTL_REPO_REF:-${CTL_REPO_REF:-main}}"
K3S_BINARY_SOURCE="${USER_K3S_BINARY_SOURCE:-${K3S_BINARY_SOURCE:-}}"
K3S_AIRGAP_IMAGES_SOURCE="${USER_K3S_AIRGAP_IMAGES_SOURCE:-${K3S_AIRGAP_IMAGES_SOURCE:-}}"
HELM_BINARY="${USER_HELM_BINARY:-${HELM_BINARY:-}}"
VALUES_FILE_SOURCE="${USER_VALUES_FILE_SOURCE:-${VALUES_FILE:-}}"
WORK_ROOT="${USER_WORK_ROOT:-${WORKDIR:-${TMPDIR:-/tmp}/appliance-build}}"
EXPORT_DIR="${USER_EXPORT_DIR:-${EXPORT_DIR:-${WORK_ROOT}/export}}"
K3S_VERSION_OVERRIDE="${USER_K3S_VERSION_OVERRIDE:-}"

if [[ -n "${K3S_VERSION_OVERRIDE}" ]]; then
  K3S_VERSION="${K3S_VERSION_OVERRIDE}"
fi

REPOS_DIR="${WORK_ROOT}/repos"
ARTIFACTS_DIR="${WORK_ROOT}/artifacts"
WORKSPACE="${WORK_ROOT}/workspace"
INPUTS_DIR="${WORKSPACE}/inputs"
GENERATED_DIR="${WORKSPACE}/generated"
CONFIG_OUT="${GENERATED_DIR}/product-bundle.env"
BUNDLE_DIR="${WORKSPACE}/out/appliance-${PRODUCT_VERSION}-bundle"
BUNDLE_ARCHIVE="${EXPORT_DIR}/appliance-${PRODUCT_VERSION}-bundle.tar.gz"
PUBLIC_KEY_EXPORT="${EXPORT_DIR}/release-signing.pub"

CODE_REPO_DIR="${REPOS_DIR}/appliance-code"
CTL_REPO_DIR="${REPOS_DIR}/appliance-ctl"
RELEASE_INPUT_TAR="${ARTIFACTS_DIR}/release-input-${PRODUCT_VERSION}.tar.gz"
CODE_RELEASE_INPUT_TAR="${CODE_REPO_DIR}/.run/release-input-${PRODUCT_VERSION}.tar.gz"
CODE_DEV_SCRIPT_REL=".run/package-release-input-in-dev-container.sh"
CODE_DEV_SCRIPT_PATH="${CODE_REPO_DIR}/${CODE_DEV_SCRIPT_REL}"

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

require_appliance_code_bootstrap() {
  local podman_path
  local probe_user="build-full-bundle-user-probe-$$"
  local probe_tag="build-full-bundle-tag-probe-$$"

  if ! command -v podman >/dev/null 2>&1; then
    echo "build-full-bundle: podman is required on PATH for appliance-code dev-run" >&2
    exit 1
  fi
  podman_path="$(command -v podman)"

  if sudo -n "${podman_path}" --version >/dev/null 2>&1 \
    && [[ "$(REGISTRY_USER="${probe_user}" sudo -n env 2>/dev/null | sed -n 's/^REGISTRY_USER=//p')" == "${probe_user}" ]] \
    && [[ "$(IMAGE_TAG="${probe_tag}" sudo -n env 2>/dev/null | sed -n 's/^IMAGE_TAG=//p')" == "${probe_tag}" ]]; then
    return 0
  fi

  cat >&2 <<EOF
build-full-bundle: appliance-code host bootstrap is missing for non-interactive CI
build-full-bundle: this script will not prompt for sudo in CI
build-full-bundle:
build-full-bundle: run this once on the build host:
build-full-bundle:   export REGISTRY_USER=<github-username>
build-full-bundle:   export REGISTRY_TOKEN=<PAT with read:packages>
build-full-bundle:   bash ${RELEASE_REPO_DIR}/scripts/ci/bootstrap-build-host.sh
build-full-bundle:
build-full-bundle: if the registry token changes later, rerun the same bootstrap script with the new token.
build-full-bundle:
build-full-bundle: then rerun:
build-full-bundle:   bash ${RELEASE_REPO_DIR}/scripts/ci/build-full-bundle.sh
EOF
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

to_abs_lexical_path() {
  local path="$1"

  case "${path}" in
    /*) ;;
    *) path="${PWD}/${path}" ;;
  esac

  while [[ "${path}" != "/" && "${path}" == */ ]]; do
    path="${path%/}"
  done

  printf '%s\n' "${path}"
}

is_within_dir() {
  local path="$1"
  local root="$2"

  path="$(to_abs_lexical_path "${path}")"
  root="$(to_abs_lexical_path "${root}")"

  case "${path}" in
    "${root}"|"${root}"/*) return 0 ;;
    *) return 1 ;;
  esac
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

require_var PRODUCT_VERSION
require_var CODE_REPO_SOURCE
require_var CTL_REPO_SOURCE
require_var K3S_VERSION
require_var K3S_BINARY_SOURCE
require_var K3S_AIRGAP_IMAGES_SOURCE

if [[ -z "${HELM_BINARY}" ]]; then
  HELM_BINARY="$(command -v helm || true)"
fi

require_file "${K3S_BINARY_SOURCE}" "k3s binary"
require_file "${K3S_AIRGAP_IMAGES_SOURCE}" "k3s airgap images"
require_file "${HELM_BINARY}" "helm binary"
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  require_file "${VALUES_FILE_SOURCE}" "values file"
fi

rm -rf "${ARTIFACTS_DIR}" "${WORKSPACE}"
if is_within_dir "${EXPORT_DIR}" "${WORK_ROOT}"; then
  rm -rf "${EXPORT_DIR}"
else
  mkdir -p "${EXPORT_DIR}"
  find "${EXPORT_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
mkdir -p "${REPOS_DIR}" "${ARTIFACTS_DIR}" "${INPUTS_DIR}" "${GENERATED_DIR}" "${EXPORT_DIR}"

clone_repo "${CODE_REPO_SOURCE}" "${CODE_REPO_REF}" "${CODE_REPO_DIR}"
clone_repo "${CTL_REPO_SOURCE}" "${CTL_REPO_REF}" "${CTL_REPO_DIR}"

require_appliance_code_bootstrap

mkdir -p "${CODE_REPO_DIR}/.run"
cat >"${CODE_DEV_SCRIPT_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd /workspace
make package-release-input-tar \
  OUT_FILE="/workspace/.run/release-input-${PRODUCT_VERSION}.tar.gz" \
  K3S_VERSION="${K3S_VERSION}"
EOF
chmod +x "${CODE_DEV_SCRIPT_PATH}"

make -C "${CODE_REPO_DIR}" dev-run SCRIPT="${CODE_DEV_SCRIPT_REL}"
cp "${CODE_RELEASE_INPUT_TAR}" "${RELEASE_INPUT_TAR}"

stage_file "${K3S_BINARY_SOURCE}" "${INPUTS_DIR}/k3s" "k3s binary"
stage_file "${K3S_AIRGAP_IMAGES_SOURCE}" "${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst" "k3s airgap images"
chmod +x "${INPUTS_DIR}/k3s" 2>/dev/null || true
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
set_env_var "${CONFIG_OUT}" HELM_BINARY "${HELM_BINARY}"
set_env_var "${CONFIG_OUT}" K3S_BINARY "${INPUTS_DIR}/k3s"
set_env_var "${CONFIG_OUT}" K3S_AIRGAP_IMAGES "${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst"
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  set_env_var "${CONFIG_OUT}" VALUES_FILE "${INPUTS_DIR}/values-minimal.yaml"
else
  set_env_var "${CONFIG_OUT}" VALUES_FILE ""
fi

echo "generated bundle config:"
echo "  ${CONFIG_OUT}"

make -C "${RELEASE_REPO_DIR}" product-bundle CONFIG="${CONFIG_OUT}"

tar -C "$(dirname "${BUNDLE_DIR}")" -czf "${BUNDLE_ARCHIVE}" "$(basename "${BUNDLE_DIR}")"
cp "${WORKSPACE}/keys/release-signing.pub" "${PUBLIC_KEY_EXPORT}"

echo
echo "release-input tarball:"
echo "  ${RELEASE_INPUT_TAR}"
echo
echo "final bundle:"
echo "  ${BUNDLE_DIR}"
echo
echo "generated bundle config:"
echo "  ${WORKSPACE}/generated/product-bundle.env"
echo
echo "exported customer delivery files:"
echo "  ${BUNDLE_ARCHIVE}"
echo "  ${PUBLIC_KEY_EXPORT}"
echo
echo "next publish step on the build machine:"
echo "  export PRODUCT_VERSION=${PRODUCT_VERSION}"
echo "  make publish-release EXPORT_DIR=${EXPORT_DIR} PUBLISH_SERVER=<user@host> PUBLISH_REMOTE_ROOT=/srv/www/releases"
echo "optional publish vars:"
echo "  PUBLISH_PUBLIC_BASE_URL=http://downloads.example.internal/releases"
echo "  PUBLISH_LATEST_ALIAS=1"
