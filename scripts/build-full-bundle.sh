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

  bash ./scripts/build-full-bundle.sh

Configuration is taken from environment variables. Exactly one mode — online or
offline — selects every third-party source together (no LAN+internet mix).

Two build-host modes (one policy for all third-party inputs — not a mix):
  Online (default, OFFLINE_BUILD unset/0): public internet for third-party inputs.
  Offline (OFFLINE_BUILD=1): LAN Artifact Server only after make seed-build-deps.

After the release skill (or the operator) chooses online vs offline inputs, packaging
uses one fixed DEV_* set for the tooling image / registry login. Do not pass
ONLINE_* into this script — unify first (offline already uses DEV_*).

  DEV_REGISTRY / DEV_IMAGE_REPO / DEV_IMAGE_NAME / DEV_IMAGE_TAG
  DEV_REGISTRY_USER / DEV_REGISTRY_TOKEN / DEV_REGISTRY_TLS_VERIFY
  OFFLINE_BUILD=0|1

Example online (DEV_* already pointed at GHCR):
  DEV_REGISTRY=ghcr.io \
  DEV_IMAGE_REPO=zoncaesaradmin/development-container \
  DEV_IMAGE_NAME=dev-build DEV_IMAGE_TAG=latest \
  DEV_REGISTRY_USER=... DEV_REGISTRY_TOKEN=... \
  bash ./scripts/build-full-bundle.sh

Example offline (after make seed-build-deps; DEV_* = LAN):
  OFFLINE_BUILD=1 \
  DEV_REGISTRY=artifact-dns-1.appliance.internal \
  DEV_IMAGE_REPO=development-container \
  DEV_REGISTRY_USER=... DEV_REGISTRY_TOKEN=... DEV_REGISTRY_TLS_VERIFY=false \
  bash ./scripts/build-full-bundle.sh

PRODUCT_VERSION defaults from configs/default-product-version.
DEV_IMAGE_NAME/TAG default to dev-build/latest.
K3s: online from GitHub releases; offline from LAN files API
  https://\$DEV_REGISTRY/api/v1/files/k3s/\$K3S_VERSION/…
K3S_VERSION comes from configs/product-bundle.ci.env (or K3S_VERSION_OVERRIDE).

See docs/offline-build-deps.md.

The workflows engine is on by default (it is a mandatory component of the
complete v1 appliance per ADR 0011) and needs no configuration: its
version and controller/executor image references are derived
automatically from appliance-code's own
deploy/charts/appliance-workflows/Chart.yaml (the chart's pinned appVersion),
and its CRDs are fetched automatically from the matching upstream Argo
Workflows GitHub release unless you provide a local copy. You never need
to set a workflows version yourself.

Optional overrides:
  PRODUCT_VERSION=0.1.0         # overrides configs/default-product-version
  RELEASE_WORK_ROOT=${TMPDIR:-/tmp}/appliance-build
  K3S_VERSION_OVERRIDE=v1.30.4+k3s1
  HELM_VERSION=v3.21.1
  HELM_BINARY=/abs/path/to/linux-amd64/helm
  VALUES_FILE_SOURCE=/ci/inputs/values-minimal.yaml
  # Host packages: always export-host-packages for mdns + wifi-ap under OS_VERSION
  # (ubuntu/<version>/amd64/*.deb). Install stages debs; enablement is day-2 only.
  # BUILD_COMPLETE_PRODUCT=false  # developer slim path only; default true requires workflows
  # COMPONENT_CACHE_DIR=/var/cache/appliance-build/components  # optional dirty-only rebuild cache
  WORKFLOWS_ENABLED=true                 # complete product always packages the workflows engine (set BUILD_COMPLETE_PRODUCT=false to allow opt-out)
  WORKFLOWS_VERSION=v3.5.10              # pin a different workflows engine version than the chart's appVersion
  WORKFLOW_CONTROLLER_IMAGE_REF=localhost/appliance-workflow-controller:v3.5.10
  WORKFLOW_EXECUTOR_IMAGE_REF=quay.io/argoproj/argoexec:v3.5.10
  # Offline: Workflow CRDs/images from LAN build-cache (seeded by make seed-build-deps).
  # Online: public upstreams (GitHub / Quay / Docker Hub / GHCR public).
  WORKSPACE_PROVISIONER_IMAGE_REF=docker.io/alpine/git:2.49.0
  # DEV_* tooling image (dev-build) builds product images on the build host only.
  # It is NOT packaged into the appliance bundle; operators supply builder images.
  ARTIFACT_SERVER_VERSION=2.1.8
  MESSAGE_BROKER_SOURCE_IMAGE=docker.io/library/nats:2.10.26-alpine
  ARTIFACT_SERVER_SOURCE_IMAGE=ghcr.io/project-zot/zot-linux-amd64:v2.1.8
  # Artifact server: always wrap upstream via appliance-code
  # package-artifact-server-image-archive (dev-run has buildah+skopeo);
  # annotate registry.local/artifact-server:bundled and derive
  # registry.local/artifact-server@sha256:<platform-digest> from index.json
  # (existing install OCI contract name).
  DNS_VERSION=1.14.4
  DNS_IMAGE_PULL_REF=registry.k8s.io/coredns/coredns:v1.14.4
  # DNS server: always wrap upstream CoreDNS via appliance-code package-dns-server-image-archive
  # (dev-run has buildah+skopeo); digest from index.json.
  INFERENCE_VERSION=0.6.5
  INFERENCE_IMAGE_PULL_REF=docker.io/ollama/ollama:0.6.5
  # Inference runtime: always re-export via appliance-code
  # package-inference-runtime-image-archive; digest from index.json.
  APPLIANCE_PACKS=all                   # all | foundation | foundation,developer | foundation,inference | …
EOF
}
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/appliance-packs.sh"
DEFAULTS_FILE="${RELEASE_REPO_DIR}/configs/product-bundle.ci.env"

USER_PRODUCT_VERSION="${PRODUCT_VERSION-}"
USER_CODE_REPO_SOURCE="${CODE_REPO_SOURCE-}"
USER_CTL_REPO_SOURCE="${CTL_REPO_SOURCE-}"
USER_HELM_BINARY="${HELM_BINARY-}"
USER_HELM_VERSION="${HELM_VERSION-}"
USER_VALUES_FILE_SOURCE="${VALUES_FILE_SOURCE-}"
USER_RELEASE_WORK_ROOT="${RELEASE_WORK_ROOT-}"
USER_OS_VERSION="${OS_VERSION-}"
USER_K3S_VERSION_OVERRIDE="${K3S_VERSION_OVERRIDE-}"
USER_WORKFLOWS_ENABLED="${WORKFLOWS_ENABLED-}"
USER_WORKFLOWS_REQUIRED="${WORKFLOWS_REQUIRED-}"
USER_WORKFLOWS_VERSION="${WORKFLOWS_VERSION-}"
USER_WORKFLOW_CONTROLLER_IMAGE_REF="${WORKFLOW_CONTROLLER_IMAGE_REF-}"
USER_WORKFLOW_EXECUTOR_IMAGE_REF="${WORKFLOW_EXECUTOR_IMAGE_REF-}"
USER_WORKSPACE_PROVISIONER_IMAGE_REF="${WORKSPACE_PROVISIONER_IMAGE_REF-}"
USER_ARTIFACT_SERVER_VERSION="${ARTIFACT_SERVER_VERSION-}"
USER_ARTIFACT_SERVER_SOURCE_IMAGE="${ARTIFACT_SERVER_SOURCE_IMAGE-}"
USER_DNS_VERSION="${DNS_VERSION-}"
USER_DNS_IMAGE_PULL_REF="${DNS_IMAGE_PULL_REF-}"
USER_INFERENCE_VERSION="${INFERENCE_VERSION-}"
USER_INFERENCE_IMAGE_PULL_REF="${INFERENCE_IMAGE_PULL_REF-}"
USER_DEV_REGISTRY="${DEV_REGISTRY-}"
USER_DEV_IMAGE_REPO="${DEV_IMAGE_REPO-}"
USER_DEV_IMAGE_NAME="${DEV_IMAGE_NAME-}"
USER_DEV_IMAGE_TAG="${DEV_IMAGE_TAG-}"
USER_APPLIANCE_PACKS="${APPLIANCE_PACKS-}"

set -a
# shellcheck disable=SC1090
source "${DEFAULTS_FILE}"
set +a

# Reject removed offline/local archive path knobs.
_removed_offline_build_inputs=(
  WORKFLOWS_CRDS_DIR_SOURCE
  WORKFLOW_CONTROLLER_IMAGE_ARCHIVE_SOURCE
  WORKFLOW_EXECUTOR_IMAGE_ARCHIVE_SOURCE
  WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE
  ARTIFACT_SERVER_IMAGE_ARCHIVE_SOURCE
  DNS_IMAGE_ARCHIVE_SOURCE
  HOST_PACKAGES_DIR_SOURCE
)
for _var in "${_removed_offline_build_inputs[@]}"; do
  if [[ -n "${!_var-}" ]]; then
    echo "build-full-bundle: ${_var} is no longer supported (no offline/local archive path inputs)." >&2
    echo "build-full-bundle: use build_flow.mode online (public) or offline (LAN after seed-build-deps)." >&2
    exit 2
  fi
done
unset _var _removed_offline_build_inputs

if [[ -n "${EXPORT_DIR-}" ]]; then
  echo "build-full-bundle: EXPORT_DIR is no longer supported." >&2
  echo "build-full-bundle: set RELEASE_WORK_ROOT; export output is always \$RELEASE_WORK_ROOT/export." >&2
  exit 2
fi

# Fixed LAN build-cache policy (offline mode only).
LAN_BUILD_CACHE_PREFIX="build-cache"
LAN_BUILD_CACHE_TIMEOUT_SECONDS="15"
# When OFFLINE_BUILD=1, packaging must not fall back to public upstreams
# (Docker Hub/GHCR/Quay/GitHub/get.helm.sh/apt). Seeds come from
# deps/* → DEV_REGISTRY (OCI build-cache + files API).
# When OFFLINE_BUILD=0 (online), DEV_* is the public tooling registry only;
# files API / LAN build-cache paths stay disabled.
OFFLINE_BUILD="${OFFLINE_BUILD:-0}"
export OFFLINE_BUILD
HOST_PACKAGES_FINGERPRINT="${HOST_PACKAGES_FINGERPRINT:-mdns-wifi-ap-v1}"
ALPINE_GIT_CACHE_TAG="${ALPINE_GIT_CACHE_TAG:-2.49.0}"

offline_build_enabled() {
  case "$(printf '%s' "${OFFLINE_BUILD}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# files API is offline-only (OFFLINE_BUILD=1). Online packaging never probes it.
files_api_download() {
  local remote_path="$1"
  local dest="$2"
  local registry token tls_verify insecure=()
  if ! offline_build_enabled; then
    return 1
  fi
  registry="$(printf '%s' "${DEV_REGISTRY:-}" | tr -d '[:space:]')"
  registry="${registry#https://}"
  registry="${registry#http://}"
  registry="${registry%/}"
  token="$(printf '%s' "${DEV_REGISTRY_TOKEN:-}" | tr -d '[:space:]')"
  if [[ -z "${registry}" || -z "${token}" ]]; then
    return 1
  fi
  case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) insecure=(-k) ;;
  esac
  mkdir -p "$(dirname "${dest}")"
  curl -fsSL "${insecure[@]}" \
    -H "Authorization: Bearer ${token}" \
    -o "${dest}" \
    "https://${registry}/api/v1/files/${remote_path#/}"
}

lan_cache_ref() {
  local short_name="$1"
  local tag="$2"
  local host
  host="$(printf '%s' "${DEV_REGISTRY:-}" | sed 's#/*$##; s#^https\?://##')"
  printf '%s/%s/%s:%s' "${host}" "${LAN_BUILD_CACHE_PREFIX}" "${short_name}" "${tag}"
}

require_seed_package() {
  local package="$1"
  local pins="${RELEASE_REPO_DIR}/deps/${package}/pins.env"
  if [[ ! -f "${pins}" ]]; then
    cat >&2 <<EOF
build-full-bundle: offline dependency seed package is missing: deps/${package}
build-full-bundle: sync the complete appliance-release checkout before building
EOF
    exit 1
  fi
}

# Fixed dependent-repo git refs (edit this script to pin a different branch).
code_git_ref="main"
ctl_git_ref="main"

# Product version: PRODUCT_VERSION env overrides configs/default-product-version.
default_product_version="$(tr -d '[:space:]' < "${RELEASE_REPO_DIR}/configs/default-product-version" 2>/dev/null || true)"
if [[ -z "${default_product_version}" ]]; then
  echo "build-full-bundle: missing or empty ${RELEASE_REPO_DIR}/configs/default-product-version" >&2
  exit 2
