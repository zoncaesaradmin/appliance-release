#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: product-bundle-from-config.sh --config PATH

Runs the complete product bundle flow from a single config file.
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
RELEASE_INPUT_SOURCE="${RELEASE_INPUT_SOURCE:-}"
RELEASE_INPUT_VERSION="${RELEASE_INPUT_VERSION:-}"
RELEASE_INPUT_FETCH_TEMPLATE="${RELEASE_INPUT_FETCH_TEMPLATE:-}"
CONTROL_PLANE_IMAGE="${CONTROL_PLANE_IMAGE:-}"
ARGO_CRDS="${ARGO_CRDS:-}"
K3S_BINARY="${K3S_BINARY:-${INPUTS_DIR}/k3s}"
K3S_INSTALL_SCRIPT="${K3S_INSTALL_SCRIPT:-${INPUTS_DIR}/install.sh}"
K3S_AIRGAP_IMAGES="${K3S_AIRGAP_IMAGES:-${INPUTS_DIR}/k3s-airgap-images-amd64.tar.zst}"
DOWNLOADS_DIR="${WORKDIR}/downloads"
STAGING_DIR="${WORKDIR}/staging"
RELEASE_INPUT_DIR="${WORKDIR}/release-input"
BUNDLE_DIR="${WORKDIR}/out/appliance-${PRODUCT_VERSION}-bundle"

mkdir -p "${WORKDIR}" "${INPUTS_DIR}" "${DOWNLOADS_DIR}"

create_sample_release_input() {
  local sample_root="${DOWNLOADS_DIR}/sample-release-input"
  local archive_path="${DOWNLOADS_DIR}/release-input-${PRODUCT_VERSION}.tar.gz"

  python3 - "${sample_root}" "${archive_path}" "${PRODUCT_VERSION}" "${CHART_VERSION}" "${K3S_VERSION}" "${ARGO_VERSION}" "${CONTROL_PLANE_IMAGE_REF}" <<'PY'
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
argo_version = sys.argv[6]
control_plane_image_ref = sys.argv[7]

if sample_root.exists():
    shutil.rmtree(sample_root)
sample_root.mkdir(parents=True)

control_plane_name = f"control-plane-api-{product_version}.tar"
chart_name = f"appliance-chart-{product_version}.tgz"
argo_name = "argo-crds.yaml"
schema_name = "configuration.schema.json"
compatibility_name = "compatibility.json"
checksums_name = "checksums.txt"

compatibility = {
    "k3sVersion": k3s_version,
    "chartVersion": chart_version,
    "argoVersion": argo_version,
    "supportedUpgradeSources": [],
}

control_plane_bytes = b"control-plane-image\n"
argo_crds_bytes = b"""apiVersion: apiextensions.k8s.io/v1
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
"""
schema_bytes = b'{\n  "$schema": "https://json-schema.org/draft/2020-12/schema",\n  "type": "object"\n}\n'
compatibility_bytes = (json.dumps(compatibility, indent=2) + "\n").encode("utf-8")
checksums_bytes = b"sample checksums placeholder\n"

(sample_root / control_plane_name).write_bytes(control_plane_bytes)
(sample_root / argo_name).write_bytes(argo_crds_bytes)
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
            "",
        ]
    ),
    encoding="utf-8",
)
with tarfile.open(sample_root / chart_name, "w:gz") as tf:
    tf.add(chart_src, arcname="appliance")
shutil.rmtree(sample_root / "chart")

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
    "productVersion": product_version,
    "releaseId": f"sample-{product_version}",
    "generatedAt": "2026-07-06T00:00:00Z",
    "artifacts": {
        "controlPlaneImage": file_artifact(control_plane_name),
        "applianceChart": file_artifact(chart_name),
        "argoCrds": file_artifact(argo_name),
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

(sample_root / "release-input.json").write_text(json.dumps(release_input, indent=2) + "\n", encoding="utf-8")

with tarfile.open(archive_path, "w:gz") as tf:
    for path in sorted(sample_root.iterdir(), key=lambda p: p.name):
        tf.add(path, arcname=path.name)
PY

  RELEASE_INPUT_SOURCE="${archive_path}"
}

