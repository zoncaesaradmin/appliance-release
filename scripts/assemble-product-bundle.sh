#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: assemble-product-bundle.sh --config PATH

Runs the complete product bundle flow from a single config file:
init workspace → import release-input → assemble → verify.
EOF
}

CONFIG_PATH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/appliance-packs.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "assemble-product-bundle: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${CONFIG_PATH}" ]]; then
  echo "assemble-product-bundle: --config is required" >&2
  usage >&2
  exit 2
fi

CONFIG_PATH="$(cd "$(dirname "${CONFIG_PATH}")" && pwd)/$(basename "${CONFIG_PATH}")"
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "assemble-product-bundle: missing config: ${CONFIG_PATH}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${CONFIG_PATH}"
set +a

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "assemble-product-bundle: config must set ${name}" >&2
    exit 1
  fi
}

require_var WORKDIR
require_var CTL_REPO_SOURCE
require_var PRODUCT_VERSION
require_var K3S_VERSION

WORKDIR="$(cd "$(dirname "${WORKDIR}")" && pwd)/$(basename "${WORKDIR}")"
SAMPLE_MODE="${SAMPLE_MODE:-0}"
INPUTS_DIR="${INPUTS_DIR:-${WORKDIR}/inputs}"
CHART_VERSION="${CHART_VERSION:-${PRODUCT_VERSION}}"
OS_VERSION="${OS_VERSION:-24.04}"
RELEASE_INPUT_SOURCE="${RELEASE_INPUT_SOURCE:-}"
RELEASE_INPUT_VERSION="${RELEASE_INPUT_VERSION:-}"
RELEASE_INPUT_FETCH_TEMPLATE="${RELEASE_INPUT_FETCH_TEMPLATE:-}"
CONTROL_PLANE_IMAGE="${CONTROL_PLANE_IMAGE:-}"
WORKFLOWS_VERSION="${WORKFLOWS_VERSION:-}"
WORKFLOW_CONTROLLER_IMAGE_REF="${WORKFLOW_CONTROLLER_IMAGE_REF:-}"
WORKFLOW_EXECUTOR_IMAGE_REF="${WORKFLOW_EXECUTOR_IMAGE_REF:-}"
K3S_BINARY="${K3S_BINARY:-${INPUTS_DIR}/k3s}"
K3S_AIRGAP_IMAGES="${K3S_AIRGAP_IMAGES:-${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst}"
HELM_BINARY="${HELM_BINARY:-}"
HELM_VERSION="${HELM_VERSION:-v3.21.1}"
HELM_DOWNLOAD_BASE_URL="${HELM_DOWNLOAD_BASE_URL:-https://get.helm.sh}"
DOWNLOADS_DIR="${WORKDIR}/downloads"
STAGING_DIR="${WORKDIR}/staging"
RELEASE_INPUT_DIR="${WORKDIR}/release-input"
BUNDLE_DIR="${WORKDIR}/out/appliance-${PRODUCT_VERSION}-foundation"
DEVELOPER_BUNDLE_DIR="${WORKDIR}/out/appliance-${PRODUCT_VERSION}-developer"
DEVICEUSER_BUNDLE_DIR="${WORKDIR}/out/appliance-${PRODUCT_VERSION}-deviceuser"
INFERENCE_BUNDLE_DIR="${WORKDIR}/out/appliance-${PRODUCT_VERSION}-inference"

mkdir -p "${WORKDIR}" "${INPUTS_DIR}" "${DOWNLOADS_DIR}"