fi
PRODUCT_VERSION="${USER_PRODUCT_VERSION:-${default_product_version}}"
CODE_REPO_SOURCE="${USER_CODE_REPO_SOURCE:-${CODE_REPO_SOURCE:-}}"
CTL_REPO_SOURCE="${USER_CTL_REPO_SOURCE:-${CTL_REPO_SOURCE:-}}"
HELM_BINARY="${USER_HELM_BINARY:-${HELM_BINARY:-}}"
HELM_VERSION="${USER_HELM_VERSION:-${HELM_VERSION:-}}"
VALUES_FILE_SOURCE="${USER_VALUES_FILE_SOURCE:-${VALUES_FILE:-}}"
RELEASE_WORK_ROOT="${USER_RELEASE_WORK_ROOT:-${RELEASE_WORK_ROOT:-${TMPDIR:-/tmp}/appliance-build}}"
EXPORT_DIR="${RELEASE_WORK_ROOT}/export"
OS_VERSION="${USER_OS_VERSION:-${OS_VERSION:-24.04}}"
K3S_VERSION_OVERRIDE="${USER_K3S_VERSION_OVERRIDE:-}"
WORKFLOWS_ENABLED="${USER_WORKFLOWS_ENABLED:-${WORKFLOWS_ENABLED:-}}"
WORKFLOWS_REQUIRED="${USER_WORKFLOWS_REQUIRED:-${WORKFLOWS_REQUIRED:-}}"
WORKFLOWS_VERSION="${USER_WORKFLOWS_VERSION:-${WORKFLOWS_VERSION:-}}"
WORKFLOW_CONTROLLER_IMAGE_REF="${USER_WORKFLOW_CONTROLLER_IMAGE_REF:-${WORKFLOW_CONTROLLER_IMAGE_REF:-}}"
WORKFLOW_EXECUTOR_IMAGE_REF="${USER_WORKFLOW_EXECUTOR_IMAGE_REF:-${WORKFLOW_EXECUTOR_IMAGE_REF:-}}"
WORKSPACE_PROVISIONER_IMAGE_REF="${USER_WORKSPACE_PROVISIONER_IMAGE_REF:-${WORKSPACE_PROVISIONER_IMAGE_REF:-docker.io/alpine/git:2.49.0}}"
# compatibility.artifactServerVersion is unprefixed (2.1.8). Chart appVersion
# and GHCR tags use a leading v (v2.1.8). Normalize before constructing the
# pull ref.
ARTIFACT_SERVER_VERSION="${USER_ARTIFACT_SERVER_VERSION:-${ARTIFACT_SERVER_VERSION:-2.1.8}}"
ARTIFACT_SERVER_VERSION="${ARTIFACT_SERVER_VERSION#v}"
ARTIFACT_SERVER_SOURCE_IMAGE="${USER_ARTIFACT_SERVER_SOURCE_IMAGE:-${ARTIFACT_SERVER_SOURCE_IMAGE:-ghcr.io/project-zot/zot-linux-amd64:v${ARTIFACT_SERVER_VERSION}}}"
MESSAGE_BROKER_SOURCE_IMAGE="${USER_MESSAGE_BROKER_SOURCE_IMAGE:-${MESSAGE_BROKER_SOURCE_IMAGE:-docker.io/library/nats:2.10.26-alpine}}"
# compatibility.dnsVersion is unprefixed (1.14.4). Chart appVersion and the
# upstream registry.k8s.io tag use a leading v (v1.14.4). Normalize before
# constructing the pull ref, same as ARTIFACT_SERVER_VERSION above.
DNS_VERSION="${USER_DNS_VERSION:-${DNS_VERSION:-1.14.4}}"
DNS_VERSION="${DNS_VERSION#v}"
DNS_IMAGE_PULL_REF="${USER_DNS_IMAGE_PULL_REF:-${DNS_IMAGE_PULL_REF:-registry.k8s.io/coredns/coredns:v${DNS_VERSION}}}"
# compatibility.inferenceVersion is unprefixed (0.6.5). Chart appVersion and
# the upstream docker.io/ollama/ollama tag are unprefixed as well.
# Use a fully qualified registry host so podman short-name resolution is not required.
INFERENCE_VERSION="${USER_INFERENCE_VERSION:-${INFERENCE_VERSION:-0.6.5}}"
INFERENCE_VERSION="${INFERENCE_VERSION#v}"
INFERENCE_IMAGE_PULL_REF="${USER_INFERENCE_IMAGE_PULL_REF:-${INFERENCE_IMAGE_PULL_REF:-docker.io/ollama/ollama:${INFERENCE_VERSION}}}"

# Pack selection (default all = foundation + developer + inference).
APPLIANCE_PACKS="${USER_APPLIANCE_PACKS:-${APPLIANCE_PACKS:-all}}"
appliance_packs_resolve
echo "build-full-bundle: APPLIANCE_PACKS=${APPLIANCE_PACKS} → ${APPLIANCE_PACKS_RESOLVED}"

# The workflows engine is a mandatory component of the complete product
# super-set (ADR 0011) when the developer pack is selected. BUILD_COMPLETE_PRODUCT
# defaults true and forces WORKFLOWS_ENABLED for that pack. Pack-selective builds
# that omit developer skip workflows packaging.
BUILD_COMPLETE_PRODUCT="${BUILD_COMPLETE_PRODUCT:-true}"
if appliance_pack_wanted developer; then
  if [[ -z "${WORKFLOWS_ENABLED}" ]]; then
    WORKFLOWS_ENABLED="true"
  fi
