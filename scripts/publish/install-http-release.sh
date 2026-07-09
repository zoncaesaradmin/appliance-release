#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install-http-release.sh --base-url URL [options]

Download a published release bundle from a plain HTTP/HTTPS location, verify
checksums, extract it locally, run zonctl preflight, and then install it.

Required:
  --base-url URL               Base URL that serves the appliance path, for
                               example:
                               http://downloads.example.internal/releases

Optional:
  --product-version VERSION    Product version to install. If omitted, the
                               script infers it from a versioned filename such
                               as install-http-release-0.1.0.sh
  --out-dir DIR                Local download/extract directory.
                               Default: /tmp/appliance-<version>
  --path-prefix PATH           Path under base URL. Default: appliance
  --use-latest                 Fetch from <base-url>/<path-prefix>/latest/
                               instead of the explicit version directory
  --state-dir DIR              zonctl state directory. Default: /var/lib/zon
  --node-name NAME             Optional zonctl --node-name override
  --dry-run                    Pass --dry-run to zonctl install
  --output FORMAT              zonctl output format. Default: json
  --help                       Show this help

Example:
  bash ./install-http-release-0.1.0.sh \
    --base-url http://downloads.example.internal/releases \
EOF
}

BASE_URL=""
PRODUCT_VERSION=""
OUT_DIR=""
PATH_PREFIX="appliance"
USE_LATEST="0"
STATE_DIR="/var/lib/zon"
NODE_NAME=""
DRY_RUN="0"
OUTPUT_FORMAT="json"
FETCH_SCRIPT_TEMP=""

infer_product_version_from_script() {
  local script_name
  script_name="$(basename "${BASH_SOURCE[0]}")"
  if [[ "${script_name}" =~ ^install-http-release-([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)\.sh$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

cleanup() {
  if [[ -n "${FETCH_SCRIPT_TEMP}" && -f "${FETCH_SCRIPT_TEMP}" ]]; then
    rm -f "${FETCH_SCRIPT_TEMP}"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --product-version)
      PRODUCT_VERSION="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --path-prefix)
      PATH_PREFIX="${2:-}"
      shift 2
      ;;
    --use-latest)
      USE_LATEST="1"
      shift 1
      ;;
    --state-dir)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --node-name)
      NODE_NAME="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift 1
      ;;
    --output)
      OUTPUT_FORMAT="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "install-http-release: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "install-http-release: ${name} is required" >&2
    usage >&2
    exit 2
  fi
}

trim_trailing_slashes() {
  local value="$1"
  while [[ "${value}" != "/" && "${value}" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "${value}"
}

require_var BASE_URL

if [[ -z "${PRODUCT_VERSION}" ]]; then
  PRODUCT_VERSION="$(infer_product_version_from_script || true)"
fi
require_var PRODUCT_VERSION

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="/tmp/appliance-${PRODUCT_VERSION}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_URL="$(trim_trailing_slashes "${BASE_URL}")"
PATH_PREFIX="$(trim_trailing_slashes "${PATH_PREFIX}")"
STATE_DIR="$(trim_trailing_slashes "${STATE_DIR}")"
mkdir -p "${OUT_DIR}"

REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}"
if [[ "${USE_LATEST}" == "1" ]]; then
  REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/latest"
fi

FETCH_SCRIPT="${SCRIPT_DIR}/fetch-http-release-${PRODUCT_VERSION}.sh"
if [[ ! -f "${FETCH_SCRIPT}" ]]; then
  FETCH_SCRIPT="${SCRIPT_DIR}/fetch-http-release.sh"
fi
if [[ ! -f "${FETCH_SCRIPT}" ]]; then
  FETCH_SCRIPT_TEMP="${OUT_DIR}/.fetch-http-release-${PRODUCT_VERSION}.sh"
  if ! curl -fsLo "${FETCH_SCRIPT_TEMP}" "${REMOTE_DIR}/fetch-http-release-${PRODUCT_VERSION}.sh"; then
    curl -fsLo "${FETCH_SCRIPT_TEMP}" "${REMOTE_DIR}/fetch-http-release.sh"
  fi
  chmod +x "${FETCH_SCRIPT_TEMP}"
  FETCH_SCRIPT="${FETCH_SCRIPT_TEMP}"
fi

fetch_args=(
  --base-url "${BASE_URL}"
  --product-version "${PRODUCT_VERSION}"
  --out-dir "${OUT_DIR}"
  --path-prefix "${PATH_PREFIX}"
)
if [[ "${USE_LATEST}" == "1" ]]; then
  fetch_args+=(--use-latest)
fi

bash "${FETCH_SCRIPT}" "${fetch_args[@]}"

BUNDLE_DIR="${OUT_DIR}/appliance-${PRODUCT_VERSION}-bundle"
PUBLIC_KEY="${OUT_DIR}/release-signing.pub"
ZONCTL="${BUNDLE_DIR}/zonctl"

chmod +x "${ZONCTL}"

sudo "${ZONCTL}" preflight --output "${OUTPUT_FORMAT}"

install_args=(
  --bundle-dir "${BUNDLE_DIR}"
  --public-key "${PUBLIC_KEY}"
  --state-dir "${STATE_DIR}"
  --output "${OUTPUT_FORMAT}"
)
if [[ -n "${NODE_NAME}" ]]; then
  install_args+=(--node-name "${NODE_NAME}")
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  install_args+=(--dry-run)
fi

sudo "${ZONCTL}" install "${install_args[@]}"
