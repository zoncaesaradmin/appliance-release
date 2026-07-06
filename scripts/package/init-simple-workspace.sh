#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: init-simple-workspace.sh --workdir DIR --zonctl-binary PATH [options]

Creates a local workspace for the minimal amd64 appliance bundle flow.

Options:
  --workdir DIR                 Workspace root to create/update. Required.
  --zonctl-binary PATH          Path to the zonctl binary that will be bundled.
                                Required.
  --product-version VERSION     Product version for filenames and bundle output.
                                Defaults to productVersion from release-input.json
                                when present, otherwise 0.1.0.
  --control-plane-image-ref REF Control-plane image reference to write into
                                values and bundle config. Defaults to
                                internal/control-plane-api:<product-version>.
  --os-version VERSION          Supported Ubuntu version. Default: 24.04.
  --help                        Show this help.
EOF
}

WORKDIR=""
ZONCTL_BINARY=""
PRODUCT_VERSION=""
CONTROL_PLANE_IMAGE_REF=""
OS_VERSION="24.04"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --zonctl-binary)
      ZONCTL_BINARY="${2:-}"
      shift 2
      ;;
    --product-version)
      PRODUCT_VERSION="${2:-}"
      shift 2
      ;;
    --control-plane-image-ref)
      CONTROL_PLANE_IMAGE_REF="${2:-}"
      shift 2
      ;;
    --os-version)
      OS_VERSION="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "init-simple-workspace: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${WORKDIR}" ]]; then
  echo "init-simple-workspace: --workdir is required" >&2
  usage >&2
  exit 2
fi
if [[ -z "${ZONCTL_BINARY}" ]]; then
  echo "init-simple-workspace: --zonctl-binary is required" >&2
  usage >&2
  exit 2
fi

WORKDIR="$(cd "$(dirname "${WORKDIR}")" && pwd)/$(basename "${WORKDIR}")"
ZONCTL_BINARY="$(cd "$(dirname "${ZONCTL_BINARY}")" && pwd)/$(basename "${ZONCTL_BINARY}")"
RELEASE_INPUT_DIR="${WORKDIR}/release-input"

extract_product_version() {
  local manifest_path="$1"
  sed -nE 's/.*"productVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "${manifest_path}" | head -n 1
}

if [[ -z "${PRODUCT_VERSION}" && -f "${RELEASE_INPUT_DIR}/release-input.json" ]]; then
  PRODUCT_VERSION="$(extract_product_version "${RELEASE_INPUT_DIR}/release-input.json")"
fi
if [[ -z "${PRODUCT_VERSION}" ]]; then
  PRODUCT_VERSION="0.1.0"
fi
if [[ -z "${CONTROL_PLANE_IMAGE_REF}" ]]; then
  CONTROL_PLANE_IMAGE_REF="internal/control-plane-api:${PRODUCT_VERSION}"
fi

STAGING_DIR="${WORKDIR}/staging"
OUT_DIR="${WORKDIR}/out"
KEYS_DIR="${WORKDIR}/keys"
BUNDLE_DIR="${OUT_DIR}/appliance-${PRODUCT_VERSION}-bundle"
CONFIG_PATH="${WORKDIR}/bundle-assembly.simple.json"
VALUES_PATH="${STAGING_DIR}/values-minimal.yaml"
STAGING_README="${STAGING_DIR}/REQUIRED-FILES.md"
WORKSPACE_README="${WORKDIR}/README.md"
PRIVATE_KEY_PATH="${KEYS_DIR}/release-signing.key"
PUBLIC_KEY_PATH="${KEYS_DIR}/release-signing.pub"
CONTROL_PLANE_TAR="${STAGING_DIR}/control-plane-api-${PRODUCT_VERSION}.tar"

mkdir -p "${WORKDIR}" "${RELEASE_INPUT_DIR}" "${STAGING_DIR}" "${OUT_DIR}" "${KEYS_DIR}"

if [[ ! -x "${ZONCTL_BINARY}" ]]; then
  echo "init-simple-workspace: zonctl binary is missing or not executable: ${ZONCTL_BINARY}" >&2
  exit 1
fi