create_sample_release_input() {
  local sample_root="${DOWNLOADS_DIR}/sample-release-input"
  local archive_path="${DOWNLOADS_DIR}/release-input-${PRODUCT_VERSION}.tar.gz"

  if [[ -z "${CONTROL_PLANE_IMAGE_REF}" ]]; then
    CONTROL_PLANE_IMAGE_REF="internal/control-plane-api:${PRODUCT_VERSION}"
  fi

  python3 - "${sample_root}" "${archive_path}" "${PRODUCT_VERSION}" "${CHART_VERSION}" "${K3S_VERSION}" "${CONTROL_PLANE_IMAGE_REF}" "${WORKFLOWS_VERSION}" "${WORKFLOW_CONTROLLER_IMAGE_REF}" "${WORKFLOW_EXECUTOR_IMAGE_REF}" <<'PY'
import hashlib
import json
import shutil
import sys
import tarfile
from pathlib import Path

sample_root = Path(sys.argv[1])
archive_path = Path(sys.argv[2])
product_version = sys.argv[3]
chart_version = sys.argv[4]
k3s_version = sys.argv[5]
control_plane_image_ref = sys.argv[6]
workflows_version = sys.argv[7]
workflow_controller_image_ref = sys.argv[8]
workflow_executor_image_ref = sys.argv[9]
ui_image_ref = f"internal/appliance-ui:{product_version}"

if sample_root.exists():
    shutil.rmtree(sample_root)
sample_root.mkdir(parents=True)

control_plane_name = f"control-plane-api-{product_version}.tar"
ui_name = f"appliance-ui-{product_version}.tar"
chart_name = f"appliance-chart-{product_version}.tgz"
schema_name = "configuration.schema.json"
compatibility_name = "compatibility.json"
checksums_name = "checksums.txt"

compatibility = {
    "k3sVersion": k3s_version,
    "chartVersion": chart_version,
    "supportedUpgradeSources": [],
}
if workflows_version:
    compatibility["workflowsVersion"] = workflows_version

control_plane_bytes = b"control-plane-image\n"
ui_bytes = b"appliance-ui-image\n"
blob_storage_name = "blob-storage.oci.tar.zst"
blob_storage_bytes = b"blob-storage-image\n"
schema_bytes = b'{\n  "$schema": "https://json-schema.org/draft/2020-12/schema",\n  "type": "object"\n}\n'
compatibility_bytes = (json.dumps(compatibility, indent=2) + "\n").encode("utf-8")
checksums_bytes = b"sample checksums placeholder\n"

(sample_root / control_plane_name).write_bytes(control_plane_bytes)
(sample_root / ui_name).write_bytes(ui_bytes)
(sample_root / blob_storage_name).write_bytes(blob_storage_bytes)
(sample_root / schema_name).write_bytes(schema_bytes)
(sample_root / compatibility_name).write_bytes(compatibility_bytes)
(sample_root / checksums_name).write_bytes(checksums_bytes)

for dirname, content in {
    "sbom": b"sample sbom placeholder\n",
    "provenance": b"sample provenance placeholder\n",
    "notices": b"sample notices placeholder\n",
    "tests": b"sample tests placeholder\n",
}.items():
    path = sample_root / dirname
    path.mkdir(parents=True, exist_ok=True)
    (path / "README.txt").write_bytes(content)

chart_src = sample_root / "chart" / "appliance"
chart_src.mkdir(parents=True, exist_ok=True)
(chart_src / "Chart.yaml").write_text(
    "\n".join(
        [
            "apiVersion: v2",
            "name: appliance",
            f"version: {chart_version}",
            f"appVersion: {product_version}",
            "type: application",
            "",
        ]
    ),
    encoding="utf-8",
)
(chart_src / "values.yaml").write_text(
    "\n".join(
        [
            "image:",
            f"  repository: {control_plane_image_ref.rsplit(':', 1)[0]}",
            f'  tag: "{control_plane_image_ref.rsplit(":", 1)[1]}"',
            "ui:",
            "  enabled: true",
            "  image:",
            f"    repository: {ui_image_ref.rsplit(':', 1)[0]}",
            f'    tag: "{ui_image_ref.rsplit(":", 1)[1]}"',
            "",
        ]
    ),
    encoding="utf-8",
)
with tarfile.open(sample_root / chart_name, "w:gz") as tf:
    tf.add(chart_src, arcname="appliance")
shutil.rmtree(sample_root / "chart")

workflows_chart_name = ""
workflow_controller_name = ""
workflow_executor_name = ""
workflows_crds_name = ""
if workflows_version:
    workflows_chart_name = f"workflows-chart-{workflows_version}.tgz"
    workflows_chart_src = sample_root / "chart" / "appliance-workflows"
    workflows_chart_src.mkdir(parents=True, exist_ok=True)
    (workflows_chart_src / "Chart.yaml").write_text(
        "\n".join(
            [
                "apiVersion: v2",
                "name: appliance-workflows",
                f"version: {workflows_version}",
                f"appVersion: {workflows_version}",
                "type: application",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (workflows_chart_src / "values.yaml").write_text("controller:\n  enabled: true\n", encoding="utf-8")
    with tarfile.open(sample_root / workflows_chart_name, "w:gz") as tf:
        tf.add(workflows_chart_src, arcname="workflows-chart")
    shutil.rmtree(sample_root / "chart")

    workflows_crds_name = "workflows-crds"
    workflows_crds_dir = sample_root / workflows_crds_name
    workflows_crds_dir.mkdir(parents=True, exist_ok=True)
    (workflows_crds_dir / "workflows.argoproj.io.yaml").write_text(
        "\n".join(
            [
                "apiVersion: apiextensions.k8s.io/v1",
                "kind: CustomResourceDefinition",
                "metadata:",
                "  name: workflows.argoproj.io",
                "",
            ]
        ),
        encoding="utf-8",
    )

    if workflow_controller_image_ref:
        workflow_controller_name = f"workflow-controller-{workflows_version}.oci.tar.zst"
        (sample_root / workflow_controller_name).write_bytes(b"sample workflow-controller image\n")
    if workflow_executor_image_ref:
        workflow_executor_name = f"workflow-executor-{workflows_version}.oci.tar.zst"
        (sample_root / workflow_executor_name).write_bytes(b"sample workflow-executor image\n")

def file_digest(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()

def dir_manifest_digest(path: Path) -> str:
    lines = []
    for file_path in sorted(p for p in path.rglob("*") if p.is_file()):
        rel = file_path.relative_to(path).as_posix()
        lines.append(f"{rel}\t{file_digest(file_path)}\t{file_path.stat().st_size}\n")
    return "sha256:" + hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()

def file_artifact(rel_path: str) -> dict:
    path = sample_root / rel_path
    return {
        "path": rel_path,
        "digest": file_digest(path),
        "sizeBytes": path.stat().st_size,
    }

release_input = {
    "schemaVersion": 1,
    "codeVersion": product_version,
    "releaseId": f"sample-{product_version}",
    "generatedAt": "2026-07-06T00:00:00Z",
    "artifacts": {
        "controlPlaneImage": file_artifact(control_plane_name),
        "uiImage": file_artifact(ui_name),
        "blobStorageImage": file_artifact(blob_storage_name),
        "applianceChart": file_artifact(chart_name),
        "configurationSchema": file_artifact(schema_name),
        "compatibility": file_artifact(compatibility_name),
        "checksums": file_artifact(checksums_name),
        "sbom": {"path": "sbom", "manifestDigest": dir_manifest_digest(sample_root / "sbom")},
        "provenance": {"path": "provenance", "manifestDigest": dir_manifest_digest(sample_root / "provenance")},
        "notices": {"path": "notices", "manifestDigest": dir_manifest_digest(sample_root / "notices")},
        "tests": {"path": "tests", "manifestDigest": dir_manifest_digest(sample_root / "tests")},
    },
    "compatibility": compatibility,
}
release_input["artifacts"]["controlPlaneImage"]["imageReference"] = control_plane_image_ref
release_input["artifacts"]["uiImage"]["imageReference"] = ui_image_ref
release_input["artifacts"]["blobStorageImage"]["imageReference"] = "registry.local/blob-storage@sha256:" + "ab" * 32

if workflows_chart_name:
    release_input["artifacts"]["workflowsChart"] = file_artifact(workflows_chart_name)
if workflows_crds_name:
    release_input["artifacts"]["workflowsCRDs"] = {
        "path": workflows_crds_name,
        "manifestDigest": dir_manifest_digest(sample_root / workflows_crds_name),
    }
if workflow_controller_name:
    release_input["artifacts"]["workflowControllerImage"] = file_artifact(workflow_controller_name)
    release_input["artifacts"]["workflowControllerImage"]["imageReference"] = workflow_controller_image_ref
if workflow_executor_name:
    release_input["artifacts"]["workflowExecutorImage"] = file_artifact(workflow_executor_name)
    release_input["artifacts"]["workflowExecutorImage"]["imageReference"] = workflow_executor_image_ref

(sample_root / "release-input.json").write_text(json.dumps(release_input, indent=2) + "\n", encoding="utf-8")

with tarfile.open(archive_path, "w:gz") as tf:
    for path in sorted(sample_root.iterdir(), key=lambda p: p.name):
        tf.add(path, arcname=path.name)
PY

  RELEASE_INPUT_SOURCE="${archive_path}"
}

if [[ "${SAMPLE_MODE}" == "1" ]]; then
  create_sample_release_input
  mkdir -p "$(dirname "${K3S_BINARY}")" "$(dirname "${K3S_AIRGAP_IMAGES}")"
  printf 'k3s-binary\n' > "${K3S_BINARY}"
  chmod +x "${K3S_BINARY}"
  printf 'k3s images\n' > "${K3S_AIRGAP_IMAGES}"
fi

if [[ "${SAMPLE_MODE}" != "1" ]]; then
  if [[ -z "${RELEASE_INPUT_SOURCE}" && ( -z "${RELEASE_INPUT_VERSION}" || -z "${RELEASE_INPUT_FETCH_TEMPLATE}" ) ]]; then
    echo "assemble-product-bundle: set RELEASE_INPUT_SOURCE or both RELEASE_INPUT_VERSION and RELEASE_INPUT_FETCH_TEMPLATE" >&2
    exit 1
  fi
fi

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "${path}" ]]; then
    echo "assemble-product-bundle: missing ${label}: ${path}" >&2
    exit 1
  fi
}

# Confirms the k3s airgap images file is actually a readable zstd-compressed
# tar, not just present. `require_file` alone only checks existence — a
# truncated download, a bad copy, or (in SAMPLE_MODE) the placeholder text
# written below would otherwise sail through unnoticed and only fail much
# later, cryptically, during `zonctl install` on a real target host (`ctr:
# archive/tar: invalid tar header`). Skipped in SAMPLE_MODE, where the
# placeholder is expected and the bundle is never meant to be installed for
# real. Warns (does not fail) if zstd isn't on PATH, rather than blocking a
# build host that's otherwise fine.
require_valid_k3s_airgap_images() {
  local path="$1"
  if [[ "${SAMPLE_MODE}" == "1" ]]; then
    return 0
  fi
  if ! command -v zstd >/dev/null 2>&1; then
    echo "assemble-product-bundle: warning: zstd not found on PATH, skipping k3s airgap images integrity check for ${path}" >&2
    return 0
  fi
  if ! zstd -t "${path}" >/dev/null 2>&1; then
    echo "assemble-product-bundle: k3s airgap images file is not a valid zstd archive: ${path}" >&2
    echo "assemble-product-bundle: re-check K3S_AIRGAP_IMAGES (files API seed: scripts/fetch-k3s-inputs.sh) before rebuilding the bundle" >&2
    exit 1
  fi
  if ! zstd -dc "${path}" 2>/dev/null | tar -tf - >/dev/null 2>&1; then
    echo "assemble-product-bundle: k3s airgap images file decompresses but is not a valid tar archive: ${path}" >&2
    echo "assemble-product-bundle: re-check K3S_AIRGAP_IMAGES (files API seed: scripts/fetch-k3s-inputs.sh) before rebuilding the bundle" >&2
    exit 1
  fi
}

require_file "${K3S_BINARY}" "k3s binary"
require_file "${K3S_AIRGAP_IMAGES}" "k3s airgap images"
require_valid_k3s_airgap_images "${K3S_AIRGAP_IMAGES}"
if [[ -n "${VALUES_FILE:-}" ]]; then
  require_file "${VALUES_FILE}" "values file"
fi

verify_sha256_file() {
  local payload="$1"
  local checksum_file="$2"

  if command -v sha256sum >/dev/null 2>&1; then
    (
      cd "$(dirname "${payload}")"
      sha256sum -c "$(basename "${checksum_file}")"
    ) >/dev/null
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    local expected actual
    expected="$(awk '{print $1}' "${checksum_file}" | head -n 1)"
    actual="$(shasum -a 256 "${payload}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]]
    return 0
  fi

  echo "assemble-product-bundle: need sha256sum or shasum to verify Helm download" >&2
  exit 1
}