if [[ "${SAMPLE_MODE}" == "1" ]]; then
  create_sample_release_input
  mkdir -p "$(dirname "${K3S_BINARY}")" "$(dirname "${K3S_INSTALL_SCRIPT}")" "$(dirname "${K3S_AIRGAP_IMAGES}")"
  printf 'k3s-binary\n' > "${K3S_BINARY}"
  chmod +x "${K3S_BINARY}"
  printf '#!/bin/sh\necho install\n' > "${K3S_INSTALL_SCRIPT}"
  chmod +x "${K3S_INSTALL_SCRIPT}"
  printf 'k3s images\n' > "${K3S_AIRGAP_IMAGES}"
fi

if [[ "${SAMPLE_MODE}" != "1" ]]; then
  if [[ -z "${RELEASE_INPUT_SOURCE}" && ( -z "${RELEASE_INPUT_VERSION}" || -z "${RELEASE_INPUT_FETCH_TEMPLATE}" ) ]]; then
    echo "product-bundle-from-config: set RELEASE_INPUT_SOURCE or both RELEASE_INPUT_VERSION and RELEASE_INPUT_FETCH_TEMPLATE" >&2
    exit 1
  fi
fi

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "${path}" ]]; then
    echo "product-bundle-from-config: missing ${label}: ${path}" >&2
    exit 1
  fi
}

require_file "${K3S_BINARY}" "k3s binary"
require_file "${K3S_INSTALL_SCRIPT}" "k3s install script"
require_file "${K3S_AIRGAP_IMAGES}" "k3s airgap images"
if [[ -n "${VALUES_FILE:-}" ]]; then
  require_file "${VALUES_FILE}" "values file"
fi

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

CTL_CLONE_DIR="${WORKDIR}/sources/appliance-ctl"

if [[ -d "${CTL_REPO_SOURCE}" && -z "${CTL_REPO_REF:-}" ]]; then
  make -C "${CTL_REPO_SOURCE}" build
  ZONCTL_BINARY="$(cd "${CTL_REPO_SOURCE}" && pwd)/bin/zonctl"
else
  clone_repo "${CTL_REPO_SOURCE}" "${CTL_REPO_REF:-}" "${CTL_CLONE_DIR}"
  make -C "${CTL_CLONE_DIR}" build
  ZONCTL_BINARY="${CTL_CLONE_DIR}/bin/zonctl"
fi
require_file "${ZONCTL_BINARY}" "zonctl binary"

make -C "${REPO_ROOT}" init-simple-workspace \
  WORKDIR="${WORKDIR}" \
  ZONCTL_BINARY="${ZONCTL_BINARY}" \
  PRODUCT_VERSION="${PRODUCT_VERSION}" \
  CONTROL_PLANE_IMAGE_REF="${CONTROL_PLANE_IMAGE_REF}" \
  OS_VERSION="${OS_VERSION}"

if [[ -n "${RELEASE_INPUT_SOURCE}" ]]; then
  make -C "${REPO_ROOT}" fetch-release-input \
    WORKDIR="${WORKDIR}" \
    RELEASE_INPUT_SOURCE="${RELEASE_INPUT_SOURCE}"
else
  make -C "${REPO_ROOT}" fetch-release-input \
    WORKDIR="${WORKDIR}" \
    RELEASE_INPUT_VERSION="${RELEASE_INPUT_VERSION}" \
    RELEASE_INPUT_FETCH_TEMPLATE="${RELEASE_INPUT_FETCH_TEMPLATE}"
fi

if [[ -z "${CONTROL_PLANE_IMAGE}" ]]; then
  CONTROL_PLANE_IMAGE="${RELEASE_INPUT_DIR}/$(json_artifact_path "${RELEASE_INPUT_DIR}/release-input.json" controlPlaneImage)"
fi
if [[ -z "${ARGO_CRDS}" ]]; then
  ARGO_CRDS="${RELEASE_INPUT_DIR}/$(json_artifact_path "${RELEASE_INPUT_DIR}/release-input.json" argoCrds)"
fi

require_file "${CONTROL_PLANE_IMAGE}" "control-plane image"
require_file "${ARGO_CRDS}" "argo CRDs"

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
