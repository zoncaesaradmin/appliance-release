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

  DEV_REGISTRY=artifact-dns-1.appliance.internal \
  DEV_IMAGE_REPO=development-container \
  DEV_REGISTRY_TOKEN=... \
  DEV_REGISTRY_USER=admin \
  DEV_REGISTRY_TLS_VERIFY=false \
  bash ./scripts/ci/build-full-bundle.sh

Required: DEV_REGISTRY (host) + DEV_IMAGE_REPO (registry-specific path).
  GHCR example: DEV_REGISTRY=ghcr.io DEV_IMAGE_REPO=zoncaesaradmin/development-container
  LAN example:  DEV_REGISTRY=<host> DEV_IMAGE_REPO=development-container
PRODUCT_VERSION defaults from configs/default-product-version.
DEV_IMAGE_NAME/TAG default to dev-build/latest (exported into appliance-code make/dev-run).
K3s binary + airgap images are downloaded at build time from the appliance
files API (seed once with scripts/ci/fetch-k3s-inputs.sh). URL layout is fixed:
  https://\$DEV_REGISTRY/api/v1/files/k3s/\$K3S_VERSION/k3s
  https://\$DEV_REGISTRY/api/v1/files/k3s/\$K3S_VERSION/k3s-airgap-images-amd64.tar.zst
K3S_VERSION comes from configs/product-bundle.ci.env (or K3S_VERSION_OVERRIDE).