resolve_helm_binary() {
  if [[ -n "${HELM_BINARY}" ]]; then
    require_file "${HELM_BINARY}" "helm binary"
    return 0
  fi

  local resolved_path="${DOWNLOADS_DIR}/helm/${HELM_VERSION}/linux-amd64/helm"
  if [[ -x "${resolved_path}" ]]; then
    HELM_BINARY="${resolved_path}"
    return 0
  fi

  mkdir -p "$(dirname "${resolved_path}")"

  if [[ "${SAMPLE_MODE}" == "1" ]]; then
    cat >"${resolved_path}" <<'EOF'
#!/usr/bin/env bash
echo "sample helm placeholder"
EOF
    chmod 755 "${resolved_path}"
    HELM_BINARY="${resolved_path}"
    return 0
  fi

  local archive_name="helm-${HELM_VERSION}-linux-amd64.tar.gz"
  local archive_path="${DOWNLOADS_DIR}/${archive_name}"
  local checksum_path="${archive_path}.sha256sum"
  local extract_dir="${DOWNLOADS_DIR}/helm-extract-${HELM_VERSION}"
  local offline="${OFFLINE_BUILD:-0}"
  local files_ok=0
  local offline_on=0

  case "$(printf '%s' "${offline}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) offline_on=1 ;;
  esac

  # Offline: Helm from LAN files API. Online: get.helm.sh (do not probe DEV_*).
  if [[ "${offline_on}" -eq 1 && -n "${DEV_REGISTRY:-}" && -n "${DEV_REGISTRY_TOKEN:-}" ]]; then
    local registry token insecure=()
    registry="$(printf '%s' "${DEV_REGISTRY}" | sed 's#^https\?://##; s#/*$##')"
    token="$(printf '%s' "${DEV_REGISTRY_TOKEN}" | tr -d '[:space:]')"
    case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')" in
      0|false|no|off) insecure=(-k) ;;
    esac
    if curl -fsSL "${insecure[@]}" \
        -H "Authorization: Bearer ${token}" \
        -o "${archive_path}" \
        "https://${registry}/api/v1/files/helm/${HELM_VERSION}/${archive_name}" \
      && curl -fsSL "${insecure[@]}" \
        -H "Authorization: Bearer ${token}" \
        -o "${checksum_path}" \
        "https://${registry}/api/v1/files/helm/${HELM_VERSION}/${archive_name}.sha256sum"; then
      files_ok=1
      echo "assemble-product-bundle: fetched Helm ${HELM_VERSION} from files API" >&2
    fi
  fi

  if [[ "${files_ok}" -ne 1 ]]; then
    if [[ "${offline_on}" -eq 1 ]]; then
      echo "assemble-product-bundle: OFFLINE_BUILD=1 and Helm files API miss for ${HELM_VERSION}" >&2
      echo "assemble-product-bundle: seed deps/platform-inputs (make -C deps/platform-inputs release)" >&2
      exit 1
    fi
    curl -fsSL "${HELM_DOWNLOAD_BASE_URL}/${archive_name}" -o "${archive_path}"
    curl -fsSL "${HELM_DOWNLOAD_BASE_URL}/${archive_name}.sha256sum" -o "${checksum_path}"
  fi
  verify_sha256_file "${archive_path}" "${checksum_path}"

  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  tar -xzf "${archive_path}" -C "${extract_dir}"

  if [[ ! -f "${extract_dir}/linux-amd64/helm" ]]; then
    echo "assemble-product-bundle: downloaded Helm archive missing linux-amd64/helm: ${archive_path}" >&2
    exit 1
  fi

  cp "${extract_dir}/linux-amd64/helm" "${resolved_path}"
  chmod 755 "${resolved_path}"
  HELM_BINARY="${resolved_path}"
}

