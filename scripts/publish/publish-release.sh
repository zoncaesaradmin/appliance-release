#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: publish-release.sh --export-dir DIR --product-version VERSION [options]

Publish the already-built customer delivery files from scripts/ci/build-full-bundle.sh.

Implemented modes:
  http-static   Copy the exported files to a remote server over SSH/SCP, where
                they are then served by a plain HTTP/HTTPS server such as NGINX.

Options:
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
  --public-base-url URL      Optional public base URL override. If omitted,
                             the script derives http://<host> from --server.
  --latest-alias             Also update <remote-root>/<path-prefix>/latest/
                             to point at this version's files.

Examples:
  bash ./scripts/publish/publish-release.sh \
    --export-dir /tmp/appliance-build/export \
    --product-version 0.1.0 \
    --server release@downloads.internal \
    --remote-root /srv/www/releases \
    --public-base-url https://downloads.internal/releases \
    --latest-alias
EOF
}

MODE="http-static"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_DIR=""
PRODUCT_VERSION=""
SERVER_TARGET=""
REMOTE_ROOT=""
PATH_PREFIX="appliance"
SSH_PORT="22"
PUBLIC_BASE_URL=""
LATEST_ALIAS="0"
PUBLIC_BASE_URL_DERIVED="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
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

extract_host_from_target() {
  local target="$1"
  target="${target##*@}"
  target="${target#\[}"
  target="${target%\]}"
  printf '%s\n' "${target}"
}

require_var EXPORT_DIR
require_var PRODUCT_VERSION

EXPORT_DIR="$(cd "$(dirname "${EXPORT_DIR}")" && pwd)/$(basename "${EXPORT_DIR}")"
BUNDLE_ARCHIVE="${EXPORT_DIR}/appliance-${PRODUCT_VERSION}-bundle.tar.gz"
PUBLIC_KEY_FILE="${EXPORT_DIR}/release-signing.pub"
CHECKSUM_FILE="${EXPORT_DIR}/sha256sum.txt"
INSTALL_HELPER="${SCRIPT_DIR}/install-http-release.sh"
INSTALL_HELPER_PUBLISHED="install-http-release.sh"

