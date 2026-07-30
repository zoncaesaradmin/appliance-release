#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/bundle-store-lib.sh"

usage() {
  cat <<'EOF'
usage: publish-release.sh --export-dir DIR --product-version VERSION [options]

Publish the already-built customer delivery files from scripts/ci/build-full-bundle.sh.

Modes:
  static_http       Copy exported files to a remote server over SSH/SCP for a
                    plain HTTP/HTTPS static file server (default).
  appliance_files   Publish through the appliance-managed authenticated file API.
                    Set PUBLISH_BEARER_TOKEN and point --public-base-url at the
                    appliance file API base, for example:
                    https://artifact-dns-1.appliance.internal/api/v1/files

Options:
  --export-dir DIR           Directory containing:
                               appliance-<version>-bundle.tar.gz
                               release-signing.pub
                             Required.
  --product-version VERSION  Product version to publish. Required.
  --mode MODE                static_http|appliance_files. Required.
  --latest-alias             Also publish/update <path-prefix>/latest/ (static_http).

static_http mode options:
  --server USER@HOST         Remote SSH target. Required for static_http.
  --remote-root DIR          Remote root directory to publish under. Required.
  --path-prefix PATH         Prefix under remote root / URL. Required
                             (from bundle_store.release_path_prefix).
  --ssh-port PORT            SSH port. Default: 22
  --public-base-url URL      Public base URL. Required (from
                             bundle_store.base_url).
  appliance_files mode requires:
    PUBLISH_BEARER_TOKEN     Appliance API bearer token with artifacts.write.
    PUBLISH_TLS_INSECURE=1   Optional; skip TLS verify for self-signed certs.
    PUBLISH_CACERT=PATH      Optional; PEM CA bundle (overrides insecure).

Examples:
  bash ./scripts/publish/publish-release.sh \
    --export-dir /tmp/appliance-build/export \
    --product-version 0.1.0 \
    --server release@downloads.internal \
    --remote-root /srv/www/releases \
    --path-prefix appliance \
    --public-base-url https://downloads.internal/releases
EOF
}

MODE=""
EXPORT_DIR=""
PRODUCT_VERSION=""
SERVER_TARGET=""
REMOTE_ROOT=""
PATH_PREFIX=""
SSH_PORT="22"
PUBLIC_BASE_URL=""
LATEST_ALIAS="0"

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
    --mode)
      MODE="${2:-}"
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

curl_upload_file() {
  local src="$1"
  local url="$2"
  local -a curl_args=(-sS -X POST)
  local http_code body
  if [[ "${PUBLISH_TLS_INSECURE:-}" == "1" ]]; then
    curl_args+=(-k)
  fi
  if [[ -n "${PUBLISH_CACERT:-}" ]]; then
    curl_args+=(--cacert "${PUBLISH_CACERT}")
  fi
  body="$(mktemp)"
  http_code="$(
    curl "${curl_args[@]}" \
      -o "${body}" -w "%{http_code}" \
      -H "Authorization: Bearer ${PUBLISH_BEARER_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${src}" \
      "${url}"
  )"
  if [[ "${http_code}" != 200 && "${http_code}" != 201 ]]; then
    echo "publish-release: upload failed http=${http_code} src=${src} url=${url}" >&2
    if [[ -s "${body}" ]]; then
      head -c 512 "${body}" >&2 || true
      echo >&2
    fi
    rm -f "${body}"
    return 22
  fi
  cat "${body}"
  rm -f "${body}"
}

upload_payloads_to_api_dir() {
  local remote_dir="$1"
  local payload=""
  for payload in "${RELEASE_PAYLOADS[@]}"; do
    curl_upload_file "${payload}" "${remote_dir}/$(basename "${payload}")" >/dev/null
  done
}

print_target_download_and_run_commands() {
  local heading="$1"
  local helper_url="$2"
  local use_latest_flag="${3:-}"
  echo "${heading}:"
  echo "  curl -fLo /tmp/${INSTALL_HELPER_HTTP_PUBLISHED} ${helper_url}"
  if [[ -n "${use_latest_flag}" ]]; then
    echo "  bash /tmp/${INSTALL_HELPER_HTTP_PUBLISHED} --base-url ${PUBLIC_BASE_URL} ${use_latest_flag} \\"
  else
    echo "  bash /tmp/${INSTALL_HELPER_HTTP_PUBLISHED} --base-url ${PUBLIC_BASE_URL} \\"
  fi
  echo "    --out-dir /tmp/appliance-${PRODUCT_VERSION} --state-dir /var/lib/zon/state \\"
  echo "    --appliance-profile <profile> --appliance-name <name> --dns-zone <zone>"
}