else
  case "$(printf '%s' "${USER_WORKFLOWS_ENABLED:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      echo "build-full-bundle: WORKFLOWS_ENABLED=true ignored because developer pack is not in APPLIANCE_PACKS (${APPLIANCE_PACKS_RESOLVED})" >&2
      ;;
  esac
  WORKFLOWS_ENABLED="false"
fi

# Unified tooling identity.
# Skill already maps ONLINE_* → DEV_* before invoke. For hand-run online with both
# families exported, refuse a hybrid (LAN DEV_* + public third-party).
DEV_REGISTRY="${USER_DEV_REGISTRY:-${DEV_REGISTRY:-}}"
DEV_IMAGE_REPO="${USER_DEV_IMAGE_REPO:-${DEV_IMAGE_REPO:-}}"
DEV_IMAGE_NAME="${USER_DEV_IMAGE_NAME:-${DEV_IMAGE_NAME:-dev-build}}"
DEV_IMAGE_TAG="${USER_DEV_IMAGE_TAG:-${DEV_IMAGE_TAG:-latest}}"

if ! offline_build_enabled; then
  if [[ -n "${ONLINE_REGISTRY:-}" ]]; then
    if [[ -z "${DEV_REGISTRY}" ]]; then
      DEV_REGISTRY="${ONLINE_REGISTRY}"
      DEV_IMAGE_REPO="${ONLINE_IMAGE_REPO:-${DEV_IMAGE_REPO}}"
      DEV_IMAGE_NAME="${ONLINE_IMAGE_NAME:-${DEV_IMAGE_NAME}}"
      DEV_IMAGE_TAG="${ONLINE_IMAGE_TAG:-${DEV_IMAGE_TAG}}"
      DEV_REGISTRY_USER="${ONLINE_REGISTRY_USER:-${DEV_REGISTRY_USER:-}}"
      DEV_REGISTRY_TOKEN="${ONLINE_REGISTRY_TOKEN:-${DEV_REGISTRY_TOKEN:-}}"
      DEV_REGISTRY_TLS_VERIFY="${ONLINE_REGISTRY_TLS_VERIFY:-${DEV_REGISTRY_TLS_VERIFY:-true}}"
    elif [[ "${DEV_REGISTRY}" != "${ONLINE_REGISTRY}" ]] \
      || [[ -n "${ONLINE_IMAGE_REPO:-}" && "${DEV_IMAGE_REPO}" != "${ONLINE_IMAGE_REPO}" ]]; then
      echo "build-full-bundle: online mode env clash: DEV_* is '${DEV_REGISTRY}/${DEV_IMAGE_REPO}' but ONLINE_* is '${ONLINE_REGISTRY}/${ONLINE_IMAGE_REPO:-}'" >&2
      echo "build-full-bundle: unify first (export DEV_*=ONLINE_* values), or use the release skill which maps online_image_pull → DEV_*." >&2
      exit 2
    fi
  fi
fi

if [[ -z "${DEV_REGISTRY}" ]]; then
  echo "build-full-bundle: DEV_REGISTRY is required (unified tooling registry after mode selection)" >&2
  exit 2
fi
if [[ -z "${DEV_IMAGE_REPO}" ]]; then
  echo "build-full-bundle: DEV_IMAGE_REPO is required (e.g. zoncaesaradmin/development-container or development-container)" >&2
  exit 2
fi
export PRODUCT_VERSION
export DEV_REGISTRY DEV_IMAGE_REPO DEV_IMAGE_NAME DEV_IMAGE_TAG
export DEV_REGISTRY_USER="${DEV_REGISTRY_USER:-}"
export DEV_REGISTRY_TOKEN="${DEV_REGISTRY_TOKEN:-}"
export DEV_REGISTRY_TLS_VERIFY="${DEV_REGISTRY_TLS_VERIFY:-true}"
BUILDER_LOCAL_REF="registry.local/dev-build"
# Tooling pull for build-host product image builds only (not packaged).
BUILDER_PULL_REF=""

if [[ -n "${K3S_VERSION_OVERRIDE}" ]]; then
  K3S_VERSION="${K3S_VERSION_OVERRIDE}"
fi

# Optional per-component cache for incremental rebuilds.
COMPONENT_CACHE_DIR="${COMPONENT_CACHE_DIR:-}"

component_fingerprint() {
  local component_id="$1"
  shift
  local parts=("${component_id}")
  local input digest
  for input in "$@"; do
    if [[ -f "${input}" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum "${input}" | awk '{print $1}')"
      else
        digest="$(shasum -a 256 "${input}" | awk '{print $1}')"
      fi
      parts+=("file:${input}:${digest}")
    elif [[ -d "${input}" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        digest="$(find "${input}" -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
      else
        digest="$(find "${input}" -type f -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}')"
      fi
      parts+=("dir:${input}:${digest}")
    else
      parts+=("str:${input}")
    fi
  done
  local joined
  joined="$(printf '%s\n' "${parts[@]}")"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${joined}" | sha256sum | awk '{print $1}'
  else
    printf '%s' "${joined}" | shasum -a 256 | awk '{print $1}'
  fi
}

component_cache_try_restore() {
  local component_id="$1"
  local dest="$2"
  shift 2
  [[ -n "${COMPONENT_CACHE_DIR:-}" ]] || return 1
  local fp cache_root stamp payload
  fp="$(component_fingerprint "${component_id}" "$@")"
  cache_root="${COMPONENT_CACHE_DIR}/${component_id}/${fp}"
  stamp="${cache_root}/.fingerprint"
  payload="${cache_root}/payload"
  [[ -f "${stamp}" && -d "${payload}" ]] || return 1
  [[ "$(tr -d '[:space:]' <"${stamp}")" == "${fp}" ]] || return 1
  rm -rf "${dest}"
  mkdir -p "${dest}"
  cp -a "${payload}/." "${dest}/"
  echo "component-cache: hit ${component_id} (${fp:0:12}…)" >&2
  return 0
}

component_cache_store() {
  local component_id="$1"
  local source="$2"
  shift 2
  [[ -n "${COMPONENT_CACHE_DIR:-}" ]] || return 0
  if [[ ! -d "${source}" ]]; then
    echo "component-cache: store skipped (not a directory): ${source}" >&2
    return 0
  fi
  local fp cache_root
  fp="$(component_fingerprint "${component_id}" "$@")"
  cache_root="${COMPONENT_CACHE_DIR}/${component_id}/${fp}"
  rm -rf "${cache_root}"
  mkdir -p "${cache_root}/payload"
  cp -a "${source}/." "${cache_root}/payload/"
  printf '%s\n' "${fp}" >"${cache_root}/.fingerprint"
  echo "component-cache: stored ${component_id} (${fp:0:12}…)" >&2
}

REPOS_DIR="${RELEASE_WORK_ROOT}/repos"
ARTIFACTS_DIR="${RELEASE_WORK_ROOT}/artifacts"
WORKSPACE="${RELEASE_WORK_ROOT}/workspace"
INPUTS_DIR="${WORKSPACE}/inputs"
GENERATED_DIR="${WORKSPACE}/generated"
CONFIG_OUT="${GENERATED_DIR}/product-bundle.env"
BUNDLE_DIR="${WORKSPACE}/out/appliance-${PRODUCT_VERSION}-foundation"
DEVELOPER_BUNDLE_DIR="${WORKSPACE}/out/appliance-${PRODUCT_VERSION}-developer"
INFERENCE_BUNDLE_DIR="${WORKSPACE}/out/appliance-${PRODUCT_VERSION}-inference"
BUNDLE_ARCHIVE="${EXPORT_DIR}/appliance-${PRODUCT_VERSION}-foundation.tar.gz"
DEVELOPER_ARCHIVE="${EXPORT_DIR}/appliance-${PRODUCT_VERSION}-developer.tar.gz"
INFERENCE_ARCHIVE="${EXPORT_DIR}/appliance-${PRODUCT_VERSION}-inference.tar.gz"
RELEASE_INDEX="${EXPORT_DIR}/release-index.yaml"
PUBLIC_KEY_EXPORT="${EXPORT_DIR}/release-signing.pub"

CODE_REPO_DIR="${REPOS_DIR}/appliance-code"
CTL_REPO_DIR="${REPOS_DIR}/appliance-ctl"
RELEASE_INPUT_TAR="${ARTIFACTS_DIR}/release-input-${PRODUCT_VERSION}.tar.gz"
CODE_RELEASE_INPUT_TAR="${CODE_REPO_DIR}/.run/release-input-${PRODUCT_VERSION}.tar.gz"
CODE_DEV_SCRIPT_REL=".run/package-release-input-in-dev-container.sh"
CODE_DEV_SCRIPT_PATH="${CODE_REPO_DIR}/${CODE_DEV_SCRIPT_REL}"

bool_true() {
  local value="${1:-}"
  case "$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if bool_true "${BUILD_COMPLETE_PRODUCT}" && appliance_pack_wanted developer && ! bool_true "${WORKFLOWS_ENABLED}"; then
  echo "build-full-bundle: BUILD_COMPLETE_PRODUCT requires WORKFLOWS_ENABLED=true when developer pack is selected (developer slim builds: BUILD_COMPLETE_PRODUCT=false)" >&2
  exit 2
fi
# Always resolve the build-host tooling image from DEV_*. This image builds
# control-plane/UI/etc. on the packaging host and is never exported into the
# signed appliance bundle (operator-supplied builder images at runtime).
BUILDER_PULL_REF="${DEV_REGISTRY}/${DEV_IMAGE_REPO}/${DEV_IMAGE_NAME}:${DEV_IMAGE_TAG}"

shell_quote() {
  printf '%q' "${1:-}"
}

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

require_dir() {
  local path="$1"
  local label="$2"
  if [[ ! -d "${path}" ]]; then
    echo "build-full-bundle: missing ${label}: ${path}" >&2
    exit 1
  fi
}

split_csv() {
  local input="$1"
  local -n out_ref="$2"
  local item

  out_ref=()
  if [[ -z "${input}" ]]; then
    return 0
  fi

  IFS=',' read -r -a out_ref <<<"${input}"
  for idx in "${!out_ref[@]}"; do
    item="${out_ref[idx]}"
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    out_ref[idx]="${item}"
  done
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

# Same layout as scripts/fetch-k3s-inputs.sh: files API under k3s/$K3S_VERSION/.
# Offline only (DEV_* LAN Artifact Server).
fetch_k3s_inputs_from_files_api() {
  local dest_dir="$1"
  local registry=""
  local token=""
  local files_base=""
  local remote_prefix=""
  local -a curl_tls=()
  local bin_dest=""
  local airgap_dest=""

  registry="$(printf '%s' "${DEV_REGISTRY:-}" | tr -d '[:space:]')"
  token="$(printf '%s' "${DEV_REGISTRY_TOKEN:-}" | tr -d '[:space:]')"
  registry="${registry#https://}"
  registry="${registry#http://}"
  registry="${registry%/}"
  if [[ -z "${registry}" ]]; then
    echo "build-full-bundle: DEV_REGISTRY is required to download K3s inputs from the appliance files API" >&2
    exit 2
  fi
  if [[ -z "${token}" ]]; then
    echo "build-full-bundle: DEV_REGISTRY_TOKEN is required to download K3s inputs from the appliance files API" >&2
    exit 2
  fi
  case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) curl_tls=(-k) ;;
  esac

  require_var K3S_VERSION
  files_base="https://${registry}/api/v1/files"
  remote_prefix="${files_base}/k3s/${K3S_VERSION}"
  bin_dest="${dest_dir}/k3s"
  airgap_dest="${dest_dir}/k3s-airgap-images-amd64.tar.zst"
  mkdir -p "${dest_dir}"
  rm -f "${bin_dest}" "${airgap_dest}"

  echo "build-full-bundle: downloading K3s ${K3S_VERSION} from ${remote_prefix}/" >&2
  if ! curl -fsSL "${curl_tls[@]}" \
    -H "Authorization: Bearer ${token}" \
    -o "${bin_dest}" \
    "${remote_prefix}/k3s"; then
    echo "build-full-bundle: failed to download k3s binary from ${remote_prefix}/k3s (seed with make -C deps/platform-inputs release)" >&2
    exit 1
  fi
  chmod +x "${bin_dest}"
  if ! curl -fsSL "${curl_tls[@]}" \
    -H "Authorization: Bearer ${token}" \
    -o "${airgap_dest}" \
    "${remote_prefix}/k3s-airgap-images-amd64.tar.zst"; then
    echo "build-full-bundle: failed to download airgap images from ${remote_prefix}/k3s-airgap-images-amd64.tar.zst (seed with make -C deps/platform-inputs release)" >&2
    exit 1
  fi
  require_file "${bin_dest}" "k3s binary"
  require_file "${airgap_dest}" "k3s airgap images"
}

# Online mode: public GitHub releases (same URLs as deps/platform-inputs).
fetch_k3s_inputs_from_github() {
  local dest_dir="$1"
  local ver_enc=""
  local k3s_base=""
  local bin_dest=""
  local airgap_dest=""

  require_var K3S_VERSION
  ver_enc="${K3S_VERSION//+/%2B}"
  k3s_base="https://github.com/k3s-io/k3s/releases/download/${ver_enc}"
  bin_dest="${dest_dir}/k3s"
  airgap_dest="${dest_dir}/k3s-airgap-images-amd64.tar.zst"
  mkdir -p "${dest_dir}"
  rm -f "${bin_dest}" "${airgap_dest}"

  echo "build-full-bundle: downloading K3s ${K3S_VERSION} from ${k3s_base}/" >&2
  if ! curl -fsSL -o "${bin_dest}" "${k3s_base}/k3s"; then
    echo "build-full-bundle: failed to download k3s binary from ${k3s_base}/k3s" >&2
    exit 1
  fi
  chmod +x "${bin_dest}"
  if ! curl -fsSL -o "${airgap_dest}" "${k3s_base}/k3s-airgap-images-amd64.tar.zst"; then
    echo "build-full-bundle: failed to download airgap images from ${k3s_base}/k3s-airgap-images-amd64.tar.zst" >&2
    exit 1
  fi
  require_file "${bin_dest}" "k3s binary"
  require_file "${airgap_dest}" "k3s airgap images"
}

fetch_k3s_inputs() {
  local dest_dir="$1"
  if offline_build_enabled; then
    fetch_k3s_inputs_from_files_api "${dest_dir}"
  else
    fetch_k3s_inputs_from_github "${dest_dir}"
  fi
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
    && [[ "$(DEV_REGISTRY_USER="${probe_user}" sudo -n env 2>/dev/null | sed -n 's/^DEV_REGISTRY_USER=//p')" == "${probe_user}" ]] \
    && [[ "$(DEV_IMAGE_TAG="${probe_tag}" sudo -n env 2>/dev/null | sed -n 's/^DEV_IMAGE_TAG=//p')" == "${probe_tag}" ]]; then
    return 0
  fi

  cat >&2 <<EOF
build-full-bundle: appliance-code host bootstrap is missing for non-interactive CI
build-full-bundle: this script will not prompt for sudo in CI
build-full-bundle:
build-full-bundle: run this once on the build host (DEV_* already unified for the mode):
build-full-bundle:   export DEV_REGISTRY=<tooling-registry-host>
build-full-bundle:   export DEV_IMAGE_REPO=<tooling-image-repo>
build-full-bundle:   export DEV_IMAGE_NAME=dev-build
build-full-bundle:   export DEV_IMAGE_TAG=latest
build-full-bundle:   export DEV_REGISTRY_USER=<username>
build-full-bundle:   export DEV_REGISTRY_TOKEN=<token>
build-full-bundle:   export DEV_REGISTRY_TLS_VERIFY=true   # false for typical LAN
build-full-bundle:   # offline packaging also needs: export OFFLINE_BUILD=1
build-full-bundle:   bash ${RELEASE_REPO_DIR}/scripts/bootstrap-build-host.sh
build-full-bundle:
build-full-bundle: then rerun:
build-full-bundle:   bash ${RELEASE_REPO_DIR}/scripts/build-full-bundle.sh
EOF
  exit 1
}

export_container_image_archive() {
  local image_ref="$1"
  local output_path="$2"
  local dest_name="${3:-$(basename "${image_ref%%:*}")}"

  # Prefer the same LAN build-cache path as other OCI exports.
  skopeo_copy_oci_archive "docker://${image_ref#docker://}" "${output_path}" "${dest_name}"
}

# Target platform for bundled OCI images. The appliance ships amd64 only.
# skopeo inspect of a multi-arch tag often returns the *index* digest even with
# overrides; skopeo copy materializes a *platform* manifest. Never trust inspect
# Digests as bundle pins. Always copy for the target platform, then derive
# registry.local/<name>@sha256:<archived-manifest-digest> from index.json.
BUNDLE_IMAGE_OS="${BUNDLE_IMAGE_OS:-linux}"
BUNDLE_IMAGE_ARCH="${BUNDLE_IMAGE_ARCH:-amd64}"

# Strip optional @sha256:... from a bundle imageReference, leaving the local name
# (e.g. registry.local/dev-build).
oci_bundle_local_name() {
  local ref="${1#docker://}"
  if [[ "${ref}" == *@sha256:* ]]; then
    printf '%s' "${ref%@sha256:*}"
    return
  fi
  printf '%s' "${ref}"
}

oci_archive_manifest_digest() {
  local archive_path="$1"

  python3 - "${archive_path}" <<'PY'
import json
import sys
import tarfile

archive = sys.argv[1]
with tarfile.open(archive) as tar:
    member = next(
        (entry for entry in tar.getmembers() if entry.isfile() and entry.name.lstrip("./") == "index.json"),
        None,
    )
    if member is None:
        raise SystemExit(f"oci archive {archive} is missing index.json")
    idx = json.load(tar.extractfile(member))
manifests = idx.get("manifests") or []
if not manifests:
    raise SystemExit(f"oci archive {archive} has no manifests in index.json")
digest = str(manifests[0].get("digest") or "").strip()
if not digest.startswith("sha256:") or len(digest) != len("sha256:") + 64:
    raise SystemExit(f"oci archive {archive} has invalid manifest digest {digest!r}")
print(digest)
PY
}

# Rewrite org.opencontainers.image.ref.name to a tag-form local name. Digest-
# pinned names (name@sha256:...) are applied at install with `ctr image tag`
# because ctr import often ignores digest-form annotations and creates
# import-DATE@sha256:... names that kubelet/CRI cannot resolve.
relabel_oci_archive_reference() {
  local archive_path="$1"
  local annotation_ref="$2"

  python3 - "${archive_path}" "${annotation_ref}" <<'PY'
import io
import json
import os
import sys
import tarfile

archive, annotation_ref = sys.argv[1], sys.argv[2]

with tarfile.open(archive) as tar:
    members = tar.getmembers()
    files = {}
    index_member_name = None
    for member in members:
        if member.isfile():
            extracted = tar.extractfile(member)
            if extracted is None:
                raise SystemExit(f"failed to read {member.name} from {archive}")
            files[member.name] = extracted.read()
            if member.name.lstrip("./") == "index.json":
                index_member_name = member.name

if index_member_name is None:
    raise SystemExit(f"oci archive {archive} is missing index.json")

index = json.loads(files[index_member_name])
manifests = index.get("manifests") or []
if not manifests:
    raise SystemExit(f"oci archive {archive} has no manifests in index.json")

annotations = dict(manifests[0].get("annotations") or {})
annotations["org.opencontainers.image.ref.name"] = annotation_ref
manifests[0]["annotations"] = annotations
index["manifests"] = manifests
files[index_member_name] = json.dumps(index, separators=(",", ":"), sort_keys=False).encode("utf-8")

tmp_path = archive + ".relabel.tmp"
with tarfile.open(tmp_path, "w") as out:
    for member in members:
        name = member.name
        if name in files and member.isfile():
            data = files[name]
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            info.mode = member.mode
            info.mtime = member.mtime
            info.uid = member.uid
            info.gid = member.gid
            out.addfile(info, io.BytesIO(data))
        else:
            out.addfile(member)

os.replace(tmp_path, archive)
PY
}

validate_bundled_oci_archive_reference() {
  local archive_path="$1"
  local bundle_ref="$2"

  python3 - "${archive_path}" "${bundle_ref}" <<'PY'
import json
import sys
import tarfile

archive, expected_ref = sys.argv[1], sys.argv[2]
if "@" not in expected_ref:
    raise SystemExit(f"bundle reference {expected_ref!r} is not digest-pinned")
expected_digest = expected_ref.split("@", 1)[1]
with tarfile.open(archive) as tar:
    member = next(
        (entry for entry in tar.getmembers() if entry.isfile() and entry.name.lstrip("./") == "index.json"),
        None,
    )
    if member is None:
        raise SystemExit(f"oci archive {archive} is missing index.json")
    idx = json.load(tar.extractfile(member))
manifests = idx.get("manifests") or []
if not manifests:
    raise SystemExit(f"oci archive {archive} has no manifests in index.json")
chosen = None
for manifest in manifests:
    ann = (manifest.get("annotations") or {}).get("org.opencontainers.image.ref.name")
    if ann == expected_ref:
        chosen = manifest
        break
if chosen is None:
    chosen = manifests[0]
content_digest = str(chosen.get("digest") or "").strip()
if content_digest != expected_digest:
    raise SystemExit(
        f"oci archive {archive} manifest digest {content_digest} does not match "
        f"bundle reference digest {expected_digest} (ref {expected_ref}). "
        "Export must archive the platform manifest whose digest is embedded in the bundle ref."
    )
ann = (chosen.get("annotations") or {}).get("org.opencontainers.image.ref.name") or ""
local_name = expected_ref.split("@", 1)[0]
allowed = {expected_ref, local_name, f"{local_name}:bundled"}
if ann and ann not in allowed and not (
    ann.startswith(local_name + ":") and "@" not in ann
):
    raise SystemExit(
        f"oci archive {archive} annotation ref {ann!r} is incompatible with bundle reference {expected_ref!r} "
        f"(expected one of {sorted(allowed)} or {local_name}:<tag>)"
    )
PY
}

skopeo_tls_args_for() {
  # prints space-separated skopeo flags for a side (src|dest); default verify on
  local side="$1"
  local verify_flag="$2"
  case "$(printf '%s' "${verify_flag}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
      if [[ "${side}" == "src" ]]; then
        printf '%s' "--src-tls-verify=false"
      else
        printf '%s' "--dest-tls-verify=false"
      fi
      ;;
  esac
}

# Map an upstream docker ref to the LAN build-cache repository on DEV_REGISTRY.
# Example: ghcr.io/project-zot/zot-linux-amd64:v2.1.8
#   →  ${DEV_REGISTRY}/build-cache/zot-linux-amd64:v2.1.8
lan_build_cache_ref_for() {
  local source_ref="$1"
  local registry prefix bare name tag digest
  registry="$(printf '%s' "${DEV_REGISTRY:-}" | sed 's#/*$##')"
  prefix="$(printf '%s' "${LAN_BUILD_CACHE_PREFIX}" | sed 's#^/*##; s#/*$##')"
  if [[ -z "${registry}" || -z "${prefix}" ]]; then
    return 1
  fi
  bare="${source_ref#docker://}"
  if [[ "${bare}" == *@sha256:* ]]; then
    name="${bare%@sha256:*}"
    digest="${bare##*@}"
    name="${name##*/}"
    printf '%s/%s/%s@%s' "${registry}" "${prefix}" "${name}" "${digest}"
    return 0
  fi
  if [[ "${bare}" == *:* ]]; then
    name="${bare%:*}"
    tag="${bare##*:}"
    # ignore port ambiguity when tag has no / and host has :port
    if [[ "${tag}" == */* ]]; then
      name="${bare}"
      tag="latest"
    fi
  else
    name="${bare}"
    tag="latest"
  fi
  name="${name##*/}"
  printf '%s/%s/%s:%s' "${registry}" "${prefix}" "${name}" "${tag}"
}

# LAN build-cache is offline-only. Online mode never probes or seeds LAN
# even when DEV_REGISTRY is set for publish.
lan_build_cache_enabled() {
  offline_build_enabled
}

# Parse oci-archive:path[:reference] (first colon after transport separates
# path from optional reference). References often contain further colons
# (registry.local/artifact-server:bundled). Linux archive paths never contain ':'.
oci_archive_path_of() {
  local rest="${1#oci-archive:}"
  printf '%s' "${rest%%:*}"
}

oci_archive_ref_of() {
  local rest="${1#oci-archive:}"
  if [[ "${rest}" == *:* ]]; then
    printf '%s' "${rest#*:}"
  fi
}

# Low-level skopeo/podman-skopeo copy. Returns non-zero on failure (no exit).
# Args: source_ref dest_spec timeout_secs src_tls dest_tls quiet src_user src_token dest_user dest_token
# quiet=true → discard stdout/stderr (LAN probe); quiet=false → keep stderr visible.
skopeo_try_copy() {
  local source_ref="$1"
  local dest_spec="$2" # oci-archive:path:name or docker://...
  local timeout_secs="${3:-0}"
  local src_tls_verify="${4:-true}"
  local dest_tls_verify="${5:-true}"
  local quiet="${6:-true}"
  local src_user="${7:-}"
  local src_token="${8:-}"
  local dest_user="${9:-}"
  local dest_token="${10:-}"
  local skopeo_bin podman_bin auth_file skopeo_image
  local -a overrides=(--override-os "${BUNDLE_IMAGE_OS}" --override-arch "${BUNDLE_IMAGE_ARCH}")
  local -a tls_args=()
  local -a cred_args=()
  local -a copy_cmd=()
  local -a wrapped=()
  local src_flag dest_flag
  local out_path out_ref out_dir out_base src_spec container_dest

  src_flag="$(skopeo_tls_args_for src "${src_tls_verify}")"
  dest_flag="$(skopeo_tls_args_for dest "${dest_tls_verify}")"
  [[ -n "${src_flag}" ]] && tls_args+=("${src_flag}")
  [[ -n "${dest_flag}" ]] && tls_args+=("${dest_flag}")
  if [[ -n "${src_user}" && -n "${src_token}" ]]; then
    cred_args+=(--src-creds "${src_user}:${src_token}")
  fi
  if [[ -n "${dest_user}" && -n "${dest_token}" ]]; then
    cred_args+=(--dest-creds "${dest_user}:${dest_token}")
  fi

  skopeo_bin="$(command -v skopeo || true)"
  if [[ -n "${skopeo_bin}" ]]; then
    if [[ "${source_ref}" == oci-archive:* ]] || [[ "${source_ref}" == docker-archive:* ]]; then
      copy_cmd=(sudo -n "${skopeo_bin}" copy "${overrides[@]}" "${tls_args[@]}" "${cred_args[@]}" "${source_ref}" "${dest_spec}")
    else
      copy_cmd=(sudo -n "${skopeo_bin}" copy "${overrides[@]}" "${tls_args[@]}" "${cred_args[@]}" "docker://${source_ref#docker://}" "${dest_spec}")
    fi
  else
    podman_bin="$(command -v podman || true)"
    if [[ -z "${podman_bin}" ]]; then
      return 127
    fi
    skopeo_image="quay.io/skopeo/stable:latest"
    auth_file="${HOME}/.config/containers/auth.json"
    mkdir -p "$(dirname "${auth_file}")"
    # Dest oci-archive: must stay under mounted /out when using containerized skopeo.
    # --network host so GHCR/public pulls match bare-host skopeo/podman (lab default
    # bridge DNS sometimes cannot resolve ghcr.io).
    copy_cmd=(
      sudo -n "${podman_bin}" run --rm
      --network host
      -v "${auth_file}:/tmp/auth.json:ro,Z"
    )
    if [[ "${dest_spec}" == oci-archive:* ]]; then
      out_path="$(oci_archive_path_of "${dest_spec}")"
      out_ref="$(oci_archive_ref_of "${dest_spec}")"
      out_dir="$(dirname "${out_path}")"
      out_base="$(basename "${out_path}")"
      if [[ "${source_ref}" == oci-archive:* ]] || [[ "${source_ref}" == docker-archive:* ]]; then
        src_spec="${source_ref}"
      else
        src_spec="docker://${source_ref#docker://}"
      fi
      if [[ -n "${out_ref}" ]]; then
        container_dest="oci-archive:/out/${out_base}:${out_ref}"
      else
        container_dest="oci-archive:/out/${out_base}"
      fi
      copy_cmd+=(
        -v "${out_dir}:/out:Z"
        "${skopeo_image}"
        copy --authfile /tmp/auth.json
        "${overrides[@]}"
        "${tls_args[@]}"
        "${cred_args[@]}"
        "${src_spec}"
        "${container_dest}"
      )
    else
      if [[ "${source_ref}" == oci-archive:* ]] || [[ "${source_ref}" == docker-archive:* ]]; then
        src_spec="${source_ref}"
      else
        src_spec="docker://${source_ref#docker://}"
      fi
      copy_cmd+=(
        "${skopeo_image}"
        copy --authfile /tmp/auth.json
        "${overrides[@]}"
        "${tls_args[@]}"
        "${cred_args[@]}"
        "${src_spec}"
        "${dest_spec}"
      )
    fi
  fi

  if [[ "${timeout_secs}" =~ ^[1-9][0-9]*$ ]]; then
    if command -v timeout >/dev/null 2>&1; then
      wrapped=(timeout --signal=TERM "${timeout_secs}" "${copy_cmd[@]}")
    else
      wrapped=("${copy_cmd[@]}")
    fi
  else
    wrapped=("${copy_cmd[@]}")
  fi

  case "$(printf '%s' "${quiet}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
      # Progress must go to stderr. call sites assign $(export_bundled...) and
      # stdout pollution corrupts registry.local/<name>@sha256:<digest> refs.
      if "${wrapped[@]}" 1>&2; then
        return 0
      fi
      return 1
      ;;
    *)
      if "${wrapped[@]}" >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
  esac
}

# Host-network podman pull/save — same path used successfully for workflows OCI.
# Used as upstream fallback when skopeo copy fails so LAN mirror work does not
# regress plain internet pulls.
podman_export_oci_archive() {
  local source_ref="$1"
  local output_path="$2"
  local podman_bin
  local bare="${source_ref#docker://}"

  podman_bin="$(command -v podman || true)"
  [[ -n "${podman_bin}" ]] || return 127
  mkdir -p "$(dirname "${output_path}")"
  rm -f "${output_path}"
  # stdout → stderr: same as skopeo_try_copy; outer $(...) must only see digest pins
  if ! sudo -n "${podman_bin}" pull "${bare}" 1>&2; then
    return 1
  fi
  if ! sudo -n "${podman_bin}" save --format oci-archive -o "${output_path}" "${bare}" 1>&2; then
    rm -f "${output_path}"
    return 1
  fi
  [[ -f "${output_path}" && -s "${output_path}" ]]
}

ensure_lan_build_cache_login() {
  local registry user token tls_verify podman_bin skopeo_bin
  local -a login_tls=()
  if ! lan_build_cache_enabled; then
    return 0
  fi
  registry="$(printf '%s' "${DEV_REGISTRY:-}" | sed 's#/*$##')"
  user="${DEV_REGISTRY_USER:-}"
  token="${DEV_REGISTRY_TOKEN:-}"
  tls_verify="${DEV_REGISTRY_TLS_VERIFY:-true}"
  echo "build-full-bundle: LAN build-cache enabled registry=${registry} prefix=${LAN_BUILD_CACHE_PREFIX} timeout=${LAN_BUILD_CACHE_TIMEOUT_SECONDS}s" >&2
  if [[ -z "${user}" || -z "${token}" ]]; then
    echo "build-full-bundle: warning: LAN build-cache has no DEV_REGISTRY_USER/TOKEN; relying on existing registry auth" >&2
    return 0
  fi
  case "$(printf '%s' "${tls_verify}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) login_tls=(--tls-verify=false) ;;
  esac
  podman_bin="$(command -v podman || true)"
  if [[ -n "${podman_bin}" ]]; then
    if printf '%s\n' "${token}" | "${podman_bin}" login "${login_tls[@]}" --username "${user}" --password-stdin "${registry}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  skopeo_bin="$(command -v skopeo || true)"
  if [[ -n "${skopeo_bin}" ]]; then
    if printf '%s\n' "${token}" | "${skopeo_bin}" login "${login_tls[@]}" --username "${user}" --password-stdin "${registry}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  echo "build-full-bundle: warning: could not login to LAN build-cache ${registry}; pulls may rely on --src-creds" >&2
}

skopeo_copy_oci_archive() {
  # Offline mode: try LAN build-cache on DEV_REGISTRY first; miss fails closed
  # (no public upstream). Online mode: pull source_ref from public upstream only
  # (never probes LAN even if DEV_REGISTRY is set for publish).
  local source_ref="$1"
  local output_path="$2"
  local dest_name="$3"
  local mirror_ref=""
  local mirror_timeout="${LAN_BUILD_CACHE_TIMEOUT_SECONDS}"
  # Public/upstream registries always verify TLS. LAN pulls use DEV_REGISTRY_TLS_VERIFY.
  local upstream_tls="true"
  local mirror_tls="${DEV_REGISTRY_TLS_VERIFY:-true}"
  local mirror_user="${DEV_REGISTRY_USER:-}"
  local mirror_token="${DEV_REGISTRY_TOKEN:-}"
  local dest_spec
  local fetched_from_upstream=0
  local bare_source mirror_host
  local tmp_labeled

  bare_source="${source_ref#docker://}"
  mirror_host="$(printf '%s' "${DEV_REGISTRY:-}" | sed 's#/*$##; s#^https\?://##')"
  if [[ -n "${mirror_host}" && ( "${bare_source}" == "${mirror_host}"/* || "${bare_source}" == "${mirror_host}:"* ) ]]; then
    upstream_tls="${DEV_REGISTRY_TLS_VERIFY:-true}"
  fi

  mkdir -p "$(dirname "${output_path}")"
  rm -f "${output_path}"
  dest_spec="oci-archive:${output_path}:${dest_name}"

  if lan_build_cache_enabled; then
    mirror_ref="$(lan_build_cache_ref_for "${source_ref}" || true)"
    if [[ -z "${mirror_ref}" ]]; then
      echo "build-full-bundle: LAN build-cache could not map ${source_ref}; fetching upstream" >&2
    else
      echo "build-full-bundle: LAN build-cache try ${mirror_ref} (timeout ${mirror_timeout}s) for ${dest_name}" >&2
      # quiet probe: miss/timeout is normal when the cache is cold
      if skopeo_try_copy "${mirror_ref}" "${dest_spec}" "${mirror_timeout}" "${mirror_tls}" "true" \
        "true" "${mirror_user}" "${mirror_token}" "" ""; then
        if [[ -f "${output_path}" && -s "${output_path}" ]]; then
          echo "build-full-bundle: LAN build-cache hit for ${dest_name} (${mirror_ref})" >&2
          return 0
        fi
        echo "build-full-bundle: LAN build-cache returned empty archive for ${mirror_ref}; treating as miss" >&2
        rm -f "${output_path}"
      else
        echo "build-full-bundle: LAN build-cache miss/timeout/unreachable for ${mirror_ref}" >&2
        rm -f "${output_path}"
      fi
      if offline_build_enabled; then
        cat >&2 <<EOF
build-full-bundle: OFFLINE_BUILD=1 and LAN build-cache miss for ${dest_name}
build-full-bundle: seed with make -C deps/<pkg> release then retry
build-full-bundle: expected mirror: ${mirror_ref}
EOF
        exit 1
      fi
      echo "build-full-bundle: falling back to upstream (internet/pull-ref) ${source_ref}" >&2
    fi
  fi

  if offline_build_enabled; then
    cat >&2 <<EOF
build-full-bundle: OFFLINE_BUILD=1 refuses upstream pull for ${dest_name}
build-full-bundle: source_ref=${source_ref}
build-full-bundle: seed LAN build-cache via make seed-build-deps and ensure DEV_REGISTRY is set
EOF
    exit 1
  fi

  # Upstream: show skopeo errors (do not swallow 2>&1). Optional podman
  # fallback matches export_container_image_archive (workflows path) — host network.
  if ! skopeo_try_copy "${source_ref}" "${dest_spec}" "0" "${upstream_tls}" "true" "false"; then
    echo "build-full-bundle: skopeo upstream copy failed for ${source_ref}; trying sudo podman pull/save fallback" >&2
    if ! podman_export_oci_archive "${source_ref}" "${output_path}"; then
      cat >&2 <<EOF
build-full-bundle: failed to export ${dest_name} from upstream ${source_ref}
build-full-bundle: skopeo and podman pull both failed (see logs above)
build-full-bundle: ensure the build host can reach the registry (LAN build-cache is automatic from DEV_REGISTRY)
EOF
      if ! command -v skopeo >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
        echo "build-full-bundle: skopeo or podman is required to export ${dest_name}" >&2
      fi
      exit 1
    fi
    # Relabel platform archive for finalize (name annotation may be missing from podman save).
    if command -v skopeo >/dev/null 2>&1; then
      tmp_labeled="${output_path}.labeled"
      rm -f "${tmp_labeled}"
      if sudo -n "$(command -v skopeo)" copy \
        --override-os "${BUNDLE_IMAGE_OS}" --override-arch "${BUNDLE_IMAGE_ARCH}" \
        "oci-archive:${output_path}" "oci-archive:${tmp_labeled}:${dest_name}" >/dev/null 2>&1; then
        mv -f "${tmp_labeled}" "${output_path}"
      else
        rm -f "${tmp_labeled}"
      fi
    fi
  fi
  if [[ ! -f "${output_path}" || ! -s "${output_path}" ]]; then
    echo "build-full-bundle: upstream export for ${dest_name} produced empty archive at ${output_path}" >&2
    exit 1
  fi
  fetched_from_upstream=1
  echo "build-full-bundle: fetched ${dest_name} from upstream ${source_ref}" >&2

  # Seed LAN Artifact Server only after a successful upstream fetch (not on mirror hit).
  if [[ "${fetched_from_upstream}" -eq 1 ]] && lan_build_cache_enabled && [[ -n "${mirror_ref}" ]]; then
    echo "build-full-bundle: seeding LAN build-cache ${mirror_ref} with ${dest_name}" >&2
    if skopeo_push_oci_archive_to_lan_cache "${output_path}" "${dest_name}" "${mirror_ref}" "${mirror_tls}"; then
      echo "build-full-bundle: seeded LAN build-cache ${mirror_ref}" >&2
    else
      echo "build-full-bundle: warning: failed to seed LAN build-cache ${mirror_ref} (build continues; next build may re-fetch upstream)" >&2
    fi
  fi
}

skopeo_push_oci_archive_to_lan_cache() {
  local archive_path="$1"
  local dest_name="$2"
  local mirror_ref="$3"
  local mirror_tls="$4"
  local mirror_user="${DEV_REGISTRY_USER:-}"
  local mirror_token="${DEV_REGISTRY_TOKEN:-}"
  local skopeo_bin podman_bin auth_file skopeo_image
  local -a overrides=(--override-os "${BUNDLE_IMAGE_OS}" --override-arch "${BUNDLE_IMAGE_ARCH}")
  local -a dest_tls=()
  local -a cred_args=()
  local dest_flag

  dest_flag="$(skopeo_tls_args_for dest "${mirror_tls}")"
  [[ -n "${dest_flag}" ]] && dest_tls+=("${dest_flag}")
  if [[ -n "${mirror_user}" && -n "${mirror_token}" ]]; then
    cred_args+=(--dest-creds "${mirror_user}:${mirror_token}")
  fi

  skopeo_bin="$(command -v skopeo || true)"
  if [[ -n "${skopeo_bin}" ]]; then
    sudo -n "${skopeo_bin}" copy "${overrides[@]}" "${dest_tls[@]}" "${cred_args[@]}" \
      "oci-archive:${archive_path}:${dest_name}" "docker://${mirror_ref#docker://}" >/dev/null 2>&1
    return $?
  fi
  podman_bin="$(command -v podman || true)"
  [[ -n "${podman_bin}" ]] || return 1
  skopeo_image="quay.io/skopeo/stable:latest"
  auth_file="${HOME}/.config/containers/auth.json"
  mkdir -p "$(dirname "${auth_file}")"
  sudo -n "${podman_bin}" run --rm \
    -v "${auth_file}:/tmp/auth.json:ro,Z" \
    -v "$(dirname "${archive_path}"):/out:Z" \
    "${skopeo_image}" \
    copy --authfile /tmp/auth.json \
    "${overrides[@]}" \
    "${dest_tls[@]}" \
    "${cred_args[@]}" \
    "oci-archive:/out/$(basename "${archive_path}"):${dest_name}" \
    "docker://${mirror_ref#docker://}" >/dev/null 2>&1
}

# Finalize any OCI archive so imageReference equals the archived platform
# manifest digest and the annotation is the :bundled local name.
# Prints the canonical registry.local/<name>@sha256:… bundle ref.
finalize_bundled_oci_archive() {
  local archive_path="$1"
  local local_name="$2"
  local optional_expected_ref="${3:-}"
  local content_digest bundle_ref expected_digest

  local_name="$(oci_bundle_local_name "${local_name}")"
  if [[ -z "${local_name}" || "${local_name}" == *@* ]]; then
    echo "build-full-bundle: invalid local OCI name '${local_name}'" >&2
    exit 2
  fi
  if [[ ! -f "${archive_path}" ]]; then
    echo "build-full-bundle: missing OCI archive ${archive_path}" >&2
    exit 1
  fi

  content_digest="$(oci_archive_manifest_digest "${archive_path}")"
  bundle_ref="${local_name}@${content_digest}"
  annotation_ref="${local_name}:bundled"

  if [[ -n "${optional_expected_ref}" && "${optional_expected_ref}" == *@sha256:* ]]; then
    expected_digest="${optional_expected_ref##*@}"
    if [[ "${expected_digest}" != "${content_digest}" ]]; then
      cat >&2 <<EOF
build-full-bundle: configured pin ${optional_expected_ref} does not match archived platform manifest ${content_digest}
build-full-bundle: using content-derived reference ${bundle_ref} (update your config pin to this digest to silence this warning)
EOF
    fi
  fi

  # Annotate with a tag-form name for reliable ctr import. Install-time zonctl
  # then runs `ctr image tag` to create the digest-pinned bundle_ref workloads use.
  relabel_oci_archive_reference "${archive_path}" "${annotation_ref}"
  validate_bundled_oci_archive_reference "${archive_path}" "${bundle_ref}"
  printf '%s' "${bundle_ref}"
}

# Online export for a registry.local/* load name; returns digest-pinned ref.
export_bundled_oci_archive() {
  local pull_ref="$1"
  local local_or_expected_ref="$2"
  local output_path="$3"
  local local_name

  local_name="$(oci_bundle_local_name "${local_or_expected_ref}")"
  if [[ "${local_name}" != registry.local/* ]]; then
    echo "build-full-bundle: bundle local name must be under registry.local/ (got ${local_name})" >&2
    exit 2
  fi

  skopeo_copy_oci_archive "${pull_ref}" "${output_path}" "${local_name}:bundled"
  finalize_bundled_oci_archive "${output_path}" "${local_name}" "${local_or_expected_ref}"
}

# derive_workflows_version_from_code_repo reads the pinned workflows engine
# version out of appliance-code's own
# deploy/charts/appliance-workflows/Chart.yaml (its appVersion field), the
# single source of truth for which upstream Argo Workflows release this
# chart is built against. This is what lets an operator build a complete
# appliance without ever having to know or set a workflows version
# themselves: it's the same version the chart itself is pinned to,
# already reviewed and committed in that repo.
derive_workflows_version_from_code_repo() {
  local chart_yaml="${CODE_REPO_DIR}/deploy/charts/appliance-workflows/Chart.yaml"
  local version

  if [[ ! -f "${chart_yaml}" ]]; then
    echo "build-full-bundle: WORKFLOWS_ENABLED is true but ${chart_yaml} was not found; cannot derive the workflows version" >&2
    exit 1
  fi
  version="$(sed -n 's/^appVersion: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${chart_yaml}")"
  if [[ -z "${version}" ]]; then
    echo "build-full-bundle: could not parse appVersion from ${chart_yaml}" >&2
    exit 1
  fi
  printf '%s' "${version}"
}

fetch_workflows_crds_from_release() {
  local workflows_version="$1"
  local output_dir="$2"
  local tmp_manifest
  local files_ok=0

  tmp_manifest="$(mktemp)"
  trap 'rm -f "${tmp_manifest}"' RETURN

  if files_api_download "argo-workflows/${workflows_version}/namespace-install.yaml" "${tmp_manifest}"; then
    echo "build-full-bundle: fetched Argo CRDs from files API argo-workflows/${workflows_version}/" >&2
    files_ok=1
  elif offline_build_enabled; then
    echo "build-full-bundle: OFFLINE_BUILD=1 and files API miss for argo-workflows/${workflows_version}/namespace-install.yaml" >&2
    echo "build-full-bundle: seed deps/workflows (make -C deps/workflows release)" >&2
    exit 1
  else
    local manifest_url="https://github.com/argoproj/argo-workflows/releases/download/${workflows_version}/namespace-install.yaml"
    curl -fsSL "${manifest_url}" -o "${tmp_manifest}"
  fi
  # silence unused when files path taken
  : "${files_ok}"

  rm -rf "${output_dir}"
  mkdir -p "${output_dir}"
  python3 - "${tmp_manifest}" "${output_dir}" <<'PY'
from pathlib import Path
import re
import sys

manifest_path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
text = manifest_path.read_text(encoding="utf-8")
docs = re.split(r"^---\s*$", text, flags=re.MULTILINE)
written = 0

for raw_doc in docs:
    doc = raw_doc.strip()
    if not doc:
        continue
    if not re.search(r"^kind:\s*CustomResourceDefinition\s*$", doc, flags=re.MULTILINE):
        continue
    match = re.search(r"^\s*name:\s*([A-Za-z0-9._-]+)\s*$", doc, flags=re.MULTILINE)
    if not match:
        raise SystemExit("build-full-bundle: could not determine workflow CRD filename from downloaded manifest")
    out_path = output_dir / f"{match.group(1)}.yaml"
    out_path.write_text(doc + "\n", encoding="utf-8")
    written += 1

if written == 0:
    raise SystemExit("build-full-bundle: downloaded workflow manifest did not contain any CRDs")
PY
  rm -f "${tmp_manifest}"
  trap - RETURN
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
    if offline_build_enabled || [[ "${USE_LOCAL_CHECKOUTS:-0}" == "1" ]]; then
      # Offline / explicit: use the synced working tree as-is (no remote fetch).
      printf '%s\n' "${source}"
      return 0
    fi
    if [[ -d "${source}/.git" ]]; then
      if git -C "${source}" remote get-url origin >/dev/null 2>&1; then
        git -C "${source}" remote get-url origin
        return 0
      fi
      echo "build-full-bundle: local repo source ${source} has no origin remote configured" >&2
      exit 1
    fi
    echo "build-full-bundle: local source ${source} is not a git checkout with an origin remote" >&2
    exit 1
  else
    printf '%s\n' "${source}"
  fi
}

warn_if_local_repo_source() {
  local source="$1"
  local label="$2"

  if [[ -d "${source}" ]]; then
    if offline_build_enabled || [[ "${USE_LOCAL_CHECKOUTS:-0}" == "1" ]]; then
      cat >&2 <<EOF
build-full-bundle: ${label} source is a local directory (OFFLINE_BUILD/USE_LOCAL_CHECKOUTS):
build-full-bundle:   ${source}
build-full-bundle: using the local working tree contents as the bundle input source
EOF
      return 0
    fi
    cat >&2 <<EOF
build-full-bundle: ${label} source is a local directory:
build-full-bundle:   ${source}
build-full-bundle: this run will resolve that checkout's origin remote and clone/fetch from the remote URL
build-full-bundle: the local working tree contents themselves will not be used as the bundle input source
EOF
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

  # Offline / local checkouts: copy or reuse the synced tree without fetching.
  if [[ -d "${clone_source}" ]] && { offline_build_enabled || [[ "${USE_LOCAL_CHECKOUTS:-0}" == "1" ]]; }; then
    if [[ "${clone_source}" == "${dest}" ]]; then
      echo "build-full-bundle: using local checkout in place at ${dest}" >&2
      return 0
    fi
    rm -rf "${dest}"
    if command -v rsync >/dev/null 2>&1; then
      mkdir -p "${dest}"
      rsync -a --delete "${clone_source}/" "${dest}/"
    else
      cp -a "${clone_source}" "${dest}"
    fi
    echo "build-full-bundle: copied local checkout ${clone_source} -> ${dest}" >&2
    return 0
  fi

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

require_var CODE_REPO_SOURCE
require_var CTL_REPO_SOURCE
require_var K3S_VERSION

warn_if_local_repo_source "${CODE_REPO_SOURCE}" "CODE_REPO"
warn_if_local_repo_source "${CTL_REPO_SOURCE}" "CTL_REPO"

# K3s inputs: downloaded into workspace after dirs exist (mkdir below).
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  require_file "${VALUES_FILE_SOURCE}" "values file"
fi
if [[ -z "${ARTIFACT_SERVER_VERSION}" || "${ARTIFACT_SERVER_VERSION}" == *latest* ]]; then
  echo "build-full-bundle: ARTIFACT_SERVER_VERSION must be an exact non-latest version" >&2
  exit 2
fi
if [[ "${ARTIFACT_SERVER_SOURCE_IMAGE}" == *:latest || "${ARTIFACT_SERVER_SOURCE_IMAGE}" == registry.local/* ]]; then
  echo "build-full-bundle: ARTIFACT_SERVER_SOURCE_IMAGE must be a version-pinned upstream image ref" >&2
  exit 2
fi
if [[ -z "${DNS_VERSION}" || "${DNS_VERSION}" == *latest* ]]; then
  echo "build-full-bundle: DNS_VERSION must be an exact non-latest version" >&2
  exit 2
fi
if [[ "${DNS_IMAGE_PULL_REF}" == *:latest || "${DNS_IMAGE_PULL_REF}" == registry.local/* ]]; then
  echo "build-full-bundle: DNS_IMAGE_PULL_REF must be a version-pinned upstream image ref" >&2
  exit 2
fi
if appliance_pack_wanted inference; then
  if [[ -z "${INFERENCE_VERSION}" || "${INFERENCE_VERSION}" == *latest* ]]; then
    echo "build-full-bundle: INFERENCE_VERSION must be an exact non-latest version" >&2
    exit 2
  fi
  if [[ "${INFERENCE_IMAGE_PULL_REF}" == *:latest || "${INFERENCE_IMAGE_PULL_REF}" == registry.local/* ]]; then
    echo "build-full-bundle: INFERENCE_IMAGE_PULL_REF must be a version-pinned upstream image ref" >&2
    exit 2
  fi
fi
if appliance_pack_wanted developer; then
  if [[ "${WORKSPACE_PROVISIONER_IMAGE_REF}" == registry.local/workspace-provisioner || "${WORKSPACE_PROVISIONER_IMAGE_REF}" == registry.local/workspace-provisioner@sha256:* ]]; then
    echo "build-full-bundle: WORKSPACE_PROVISIONER_IMAGE_REF must be an upstream or LAN build-cache pull ref (default docker.io/alpine/git:2.49.0); got ${WORKSPACE_PROVISIONER_IMAGE_REF}" >&2
    exit 2
  fi
fi

rm -rf "${ARTIFACTS_DIR}" "${WORKSPACE}"
if is_within_dir "${EXPORT_DIR}" "${RELEASE_WORK_ROOT}"; then
  rm -rf "${EXPORT_DIR}"
else
  mkdir -p "${EXPORT_DIR}"
  find "${EXPORT_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
mkdir -p "${REPOS_DIR}" "${ARTIFACTS_DIR}" "${INPUTS_DIR}" "${GENERATED_DIR}" "${EXPORT_DIR}"

clone_repo "${CODE_REPO_SOURCE}" "${code_git_ref}" "${CODE_REPO_DIR}"
clone_repo "${CTL_REPO_SOURCE}" "${ctl_git_ref}" "${CTL_REPO_DIR}"

ARTIFACT_SERVER_CHART_APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${CODE_REPO_DIR}/deploy/charts/appliance-registry/Chart.yaml")"
# Chart.yaml may use Helm/upstream form v2.1.8 while ARTIFACT_SERVER_VERSION is 2.1.8.
if [[ -z "${ARTIFACT_SERVER_CHART_APP_VERSION}" || "${ARTIFACT_SERVER_CHART_APP_VERSION#v}" != "${ARTIFACT_SERVER_VERSION}" ]]; then
  echo "build-full-bundle: ARTIFACT_SERVER_VERSION ${ARTIFACT_SERVER_VERSION} must match appliance-registry chart appVersion ${ARTIFACT_SERVER_CHART_APP_VERSION:-<missing>}" >&2
  exit 2
fi

DNS_CHART_APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${CODE_REPO_DIR}/deploy/charts/appliance-dns/Chart.yaml")"
# Chart.yaml may use Helm/upstream form v1.14.4 while DNS_VERSION is 1.14.4.
if [[ -z "${DNS_CHART_APP_VERSION}" || "${DNS_CHART_APP_VERSION#v}" != "${DNS_VERSION}" ]]; then
  echo "build-full-bundle: DNS_VERSION ${DNS_VERSION} must match appliance-dns chart appVersion ${DNS_CHART_APP_VERSION:-<missing>}" >&2
  exit 2
fi

INFERENCE_CHART_APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${CODE_REPO_DIR}/deploy/charts/appliance-inference/Chart.yaml")"
# Chart.yaml may use Helm/upstream form v0.6.5 while INFERENCE_VERSION is 0.6.5.
if appliance_pack_wanted inference; then
  if [[ -z "${INFERENCE_CHART_APP_VERSION}" || "${INFERENCE_CHART_APP_VERSION#v}" != "${INFERENCE_VERSION}" ]]; then
    echo "build-full-bundle: INFERENCE_VERSION ${INFERENCE_VERSION} must match appliance-inference chart appVersion ${INFERENCE_CHART_APP_VERSION:-<missing>}" >&2
    exit 2
  fi
fi

require_appliance_code_bootstrap

if bool_true "${WORKFLOWS_ENABLED}"; then
  if [[ -z "${WORKFLOWS_VERSION}" ]]; then
    WORKFLOWS_VERSION="$(derive_workflows_version_from_code_repo)"
  fi
  if [[ -z "${WORKFLOW_CONTROLLER_IMAGE_REF}" ]]; then
    WORKFLOW_CONTROLLER_IMAGE_REF="localhost/appliance-workflow-controller:${WORKFLOWS_VERSION}"
  fi
  if [[ -z "${WORKFLOW_EXECUTOR_IMAGE_REF}" ]]; then
    WORKFLOW_EXECUTOR_IMAGE_REF="quay.io/argoproj/argoexec:${WORKFLOWS_VERSION}"
  fi
fi

# When offline (or when DEV_REGISTRY is available and refs still point at
# public upstreams), prefer LAN build-cache (deps/*) names.
if offline_build_enabled; then
  require_var DEV_REGISTRY
  require_seed_package message-broker
  if appliance_pack_wanted developer; then
    WORKSPACE_PROVISIONER_IMAGE_REF="$(lan_cache_ref alpine-git "${ALPINE_GIT_CACHE_TAG}")"
  fi
  ARTIFACT_SERVER_SOURCE_IMAGE="$(lan_cache_ref zot-linux-amd64 "v${ARTIFACT_SERVER_VERSION}")"
  MESSAGE_BROKER_SOURCE_IMAGE="$(lan_cache_ref nats "2.10.26-alpine")"
  DNS_IMAGE_PULL_REF="$(lan_cache_ref coredns "v${DNS_VERSION}")"
  if appliance_pack_wanted inference; then
    INFERENCE_IMAGE_PULL_REF="$(lan_cache_ref ollama "${INFERENCE_VERSION}")"
  fi
  if bool_true "${WORKFLOWS_ENABLED}"; then
    WORKFLOW_EXECUTOR_IMAGE_REF="$(lan_cache_ref argoexec "${WORKFLOWS_VERSION}")"
    WORKFLOW_CONTROLLER_BASE_IMAGE="$(lan_cache_ref workflow-controller "${WORKFLOWS_VERSION}")"
  fi
  CP_GO_IMAGE="$(lan_cache_ref golang 1.26)"
  CP_RUNTIME_IMAGE="$(lan_cache_ref alpine-3.24.1-runtime 3.24.1)"
  UI_NODE_IMAGE="$(lan_cache_ref node 22-alpine)"
  UI_GO_IMAGE="$(lan_cache_ref golang 1.26)"
  UI_RUNTIME_IMAGE="$(lan_cache_ref alpine-3.24.1-runtime 3.24.1)"
  UI_WEB_DEPS_IMAGE="$(lan_cache_ref controlplane-ui-web-deps lockfile)"
  ARTIFACT_RUNTIME_SOURCE_IMAGE="$(lan_cache_ref debian-bookworm-slim-runtime bookworm-slim)"
  RUNTIME_PACKAGES_INSTALLED=1
  echo "build-full-bundle: OFFLINE_BUILD=1 using LAN build-cache refs on ${DEV_REGISTRY}" >&2
else
  WORKFLOW_CONTROLLER_BASE_IMAGE="${WORKFLOW_CONTROLLER_BASE_IMAGE:-quay.io/argoproj/workflow-controller:${WORKFLOWS_VERSION:-v3.5.10}}"
  CP_GO_IMAGE="${CP_GO_IMAGE:-}"
  CP_RUNTIME_IMAGE="${CP_RUNTIME_IMAGE:-}"
  UI_NODE_IMAGE="${UI_NODE_IMAGE:-}"
  UI_GO_IMAGE="${UI_GO_IMAGE:-}"
  UI_RUNTIME_IMAGE="${UI_RUNTIME_IMAGE:-}"
  UI_WEB_DEPS_IMAGE="${UI_WEB_DEPS_IMAGE:-}"
  ARTIFACT_RUNTIME_SOURCE_IMAGE="${RUNTIME_SOURCE_IMAGE:-debian:bookworm-slim}"
  RUNTIME_PACKAGES_INSTALLED="${RUNTIME_PACKAGES_INSTALLED:-0}"
fi

mkdir -p "${CODE_REPO_DIR}/.run"

WORKFLOWS_CRDS_DIR_FOR_DEV=""
WORKFLOW_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV=""
WORKFLOW_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV=""
rm -rf "${CODE_REPO_DIR}/.run/host-packages"
# Complete product super-set always packages both host capability closures by
# export on the build host (no external host-packages tree override).
HOST_PACKAGES_DIR_FOR_DEV="/workspace/.run/host-packages"
HOST_CAPABILITIES=(mdns wifi-ap)
mkdir -p "${CODE_REPO_DIR}/.run/host-packages"
host_packages_fingerprint_inputs=("${OS_VERSION}" "mdns" "wifi-ap" "${HOST_PACKAGES_FINGERPRINT}")
if ! component_cache_try_restore "host-packages" "${CODE_REPO_DIR}/.run/host-packages" "${host_packages_fingerprint_inputs[@]}"; then
  host_pkg_archive="${CODE_REPO_DIR}/.run/host-packages-seed.tar.zst"
  host_pkg_remote="host-packages/ubuntu-${OS_VERSION}/${HOST_PACKAGES_FINGERPRINT}/host-packages.tar.zst"
  if files_api_download "${host_pkg_remote}" "${host_pkg_archive}"; then
    echo "build-full-bundle: unpacking host-packages from files API ${host_pkg_remote}" >&2
    if tar --help 2>&1 | grep -q zstd; then
      tar --zstd -xf "${host_pkg_archive}" -C "${CODE_REPO_DIR}/.run/host-packages"
    else
      zstd -dc "${host_pkg_archive}" | tar -xf - -C "${CODE_REPO_DIR}/.run/host-packages"
    fi
    rm -f "${host_pkg_archive}"
  elif offline_build_enabled; then
    echo "build-full-bundle: OFFLINE_BUILD=1 and files API miss for ${host_pkg_remote}" >&2
    echo "build-full-bundle: seed deps/host-packages (make -C deps/host-packages release)" >&2
    exit 1
  else
    CAP_ARGS=()
    for cap in "${HOST_CAPABILITIES[@]}"; do
      CAP_ARGS+=(--capability "${cap}")
    done
    bash "${CODE_REPO_DIR}/scripts/package/export-host-packages.sh" \
      --out-dir "${CODE_REPO_DIR}/.run/host-packages" \
      --os-version "${OS_VERSION}" \
      "${CAP_ARGS[@]}"
  fi
  component_cache_store "host-packages" "${CODE_REPO_DIR}/.run/host-packages" "${host_packages_fingerprint_inputs[@]}"
fi

if bool_true "${WORKFLOWS_ENABLED}"; then
  # Always fetch CRDs and pull/package images (no local archive path inputs).
  if bool_true "${WORKFLOWS_REQUIRED:-true}"; then
    WORKFLOWS_CRDS_DIR_FOR_DEV="/workspace/.run/workflows-crds"
    fetch_workflows_crds_from_release "${WORKFLOWS_VERSION}" "${CODE_REPO_DIR}/.run/workflows-crds"
  fi
  # Controller image is wrapped inside the code-repo dev-run (buildah).
  WORKFLOW_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV=""
  WORKFLOW_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/workflow-executor-image.tar"
  export_container_image_archive "${WORKFLOW_EXECUTOR_IMAGE_REF}" "${CODE_REPO_DIR}/.run/workflow-executor-image.tar"
fi

# Bundled supplemental images for release-input (--extra-oci-image flags):
# workspace-provisioner when the developer pack is selected.
BUNDLED_IMAGE_ARCHIVES=()
BUNDLED_IMAGE_REFS=()

ensure_lan_build_cache_login

ARTIFACT_SERVER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/artifact-server-image.tar"
ARTIFACT_SERVER_IMAGE_REF=""

DNS_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/dns-server-image.tar"
DNS_IMAGE_REF=""

INFERENCE_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/inference-runtime-image.tar"
INFERENCE_IMAGE_REF=""

if appliance_pack_wanted developer; then
  WORKSPACE_PROVISIONER_PULL_REF="${WORKSPACE_PROVISIONER_IMAGE_REF:-docker.io/alpine/git:2.49.0}"
  WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/workspace-provisioner-image.tar"
  WORKSPACE_PROVISIONER_IMAGE_REF="$(export_bundled_oci_archive "${WORKSPACE_PROVISIONER_PULL_REF}" "registry.local/workspace-provisioner" "${CODE_REPO_DIR}/.run/workspace-provisioner-image.tar")"
  BUNDLED_IMAGE_ARCHIVES+=("${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_FOR_DEV}")
  BUNDLED_IMAGE_REFS+=("${WORKSPACE_PROVISIONER_IMAGE_REF}")
fi

# Note: registry.local/dev-build is intentionally NOT packaged. The DEV_* image
# remains build-host tooling only; runtime builder images are operator-supplied.

BUNDLED_IMAGE_ARG_LINES=""
for idx in "${!BUNDLED_IMAGE_ARCHIVES[@]}"; do
  BUNDLED_IMAGE_ARG_LINES+="  BUNDLED_IMAGE_ARGS+=(--extra-oci-image $(shell_quote "${BUNDLED_IMAGE_ARCHIVES[idx]}") --extra-oci-image-reference $(shell_quote "${BUNDLED_IMAGE_REFS[idx]}"))"$'\n'
done

INFERENCE_PACKAGE_LINES=""
INFERENCE_ARCHIVE_ARG_LINES=""
if appliance_pack_wanted inference; then
  # Build as a plain double-quoted string (not $(cat <<...)). A nested
  # command-substitution heredoc breaks on the ")" in \$(tr ...).
  INFERENCE_PACKAGE_LINES="# Appliance inference runtime (upstream Ollama-compatible image re-export).
make package-inference-runtime-image-archive \\
  OUT_FILE=\"/workspace/.run/inference-runtime-image.tar\" \\
  INFERENCE_VERSION=$(shell_quote "${INFERENCE_VERSION}") \\
  INFERENCE_SOURCE_IMAGE=$(shell_quote "${INFERENCE_IMAGE_PULL_REF}")
INFERENCE_IMAGE_ARCHIVE_FOR_DEV=\"/workspace/.run/inference-runtime-image.tar\"
INFERENCE_IMAGE_REF=\"\$(tr -d '\r\n' </workspace/.run/inference-runtime-image.reference)\"
"
  INFERENCE_ARCHIVE_ARG_LINES="  --inference-version $(shell_quote "${INFERENCE_VERSION}") \\"$'\n'
  INFERENCE_ARCHIVE_ARG_LINES+="  --inference-runtime-image \"\${INFERENCE_IMAGE_ARCHIVE_FOR_DEV}\" \\"$'\n'
  INFERENCE_ARCHIVE_ARG_LINES+="  --inference-runtime-image-reference \"\${INFERENCE_IMAGE_REF}\" \\"$'\n'
fi

cat >"${CODE_DEV_SCRIPT_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd /workspace
CONTROL_PLANE_IMAGE_OUT="/workspace/.run/control-plane-image.tar"
UI_IMAGE_OUT="/workspace/.run/appliance-ui-image.tar"
HOST_AGENT_IMAGE_OUT="/workspace/.run/appliance-host-agent-image.tar"
HOST_AGENT_IMAGE_REF_FILE="/workspace/.run/appliance-host-agent-image.reference"
MESSAGE_BROKER_IMAGE_OUT="/workspace/.run/message-broker-image.tar"
MESSAGE_BROKER_IMAGE_REF_FILE="/workspace/.run/message-broker-image.reference"
WORKFLOWS_ARGS=()
BUNDLED_IMAGE_ARGS=()
# Prefer the release/product version for image tags and the control-plane
# /version payload. Commit SHA stays in the separate Commit build field.
CODE_VERSION="\${CODE_VERSION:-$(shell_quote "${PRODUCT_VERSION}")}"
HOST_PACKAGES_DIR_FOR_DEV=$(shell_quote "${HOST_PACKAGES_DIR_FOR_DEV}")
HOST_PACKAGES_OS_VERSION=$(shell_quote "${OS_VERSION}")

bool_true() {
  local value="\${1:-}"
  case "\$(printf '%s' "\${value}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

make package-control-plane-image-archive OUT_FILE="\${CONTROL_PLANE_IMAGE_OUT}" IMAGE_TAG="\${CODE_VERSION}" \
  GO_IMAGE=$(shell_quote "${CP_GO_IMAGE}") \
  RUNTIME_IMAGE=$(shell_quote "${CP_RUNTIME_IMAGE}") \
  RUNTIME_PREBAKED=$(shell_quote "${RUNTIME_PACKAGES_INSTALLED}")
make package-ui-image-archive OUT_FILE="\${UI_IMAGE_OUT}" IMAGE_TAG="\${CODE_VERSION}" \
  UI_NODE_IMAGE=$(shell_quote "${UI_NODE_IMAGE}") \
  UI_GO_IMAGE=$(shell_quote "${UI_GO_IMAGE}") \
  UI_RUNTIME_IMAGE=$(shell_quote "${UI_RUNTIME_IMAGE}") \
  UI_WEB_DEPS_IMAGE=$(shell_quote "${UI_WEB_DEPS_IMAGE}") \
  USE_PREBAKED_NPM=$(shell_quote "${RUNTIME_PACKAGES_INSTALLED}") \
  RUNTIME_PREBAKED=$(shell_quote "${RUNTIME_PACKAGES_INSTALLED}")
make package-host-agent-image-archive \
  OUT_FILE="\${HOST_AGENT_IMAGE_OUT}" \
  REFERENCE_OUT_FILE="\${HOST_AGENT_IMAGE_REF_FILE}" \
  IMAGE_TAG="\${CODE_VERSION}" \
  GO_IMAGE=$(shell_quote "${CP_GO_IMAGE}") \
  RUNTIME_IMAGE=$(shell_quote "${CP_RUNTIME_IMAGE}") \
  RUNTIME_PREBAKED=$(shell_quote "${RUNTIME_PACKAGES_INSTALLED}")
HOST_AGENT_IMAGE_REF="\$(tr -d '\r\n' < "\${HOST_AGENT_IMAGE_REF_FILE}")"
make package-message-broker-image-archive \
  OUT_FILE="\${MESSAGE_BROKER_IMAGE_OUT}" \
  REFERENCE_OUT_FILE="\${MESSAGE_BROKER_IMAGE_REF_FILE}" \
  MESSAGE_BROKER_SOURCE_IMAGE=$(shell_quote "${MESSAGE_BROKER_SOURCE_IMAGE:-docker.io/library/nats:2.10.26-alpine}")
MESSAGE_BROKER_IMAGE_REF="\$(tr -d '\r\n' < "\${MESSAGE_BROKER_IMAGE_REF_FILE}")"
# Super-set: always pass host-packages (packages staged at install; services off).
HOST_PACKAGES_ARGS=(
  --host-packages-dir "\${HOST_PACKAGES_DIR_FOR_DEV}"
  --host-packages-os-version "\${HOST_PACKAGES_OS_VERSION}"
)

# Appliance-owned artifact-server wrapper: upstream registry binary + thin
# entrypoint; native application.log under /data/zon/logs/artifactserver via
# chart config. Always package from upstream pull ref (no pre-supplied archive).
make package-artifact-server-image-archive \
  OUT_FILE="/workspace/.run/artifact-server-image.tar" \
  ARTIFACT_SERVER_VERSION=$(shell_quote "${ARTIFACT_SERVER_VERSION}") \
  ARTIFACT_SERVER_SOURCE_IMAGE=$(shell_quote "${ARTIFACT_SERVER_SOURCE_IMAGE}") \
  RUNTIME_SOURCE_IMAGE=$(shell_quote "${ARTIFACT_RUNTIME_SOURCE_IMAGE}") \
  RUNTIME_PACKAGES_INSTALLED=$(shell_quote "${RUNTIME_PACKAGES_INSTALLED}")
ARTIFACT_SERVER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/artifact-server-image.tar"
ARTIFACT_SERVER_IMAGE_REF="\$(tr -d '\r\n' </workspace/.run/artifact-server-image.reference)"

# Appliance-owned dns-server wrapper (upstream CoreDNS): tees stdout/stderr into /data/zon/logs/dns.
# Always package from upstream pull ref (no pre-supplied archive path).
make package-dns-server-image-archive \
  OUT_FILE="/workspace/.run/dns-server-image.tar" \
  DNS_VERSION=$(shell_quote "${DNS_VERSION}") \
  DNS_SOURCE_IMAGE=$(shell_quote "${DNS_IMAGE_PULL_REF}") \
  RUNTIME_IMAGE=$(shell_quote "${CP_RUNTIME_IMAGE}") \
  RUNTIME_PREBAKED=$(shell_quote "${RUNTIME_PACKAGES_INSTALLED}")
DNS_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/dns-server-image.tar"
DNS_IMAGE_REF="\$(tr -d '\r\n' </workspace/.run/dns-server-image.reference)"

${INFERENCE_PACKAGE_LINES}

METADATA_BUNDLE_ARCHIVE_FOR_DEV="\$(bash ./scripts/package/generate-metadata-bundle.sh --software-version "\${CODE_VERSION}" --out-dir "/workspace/.run/metadata-bundle")"

if bool_true $(shell_quote "${WORKFLOWS_ENABLED}"); then
  WORKFLOWS_ARGS+=(--workflows-version $(shell_quote "${WORKFLOWS_VERSION}"))

  if [[ -n $(shell_quote "${WORKFLOWS_CRDS_DIR_FOR_DEV}") ]]; then
    WORKFLOWS_ARGS+=(--workflows-crds-dir $(shell_quote "${WORKFLOWS_CRDS_DIR_FOR_DEV}"))
  fi

  # Always wrap the upstream controller inside the code-repo dev environment.
  make package-workflow-controller-image-archive \
    OUT_FILE="/workspace/.run/workflow-controller-image.tar" \
    WORKFLOWS_VERSION=$(shell_quote "${WORKFLOWS_VERSION}") \
    WORKFLOW_CONTROLLER_BASE_IMAGE=$(shell_quote "${WORKFLOW_CONTROLLER_BASE_IMAGE}") \
    RUNTIME_IMAGE=$(shell_quote "${CP_RUNTIME_IMAGE}") \
    RUNTIME_PREBAKED=$(shell_quote "${RUNTIME_PACKAGES_INSTALLED}")
  WORKFLOW_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/workflow-controller-image.tar"

  WORKFLOWS_ARGS+=(--workflow-controller-image "\${WORKFLOW_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV}")
  WORKFLOWS_ARGS+=(--workflow-controller-image-reference $(shell_quote "${WORKFLOW_CONTROLLER_IMAGE_REF}"))

  WORKFLOWS_ARGS+=(--workflow-executor-image $(shell_quote "${WORKFLOW_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV}"))
  WORKFLOWS_ARGS+=(--workflow-executor-image-reference $(shell_quote "${WORKFLOW_EXECUTOR_IMAGE_REF}"))
fi

${BUNDLED_IMAGE_ARG_LINES}

bash ./scripts/package/archive-release-input.sh \
  --out-file "/workspace/.run/release-input-${PRODUCT_VERSION}.tar.gz" \
  --code-version "\${CODE_VERSION}" \
  --control-plane-image "\${CONTROL_PLANE_IMAGE_OUT}" \
  --control-plane-image-reference "localhost/appliance-control-plane:\${CODE_VERSION}" \
  --ui-image "\${UI_IMAGE_OUT}" \
  --ui-image-reference "localhost/appliance-ui:\${CODE_VERSION}" \
  --host-agent-image "\${HOST_AGENT_IMAGE_OUT}" \
  --host-agent-image-reference "\${HOST_AGENT_IMAGE_REF}" \
  --message-broker-image "\${MESSAGE_BROKER_IMAGE_OUT}" \
  --message-broker-image-reference "\${MESSAGE_BROKER_IMAGE_REF}" \
  "\${HOST_PACKAGES_ARGS[@]}" \
  --k3s-version $(shell_quote "${K3S_VERSION}") \
  --artifact-server-version $(shell_quote "${ARTIFACT_SERVER_VERSION}") \
  --artifact-server-image "\${ARTIFACT_SERVER_IMAGE_ARCHIVE_FOR_DEV}" \
  --artifact-server-image-reference "\${ARTIFACT_SERVER_IMAGE_REF}" \
  --dns-version $(shell_quote "${DNS_VERSION}") \
  --dns-image "\${DNS_IMAGE_ARCHIVE_FOR_DEV}" \
  --dns-image-reference "\${DNS_IMAGE_REF}" \
${INFERENCE_ARCHIVE_ARG_LINES}  --metadata-bundle "\${METADATA_BUNDLE_ARCHIVE_FOR_DEV}" \
  "\${WORKFLOWS_ARGS[@]}" \
  "\${BUNDLED_IMAGE_ARGS[@]}"
EOF
chmod +x "${CODE_DEV_SCRIPT_PATH}"

# Tooling image for make/dev-run (DEV_* / OFFLINE_BUILD already exported above).
export DEV_IMAGE="${BUILDER_PULL_REF:-${DEV_IMAGE:-}}"
make -C "${CODE_REPO_DIR}" DEV_IMAGE="${DEV_IMAGE}" OFFLINE_BUILD="${OFFLINE_BUILD}" \
  dev-run SCRIPT="${CODE_DEV_SCRIPT_REL}"
cp "${CODE_RELEASE_INPUT_TAR}" "${RELEASE_INPUT_TAR}"
ARTIFACT_SERVER_IMAGE_REF="$(tr -d '\r\n' < "${CODE_REPO_DIR}/.run/artifact-server-image.reference")"

fetch_k3s_inputs "${INPUTS_DIR}"
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  stage_file "${VALUES_FILE_SOURCE}" "${INPUTS_DIR}/values-minimal.yaml" "values file"
fi

cp "${DEFAULTS_FILE}" "${CONFIG_OUT}"
set_env_var "${CONFIG_OUT}" WORKDIR "${WORKSPACE}"
set_env_var "${CONFIG_OUT}" PRODUCT_VERSION "${PRODUCT_VERSION}"
set_env_var "${CONFIG_OUT}" OS_VERSION "${OS_VERSION}"
set_env_var "${CONFIG_OUT}" K3S_VERSION "${K3S_VERSION}"
set_env_var "${CONFIG_OUT}" RELEASE_INPUT_SOURCE "${RELEASE_INPUT_TAR}"
set_env_var "${CONFIG_OUT}" RELEASE_INPUT_VERSION ""
set_env_var "${CONFIG_OUT}" RELEASE_INPUT_FETCH_TEMPLATE ""
set_env_var "${CONFIG_OUT}" CTL_REPO_SOURCE "${CTL_REPO_DIR}"
set_env_var "${CONFIG_OUT}" INPUTS_DIR "${INPUTS_DIR}"
set_env_var "${CONFIG_OUT}" SAMPLE_MODE "0"
set_env_var "${CONFIG_OUT}" HELM_BINARY "${HELM_BINARY}"
set_env_var "${CONFIG_OUT}" HELM_VERSION "${HELM_VERSION}"
set_env_var "${CONFIG_OUT}" K3S_BINARY "${INPUTS_DIR}/k3s"
set_env_var "${CONFIG_OUT}" K3S_AIRGAP_IMAGES "${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst"
set_env_var "${CONFIG_OUT}" OFFLINE_BUILD "${OFFLINE_BUILD}"
set_env_var "${CONFIG_OUT}" APPLIANCE_PACKS "${APPLIANCE_PACKS}"
# Assemble only needs DEV_* for offline files API. Online tooling registry must
# not be written here — it is not the LAN Artifact Server.
if offline_build_enabled; then
  set_env_var "${CONFIG_OUT}" DEV_REGISTRY "${DEV_REGISTRY}"
  set_env_var "${CONFIG_OUT}" DEV_REGISTRY_TOKEN "${DEV_REGISTRY_TOKEN}"
  set_env_var "${CONFIG_OUT}" DEV_REGISTRY_TLS_VERIFY "${DEV_REGISTRY_TLS_VERIFY:-true}"
else
  set_env_var "${CONFIG_OUT}" DEV_REGISTRY ""
  set_env_var "${CONFIG_OUT}" DEV_REGISTRY_TOKEN ""
  set_env_var "${CONFIG_OUT}" DEV_REGISTRY_TLS_VERIFY "true"
fi
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  set_env_var "${CONFIG_OUT}" VALUES_FILE "${INPUTS_DIR}/values-minimal.yaml"
else
  set_env_var "${CONFIG_OUT}" VALUES_FILE ""
fi

echo "generated bundle config:"
echo "  ${CONFIG_OUT}"

make -C "${RELEASE_REPO_DIR}" product-bundle CONFIG="${CONFIG_OUT}"

EXPORTED_ARCHIVES=()
if appliance_pack_wanted foundation; then
  tar -C "$(dirname "${BUNDLE_DIR}")" -czf "${BUNDLE_ARCHIVE}" "$(basename "${BUNDLE_DIR}")"
  EXPORTED_ARCHIVES+=("${BUNDLE_ARCHIVE}")
fi
if appliance_pack_wanted developer; then
  tar -C "$(dirname "${DEVELOPER_BUNDLE_DIR}")" -czf "${DEVELOPER_ARCHIVE}" "$(basename "${DEVELOPER_BUNDLE_DIR}")"
  EXPORTED_ARCHIVES+=("${DEVELOPER_ARCHIVE}")
fi
if appliance_pack_wanted inference; then
  tar -C "$(dirname "${INFERENCE_BUNDLE_DIR}")" -czf "${INFERENCE_ARCHIVE}" "$(basename "${INFERENCE_BUNDLE_DIR}")"
  EXPORTED_ARCHIVES+=("${INFERENCE_ARCHIVE}")
fi
cp "${WORKSPACE}/keys/release-signing.pub" "${PUBLIC_KEY_EXPORT}"

python3 - "${RELEASE_INDEX}" "${PRODUCT_VERSION}" ${APPLIANCE_PACKS_RESOLVED} \
  "$(basename "${BUNDLE_ARCHIVE}")" \
  "$(basename "${DEVELOPER_ARCHIVE}")" \
  "$(basename "${INFERENCE_ARCHIVE}")" <<'PY'
from pathlib import Path
import sys

index_path = Path(sys.argv[1])
version = sys.argv[2]
args = sys.argv[3:]
if len(args) < 4:
    raise SystemExit("release-index writer: expected pack ids then three filenames")
base_name, developer_name, inference_name = args[-3:]
selected = set(args[:-3])

pack_specs = []
capability_lines = []
if "foundation" in selected:
    pack_specs.append(
        f"  - id: foundation\n    filename: {base_name}\n    capabilities: [base, host, artifact, dns]"
    )
if "developer" in selected:
    pack_specs.append(
        f"  - id: developer\n    filename: {developer_name}\n    capabilities: [workflows, build]"
    )
    capability_lines.append("  workflows: developer")
    capability_lines.append("  build: developer")
if "inference" in selected:
    pack_specs.append(
        f"  - id: inference\n    filename: {inference_name}\n    capabilities: [inference]"
    )
    capability_lines.append("  inference: inference")

if capability_lines:
    capability_block = "\n".join(capability_lines)
    text = f"""version: {version}
packs:
{chr(10).join(pack_specs)}
capabilityPacks:
{capability_block}
"""
else:
    text = f"""version: {version}
packs:
{chr(10).join(pack_specs)}
capabilityPacks: {{}}
"""
index_path.write_text(text, encoding="utf-8")
PY

echo
echo "release-input tarball:"
echo "  ${RELEASE_INPUT_TAR}"
echo
echo "final packs (${APPLIANCE_PACKS_RESOLVED}):"
if appliance_pack_wanted foundation; then
  echo "  ${BUNDLE_DIR}"
fi
if appliance_pack_wanted developer; then
  echo "  ${DEVELOPER_BUNDLE_DIR}"
fi
if appliance_pack_wanted inference; then
  echo "  ${INFERENCE_BUNDLE_DIR}"
fi
echo
echo "bundled artifact-server image:"
echo "  ${ARTIFACT_SERVER_IMAGE_REF}"
echo
echo "generated bundle config:"
echo "  ${WORKSPACE}/generated/product-bundle.env"
echo
echo "exported customer delivery files:"
for archive in "${EXPORTED_ARCHIVES[@]}"; do
  echo "  ${archive}"
done
echo "  ${RELEASE_INDEX}"
echo "  ${PUBLIC_KEY_EXPORT}"
echo
echo "next step on the build machine:"
echo "  # PRODUCT_VERSION defaults from configs/default-product-version"
echo "  # export dir is \$RELEASE_WORK_ROOT/export"
echo "  # uploads to https://\$DEV_REGISTRY/api/v1/files/appliance/<version>/"
echo "  export RELEASE_WORK_ROOT=${RELEASE_WORK_ROOT}"
echo "  # DEV_REGISTRY + DEV_REGISTRY_TOKEN (+ DEV_IMAGE_REPO / TLS) from build"
echo "  # publish follows export/release-index.yaml (same packs as this build)"
echo "  bash ./scripts/publish-release.sh"
echo "optional:"
echo "  bash ./scripts/publish-release.sh --latest-alias"
echo "  PRODUCT_VERSION=<override>"
echo "  APPLIANCE_PACKS=foundation|foundation,developer|all  # default all"