if [[ ! -f "${PRIVATE_KEY_PATH}" || ! -f "${PUBLIC_KEY_PATH}" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "init-simple-workspace: openssl is required to generate ${PRIVATE_KEY_PATH}" >&2
    exit 1
  fi
  openssl genpkey -algorithm Ed25519 -out "${PRIVATE_KEY_PATH}" >/dev/null 2>&1
  openssl pkey -in "${PRIVATE_KEY_PATH}" -pubout -out "${PUBLIC_KEY_PATH}" >/dev/null 2>&1
fi

cat >"${VALUES_PATH}" <<EOF
replicaCount: 1

image:
  repository: ${CONTROL_PLANE_IMAGE_REF%:*}
  tag: "${CONTROL_PLANE_IMAGE_REF##*:}"
  digest: ""
  pullPolicy: Never

namespace:
  create: true
  name: ""

config:
  environment: production
  canonicalOrigin: https://zon.example.internal
  logLevel: info
  trustedProxyCount: 1

secrets:
  keysSecretName: appliance-keys

persistence:
  enabled: true
  storageClassName: ""
  accessMode: ReadWriteOnce
  size: 10Gi
  dataDir: /var/lib/appliance/data

service:
  publicPort: 8080
  internalPort: 8081

ingress:
  enabled: true
  entryPoints:
    - websecure
  host: zon.example.internal
  tlsSecretName: appliance-tls

serviceAccount:
  create: true
  name: ""
  automountServiceAccountToken: false

networkPolicy:
  enabled: true
  traefikNamespaceLabel: {}
EOF

cat >"${STAGING_README}" <<EOF
# Required staged files

Place the remaining release-side artifacts in this directory before assembly:

- \`k3s\`
- \`install.sh\`
- \`k3s-airgap-images-amd64.tar.zst\`
- \`control-plane-api-${PRODUCT_VERSION}.tar\`
- \`argo-crds.yaml\`
- \`values-minimal.yaml\` (generated for you; edit as needed)

The \`release-input\` directory is produced by \`appliance-code\` and must contain:

- \`release-input.json\`
- \`appliance-chart-${PRODUCT_VERSION}.tgz\`
- \`configuration.schema.json\`
- \`checksums.txt\`
- \`sbom/\`
- \`provenance/\`
- \`notices/\`
- \`tests/\`
EOF

cat >"${CONFIG_PATH}" <<EOF
{
  "schemaVersion": 1,
  "releaseInputDir": "${RELEASE_INPUT_DIR}",
  "bundleDir": "${BUNDLE_DIR}",
  "signingKeyId": "release-signing-key",
  "signingPrivateKeyPath": "${PRIVATE_KEY_PATH}",
  "hostBaseline": {
    "os": "ubuntu",
    "osVersion": "${OS_VERSION}",
    "arch": "amd64"
  },
  "entries": [
    {
      "sourcePath": "${ZONCTL_BINARY}",
      "targetPath": "zonctl",
      "component": "appliance",
      "executable": true
    },
    {
      "sourcePath": "${STAGING_DIR}/k3s",
      "targetPath": "k3s/binary/k3s",
      "component": "k3s-binary",
      "executable": true
    },
    {
      "sourcePath": "${STAGING_DIR}/install.sh",
      "targetPath": "k3s/install/install.sh",
      "component": "k3s-install",
      "executable": true
    },
    {
      "sourcePath": "${STAGING_DIR}/k3s-airgap-images-amd64.tar.zst",
      "targetPath": "k3s/images/k3s-airgap-images-amd64.tar.zst",
      "component": "k3s-images"
    },
    {
      "sourcePath": "${CONTROL_PLANE_TAR}",
      "targetPath": "oci-images/control-plane-api-${PRODUCT_VERSION}.tar",
      "component": "oci-images",
      "imageReference": "${CONTROL_PLANE_IMAGE_REF}"
    },
    {
      "sourcePath": "${RELEASE_INPUT_DIR}/appliance-chart-${PRODUCT_VERSION}.tgz",
      "targetPath": "charts/appliance-chart-${PRODUCT_VERSION}.tgz",
      "component": "chart"
    },
    {
      "sourcePath": "${STAGING_DIR}/argo-crds.yaml",
      "targetPath": "crds/argo-crds.yaml",
      "component": "crds"
    },
    {
      "sourcePath": "${VALUES_PATH}",
      "targetPath": "configuration/values.yaml",
      "component": "configuration"
    }
  ]
}
EOF

cat >"${WORKSPACE_README}" <<EOF
# Simple Appliance Bundle Workspace

This workspace is the handoff point between the two repos:

1. \`appliance-code\` must produce/populate \`${RELEASE_INPUT_DIR}\`
2. \`appliance-release\` stages host/bundle artifacts in \`${STAGING_DIR}\`
3. \`appliance-release\` assembles the final bundle using:
   \`${CONFIG_PATH}\`

Suggested flow:

\`\`\`bash
make -C ../appliance-ctl build
make fetch-release-input WORKDIR=${WORKDIR} RELEASE_INPUT_SOURCE=/path/to/release-input-or-tarball
scripts/package/assemble-simple-bundle.sh --workdir ${WORKDIR} --zonctl-binary /abs/path/to/zonctl
\`\`\`

Public key for install-time verification:

- \`${PUBLIC_KEY_PATH}\`
EOF

echo "created simple bundle workspace:"
echo "  workdir: ${WORKDIR}"
echo "  config: ${CONFIG_PATH}"
echo "  release-input dir: ${RELEASE_INPUT_DIR}"
echo "  staging dir: ${STAGING_DIR}"
echo "  bundle output dir: ${BUNDLE_DIR}"
echo "  public key: ${PUBLIC_KEY_PATH}"