MODE="$(normalize_bundle_store_mode "${MODE}")" || {
  echo "publish-release: --mode is required (static_http or appliance_files)" >&2
  usage >&2
  exit 2
}

require_var EXPORT_DIR
require_var PRODUCT_VERSION
require_var PATH_PREFIX
require_var PUBLIC_BASE_URL

EXPORT_DIR="$(cd "$(dirname "${EXPORT_DIR}")" && pwd)/$(basename "${EXPORT_DIR}")"
BUNDLE_ARCHIVE="${EXPORT_DIR}/appliance-${PRODUCT_VERSION}-bundle.tar.gz"
PUBLIC_KEY_FILE="${EXPORT_DIR}/release-signing.pub"
CHECKSUM_FILE="${EXPORT_DIR}/sha256sum.txt"
INSTALL_HELPER_HTTP="${SCRIPT_DIR}/install-http-release.sh"
INSTALL_HELPER_HTTP_PUBLISHED="install-http-release.sh"

require_file "${BUNDLE_ARCHIVE}" "bundle archive"
require_file "${PUBLIC_KEY_FILE}" "release signing public key"
require_file "${INSTALL_HELPER_HTTP}" "HTTP install helper script"

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

stamp_helper() {
  local src="$1" dest="$2"
  sed \
    -e "s/^PRODUCT_VERSION_EMBEDDED=\"\"\$/PRODUCT_VERSION_EMBEDDED=\"${PRODUCT_VERSION}\"/" \
    -e "s/^PATH_PREFIX_EMBEDDED=\"\"\$/PATH_PREFIX_EMBEDDED=\"${PATH_PREFIX}\"/" \
    "${src}" > "${dest}"
  chmod +x "${dest}"
  if ! grep -q "PRODUCT_VERSION_EMBEDDED=\"${PRODUCT_VERSION}\"" "${dest}"; then
    echo "publish-release: failed to stamp PRODUCT_VERSION_EMBEDDED into ${dest}" >&2
    exit 1
  fi
  if ! grep -q "PATH_PREFIX_EMBEDDED=\"${PATH_PREFIX}\"" "${dest}"; then
    echo "publish-release: failed to stamp PATH_PREFIX_EMBEDDED into ${dest}" >&2
    exit 1
  fi
}

PATH_PREFIX="$(trim_trailing_slashes "${PATH_PREFIX}")"
PUBLIC_BASE_URL="$(trim_trailing_slashes "${PUBLIC_BASE_URL}")"
PUBLISH_STAGE_DIR="$(mktemp -d "${EXPORT_DIR}/.publish-stage.XXXXXX")"
trap 'rm -rf "${PUBLISH_STAGE_DIR}"' EXIT
PUBLISHED_INSTALL_HELPER="${PUBLISH_STAGE_DIR}/${INSTALL_HELPER_HTTP_PUBLISHED}"
stamp_helper "${INSTALL_HELPER_HTTP}" "${PUBLISHED_INSTALL_HELPER}"
RELEASE_FILE_PAYLOADS=(
  "${BUNDLE_ARCHIVE}"
  "${PUBLIC_KEY_FILE}"
  "${CHECKSUM_FILE}"
)
RELEASE_PAYLOADS=(
  "${RELEASE_FILE_PAYLOADS[@]}"
  "${PUBLISHED_INSTALL_HELPER}"
)

