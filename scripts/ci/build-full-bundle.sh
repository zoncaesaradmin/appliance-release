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
  bash ./scripts/ci/build-full-bundle.sh

Argo Workflows is on by default (it is a mandatory component of the
complete v1 appliance per ADR 0011) and needs no configuration: its
version and controller/executor image references are derived
automatically from appliance-code's own
deploy/charts/argo-workflows/Chart.yaml (the chart's pinned appVersion),
and its CRDs are fetched automatically from the matching upstream Argo
Workflows GitHub release unless you provide a local copy. You never need
to set an Argo version yourself.

Optional overrides:
  CODE_REPO_REF=main
  CTL_REPO_REF=main
  WORK_ROOT=${TMPDIR:-/tmp}/appliance-build
  EXPORT_DIR=\$WORK_ROOT/export
  K3S_VERSION_OVERRIDE=v1.30.4+k3s1
  HELM_VERSION=v3.21.1
  HELM_BINARY=/abs/path/to/linux-amd64/helm
  VALUES_FILE_SOURCE=/ci/inputs/values-minimal.yaml
  ARGO_ENABLED=0                    # opt out entirely (control-plane-only debug build)
  ARGO_CRDS_DIR_SOURCE=/ci/inputs/argo-crds   # use a local/offline CRD copy instead of fetching from GitHub
  ARGO_VERSION=v3.5.10                        # pin a different Argo version than the chart's appVersion
  ARGO_CONTROLLER_IMAGE_REF=localhost/appliance-argo-controller:v3.5.10
  ARGO_EXECUTOR_IMAGE_REF=quay.io/argoproj/argoexec:v3.5.10
  WORKSPACE_PROVISIONER_IMAGE_REF=docker.io/alpine/git:latest
  WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE=/ci/inputs/workspace-provisioner.oci.tar
  # When WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE is omitted, WORKSPACE_PROVISIONER_IMAGE_REF
  # is the upstream pull ref (default docker.io/alpine/git:latest). The build copies the
  # linux/amd64 image, then sets registry.local/workspace-provisioner@sha256:<archived
  # platform manifest digest> from the archive contents (never from skopeo inspect).
  EXTRA_OCI_IMAGE_ARCHIVE_SOURCES=/ci/inputs/buildah.tar,/ci/inputs/tooling.tar
  EXTRA_OCI_IMAGE_REFS=registry.local/buildah@sha256:...,registry.local/tooling@sha256:...
  EXTRA_OCI_IMAGE_PULL_REFS=ghcr.io/org/automation-dev:v0.1.0
  # EXTRA_OCI_IMAGE_REFS names the local registry.local/... reference. Digests in those
  # refs are optional advisory pins; the archived platform manifest digest always wins.
  ZOT_VERSION=2.1.8
  ZOT_IMAGE_PULL_REF=ghcr.io/project-zot/zot-linux-amd64:v2.1.8
  ZOT_IMAGE_ARCHIVE_SOURCE=/ci/inputs/zot.oci.tar
  # Zot is a first-class release artifact, not an EXTRA_OCI image. Online builds
  # copy linux/amd64 on the build host; offline builds may supply an archive.
  # Both paths derive registry.local/zot@sha256:<platform-digest> from index.json.
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
USER_HELM_VERSION="${HELM_VERSION-}"
USER_VALUES_FILE_SOURCE="${VALUES_FILE_SOURCE-}"
USER_WORK_ROOT="${WORK_ROOT-}"
USER_EXPORT_DIR="${EXPORT_DIR-}"
USER_K3S_VERSION_OVERRIDE="${K3S_VERSION_OVERRIDE-}"
USER_ARGO_ENABLED="${ARGO_ENABLED-}"
USER_ARGO_REQUIRED="${ARGO_REQUIRED-}"
USER_ARGO_VERSION="${ARGO_VERSION-}"
USER_ARGO_CRDS_DIR_SOURCE="${ARGO_CRDS_DIR_SOURCE-}"
USER_ARGO_CONTROLLER_IMAGE_REF="${ARGO_CONTROLLER_IMAGE_REF-}"
USER_ARGO_EXECUTOR_IMAGE_REF="${ARGO_EXECUTOR_IMAGE_REF-}"
USER_ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE="${ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE-}"
USER_ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE="${ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE-}"
USER_WORKSPACE_PROVISIONER_IMAGE_REF="${WORKSPACE_PROVISIONER_IMAGE_REF-}"
USER_WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE="${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE-}"
USER_ZOT_VERSION="${ZOT_VERSION-}"
USER_ZOT_IMAGE_PULL_REF="${ZOT_IMAGE_PULL_REF-}"
USER_ZOT_IMAGE_ARCHIVE_SOURCE="${ZOT_IMAGE_ARCHIVE_SOURCE-}"
USER_EXTRA_OCI_IMAGE_ARCHIVE_SOURCES="${EXTRA_OCI_IMAGE_ARCHIVE_SOURCES-}"
USER_EXTRA_OCI_IMAGE_REFS="${EXTRA_OCI_IMAGE_REFS-}"
USER_EXTRA_OCI_IMAGE_PULL_REFS="${EXTRA_OCI_IMAGE_PULL_REFS-}"

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
HELM_VERSION="${USER_HELM_VERSION:-${HELM_VERSION:-}}"
VALUES_FILE_SOURCE="${USER_VALUES_FILE_SOURCE:-${VALUES_FILE:-}}"
WORK_ROOT="${USER_WORK_ROOT:-${WORKDIR:-${TMPDIR:-/tmp}/appliance-build}}"
EXPORT_DIR="${USER_EXPORT_DIR:-${EXPORT_DIR:-${WORK_ROOT}/export}}"
K3S_VERSION_OVERRIDE="${USER_K3S_VERSION_OVERRIDE:-}"
ARGO_ENABLED="${USER_ARGO_ENABLED:-${ARGO_ENABLED:-}}"
ARGO_REQUIRED="${USER_ARGO_REQUIRED:-${ARGO_REQUIRED:-}}"
ARGO_VERSION="${USER_ARGO_VERSION:-${ARGO_VERSION:-}}"
ARGO_CRDS_DIR_SOURCE="${USER_ARGO_CRDS_DIR_SOURCE:-${ARGO_CRDS_DIR_SOURCE:-}}"
ARGO_CONTROLLER_IMAGE_REF="${USER_ARGO_CONTROLLER_IMAGE_REF:-${ARGO_CONTROLLER_IMAGE_REF:-}}"
ARGO_EXECUTOR_IMAGE_REF="${USER_ARGO_EXECUTOR_IMAGE_REF:-${ARGO_EXECUTOR_IMAGE_REF:-}}"
ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE="${USER_ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE:-${ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE:-}}"
ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE="${USER_ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE:-${ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE:-}}"
WORKSPACE_PROVISIONER_IMAGE_REF="${USER_WORKSPACE_PROVISIONER_IMAGE_REF:-${WORKSPACE_PROVISIONER_IMAGE_REF:-docker.io/alpine/git:latest}}"
WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE="${USER_WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE:-${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE:-}}"
ZOT_VERSION="${USER_ZOT_VERSION:-${ZOT_VERSION:-2.1.8}}"
ZOT_IMAGE_PULL_REF="${USER_ZOT_IMAGE_PULL_REF:-${ZOT_IMAGE_PULL_REF:-ghcr.io/project-zot/zot-linux-amd64:v${ZOT_VERSION}}}"
ZOT_IMAGE_ARCHIVE_SOURCE="${USER_ZOT_IMAGE_ARCHIVE_SOURCE:-${ZOT_IMAGE_ARCHIVE_SOURCE:-}}"
EXTRA_OCI_IMAGE_ARCHIVE_SOURCES="${USER_EXTRA_OCI_IMAGE_ARCHIVE_SOURCES:-${EXTRA_OCI_IMAGE_ARCHIVE_SOURCES:-}}"
EXTRA_OCI_IMAGE_REFS="${USER_EXTRA_OCI_IMAGE_REFS:-${EXTRA_OCI_IMAGE_REFS:-}}"
EXTRA_OCI_IMAGE_PULL_REFS="${USER_EXTRA_OCI_IMAGE_PULL_REFS:-${EXTRA_OCI_IMAGE_PULL_REFS:-}}"

# Argo Workflows is a mandatory component of the complete v1 appliance
# (ADR 0011 in appliance-code), so it is on by default. ARGO_VERSION is
# derived later from appliance-code's own deploy/charts/argo-workflows/
# Chart.yaml (the chart's pinned appVersion is the single source of
# truth), once that repo is cloned. The appliance-owned controller
# wrapper image reference is then derived from that version.
if [[ -z "${ARGO_ENABLED}" ]]; then
  ARGO_ENABLED="true"
fi

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

bool_true() {
  local value="${1:-}"
  case "$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

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

oci_image_repository() {
  local ref="${1#docker://}"
  if [[ "${ref}" == *@sha256:* ]]; then
    printf '%s' "${ref%@sha256:*}"
    return
  fi
  if [[ "${ref}" =~ ^(.+):([^:/]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  printf '%s' "${ref}"
}

# Strip optional @sha256:... from a bundle imageReference, leaving the local name
# (e.g. registry.local/automation-dev).
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
    try:
        idx = json.load(tar.extractfile("index.json"))
    except KeyError as exc:
        raise SystemExit(f"oci archive {archive} is missing index.json") from exc
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
    for member in members:
        if member.isfile():
            extracted = tar.extractfile(member)
            if extracted is None:
                raise SystemExit(f"failed to read {member.name} from {archive}")
            files[member.name] = extracted.read()

if "index.json" not in files:
    raise SystemExit(f"oci archive {archive} is missing index.json")

index = json.loads(files["index.json"])
manifests = index.get("manifests") or []
if not manifests:
    raise SystemExit(f"oci archive {archive} has no manifests in index.json")

annotations = dict(manifests[0].get("annotations") or {})
annotations["org.opencontainers.image.ref.name"] = annotation_ref
manifests[0]["annotations"] = annotations
index["manifests"] = manifests
files["index.json"] = json.dumps(index, separators=(",", ":"), sort_keys=False).encode("utf-8")

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
    try:
        idx = json.load(tar.extractfile("index.json"))
    except KeyError as exc:
        raise SystemExit(f"oci archive {archive} is missing index.json") from exc
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

skopeo_copy_oci_archive() {
  local source_ref="$1"
  local output_path="$2"
  local dest_name="$3"
  local skopeo_bin podman_bin auth_file skopeo_image
  local -a overrides=(--override-os "${BUNDLE_IMAGE_OS}" --override-arch "${BUNDLE_IMAGE_ARCH}")
  local -a copy_cmd

  mkdir -p "$(dirname "${output_path}")"
  rm -f "${output_path}"

  skopeo_bin="$(command -v skopeo || true)"
  if [[ -n "${skopeo_bin}" ]]; then
    copy_cmd=(sudo -n "${skopeo_bin}" copy "${overrides[@]}" "docker://${source_ref#docker://}" "oci-archive:${output_path}:${dest_name}")
  else
    podman_bin="$(command -v podman || true)"
    if [[ -z "${podman_bin}" ]]; then
      cat >&2 <<EOF
build-full-bundle: skopeo or podman is required to export ${dest_name} from ${source_ref}
build-full-bundle: install skopeo on the build host, or pre-export the archive and set EXTRA_OCI_IMAGE_ARCHIVE_SOURCES / WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE instead
EOF
      exit 1
    fi
    skopeo_image="quay.io/skopeo/stable:latest"
    auth_file="${HOME}/.config/containers/auth.json"
    copy_cmd=(
      sudo -n "${podman_bin}" run --rm
      -v "${auth_file}:/tmp/auth.json:ro,Z"
      -v "$(dirname "${output_path}"):/out:Z"
      "${skopeo_image}"
      copy --authfile /tmp/auth.json
      "${overrides[@]}"
      "docker://${source_ref#docker://}"
      "oci-archive:/out/$(basename "${output_path}"):${dest_name}"
    )
  fi

  if ! "${copy_cmd[@]}" >/dev/null; then
    cat >&2 <<EOF
build-full-bundle: failed to export ${dest_name} from ${source_ref}
build-full-bundle: ensure the build host can pull the image (make dev-registry-login in appliance-code for GHCR) or pre-export the archive locally
EOF
    exit 1
  fi
}

# Finalize any OCI archive (online copy or pre-exported) so imageReference equals
# the archived platform manifest digest. Prints the canonical bundle ref.
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

# Online export: copy pull_ref for the appliance platform, then label from content.
# optional_expected_ref, when set, is only an advisory pin (name + optional digest).
export_bundled_extra_oci_image_archive() {
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

require_var PRODUCT_VERSION
require_var CODE_REPO_SOURCE
require_var CTL_REPO_SOURCE
require_var K3S_VERSION
require_var K3S_BINARY_SOURCE
require_var K3S_AIRGAP_IMAGES_SOURCE

warn_if_local_repo_source "${CODE_REPO_SOURCE}" "CODE_REPO"
warn_if_local_repo_source "${CTL_REPO_SOURCE}" "CTL_REPO"

require_file "${K3S_BINARY_SOURCE}" "k3s binary"
require_file "${K3S_AIRGAP_IMAGES_SOURCE}" "k3s airgap images"
if [[ -n "${VALUES_FILE_SOURCE}" ]]; then
  require_file "${VALUES_FILE_SOURCE}" "values file"
fi
if [[ -n "${ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE}" ]]; then
  require_file "${ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE}" "Argo controller image archive"
fi
if [[ -n "${ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE}" ]]; then
  require_file "${ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE}" "Argo executor image archive"
fi
if [[ -n "${ARGO_CRDS_DIR_SOURCE}" && ! -d "${ARGO_CRDS_DIR_SOURCE}" ]]; then
  echo "build-full-bundle: missing Argo CRDs directory: ${ARGO_CRDS_DIR_SOURCE}" >&2
  exit 1
fi
if [[ -n "${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE}" ]]; then
  require_file "${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE}" "workspace provisioner image archive"
  if [[ -n "${WORKSPACE_PROVISIONER_IMAGE_REF}" && "${WORKSPACE_PROVISIONER_IMAGE_REF}" != registry.local/workspace-provisioner && "${WORKSPACE_PROVISIONER_IMAGE_REF}" != registry.local/workspace-provisioner@sha256:* ]]; then
    echo "build-full-bundle: WORKSPACE_PROVISIONER_IMAGE_REF must be registry.local/workspace-provisioner[@sha256:...] when WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE is provided (digest is derived from the archive)" >&2
    exit 2
  fi
fi
if [[ -z "${ZOT_VERSION}" || "${ZOT_VERSION}" == *latest* ]]; then
  echo "build-full-bundle: ZOT_VERSION must be an exact non-latest version" >&2
  exit 2
fi
if [[ -n "${ZOT_IMAGE_ARCHIVE_SOURCE}" ]]; then
  require_file "${ZOT_IMAGE_ARCHIVE_SOURCE}" "zot image archive"
elif [[ "${ZOT_IMAGE_PULL_REF}" == *:latest || "${ZOT_IMAGE_PULL_REF}" == registry.local/* ]]; then
  echo "build-full-bundle: ZOT_IMAGE_PULL_REF must be a version-pinned upstream image when no archive is supplied" >&2
  exit 2
fi

EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST=()
EXTRA_OCI_IMAGE_REF_LIST=()
EXTRA_OCI_IMAGE_PULL_REF_LIST=()
split_csv "${EXTRA_OCI_IMAGE_ARCHIVE_SOURCES}" EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST
split_csv "${EXTRA_OCI_IMAGE_REFS}" EXTRA_OCI_IMAGE_REF_LIST
split_csv "${EXTRA_OCI_IMAGE_PULL_REFS}" EXTRA_OCI_IMAGE_PULL_REF_LIST
if [[ ${#EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[@]} -gt 0 && ${#EXTRA_OCI_IMAGE_PULL_REF_LIST[@]} -gt 0 ]]; then
  echo "build-full-bundle: set either EXTRA_OCI_IMAGE_ARCHIVE_SOURCES or EXTRA_OCI_IMAGE_PULL_REFS, not both" >&2
  exit 2
fi
if [[ ${#EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[@]} -gt 0 ]]; then
  if [[ ${#EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[@]} -ne ${#EXTRA_OCI_IMAGE_REF_LIST[@]} ]]; then
    echo "build-full-bundle: EXTRA_OCI_IMAGE_ARCHIVE_SOURCES and EXTRA_OCI_IMAGE_REFS must have the same comma-separated length" >&2
    exit 2
  fi
  for idx in "${!EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[@]}"; do
    if [[ -z "${EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[idx]}" || -z "${EXTRA_OCI_IMAGE_REF_LIST[idx]}" ]]; then
      echo "build-full-bundle: extra OCI image archive sources and refs must not contain empty entries" >&2
      exit 2
    fi
    require_file "${EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[idx]}" "extra OCI image archive"
    local_name="$(oci_bundle_local_name "${EXTRA_OCI_IMAGE_REF_LIST[idx]}")"
    if [[ "${local_name}" != registry.local/* ]]; then
      echo "build-full-bundle: EXTRA_OCI_IMAGE_REFS[${idx}] must be a registry.local/... name (optional @sha256 digest is derived from the archived platform manifest)" >&2
      exit 2
    fi
  done
elif [[ ${#EXTRA_OCI_IMAGE_PULL_REF_LIST[@]} -gt 0 ]]; then
  if [[ ${#EXTRA_OCI_IMAGE_PULL_REF_LIST[@]} -ne ${#EXTRA_OCI_IMAGE_REF_LIST[@]} ]]; then
    echo "build-full-bundle: EXTRA_OCI_IMAGE_PULL_REFS and EXTRA_OCI_IMAGE_REFS must have the same comma-separated length" >&2
    exit 2
  fi
  for idx in "${!EXTRA_OCI_IMAGE_PULL_REF_LIST[@]}"; do
    if [[ -z "${EXTRA_OCI_IMAGE_PULL_REF_LIST[idx]}" || -z "${EXTRA_OCI_IMAGE_REF_LIST[idx]}" ]]; then
      echo "build-full-bundle: extra OCI image pull refs and bundle refs must not contain empty entries" >&2
      exit 2
    fi
    local_name="$(oci_bundle_local_name "${EXTRA_OCI_IMAGE_REF_LIST[idx]}")"
    if [[ "${local_name}" != registry.local/* ]]; then
      echo "build-full-bundle: EXTRA_OCI_IMAGE_REFS[${idx}] must be a registry.local/... name (optional @sha256 digest is derived from the archived platform manifest)" >&2
      exit 2
    fi
  done
elif [[ ${#EXTRA_OCI_IMAGE_REF_LIST[@]} -gt 0 ]]; then
  echo "build-full-bundle: EXTRA_OCI_IMAGE_REFS is set without matching EXTRA_OCI_IMAGE_ARCHIVE_SOURCES or EXTRA_OCI_IMAGE_PULL_REFS" >&2
  exit 2
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

ZOT_CHART_APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "${CODE_REPO_DIR}/deploy/charts/appliance-registry/Chart.yaml")"
if [[ -z "${ZOT_CHART_APP_VERSION}" || "${ZOT_CHART_APP_VERSION}" != "${ZOT_VERSION}" ]]; then
  echo "build-full-bundle: ZOT_VERSION ${ZOT_VERSION} must match appliance-registry chart appVersion ${ZOT_CHART_APP_VERSION:-<missing>}" >&2
  exit 2
fi

require_appliance_code_bootstrap

if bool_true "${ARGO_ENABLED}"; then
  if [[ -z "${ARGO_VERSION}" ]]; then
    ARGO_VERSION="$(derive_argo_version_from_code_repo)"
  fi
  if [[ -z "${ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE}" && -z "${ARGO_CONTROLLER_IMAGE_REF}" ]]; then
    ARGO_CONTROLLER_IMAGE_REF="localhost/appliance-argo-controller:${ARGO_VERSION}"
  fi
  if [[ -z "${ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE}" && -z "${ARGO_EXECUTOR_IMAGE_REF}" ]]; then
    ARGO_EXECUTOR_IMAGE_REF="quay.io/argoproj/argoexec:${ARGO_VERSION}"
  fi
fi

mkdir -p "${CODE_REPO_DIR}/.run"

ARGO_CRDS_DIR_FOR_DEV=""
ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV=""
ARGO_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV=""

if bool_true "${ARGO_ENABLED}"; then
  if [[ -n "${ARGO_CRDS_DIR_SOURCE}" ]]; then
    ARGO_CRDS_DIR_FOR_DEV="/workspace/.run/argo-crds"
    rm -rf "${CODE_REPO_DIR}/.run/argo-crds"
    mkdir -p "${CODE_REPO_DIR}/.run/argo-crds"
    cp -R "${ARGO_CRDS_DIR_SOURCE}/." "${CODE_REPO_DIR}/.run/argo-crds/"
  elif bool_true "${ARGO_REQUIRED:-true}"; then
    ARGO_CRDS_DIR_FOR_DEV="/workspace/.run/argo-crds"
    fetch_argo_crds_from_release "${ARGO_VERSION}" "${CODE_REPO_DIR}/.run/argo-crds"
  fi

  if [[ -n "${ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE}" ]]; then
    ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/argo-controller-image.tar"
    cp "${ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE}" "${CODE_REPO_DIR}/.run/argo-controller-image.tar"
  fi

  if [[ -n "${ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE}" ]]; then
    ARGO_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/argo-executor-image.tar"
    cp "${ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE}" "${CODE_REPO_DIR}/.run/argo-executor-image.tar"
  else
    ARGO_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/argo-executor-image.tar"
    export_container_image_archive "${ARGO_EXECUTOR_IMAGE_REF}" "${CODE_REPO_DIR}/.run/argo-executor-image.tar"
  fi
fi

# Build the final archive/reference pairs carefully. EXTRA_OCI_IMAGE_REF_LIST is
# the user-configured extra refs only (e.g. automation-dev). Do not append the
# workspace provisioner ref onto that list before pairing archives, or the
# provisioner archive will be labeled with the automation-dev reference and
# install-time ctr import will fail RequireReference checks.
PACKAGED_EXTRA_OCI_IMAGE_ARCHIVES=()
PACKAGED_EXTRA_OCI_IMAGE_REFS=()

ZOT_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/zot-image.tar"
if [[ -n "${ZOT_IMAGE_ARCHIVE_SOURCE}" ]]; then
  cp "${ZOT_IMAGE_ARCHIVE_SOURCE}" "${CODE_REPO_DIR}/.run/zot-image.tar"
  ZOT_IMAGE_REF="$(finalize_bundled_oci_archive "${CODE_REPO_DIR}/.run/zot-image.tar" "registry.local/zot")"
else
  ZOT_IMAGE_REF="$(export_bundled_extra_oci_image_archive "${ZOT_IMAGE_PULL_REF}" "registry.local/zot" "${CODE_REPO_DIR}/.run/zot-image.tar")"
fi

if [[ -n "${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE}" ]]; then
  WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/workspace-provisioner-image.tar"
  cp "${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE}" "${CODE_REPO_DIR}/.run/workspace-provisioner-image.tar"
  WORKSPACE_PROVISIONER_IMAGE_REF="$(finalize_bundled_oci_archive "${CODE_REPO_DIR}/.run/workspace-provisioner-image.tar" "registry.local/workspace-provisioner" "${WORKSPACE_PROVISIONER_IMAGE_REF:-}")"
else
  WORKSPACE_PROVISIONER_PULL_REF="${WORKSPACE_PROVISIONER_IMAGE_REF:-docker.io/alpine/git:latest}"
  if [[ "${WORKSPACE_PROVISIONER_PULL_REF}" == registry.local/workspace-provisioner || "${WORKSPACE_PROVISIONER_PULL_REF}" == registry.local/workspace-provisioner@sha256:* ]]; then
    echo "build-full-bundle: online workspace provisioner export uses WORKSPACE_PROVISIONER_IMAGE_REF as an upstream pull ref (default docker.io/alpine/git:latest); got bundle name ${WORKSPACE_PROVISIONER_PULL_REF}" >&2
    echo "build-full-bundle: set WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE when supplying a pre-exported registry.local/workspace-provisioner archive" >&2
    exit 2
  fi
  WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/workspace-provisioner-image.tar"
  WORKSPACE_PROVISIONER_IMAGE_REF="$(export_bundled_extra_oci_image_archive "${WORKSPACE_PROVISIONER_PULL_REF}" "registry.local/workspace-provisioner" "${CODE_REPO_DIR}/.run/workspace-provisioner-image.tar")"
fi
PACKAGED_EXTRA_OCI_IMAGE_ARCHIVES+=("${WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_FOR_DEV}")
PACKAGED_EXTRA_OCI_IMAGE_REFS+=("${WORKSPACE_PROVISIONER_IMAGE_REF}")

if [[ ${#EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[@]} -gt 0 ]]; then
  mkdir -p "${CODE_REPO_DIR}/.run/extra-oci-images"
  for idx in "${!EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[@]}"; do
    dest="${CODE_REPO_DIR}/.run/extra-oci-images/extra-oci-image-${idx}.tar"
    cp "${EXTRA_OCI_IMAGE_ARCHIVE_SOURCE_LIST[idx]}" "${dest}"
    derived_ref="$(finalize_bundled_oci_archive "${dest}" "${EXTRA_OCI_IMAGE_REF_LIST[idx]}" "${EXTRA_OCI_IMAGE_REF_LIST[idx]}")"
    PACKAGED_EXTRA_OCI_IMAGE_ARCHIVES+=("/workspace/.run/extra-oci-images/extra-oci-image-${idx}.tar")
    PACKAGED_EXTRA_OCI_IMAGE_REFS+=("${derived_ref}")
  done
elif [[ ${#EXTRA_OCI_IMAGE_PULL_REF_LIST[@]} -gt 0 ]]; then
  mkdir -p "${CODE_REPO_DIR}/.run/extra-oci-images"
  for idx in "${!EXTRA_OCI_IMAGE_PULL_REF_LIST[@]}"; do
    dest="${CODE_REPO_DIR}/.run/extra-oci-images/extra-oci-image-${idx}.tar"
    derived_ref="$(export_bundled_extra_oci_image_archive "${EXTRA_OCI_IMAGE_PULL_REF_LIST[idx]}" "${EXTRA_OCI_IMAGE_REF_LIST[idx]}" "${dest}")"
    PACKAGED_EXTRA_OCI_IMAGE_ARCHIVES+=("/workspace/.run/extra-oci-images/extra-oci-image-${idx}.tar")
    PACKAGED_EXTRA_OCI_IMAGE_REFS+=("${derived_ref}")
  done
fi

if [[ ${#PACKAGED_EXTRA_OCI_IMAGE_ARCHIVES[@]} -ne ${#PACKAGED_EXTRA_OCI_IMAGE_REFS[@]} ]]; then
  echo "build-full-bundle: internal error: packaged extra OCI archives (${#PACKAGED_EXTRA_OCI_IMAGE_ARCHIVES[@]}) and refs (${#PACKAGED_EXTRA_OCI_IMAGE_REFS[@]}) length mismatch" >&2
  exit 1
fi

EXTRA_OCI_ARG_LINES=""
for idx in "${!PACKAGED_EXTRA_OCI_IMAGE_ARCHIVES[@]}"; do
  EXTRA_OCI_ARG_LINES+="  EXTRA_OCI_ARGS+=(--extra-oci-image $(shell_quote "${PACKAGED_EXTRA_OCI_IMAGE_ARCHIVES[idx]}") --extra-oci-image-reference $(shell_quote "${PACKAGED_EXTRA_OCI_IMAGE_REFS[idx]}"))"$'\n'
done

cat >"${CODE_DEV_SCRIPT_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd /workspace
CONTROL_PLANE_IMAGE_OUT="/workspace/.run/control-plane-image.tar"
UI_IMAGE_OUT="/workspace/.run/appliance-ui-image.tar"
ARGO_ARGS=()
EXTRA_OCI_ARGS=()
CODE_VERSION="\${CODE_VERSION:-\$(git describe --tags --always --dirty 2>/dev/null | sed 's/[^A-Za-z0-9_.-]/-/g')}"

bool_true() {
  local value="\${1:-}"
  case "\$(printf '%s' "\${value}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

make package-control-plane-image-archive OUT_FILE="\${CONTROL_PLANE_IMAGE_OUT}"
make package-ui-image-archive OUT_FILE="\${UI_IMAGE_OUT}"

if bool_true $(shell_quote "${ARGO_ENABLED}"); then
  ARGO_ARGS+=(--argo-version $(shell_quote "${ARGO_VERSION}"))

  if [[ -n $(shell_quote "${ARGO_CRDS_DIR_FOR_DEV}") ]]; then
    ARGO_ARGS+=(--argo-crds-dir $(shell_quote "${ARGO_CRDS_DIR_FOR_DEV}"))
  fi

  if [[ -z $(shell_quote "${ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV}") ]]; then
    make package-argo-controller-image-archive \
      OUT_FILE="/workspace/.run/argo-controller-image.tar" \
      ARGO_VERSION=$(shell_quote "${ARGO_VERSION}") \
      ARGO_CONTROLLER_BASE_IMAGE=$(shell_quote "quay.io/argoproj/workflow-controller:${ARGO_VERSION}")
    ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV="/workspace/.run/argo-controller-image.tar"
  else
    ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV=$(shell_quote "${ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV}")
  fi

  ARGO_ARGS+=(--argo-controller-image "\${ARGO_CONTROLLER_IMAGE_ARCHIVE_FOR_DEV}")
  ARGO_ARGS+=(--argo-controller-image-reference $(shell_quote "${ARGO_CONTROLLER_IMAGE_REF}"))

  ARGO_ARGS+=(--argo-executor-image $(shell_quote "${ARGO_EXECUTOR_IMAGE_ARCHIVE_FOR_DEV}"))
  ARGO_ARGS+=(--argo-executor-image-reference $(shell_quote "${ARGO_EXECUTOR_IMAGE_REF}"))
fi

${EXTRA_OCI_ARG_LINES}

bash ./scripts/package/archive-release-input.sh \
  --out-file "/workspace/.run/release-input-${PRODUCT_VERSION}.tar.gz" \
  --code-version "\${CODE_VERSION}" \
  --control-plane-image "\${CONTROL_PLANE_IMAGE_OUT}" \
  --control-plane-image-reference "localhost/appliance-control-plane:\${CODE_VERSION}" \
  --ui-image "\${UI_IMAGE_OUT}" \
  --ui-image-reference "localhost/appliance-ui:\${CODE_VERSION}" \
  --k3s-version $(shell_quote "${K3S_VERSION}") \
  --zot-version $(shell_quote "${ZOT_VERSION}") \
  --zot-image $(shell_quote "${ZOT_IMAGE_ARCHIVE_FOR_DEV}") \
  --zot-image-reference $(shell_quote "${ZOT_IMAGE_REF}") \
  "\${ARGO_ARGS[@]}" \
  "\${EXTRA_OCI_ARGS[@]}"
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
