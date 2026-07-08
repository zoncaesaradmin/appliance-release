#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: publish-release.sh --mode MODE --export-dir DIR --product-version VERSION [options]

Publish the already-built customer delivery files from scripts/ci/build-full-bundle.sh.

Implemented modes:
  http-static   Copy the exported files to a remote server over SSH/SCP, where
                they are then served by a plain HTTP/HTTPS server such as NGINX.

Options:
  --mode MODE                Publishing mode. Required. Current: http-static
  --export-dir DIR           Directory containing:
                               appliance-<version>-bundle.tar.gz
                               release-signing.pub
                             Required.
  --product-version VERSION  Product version to publish. Required.

http-static mode options:
  --server USER@HOST         Remote SSH target. Required for http-static.
  --remote-root DIR          Remote root directory to publish under. Required.
  --path-prefix PATH         Prefix under remote root. Default: appliance
  --ssh-port PORT            SSH port. Default: 22
  --public-base-url URL      Optional public base URL. If set, prints final
                             download URLs.
  --latest-alias             Also update <remote-root>/<path-prefix>/latest/
                             to point at this version's files.

Examples:
  bash ./scripts/publish/publish-release.sh \
    --mode http-static \
    --export-dir /tmp/appliance-build/export \
    --product-version 0.1.0 \
    --server release@downloads.internal \
    --remote-root /srv/www/releases \
    --public-base-url https://downloads.internal/releases \
    --latest-alias
EOF
}

MODE=""
EXPORT_DIR=""
PRODUCT_VERSION=""
SERVER_TARGET=""
REMOTE_ROOT=""
PATH_PREFIX="appliance"
SSH_PORT="22"
PUBLIC_BASE_URL=""
LATEST_ALIAS="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --export-dir)
      EXPORT_DIR="${2:-}"
      shift 2
      ;;
    --product-version)
      PRODUCT_VERSION="${2:-}"
      shift 2
      ;;
    --server)
      SERVER_TARGET="${2:-}"
      shift 2
      ;;
    --remote-root)
      REMOTE_ROOT="${2:-}"
      shift 2
      ;;
    --path-prefix)
      PATH_PREFIX="${2:-}"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="${2:-}"
      shift 2
      ;;
    --public-base-url)
      PUBLIC_BASE_URL="${2:-}"
      shift 2
      ;;
    --latest-alias)
      LATEST_ALIAS="1"
      shift 1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "publish-release: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "publish-release: ${name} is required" >&2
    usage >&2
    exit 2
  fi
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "${path}" ]]; then
    echo "publish-release: missing ${label}: ${path}" >&2
    exit 1
  fi
}

trim_trailing_slashes() {
  local value="$1"
  while [[ "${value}" != "/" && "${value}" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "${value}"
}

require_var MODE
require_var EXPORT_DIR
require_var PRODUCT_VERSION

EXPORT_DIR="$(cd "$(dirname "${EXPORT_DIR}")" && pwd)/$(basename "${EXPORT_DIR}")"
BUNDLE_ARCHIVE="${EXPORT_DIR}/appliance-${PRODUCT_VERSION}-bundle.tar.gz"
PUBLIC_KEY_FILE="${EXPORT_DIR}/release-signing.pub"
CHECKSUM_FILE="${EXPORT_DIR}/sha256sum.txt"

require_file "${BUNDLE_ARCHIVE}" "bundle archive"
require_file "${PUBLIC_KEY_FILE}" "release signing public key"

if command -v shasum >/dev/null 2>&1; then
  (
    cd "${EXPORT_DIR}"
    shasum -a 256 "$(basename "${BUNDLE_ARCHIVE}")" "$(basename "${PUBLIC_KEY_FILE}")"
  ) > "${CHECKSUM_FILE}"
else
  (
    cd "${EXPORT_DIR}"
    sha256sum "$(basename "${BUNDLE_ARCHIVE}")" "$(basename "${PUBLIC_KEY_FILE}")"
  ) > "${CHECKSUM_FILE}"
fi

case "${MODE}" in
  http-static)
    require_var SERVER_TARGET
    require_var REMOTE_ROOT

    REMOTE_ROOT="$(trim_trailing_slashes "${REMOTE_ROOT}")"
    PATH_PREFIX="$(trim_trailing_slashes "${PATH_PREFIX}")"
    if [[ -n "${PUBLIC_BASE_URL}" ]]; then
      PUBLIC_BASE_URL="$(trim_trailing_slashes "${PUBLIC_BASE_URL}")"
    fi

    REMOTE_VERSION_DIR="${REMOTE_ROOT}/${PATH_PREFIX}/${PRODUCT_VERSION}"
    REMOTE_LATEST_DIR="${REMOTE_ROOT}/${PATH_PREFIX}/latest"

    ssh -p "${SSH_PORT}" "${SERVER_TARGET}" "mkdir -p '${REMOTE_VERSION_DIR}'"
    scp -P "${SSH_PORT}" \
      "${BUNDLE_ARCHIVE}" \
      "${PUBLIC_KEY_FILE}" \
      "${CHECKSUM_FILE}" \
      "${SERVER_TARGET}:${REMOTE_VERSION_DIR}/"

    if [[ "${LATEST_ALIAS}" == "1" ]]; then
      ssh -p "${SSH_PORT}" "${SERVER_TARGET}" \
        "mkdir -p '${REMOTE_LATEST_DIR}' && cp '${REMOTE_VERSION_DIR}/$(basename "${BUNDLE_ARCHIVE}")' '${REMOTE_LATEST_DIR}/' && cp '${REMOTE_VERSION_DIR}/$(basename "${PUBLIC_KEY_FILE}")' '${REMOTE_LATEST_DIR}/' && cp '${REMOTE_VERSION_DIR}/$(basename "${CHECKSUM_FILE}")' '${REMOTE_LATEST_DIR}/'"
    fi

    echo "published release files:"
    echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/$(basename "${BUNDLE_ARCHIVE}")"
    echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/$(basename "${PUBLIC_KEY_FILE}")"
    echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/$(basename "${CHECKSUM_FILE}")"

    if [[ -n "${PUBLIC_BASE_URL}" ]]; then
      echo
      echo "download URLs:"
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/$(basename "${BUNDLE_ARCHIVE}")"
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/$(basename "${PUBLIC_KEY_FILE}")"
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/$(basename "${CHECKSUM_FILE}")"
      if [[ "${LATEST_ALIAS}" == "1" ]]; then
        echo
        echo "latest alias URLs:"
        echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/$(basename "${BUNDLE_ARCHIVE}")"
        echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/$(basename "${PUBLIC_KEY_FILE}")"
        echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/$(basename "${CHECKSUM_FILE}")"
      fi
    fi
    ;;
  *)
    echo "publish-release: unsupported mode: ${MODE}" >&2
    echo "publish-release: current mode is http-static; zot-based publishing can be added later without changing the build flow." >&2
    exit 2
    ;;
esac
