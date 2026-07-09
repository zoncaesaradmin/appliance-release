#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: fetch-http-release.sh --base-url URL --out-dir DIR [options]

Fetch the published bundle archive, public key, and checksum file from a plain
HTTP/HTTPS release location, verify checksums, and extract the bundle locally.

Required:
  --base-url URL               Base URL that serves the appliance path, for
                               example:
                               http://downloads.example.internal/releases
  --out-dir DIR                Local directory to download into

Optional:
  --product-version VERSION    Product version to fetch. If omitted, the script
                               infers it from a versioned filename such as
                               fetch-http-release-0.1.0.sh
  --path-prefix PATH           Path under base URL. Default: appliance
  --use-latest                 Fetch from <base-url>/<path-prefix>/latest/
                               instead of the explicit version directory
  --help                       Show this help

Example:
  bash ./fetch-http-release-0.1.0.sh \
    --base-url http://downloads.example.internal/releases \
    --out-dir /tmp/appliance-0.1.0
EOF
}

BASE_URL=""
PRODUCT_VERSION=""
OUT_DIR=""
PATH_PREFIX="appliance"
USE_LATEST="0"

infer_product_version_from_script() {
  local script_name
  script_name="$(basename "${BASH_SOURCE[0]}")"
  if [[ "${script_name}" =~ ^fetch-http-release-([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)\.sh$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "fetch-http-release: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "fetch-http-release: ${name} is required" >&2
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
require_var OUT_DIR

if [[ -z "${PRODUCT_VERSION}" ]]; then
  PRODUCT_VERSION="$(infer_product_version_from_script || true)"
fi
require_var PRODUCT_VERSION

BASE_URL="$(trim_trailing_slashes "${BASE_URL}")"
PATH_PREFIX="$(trim_trailing_slashes "${PATH_PREFIX}")"
OUT_DIR="$(cd "$(dirname "${OUT_DIR}")" && pwd)/$(basename "${OUT_DIR}")"
mkdir -p "${OUT_DIR}"

BUNDLE_ARCHIVE="appliance-${PRODUCT_VERSION}-bundle.tar.gz"
PUBLIC_KEY_FILE="release-signing.pub"
CHECKSUM_FILE="sha256sum.txt"
BUNDLE_DIR_NAME="appliance-${PRODUCT_VERSION}-bundle"

if [[ "${USE_LATEST}" == "1" ]]; then
  REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/latest"
else
  REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}"
fi

curl -fLo "${OUT_DIR}/${BUNDLE_ARCHIVE}" "${REMOTE_DIR}/${BUNDLE_ARCHIVE}"
curl -fLo "${OUT_DIR}/${PUBLIC_KEY_FILE}" "${REMOTE_DIR}/${PUBLIC_KEY_FILE}"
curl -fLo "${OUT_DIR}/${CHECKSUM_FILE}" "${REMOTE_DIR}/${CHECKSUM_FILE}"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && sha256sum -c "${CHECKSUM_FILE}")
else
  if ! command -v shasum >/dev/null 2>&1; then
    echo "fetch-http-release: need sha256sum or shasum to verify checksums" >&2
    exit 1
  fi
  tmp_checksums="${OUT_DIR}/.sha256sum.tmp"
  awk '{print $1 "  " $2}' "${OUT_DIR}/${CHECKSUM_FILE}" > "${tmp_checksums}"
  (cd "${OUT_DIR}" && shasum -a 256 -c "$(basename "${tmp_checksums}")")
  rm -f "${tmp_checksums}"
fi

rm -rf "${OUT_DIR:?}/${BUNDLE_DIR_NAME}"
tar -C "${OUT_DIR}" -xzf "${OUT_DIR}/${BUNDLE_ARCHIVE}"

echo "downloaded release files:"
echo "  ${OUT_DIR}/${BUNDLE_ARCHIVE}"
echo "  ${OUT_DIR}/${PUBLIC_KEY_FILE}"
echo "  ${OUT_DIR}/${CHECKSUM_FILE}"
echo
echo "extracted bundle:"
echo "  ${OUT_DIR}/${BUNDLE_DIR_NAME}"
echo
echo "next steps:"
echo "  chmod +x ${OUT_DIR}/${BUNDLE_DIR_NAME}/zonctl"
echo "  sudo ${OUT_DIR}/${BUNDLE_DIR_NAME}/zonctl preflight --output json"
echo "  sudo ${OUT_DIR}/${BUNDLE_DIR_NAME}/zonctl install --bundle-dir ${OUT_DIR}/${BUNDLE_DIR_NAME} --public-key ${OUT_DIR}/${PUBLIC_KEY_FILE} --state-dir /var/lib/zon --output json"