resolve_helm_binary

json_artifact_path() {
  local manifest_path="$1"
  local artifact_key="$2"
  python3 - "${manifest_path}" "${artifact_key}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

print(data["artifacts"][sys.argv[2]]["path"])
PY
}

clone_repo() {
  local source="$1"
  local ref="$2"
  local dest="$3"
  local clone_source="${source}"
  if [[ -d "${source}" ]]; then
    if [[ -d "${source}/.git" ]]; then
      if git -C "${source}" remote get-url origin >/dev/null 2>&1; then
        clone_source="$(git -C "${source}" remote get-url origin)"
      else
        echo "assemble-product-bundle: local repo source ${source} has no origin remote configured" >&2
        exit 1
      fi
    else
      echo "assemble-product-bundle: local source ${source} is not a git checkout with an origin remote" >&2
      exit 1
    fi
  fi
  rm -rf "${dest}"
  mkdir -p "$(dirname "${dest}")"
  if [[ -n "${ref}" ]]; then
    git clone --depth 1 --branch "${ref}" "${clone_source}" "${dest}"
  else
    git clone --depth 1 "${clone_source}" "${dest}"
  fi
}

CTL_CLONE_DIR="${WORKDIR}/sources/appliance-ctl"

init_bundle_workspace() {
  local args=(
    --workdir "${WORKDIR}"
    --zonctl-binary "${ZONCTL_BINARY}"
    --helm-binary "${HELM_BINARY}"
    --product-version "${PRODUCT_VERSION}"
  )
  if [[ -n "${CONTROL_PLANE_IMAGE_REF}" ]]; then
    args+=(--control-plane-image-ref "${CONTROL_PLANE_IMAGE_REF}")
  fi
  if [[ -n "${OS_VERSION}" ]]; then
    args+=(--os-version "${OS_VERSION}")
  fi
  bash "${SCRIPT_DIR}/init-bundle-workspace.sh" "${args[@]}"
}