require_file "${BUNDLE_ARCHIVE}" "bundle archive"
require_file "${PUBLIC_KEY_FILE}" "release signing public key"
require_file "${INSTALL_HELPER}" "install helper script"

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
    else
      PUBLIC_BASE_URL="http://$(extract_host_from_target "${SERVER_TARGET}")"
      PUBLIC_BASE_URL_DERIVED="1"
    fi

    REMOTE_VERSION_DIR="${REMOTE_ROOT}/${PATH_PREFIX}/${PRODUCT_VERSION}"
    REMOTE_LATEST_DIR="${REMOTE_ROOT}/${PATH_PREFIX}/latest"
    PUBLISH_STAGE_DIR="$(mktemp -d "${EXPORT_DIR}/.publish-stage.XXXXXX")"
    trap 'rm -rf "${PUBLISH_STAGE_DIR}"' EXIT

    # Stamp PRODUCT_VERSION into each helper's PRODUCT_VERSION_EMBEDDED
    # placeholder. The public helper filenames stay stable, so the
    # release version has to live in the file content itself, and that
    # also keeps curl-piped execution working where there is no useful
    # filename to parse.
    stamp_version() {
      local src="$1" dest="$2"
      sed "s/^PRODUCT_VERSION_EMBEDDED=\"\"\$/PRODUCT_VERSION_EMBEDDED=\"${PRODUCT_VERSION}\"/" "${src}" > "${dest}"
      chmod +x "${dest}"
    }
    stamp_version "${INSTALL_HELPER}" "${PUBLISH_STAGE_DIR}/${INSTALL_HELPER_PUBLISHED}"

    for stamped in "${PUBLISH_STAGE_DIR}/${INSTALL_HELPER_PUBLISHED}"; do
      if ! grep -q "PRODUCT_VERSION_EMBEDDED=\"${PRODUCT_VERSION}\"" "${stamped}"; then
        echo "publish-release: failed to stamp PRODUCT_VERSION_EMBEDDED into $(basename "${stamped}")" >&2
        exit 1
      fi
    done

    ssh -p "${SSH_PORT}" "${SERVER_TARGET}" "mkdir -p '${REMOTE_VERSION_DIR}'"
    scp -P "${SSH_PORT}" \
      "${BUNDLE_ARCHIVE}" \
      "${PUBLIC_KEY_FILE}" \
      "${CHECKSUM_FILE}" \
      "${PUBLISH_STAGE_DIR}/${INSTALL_HELPER_PUBLISHED}" \
      "${SERVER_TARGET}:${REMOTE_VERSION_DIR}/"

    if [[ "${LATEST_ALIAS}" == "1" ]]; then
      ssh -p "${SSH_PORT}" "${SERVER_TARGET}" \
        "mkdir -p '${REMOTE_LATEST_DIR}' && cp '${REMOTE_VERSION_DIR}/$(basename "${BUNDLE_ARCHIVE}")' '${REMOTE_LATEST_DIR}/' && cp '${REMOTE_VERSION_DIR}/$(basename "${PUBLIC_KEY_FILE}")' '${REMOTE_LATEST_DIR}/' && cp '${REMOTE_VERSION_DIR}/$(basename "${CHECKSUM_FILE}")' '${REMOTE_LATEST_DIR}/' && cp '${REMOTE_VERSION_DIR}/${INSTALL_HELPER_PUBLISHED}' '${REMOTE_LATEST_DIR}/'"
    fi

    echo "published release files:"
    echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/$(basename "${BUNDLE_ARCHIVE}")"
    echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/$(basename "${PUBLIC_KEY_FILE}")"
    echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/$(basename "${CHECKSUM_FILE}")"
    echo
    echo "published helper script:"
    echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/${INSTALL_HELPER_PUBLISHED}"

    echo
    echo "public base URL used for commands:"
    echo "  ${PUBLIC_BASE_URL}"
    if [[ "${PUBLIC_BASE_URL_DERIVED}" == "1" ]]; then
      echo "  note: derived automatically from PUBLISH_SERVER; override with PUBLISH_PUBLIC_BASE_URL if your HTTP server uses a non-default port or extra base path."
    fi
    echo
    echo "download URLs:"
    echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/$(basename "${BUNDLE_ARCHIVE}")"
    echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/$(basename "${PUBLIC_KEY_FILE}")"
    echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/$(basename "${CHECKSUM_FILE}")"
    echo
    echo "helper script URL:"
    echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/${INSTALL_HELPER_PUBLISHED}"
    echo
    echo "target host install command (single line, piped):"
    echo "  curl -fsSL ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/${INSTALL_HELPER_PUBLISHED} | bash -s -- --base-url ${PUBLIC_BASE_URL}"
    echo
    echo "target host install commands (download then run):"
    echo "  curl -fLo /tmp/${INSTALL_HELPER_PUBLISHED} ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/${INSTALL_HELPER_PUBLISHED}"
    echo "  bash /tmp/${INSTALL_HELPER_PUBLISHED} --base-url ${PUBLIC_BASE_URL}"
    if [[ "${LATEST_ALIAS}" == "1" ]]; then
      echo
      echo "latest alias URLs:"
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/$(basename "${BUNDLE_ARCHIVE}")"
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/$(basename "${PUBLIC_KEY_FILE}")"
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/$(basename "${CHECKSUM_FILE}")"
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/${INSTALL_HELPER_PUBLISHED}"
      echo
      echo "target host latest-install commands:"
      echo "  curl -fLo /tmp/${INSTALL_HELPER_PUBLISHED} ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/${INSTALL_HELPER_PUBLISHED}"
      echo "  bash /tmp/${INSTALL_HELPER_PUBLISHED} --base-url ${PUBLIC_BASE_URL} --use-latest"
    fi
    ;;
  *)
    echo "publish-release: unsupported mode: ${MODE}" >&2
    echo "publish-release: current mode is http-static; zot-based publishing can be added later without changing the build flow." >&2
    exit 2
    ;;
esac