case "${MODE}" in
  static_http)
    require_var SERVER_TARGET
    require_var REMOTE_ROOT

    REMOTE_ROOT="$(trim_trailing_slashes "${REMOTE_ROOT}")"
    REMOTE_VERSION_DIR="${REMOTE_ROOT}/${PATH_PREFIX}/${PRODUCT_VERSION}"
    REMOTE_LATEST_DIR="${REMOTE_ROOT}/${PATH_PREFIX}/latest"

    ssh -p "${SSH_PORT}" "${SERVER_TARGET}" "mkdir -p '${REMOTE_VERSION_DIR}'"
    scp -P "${SSH_PORT}" "${RELEASE_PAYLOADS[@]}" "${SERVER_TARGET}:${REMOTE_VERSION_DIR}/"

    if [[ "${LATEST_ALIAS}" == "1" ]]; then
      latest_copy_cmd="mkdir -p '${REMOTE_LATEST_DIR}'"
      for payload in "${RELEASE_PAYLOADS[@]}"; do
        latest_copy_cmd+=" && cp '${REMOTE_VERSION_DIR}/$(basename "${payload}")' '${REMOTE_LATEST_DIR}/'"
      done
      ssh -p "${SSH_PORT}" "${SERVER_TARGET}" \
        "${latest_copy_cmd}"
    fi

    echo "published release files:"
    for payload in "${RELEASE_FILE_PAYLOADS[@]}"; do
      echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/$(basename "${payload}")"
    done
    echo
    echo "published helper script:"
    echo "  ${SERVER_TARGET}:${REMOTE_VERSION_DIR}/${INSTALL_HELPER_HTTP_PUBLISHED}"
    echo
    echo "public base URL used for commands:"
    echo "  ${PUBLIC_BASE_URL}"
    echo
    echo "download URLs:"
    for payload in "${RELEASE_FILE_PAYLOADS[@]}"; do
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/$(basename "${payload}")"
    done
    echo
    echo "helper script URL:"
    echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/${INSTALL_HELPER_HTTP_PUBLISHED}"
    echo
    echo "target host install command (pass target-specific flags; version/path-prefix are stamped):"
    echo "  curl -fsSL ${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/${INSTALL_HELPER_HTTP_PUBLISHED} | bash -s -- \\"
    echo "    --base-url ${PUBLIC_BASE_URL} \\"
    echo "    --out-dir /tmp/appliance-${PRODUCT_VERSION} \\"
    echo "    --state-dir /var/lib/zon/state \\"
    echo "    --appliance-profile <profile> \\"
    echo "    --appliance-name <name> \\"
    echo "    --dns-zone <zone>"
    echo
    print_target_download_and_run_commands \
      "target host install commands (download then run)" \
      "${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}/${INSTALL_HELPER_HTTP_PUBLISHED}"
    if [[ "${LATEST_ALIAS}" == "1" ]]; then
      echo
      echo "latest alias URLs:"
      for payload in "${RELEASE_FILE_PAYLOADS[@]}"; do
        echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/$(basename "${payload}")"
      done
      echo "  ${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/${INSTALL_HELPER_HTTP_PUBLISHED}"
      echo
      print_target_download_and_run_commands \
        "target host latest-install commands" \
        "${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest/${INSTALL_HELPER_HTTP_PUBLISHED}" \
        "--use-latest"
    fi
    ;;
  appliance_files)
    require_var PUBLISH_BEARER_TOKEN

    REMOTE_VERSION_DIR="${PUBLIC_BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}"
    upload_payloads_to_api_dir "${REMOTE_VERSION_DIR}"

    if [[ "${LATEST_ALIAS}" == "1" ]]; then
      REMOTE_LATEST_DIR="${PUBLIC_BASE_URL}/${PATH_PREFIX}/latest"
      upload_payloads_to_api_dir "${REMOTE_LATEST_DIR}"
    fi

    echo "published release files via appliance file API:"
    for payload in "${RELEASE_FILE_PAYLOADS[@]}"; do
      echo "  ${REMOTE_VERSION_DIR}/$(basename "${payload}")"
    done
    echo
    echo "published helper script:"
    echo "  ${REMOTE_VERSION_DIR}/${INSTALL_HELPER_HTTP_PUBLISHED}"
    echo
    echo "authenticated install helper example:"
    echo "  curl -fsSL -H 'Authorization: Bearer <token>' ${REMOTE_VERSION_DIR}/${INSTALL_HELPER_HTTP_PUBLISHED} | bash -s -- --base-url ${PUBLIC_BASE_URL}"
    ;;
  *)
    echo "publish-release: unsupported mode: ${MODE}" >&2
    exit 2
    ;;
esac
