#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install-http-release.sh --base-url URL [options]

Download a published release bundle from a plain HTTP/HTTPS location, verify
checksums, extract it locally, run zonctl preflight, and then install it.
During install, zonctl also bootstraps the first administrator in the same
workflow: it prompts on the terminal for the initial password unless you use
zonctl's own non-interactive bootstrap flags directly.

Required:
  --base-url URL               Base URL that serves the appliance path, for
                               example:
                               http://downloads.example.internal/releases

Optional:
  --product-version VERSION    Product version to install. If omitted, the
                               script uses its own embedded version set at
                               publish time
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

Example (piped, no local file needed — the version below is embedded in
the published script's content, not inferred from its filename):
  curl -fsSL http://downloads.example.internal/releases/appliance/0.1.0/install-http-release.sh \
    | bash -s -- --base-url http://downloads.example.internal/releases
EOF
}

# Substituted by publish-release.sh into the published copy of this script,
# so the version travels with the file's content rather than relying on the
# filename. That keeps the public helper URL stable as install-http-release.sh
# under each versioned release directory and also works when the script is
# piped straight into `bash` (curl ... | bash). Left empty in the tracked source copy;
# publish-release.sh's sed substitution is the only thing that sets it.
PRODUCT_VERSION_EMBEDDED=""

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

if [[ -z "${PRODUCT_VERSION}" ]]; then
  PRODUCT_VERSION="${PRODUCT_VERSION_EMBEDDED}"
fi
require_var PRODUCT_VERSION

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="/tmp/appliance-${PRODUCT_VERSION}"
fi

BASE_URL="$(trim_trailing_slashes "${BASE_URL}")"
PATH_PREFIX="$(trim_trailing_slashes "${PATH_PREFIX}")"
STATE_DIR="$(trim_trailing_slashes "${STATE_DIR}")"
mkdir -p "${OUT_DIR}"

REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}"
if [[ "${USE_LATEST}" == "1" ]]; then
  REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/latest"
fi

BUNDLE_ARCHIVE="appliance-${PRODUCT_VERSION}-bundle.tar.gz"
PUBLIC_KEY_FILE="release-signing.pub"
CHECKSUM_FILE="sha256sum.txt"
BUNDLE_DIR="${OUT_DIR}/appliance-${PRODUCT_VERSION}-bundle"
PUBLIC_KEY="${OUT_DIR}/release-signing.pub"
ZONCTL="${BUNDLE_DIR}/zonctl"

curl -fLo "${OUT_DIR}/${BUNDLE_ARCHIVE}" "${REMOTE_DIR}/${BUNDLE_ARCHIVE}"
curl -fLo "${OUT_DIR}/${PUBLIC_KEY_FILE}" "${REMOTE_DIR}/${PUBLIC_KEY_FILE}"
curl -fLo "${OUT_DIR}/${CHECKSUM_FILE}" "${REMOTE_DIR}/${CHECKSUM_FILE}"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && sha256sum -c "${CHECKSUM_FILE}")
else
  if ! command -v shasum >/dev/null 2>&1; then
    echo "install-http-release: need sha256sum or shasum to verify checksums" >&2
    exit 1
  fi
  tmp_checksums="${OUT_DIR}/.sha256sum.tmp"
  awk '{print $1 "  " $2}' "${OUT_DIR}/${CHECKSUM_FILE}" > "${tmp_checksums}"
  (cd "${OUT_DIR}" && shasum -a 256 -c "$(basename "${tmp_checksums}")")
  rm -f "${tmp_checksums}"
fi

rm -rf "${OUT_DIR:?}/$(basename "${BUNDLE_DIR}")"
tar -C "${OUT_DIR}" -xzf "${OUT_DIR}/${BUNDLE_ARCHIVE}"

echo "downloaded release files:"
echo "  ${OUT_DIR}/${BUNDLE_ARCHIVE}"
echo "  ${OUT_DIR}/${PUBLIC_KEY_FILE}"
echo "  ${OUT_DIR}/${CHECKSUM_FILE}"
echo
echo "extracted bundle:"
echo "  ${BUNDLE_DIR}"
echo

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
