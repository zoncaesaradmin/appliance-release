#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install-http-release.sh --base-url URL --product-version VERSION [options]

Download a published release bundle from a plain HTTP/HTTPS location, verify
checksums, extract it locally, run zonctl preflight, and then install it.

Required:
  --base-url URL               Base URL that serves the appliance path, for
                               example:
                               http://downloads.example.internal/releases
  --product-version VERSION    Product version to install, for example: 0.1.0

Optional:
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
  bash ./install-http-release.sh \
    --base-url http://downloads.example.internal/releases \
    --product-version 0.1.0
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
require_var PRODUCT_VERSION

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="/tmp/appliance-${PRODUCT_VERSION}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_SCRIPT="${SCRIPT_DIR}/fetch-http-release.sh"

if [[ ! -f "${FETCH_SCRIPT}" ]]; then
  echo "install-http-release: missing companion fetch helper: ${FETCH_SCRIPT}" >&2
  exit 1
fi

BASE_URL="$(trim_trailing_slashes "${BASE_URL}")"
PATH_PREFIX="$(trim_trailing_slashes "${PATH_PREFIX}")"
STATE_DIR="$(trim_trailing_slashes "${STATE_DIR}")"

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