import_release_input() {
  local source="${1:-}"
  local version="${2:-}"
  local template="${3:-}"
  local cache_dir="${WORKDIR}/downloads"
  local release_input_dir="${WORKDIR}/release-input"
  local local_source=""
  local filename=""

  if [[ -n "${source}" && -n "${version}" ]]; then
    echo "assemble-product-bundle: choose either RELEASE_INPUT_SOURCE or RELEASE_INPUT_VERSION/TEMPLATE, not both" >&2
    exit 2
  fi
  if [[ -z "${source}" ]]; then
    if [[ -z "${version}" || -z "${template}" ]]; then
      echo "assemble-product-bundle: set RELEASE_INPUT_SOURCE or both RELEASE_INPUT_VERSION and RELEASE_INPUT_FETCH_TEMPLATE" >&2
      exit 2
    fi
    if [[ "${template}" != *"{version}"* ]]; then
      echo "assemble-product-bundle: RELEASE_INPUT_FETCH_TEMPLATE must contain {version}" >&2
      exit 2
    fi
    source="${template//\{version\}/${version}}"
  fi

  mkdir -p "${cache_dir}"
  if [[ "${source}" =~ ^https?:// || "${source}" =~ ^file:// ]]; then
    filename="$(basename "${source}")"
    if [[ -z "${filename}" || "${filename}" == "/" ]]; then
      filename="release-input-${version:-fetched}.tar.gz"
    fi
    local_source="${cache_dir}/${filename}"
    if [[ "${source}" =~ ^file:// ]]; then
      cp "${source#file://}" "${local_source}"
    else
      curl -fsSL "${source}" -o "${local_source}"
    fi
  else
    local_source="$(cd "$(dirname "${source}")" && pwd)/$(basename "${source}")"
  fi

  mkdir -p "${release_input_dir}"
  find "${release_input_dir}" -mindepth 1 -delete
  case "${local_source}" in
    *.tar.gz|*.tgz) tar -xzf "${local_source}" -C "${release_input_dir}" ;;
    *.tar) tar -xf "${local_source}" -C "${release_input_dir}" ;;
    *)
      if [[ -d "${local_source}" ]]; then
        cp -R "${local_source}/." "${release_input_dir}/"
      else
        echo "assemble-product-bundle: unsupported release-input source: ${local_source}" >&2
        exit 1
      fi
      ;;
  esac
  if [[ ! -f "${release_input_dir}/release-input.json" ]]; then
    echo "assemble-product-bundle: imported content does not contain release-input.json at the root" >&2
    exit 1
  fi
  echo "imported release-input into:"
  echo "  ${release_input_dir}"
}

assemble_pack_bundle() {
  local config_path="$1"
  local release_input_dir=""
  if [[ ! -f "${config_path}" ]]; then
    echo "assemble-product-bundle: missing config: ${config_path}" >&2
    exit 1
  fi
  release_input_dir="$(sed -nE 's/.*"releaseInputDir"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "${config_path}" | head -n 1)"
  if [[ -z "${release_input_dir}" ]]; then
    echo "assemble-product-bundle: could not read releaseInputDir from ${config_path}" >&2
    exit 1
  fi
  if [[ ! -f "${release_input_dir}/release-input.json" ]]; then
    echo "assemble-product-bundle: missing ${release_input_dir}/release-input.json" >&2
    exit 1
  fi
  if [[ ! -x "${ZONCTL_BINARY}" ]]; then
    echo "assemble-product-bundle: zonctl binary is missing or not executable: ${ZONCTL_BINARY}" >&2
    exit 1
  fi
  "${ZONCTL_BINARY}" assemble-bundle --config "${config_path}"
}

assemble_all_packs() {
  local pack_id=""
  local config_path=""
  local bundle_dir=""
  appliance_packs_resolve
  echo "assemble-product-bundle: APPLIANCE_PACKS=${APPLIANCE_PACKS} → ${APPLIANCE_PACKS_RESOLVED}"
  for pack_id in ${APPLIANCE_PACKS_RESOLVED}; do
    config_path="${WORKDIR}/bundle-assembly.${pack_id}.json"
    case "${pack_id}" in
      foundation) bundle_dir="${BUNDLE_DIR}" ;;
      developer) bundle_dir="${DEVELOPER_BUNDLE_DIR}" ;;
      deviceuser) bundle_dir="${DEVICEUSER_BUNDLE_DIR}" ;;
      inference) bundle_dir="${INFERENCE_BUNDLE_DIR}" ;;
      *)
        echo "assemble-product-bundle: unsupported pack id ${pack_id}" >&2
        exit 2
        ;;
    esac
    rm -rf "${bundle_dir}"
    echo "assemble-product-bundle: assembling pack ${pack_id}"
    assemble_pack_bundle "${config_path}"
    make -C "${REPO_ROOT}" verify-bundle \
      ZONCTL_BINARY="${ZONCTL_BINARY}" \
      BUNDLE_DIR="${bundle_dir}" \
      PUBLIC_KEY="${WORKDIR}/keys/release-signing.pub"
  done
}

