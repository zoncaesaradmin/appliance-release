#!/usr/bin/env bash
# Fetch pinned K3s binary + airgap images for local build inputs, then publish
# the same files to the appliance files API (authenticated artifact store).
#
# Required environment:
#   RELEASE_WORK_ROOT  Build root (e.g. /home/zonsys/appliance-build).
#                      Files are staged under $RELEASE_WORK_ROOT/inputs/:
#                        $RELEASE_WORK_ROOT/inputs/k3s
#                        $RELEASE_WORK_ROOT/inputs/k3s-airgap-images-amd64.tar.zst
#   DEV_REGISTRY       Appliance host (e.g. artifact-dns-1.appliance.internal)
#   DEV_REGISTRY_TOKEN Bearer token with files/artifacts write
#
# Optional environment:
#   DEV_REGISTRY_TLS_VERIFY   false/0/no → curl -k (default true)
#   SKIP_PUBLISH=1            Download/stage only; do not upload to files API
#
# Version is fixed in this script to match configs/product-bundle.ci.env (K3S_VERSION).
# Bump both together when changing the product K3s pin.
#
# Usage:
#   export RELEASE_WORK_ROOT=... DEV_REGISTRY=... DEV_REGISTRY_TOKEN=...
#   bash ./scripts/ci/fetch-k3s-inputs.sh
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
usage: bash ./scripts/ci/fetch-k3s-inputs.sh

Required environment:
  RELEASE_WORK_ROOT   Build root; stages under $RELEASE_WORK_ROOT/inputs/
  DEV_REGISTRY        Appliance host
  DEV_REGISTRY_TOKEN  Bearer token with files write

Optional:
  DEV_REGISTRY_TLS_VERIFY=false  use curl -k
  SKIP_PUBLISH=1                 stage only; do not upload

K3s version is hardcoded here (must match product-bundle.ci.env K3S_VERSION).
EOF
  exit 0
fi

# Keep in sync with configs/product-bundle.ci.env K3S_VERSION.
readonly K3S_VERSION="v1.30.4+k3s1"
readonly K3S_BINARY_NAME="k3s"
readonly K3S_AIRGAP_NAME="k3s-airgap-images-amd64.tar.zst"

require_var() {
  local n="$1"
  if [[ -z "${!n:-}" ]]; then
    echo "fetch-k3s-inputs: ${n} is required" >&2
    exit 2
  fi
}

require_var RELEASE_WORK_ROOT
require_var DEV_REGISTRY
require_var DEV_REGISTRY_TOKEN

tls_insecure=()
case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) tls_insecure=(-k) ;;
esac

release_work_root="${RELEASE_WORK_ROOT%/}"
inputs_dir="${release_work_root}/inputs"
bin_path="${inputs_dir}/${K3S_BINARY_NAME}"
airgap_path="${inputs_dir}/${K3S_AIRGAP_NAME}"

ver_enc="${K3S_VERSION//+/%2B}"
base_url="https://github.com/k3s-io/k3s/releases/download/${ver_enc}"

echo "fetch-k3s-inputs: K3S_VERSION=${K3S_VERSION} dir=${inputs_dir}"
rm -rf "${inputs_dir}"
mkdir -p "${inputs_dir}"

echo "fetch-k3s-inputs: downloading ${K3S_BINARY_NAME} → ${bin_path}"
curl -fsSL -o "${bin_path}" "${base_url}/k3s"
chmod +x "${bin_path}"

echo "fetch-k3s-inputs: downloading ${K3S_AIRGAP_NAME} → ${airgap_path}"
curl -fsSL -o "${airgap_path}" "${base_url}/k3s-airgap-images-amd64.tar.zst"

if [[ "${SKIP_PUBLISH:-}" == "1" ]]; then
  echo "fetch-k3s-inputs: SKIP_PUBLISH=1; local files ready"
  exit 0
fi

registry="${DEV_REGISTRY#https://}"
registry="${registry#http://}"
registry="${registry%/}"
remote_prefix="https://${registry}/api/v1/files/k3s/${K3S_VERSION}"

upload() {
  local src="$1"
  local url="$2"
  local code
  code="$(
    curl -sS "${tls_insecure[@]}" -X POST \
      -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${DEV_REGISTRY_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${src}" \
      "${url}"
  )"
  if [[ "${code}" != "200" && "${code}" != "201" ]]; then
    echo "fetch-k3s-inputs: upload failed http=${code} url=${url}" >&2
    exit 1
  fi
  echo "fetch-k3s-inputs: published ${url}"
}

upload "${bin_path}" "${remote_prefix}/${K3S_BINARY_NAME}"
upload "${airgap_path}" "${remote_prefix}/${K3S_AIRGAP_NAME}"
echo "fetch-k3s-inputs: done"