Argo Workflows is on by default (it is a mandatory component of the
complete v1 appliance per ADR 0011) and needs no configuration: its
version and controller/executor image references are derived
automatically from appliance-code's own
deploy/charts/argo-workflows/Chart.yaml (the chart's pinned appVersion),
and its CRDs are fetched automatically from the matching upstream Argo
Workflows GitHub release unless you provide a local copy. You never need
to set an Argo version yourself.

Optional overrides:
  PRODUCT_VERSION=0.1.0         # overrides configs/default-product-version
  RELEASE_WORK_ROOT=${TMPDIR:-/tmp}/appliance-build
  K3S_VERSION_OVERRIDE=v1.30.4+k3s1
  HELM_VERSION=v3.21.1
  HELM_BINARY=/abs/path/to/linux-amd64/helm
  VALUES_FILE_SOURCE=/ci/inputs/values-minimal.yaml
  # Host packages: always export-host-packages for mdns + wifi-ap under OS_VERSION
  # (ubuntu/<version>/amd64/*.deb). Install stages debs; enablement is day-2 only.
  # BUILD_COMPLETE_PRODUCT=false  # developer slim path only; default true requires Argo + dev-build
  # COMPONENT_CACHE_DIR=/var/cache/appliance-build/components  # optional dirty-only rebuild cache
  ARGO_ENABLED=true                 # complete product always packages Argo (set BUILD_COMPLETE_PRODUCT=false to allow opt-out)
  ARGO_VERSION=v3.5.10              # pin a different Argo version than the chart's appVersion
  ARGO_CONTROLLER_IMAGE_REF=localhost/appliance-argo-controller:v3.5.10
  ARGO_EXECUTOR_IMAGE_REF=quay.io/argoproj/argoexec:v3.5.10
  # Argo CRDs and controller/executor images are always fetched/packaged online
  # (or via the automatic LAN build-cache on DEV_REGISTRY). Pre-supplied local
  # archive/dir paths are not supported.
  WORKSPACE_PROVISIONER_IMAGE_REF=docker.io/alpine/git:latest
  # Complete product packages registry.local/dev-build from
  # DEV_REGISTRY + required DEV_IMAGE_REPO + DEV_IMAGE_NAME/TAG
  # (NAME/TAG default to dev-build/latest).
  # When DEV_REGISTRY is set, packaging auto-uses a LAN build-cache on that
  # host (prefix build-cache/, 15s probe): try LAN → miss/timeout → upstream →
  # best-effort push back to LAN. Auth/TLS reuse DEV_REGISTRY_USER/TOKEN/TLS_VERIFY.
  ZOT_VERSION=2.1.8
  ZOT_IMAGE_PULL_REF=ghcr.io/project-zot/zot-linux-amd64:v2.1.8
  # Zot is a first-class release artifact: always pull/copy linux/amd64 and derive
  # registry.local/zot@sha256:<platform-digest> from index.json.
  DNS_VERSION=1.14.4
  DNS_IMAGE_PULL_REF=registry.k8s.io/coredns/coredns:v1.14.4
  # CoreDNS: always wrap upstream via appliance-code package-coredns-image-archive
  # (dev-run has buildah+skopeo); digest from index.json.
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
USER_CTL_REPO_SOURCE="${CTL_REPO_SOURCE-}"
USER_HELM_BINARY="${HELM_BINARY-}"
USER_HELM_VERSION="${HELM_VERSION-}"
USER_VALUES_FILE_SOURCE="${VALUES_FILE_SOURCE-}"
USER_RELEASE_WORK_ROOT="${RELEASE_WORK_ROOT-}"
USER_OS_VERSION="${OS_VERSION-}"
USER_K3S_VERSION_OVERRIDE="${K3S_VERSION_OVERRIDE-}"
USER_ARGO_ENABLED="${ARGO_ENABLED-}"
USER_ARGO_REQUIRED="${ARGO_REQUIRED-}"
USER_ARGO_VERSION="${ARGO_VERSION-}"
USER_ARGO_CONTROLLER_IMAGE_REF="${ARGO_CONTROLLER_IMAGE_REF-}"
USER_ARGO_EXECUTOR_IMAGE_REF="${ARGO_EXECUTOR_IMAGE_REF-}"
USER_WORKSPACE_PROVISIONER_IMAGE_REF="${WORKSPACE_PROVISIONER_IMAGE_REF-}"
USER_ZOT_VERSION="${ZOT_VERSION-}"
USER_ZOT_IMAGE_PULL_REF="${ZOT_IMAGE_PULL_REF-}"
USER_DNS_VERSION="${DNS_VERSION-}"
USER_DNS_IMAGE_PULL_REF="${DNS_IMAGE_PULL_REF-}"
USER_DEV_REGISTRY="${DEV_REGISTRY-}"
USER_DEV_IMAGE_REPO="${DEV_IMAGE_REPO-}"
USER_DEV_IMAGE_NAME="${DEV_IMAGE_NAME-}"
USER_DEV_IMAGE_TAG="${DEV_IMAGE_TAG-}"

set -a
# shellcheck disable=SC1090
source "${DEFAULTS_FILE}"
set +a

# Reject removed offline/local archive path knobs (build always pulls/packages
# from the network, with an automatic LAN build-cache when DEV_REGISTRY is set).
_removed_offline_build_inputs=(
  ARGO_CRDS_DIR_SOURCE
  ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE
  ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE
  WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE
  ZOT_IMAGE_ARCHIVE_SOURCE
  DNS_IMAGE_ARCHIVE_SOURCE
  HOST_PACKAGES_DIR_SOURCE
)
for _var in "${_removed_offline_build_inputs[@]}"; do
  if [[ -n "${!_var-}" ]]; then
    echo "build-full-bundle: ${_var} is no longer supported (no offline/local archive path inputs)." >&2
    echo "build-full-bundle: use network packaging (LAN build-cache is automatic from DEV_REGISTRY)." >&2
    exit 2
  fi
done
unset _var _removed_offline_build_inputs

if [[ -n "${EXPORT_DIR-}" ]]; then
  echo "build-full-bundle: EXPORT_DIR is no longer supported." >&2
  echo "build-full-bundle: set RELEASE_WORK_ROOT; export output is always \$RELEASE_WORK_ROOT/export." >&2
  exit 2
fi

# Fixed LAN build-cache policy.
LAN_BUILD_CACHE_PREFIX="build-cache"
LAN_BUILD_CACHE_TIMEOUT_SECONDS="15"

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
ARGO_ENABLED="${USER_ARGO_ENABLED:-${ARGO_ENABLED:-}}"
ARGO_REQUIRED="${USER_ARGO_REQUIRED:-${ARGO_REQUIRED:-}}"
ARGO_VERSION="${USER_ARGO_VERSION:-${ARGO_VERSION:-}}"
ARGO_CONTROLLER_IMAGE_REF="${USER_ARGO_CONTROLLER_IMAGE_REF:-${ARGO_CONTROLLER_IMAGE_REF:-}}"
ARGO_EXECUTOR_IMAGE_REF="${USER_ARGO_EXECUTOR_IMAGE_REF:-${ARGO_EXECUTOR_IMAGE_REF:-}}"
WORKSPACE_PROVISIONER_IMAGE_REF="${USER_WORKSPACE_PROVISIONER_IMAGE_REF:-${WORKSPACE_PROVISIONER_IMAGE_REF:-docker.io/alpine/git:latest}}"
# compatibility.zotVersion is unprefixed (2.1.8). Chart appVersion and GHCR
# tags use a leading v (v2.1.8). Normalize before constructing the pull ref.
ZOT_VERSION="${USER_ZOT_VERSION:-${ZOT_VERSION:-2.1.8}}"
ZOT_VERSION="${ZOT_VERSION#v}"
ZOT_IMAGE_PULL_REF="${USER_ZOT_IMAGE_PULL_REF:-${ZOT_IMAGE_PULL_REF:-ghcr.io/project-zot/zot-linux-amd64:v${ZOT_VERSION}}}"
# compatibility.dnsVersion is unprefixed (1.14.4). Chart appVersion and the
# upstream registry.k8s.io tag use a leading v (v1.14.4). Normalize before
# constructing the pull ref, same as ZOT_VERSION above.
DNS_VERSION="${USER_DNS_VERSION:-${DNS_VERSION:-1.14.4}}"
DNS_VERSION="${DNS_VERSION#v}"
DNS_IMAGE_PULL_REF="${USER_DNS_IMAGE_PULL_REF:-${DNS_IMAGE_PULL_REF:-registry.k8s.io/coredns/coredns:v${DNS_VERSION}}}"

# Argo Workflows is a mandatory component of the complete product super-set
# (ADR 0011). BUILD_COMPLETE_PRODUCT defaults true and forces ARGO_ENABLED.
# ARGO_VERSION is derived later from appliance-code's Chart.yaml once checked out.
BUILD_COMPLETE_PRODUCT="${BUILD_COMPLETE_PRODUCT:-true}"
if [[ -z "${ARGO_ENABLED}" ]]; then
  ARGO_ENABLED="true"
fi

DEV_REGISTRY="${USER_DEV_REGISTRY:-${DEV_REGISTRY:-}}"
DEV_IMAGE_REPO="${USER_DEV_IMAGE_REPO:-${DEV_IMAGE_REPO:-}}"
DEV_IMAGE_NAME="${USER_DEV_IMAGE_NAME:-${DEV_IMAGE_NAME:-dev-build}}"
DEV_IMAGE_TAG="${USER_DEV_IMAGE_TAG:-${DEV_IMAGE_TAG:-latest}}"
# DEV_IMAGE_REPO is registry-specific and required (host-only DEV_REGISTRY):
#   GHCR:  zoncaesaradmin/development-container
#   LAN:   development-container
# Export so appliance-code make/dev-run sees the composed pull ref.
if [[ -z "${DEV_REGISTRY}" ]]; then
  echo "build-full-bundle: DEV_REGISTRY is required (registry host, e.g. ghcr.io or artifact-dns-1.appliance.internal)" >&2
  exit 2
fi
if [[ -z "${DEV_IMAGE_REPO}" ]]; then
  echo "build-full-bundle: DEV_IMAGE_REPO is required (e.g. zoncaesaradmin/development-container on GHCR, or development-container on LAN)" >&2
  exit 2
fi
export PRODUCT_VERSION
export DEV_REGISTRY DEV_IMAGE_REPO DEV_IMAGE_NAME DEV_IMAGE_TAG
export DEV_REGISTRY_USER="${DEV_REGISTRY_USER:-}"
export DEV_REGISTRY_TOKEN="${DEV_REGISTRY_TOKEN:-}"
export DEV_REGISTRY_TLS_VERIFY="${DEV_REGISTRY_TLS_VERIFY:-true}"
BUILDER_LOCAL_REF="registry.local/dev-build"
BUILDER_PULL_REF=""

if [[ -n "${K3S_VERSION_OVERRIDE}" ]]; then
  K3S_VERSION="${K3S_VERSION_OVERRIDE}"
fi

# Optional per-component cache for incremental rebuilds (Phase C).
COMPONENT_CACHE_DIR="${COMPONENT_CACHE_DIR:-}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/component-cache.sh"

REPOS_DIR="${RELEASE_WORK_ROOT}/repos"
ARTIFACTS_DIR="${RELEASE_WORK_ROOT}/artifacts"
WORKSPACE="${RELEASE_WORK_ROOT}/workspace"
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

bool_true() {
  local value="${1:-}"
  case "$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if bool_true "${BUILD_COMPLETE_PRODUCT}" && ! bool_true "${ARGO_ENABLED}"; then
  echo "build-full-bundle: BUILD_COMPLETE_PRODUCT requires ARGO_ENABLED=true (developer slim builds: BUILD_COMPLETE_PRODUCT=false)" >&2
  exit 2
fi
if bool_true "${BUILD_COMPLETE_PRODUCT}"; then
  if [[ -z "${DEV_REGISTRY}" ]]; then
    echo "build-full-bundle: DEV_REGISTRY is required to package ${BUILDER_LOCAL_REF}" >&2
    exit 2
  fi
  BUILDER_PULL_REF="${DEV_REGISTRY}/${DEV_IMAGE_REPO}/${DEV_IMAGE_NAME}:${DEV_IMAGE_TAG}"
fi

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

# Same layout as scripts/ci/fetch-k3s-inputs.sh: files API under k3s/$K3S_VERSION/.
# Requires DEV_REGISTRY + DEV_REGISTRY_TOKEN (existing registry/files auth vars).
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
    echo "build-full-bundle: failed to download k3s binary from ${remote_prefix}/k3s (seed with scripts/ci/fetch-k3s-inputs.sh)" >&2
    exit 1
  fi
  chmod +x "${bin_dest}"
  if ! curl -fsSL "${curl_tls[@]}" \
    -H "Authorization: Bearer ${token}" \
    -o "${airgap_dest}" \
    "${remote_prefix}/k3s-airgap-images-amd64.tar.zst"; then
    echo "build-full-bundle: failed to download airgap images from ${remote_prefix}/k3s-airgap-images-amd64.tar.zst (seed with scripts/ci/fetch-k3s-inputs.sh)" >&2
    exit 1
  fi
  require_file "${bin_dest}" "k3s binary"
  require_file "${airgap_dest}" "k3s airgap images"
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
build-full-bundle: run this once on the build host:
build-full-bundle:   export DEV_REGISTRY_USER=<github-username>
build-full-bundle:   export DEV_REGISTRY_TOKEN=<PAT with read:packages>
build-full-bundle:   bash ${RELEASE_REPO_DIR}/scripts/ci/bootstrap-build-host.sh
build-full-bundle:
build-full-bundle: if the registry token changes later, rerun the same bootstrap script with the new token.
build-full-bundle:
build-full-bundle: then rerun:
build-full-bundle:   bash ${RELEASE_REPO_DIR}/scripts/ci/build-full-bundle.sh
EOF
  exit 1
}

export_container_image_archive() {
  local image_ref="$1"
  local output_path="$2"
  local podman_bin

  podman_bin="$(command -v podman)"
  mkdir -p "$(dirname "${output_path}")"
  rm -f "${output_path}"

  sudo -n "${podman_bin}" pull "${image_ref}" >/dev/null
  sudo -n "${podman_bin}" save --format oci-archive -o "${output_path}" "${image_ref}" >/dev/null
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

# LAN build-cache is on whenever packaging already has DEV_REGISTRY (required
# for K3s files API and builder pull). Miss/timeout falls back to upstream.
lan_build_cache_enabled() {
  [[ -n "${DEV_REGISTRY:-}" ]]
}

# Parse oci-archive:path[:reference] (first colon after transport separates
# path from optional reference). References often contain further colons
# (registry.local/zot:bundled). Linux archive paths never contain ':'.
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

# Host-network podman pull/save — same path used successfully for Argo OCI.
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
  # Pull-through to local LAN appliance Artifact Server (build-cache on DEV_REGISTRY):
  #   1) If DEV_REGISTRY is set: try LAN first (short timeout). Hit → done.
  #   2) Else (miss / timeout / unreachable / no DEV_REGISTRY): pull upstream
  #      (internet or configured pull ref). Upstream TLS is independent of the
  #      LAN TLS/insecure settings used for Artifact Server (self-signed lab cert).
  #   3) If (2) succeeded and DEV_REGISTRY is set: best-effort push the just-fetched
  #      archive to the LAN Artifact Server so the next build is a hit.
  # Bundle output always lands in output_path; fail closed only if (2) fails.
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
      echo "build-full-bundle: falling back to upstream (internet/pull-ref) ${source_ref}" >&2
    fi
  fi

  # Upstream: show skopeo errors (do not swallow 2>&1). Optional podman
  # fallback matches export_container_image_archive (Argo path) — host network.
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

# derive_argo_version_from_code_repo reads the pinned Argo version out of
# appliance-code's own deploy/charts/argo-workflows/Chart.yaml (its
# appVersion field), the single source of truth for which Argo release
# this chart is built against. This is what lets an operator build a
# complete appliance without ever having to know or set an Argo version
# themselves: it's the same version the chart itself is pinned to,
# already reviewed and committed in that repo.
derive_argo_version_from_code_repo() {
  local chart_yaml="${CODE_REPO_DIR}/deploy/charts/argo-workflows/Chart.yaml"
  local version

  if [[ ! -f "${chart_yaml}" ]]; then
    echo "build-full-bundle: ARGO_ENABLED is true but ${chart_yaml} was not found; cannot derive the Argo version" >&2
    exit 1
  fi
  version="$(sed -n 's/^appVersion: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${chart_yaml}")"
  if [[ -z "${version}" ]]; then
    echo "build-full-bundle: could not parse appVersion from ${chart_yaml}" >&2
    exit 1
  fi
  printf '%s' "${version}"
}

fetch_argo_crds_from_release() {
  local argo_version="$1"
  local output_dir="$2"
  local manifest_url="https://github.com/argoproj/argo-workflows/releases/download/${argo_version}/namespace-install.yaml"
  local tmp_manifest

  tmp_manifest="$(mktemp)"
  trap 'rm -f "${tmp_manifest}"' RETURN
  curl -fsSL "${manifest_url}" -o "${tmp_manifest}"

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
        raise SystemExit("build-full-bundle: could not determine Argo CRD filename from downloaded manifest")
    out_path = output_dir / f"{match.group(1)}.yaml"
    out_path.write_text(doc + "\n", encoding="utf-8")
    written += 1

if written == 0:
    raise SystemExit("build-full-bundle: downloaded Argo manifest did not contain any CRDs")
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
if [[ -z "${ZOT_VERSION}" || "${ZOT_VERSION}" == *latest* ]]; then
  echo "build-full-bundle: ZOT_VERSION must be an exact non-latest version" >&2
  exit 2
fi
if [[ "${ZOT_IMAGE_PULL_REF}" == *:latest || "${ZOT_IMAGE_PULL_REF}" == registry.local/* ]]; then
  echo "build-full-bundle: ZOT_IMAGE_PULL_REF must be a version-pinned upstream image ref" >&2
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
if [[ "${WORKSPACE_PROVISIONER_IMAGE_REF}" == registry.local/workspace-provisioner || "${WORKSPACE_PROVISIONER_IMAGE_REF}" == registry.local/workspace-provisioner@sha256:* ]]; then
  echo "build-full-bundle: WORKSPACE_PROVISIONER_IMAGE_REF must be an upstream pull ref (default docker.io/alpine/git:latest); got ${WORKSPACE_PROVISIONER_IMAGE_REF}" >&2
  exit 2
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

ZOT_CHART_APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${CODE_REPO_DIR}/deploy/charts/appliance-registry/Chart.yaml")"
# Chart.yaml may use Helm/upstream form v2.1.8 while ZOT_VERSION is 2.1.8.
if [[ -z "${ZOT_CHART_APP_VERSION}" || "${ZOT_CHART_APP_VERSION#v}" != "${ZOT_VERSION}" ]]; then
  echo "build-full-bundle: ZOT_VERSION ${ZOT_VERSION} must match appliance-registry chart appVersion ${ZOT_CHART_APP_VERSION:-<missing>}" >&2
  exit 2
fi

DNS_CHART_APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${CODE_REPO_DIR}/deploy/charts/appliance-dns/Chart.yaml")"
# Chart.yaml may use Helm/upstream form v1.14.4 while DNS_VERSION is 1.14.4.
if [[ -z "${DNS_CHART_APP_VERSION}" || "${DNS_CHART_APP_VERSION#v}" != "${DNS_VERSION}" ]]; then
  echo "build-full-bundle: DNS_VERSION ${DNS_VERSION} must match appliance-dns chart appVersion ${DNS_CHART_APP_VERSION:-<missing>}" >&2
  exit 2
fi

require_appliance_code_bootstrap

if bool_true "${ARGO_ENABLED}"; then
  if [[ -z "${ARGO_VERSION}" ]]; then
    ARGO_VERSION="$(derive_argo_version_from_code_repo)"
  fi
  if [[ -z "${ARGO_CONTROLLER_IMAGE_REF}" ]]; then
    ARGO_CONTROLLER_IMAGE_REF="localhost/appliance-argo-controller:${ARGO_VERSION}"
  fi
  if [[ -z "${ARGO_EXECUTOR_IMAGE_REF}" ]]; then
    ARGO_EXECUTOR_IMAGE_REF="quay.io/argoproj/argoexec:${ARGO_VERSION}"
  fi
fi

mkdir -p "${CODE_REPO_DIR}/.run"

ARGO_CRDS_DIR_FOR_DEV=""
ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV=""
ARGO_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV=""
rm -rf "${CODE_REPO_DIR}/.run/host-packages"
# Complete product super-set always packages both host capability closures by
# export on the build host (no external host-packages tree override).
HOST_PACKAGES_DIR_FOR_DEV="/workspace/.run/host-packages"
HOST_CAPABILITIES=(mdns wifi-ap)
mkdir -p "${CODE_REPO_DIR}/.run/host-packages"
host_packages_fingerprint_inputs=("${OS_VERSION}" "mdns" "wifi-ap")
if ! component_cache_try_restore "host-packages" "${CODE_REPO_DIR}/.run/host-packages" "${host_packages_fingerprint_inputs[@]}"; then
  CAP_ARGS=()
  for cap in "${HOST_CAPABILITIES[@]}"; do
    CAP_ARGS+=(--capability "${cap}")
  done
  bash "${CODE_REPO_DIR}/scripts/package/export-host-packages.sh" \
    --out-dir "${CODE_REPO_DIR}/.run/host-packages" \
    --os-version "${OS_VERSION}" \
    "${CAP_ARGS[@]}"
  component_cache_store "host-packages" "${CODE_REPO_DIR}/.run/host-packages" "${host_packages_fingerprint_inputs[@]}"
fi

if bool_true "${ARGO_ENABLED}"; then
  # Always fetch CRDs and pull/package images (no local archive path inputs).
  if bool_true "${ARGO_REQUIRED:-true}"; then
    ARGO_CRDS_DIR_FOR_DEV="/workspace/.run/argo-crds"
    fetch_argo_crds_from_release "${ARGO_VERSION}" "${CODE_REPO_DIR}/.run/argo-crds"
  fi
  # Controller image is wrapped inside the code-repo dev-run (buildah).
  ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV=""
  ARGO_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/argo-executor-image.tar"
  export_container_image_archive "${ARGO_EXECUTOR_IMAGE_REF}" "${CODE_REPO_DIR}/.run/argo-executor-image.tar"
fi

# Bundled supplemental images for release-input (--extra-oci-image flags):
# provisioner always; builder only when complete product.
BUNDLED_IMAGE_ARCHIVES=()
BUNDLED_IMAGE_REFS=()

ensure_lan_build_cache_login

ZOT_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/zot-image.tar"
ZOT_IMAGE_REF="$(export_bundled_oci_archive "${ZOT_IMAGE_PULL_REF}" "registry.local/zot" "${CODE_REPO_DIR}/.run/zot-image.tar")"

DNS_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/coredns-image.tar"
DNS_IMAGE_REF=""

WORKSPACE_PROVISIONER_PULL_REF="${WORKSPACE_PROVISIONER_IMAGE_REF:-docker.io/alpine/git:latest}"
WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/workspace-provisioner-image.tar"
WORKSPACE_PROVISIONER_IMAGE_REF="$(export_bundled_oci_archive "${WORKSPACE_PROVISIONER_PULL_REF}" "registry.local/workspace-provisioner" "${CODE_REPO_DIR}/.run/workspace-provisioner-image.tar")"
BUNDLED_IMAGE_ARCHIVES+=("${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_FOR_DEV}")
BUNDLED_IMAGE_REFS+=("${WORKSPACE_PROVISIONER_IMAGE_REF}")

if bool_true "${BUILD_COMPLETE_PRODUCT}"; then
  mkdir -p "${CODE_REPO_DIR}/.run/builder-image"
  dest="${CODE_REPO_DIR}/.run/builder-image/dev-build.tar"
  derived_ref="$(export_bundled_oci_archive "${BUILDER_PULL_REF}" "${BUILDER_LOCAL_REF}" "${dest}")"
  BUNDLED_IMAGE_ARCHIVES+=("/workspace/.run/builder-image/dev-build.tar")
  BUNDLED_IMAGE_REFS+=("${derived_ref}")
fi

BUNDLED_IMAGE_ARG_LINES=""
for idx in "${!BUNDLED_IMAGE_ARCHIVES[@]}"; do
  BUNDLED_IMAGE_ARG_LINES+="  BUNDLED_IMAGE_ARGS+=(--extra-oci-image $(shell_quote "${BUNDLED_IMAGE_ARCHIVES[idx]}") --extra-oci-image-reference $(shell_quote "${BUNDLED_IMAGE_REFS[idx]}"))"$'\n'
done

cat >"${CODE_DEV_SCRIPT_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd /workspace
CONTROL_PLANE_IMAGE_OUT="/workspace/.run/control-plane-image.tar"
UI_IMAGE_OUT="/workspace/.run/appliance-ui-image.tar"
HOST_AGENT_IMAGE_OUT="/workspace/.run/appliance-host-agent-image.tar"
HOST_AGENT_IMAGE_REF_FILE="/workspace/.run/appliance-host-agent-image.reference"
ARGO_ARGS=()
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

make package-control-plane-image-archive OUT_FILE="\${CONTROL_PLANE_IMAGE_OUT}" IMAGE_TAG="\${CODE_VERSION}"
make package-ui-image-archive OUT_FILE="\${UI_IMAGE_OUT}" IMAGE_TAG="\${CODE_VERSION}"
make package-host-agent-image-archive \
  OUT_FILE="\${HOST_AGENT_IMAGE_OUT}" \
  REFERENCE_OUT_FILE="\${HOST_AGENT_IMAGE_REF_FILE}" \
  IMAGE_TAG="\${CODE_VERSION}"
HOST_AGENT_IMAGE_REF="\$(tr -d '\r\n' < "\${HOST_AGENT_IMAGE_REF_FILE}")"
# Super-set: always pass host-packages (packages staged at install; services off).
HOST_PACKAGES_ARGS=(
  --host-packages-dir "\${HOST_PACKAGES_DIR_FOR_DEV}"
  --host-packages-os-version "\${HOST_PACKAGES_OS_VERSION}"
)

# Appliance-owned CoreDNS wrapper: tees stdout/stderr into /data/zon/logs/dns.
# Always package from upstream pull ref (no pre-supplied archive path).
make package-coredns-image-archive \
  OUT_FILE="/workspace/.run/coredns-image.tar" \
  DNS_VERSION=$(shell_quote "${DNS_VERSION}") \
  DNS_SOURCE_IMAGE=$(shell_quote "${DNS_IMAGE_PULL_REF}")
DNS_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/coredns-image.tar"
DNS_IMAGE_REF="\$(tr -d '\r\n' </workspace/.run/coredns-image.reference)"


METADATA_BUNDLE_ARCHIVE_FOR_DEV="\$(bash ./scripts/package/generate-metadata-bundle.sh --software-version "\${CODE_VERSION}" --out-dir "/workspace/.run/metadata-bundle")"

if bool_true $(shell_quote "${ARGO_ENABLED}"); then
  ARGO_ARGS+=(--argo-version $(shell_quote "${ARGO_VERSION}"))

  if [[ -n $(shell_quote "${ARGO_CRDS_DIR_FOR_DEV}") ]]; then
    ARGO_ARGS+=(--argo-crds-dir $(shell_quote "${ARGO_CRDS_DIR_FOR_DEV}"))
  fi

  # Always wrap the upstream controller inside the code-repo dev environment.
  make package-argo-controller-image-archive \
    OUT_FILE="/workspace/.run/argo-controller-image.tar" \
    ARGO_VERSION=$(shell_quote "${ARGO_VERSION}") \
    ARGO_CONTROLLER_BASE_IMAGE=$(shell_quote "quay.io/argoproj/workflow-controller:${ARGO_VERSION}")
  ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/argo-controller-image.tar"

  ARGO_ARGS+=(--argo-controller-image "\${ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV}")
  ARGO_ARGS+=(--argo-controller-image-reference $(shell_quote "${ARGO_CONTROLLER_IMAGE_REF}"))

  ARGO_ARGS+=(--argo-executor-image $(shell_quote "${ARGO_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV}"))
  ARGO_ARGS+=(--argo-executor-image-reference $(shell_quote "${ARGO_EXECUTOR_IMAGE_REF}"))
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
  "\${HOST_PACKAGES_ARGS[@]}" \
  --k3s-version $(shell_quote "${K3S_VERSION}") \
  --zot-version $(shell_quote "${ZOT_VERSION}") \
  --zot-image $(shell_quote "${ZOT_IMAGE_ARCHIVE_FOR_DEV}") \
  --zot-image-reference $(shell_quote "${ZOT_IMAGE_REF}") \
  --dns-version $(shell_quote "${DNS_VERSION}") \
  --dns-image "\${DNS_IMAGE_ARCHIVE_FOR_DEV}" \
  --dns-image-reference "\${DNS_IMAGE_REF}" \
  --metadata-bundle "\${METADATA_BUNDLE_ARCHIVE_FOR_DEV}" \
  "\${ARGO_ARGS[@]}" \
  "\${BUNDLED_IMAGE_ARGS[@]}"
EOF
chmod +x "${CODE_DEV_SCRIPT_PATH}"

make -C "${CODE_REPO_DIR}" dev-run SCRIPT="${CODE_DEV_SCRIPT_REL}"
cp "${CODE_RELEASE_INPUT_TAR}" "${RELEASE_INPUT_TAR}"

fetch_k3s_inputs_from_files_api "${INPUTS_DIR}"
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
echo "bundled zot image:"
echo "  ${ZOT_IMAGE_REF}"
echo
echo "generated bundle config:"
echo "  ${WORKSPACE}/generated/product-bundle.env"
echo
echo "exported customer delivery files:"
echo "  ${BUNDLE_ARCHIVE}"
echo "  ${PUBLIC_KEY_EXPORT}"
echo
echo "next publish step on the build machine:"
echo "  # PRODUCT_VERSION defaults from configs/default-product-version"
echo "  # export dir is \$RELEASE_WORK_ROOT/export"
echo "  export RELEASE_WORK_ROOT=${RELEASE_WORK_ROOT}"
echo "  export PUBLISH_MODE=static_http   # or appliance_files"
echo "  export PUBLISH_PATH_PREFIX=appliance"
echo "  export PUBLISH_PUBLIC_BASE_URL=http://downloads.example.internal/releases"
echo "  export PUBLISH_SERVER=<user@host>          # static_http only"
echo "  export PUBLISH_REMOTE_ROOT=/srv/www/releases  # static_http only"
echo "  make publish-release"
echo "optional:"
echo "  PUBLISH_LATEST_ALIAS=1"
echo "  PRODUCT_VERSION=<override>"