if [[ -d "${CTL_REPO_SOURCE}" ]]; then
  make -C "${CTL_REPO_SOURCE}" build
  ZONCTL_BINARY="$(cd "${CTL_REPO_SOURCE}" && pwd)/bin/zonctl"
else
  # Git URL: clone default branch (local path is preferred; set by build-full-bundle).
  clone_repo "${CTL_REPO_SOURCE}" "" "${CTL_CLONE_DIR}"
  make -C "${CTL_CLONE_DIR}" build
  ZONCTL_BINARY="${CTL_CLONE_DIR}/bin/zonctl"
fi
require_file "${ZONCTL_BINARY}" "zonctl binary"

init_bundle_workspace
import_release_input "${RELEASE_INPUT_SOURCE}" "${RELEASE_INPUT_VERSION}" "${RELEASE_INPUT_FETCH_TEMPLATE}"
init_bundle_workspace

if [[ -z "${CONTROL_PLANE_IMAGE}" ]]; then
  CONTROL_PLANE_IMAGE="${RELEASE_INPUT_DIR}/$(json_artifact_path "${RELEASE_INPUT_DIR}/release-input.json" controlPlaneImage)"
fi

require_file "${CONTROL_PLANE_IMAGE}" "control-plane image"

mkdir -p "${STAGING_DIR}"
cp "${K3S_BINARY}" "${STAGING_DIR}/k3s"
chmod +x "${STAGING_DIR}/k3s"
cp "${K3S_AIRGAP_IMAGES}" "${STAGING_DIR}/k3s-airgap-images-amd64.tar.zst"
control_plane_staging_name="$(basename "$(json_artifact_path "${RELEASE_INPUT_DIR}/release-input.json" controlPlaneImage)")"
if [[ -z "${control_plane_staging_name}" ]]; then
  control_plane_staging_name="$(basename "${CONTROL_PLANE_IMAGE}")"
fi
cp "${CONTROL_PLANE_IMAGE}" "${STAGING_DIR}/${control_plane_staging_name}"
if [[ -n "${VALUES_FILE:-}" ]]; then
  cp "${VALUES_FILE}" "${STAGING_DIR}/values-minimal.yaml"
fi

rm -rf "${BUNDLE_DIR}" "${DEVELOPER_BUNDLE_DIR}" "${DEVICEUSER_BUNDLE_DIR}" "${INFERENCE_BUNDLE_DIR}"

assemble_all_packs

echo "packs ready (${APPLIANCE_PACKS_RESOLVED}):"
if appliance_pack_wanted foundation; then
  echo "  foundation: ${BUNDLE_DIR}"
fi
if appliance_pack_wanted developer; then
  echo "  developer: ${DEVELOPER_BUNDLE_DIR}"
fi
if appliance_pack_wanted deviceuser; then
  echo "  deviceuser: ${DEVICEUSER_BUNDLE_DIR}"
fi
if appliance_pack_wanted inference; then
  echo "  inference: ${INFERENCE_BUNDLE_DIR}"
fi
