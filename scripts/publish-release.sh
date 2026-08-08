#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Fixed layout under the appliance file API.
readonly PUBLISH_PATH_PREFIX="appliance"
readonly PUBLISH_FILES_PATH="/api/v1/files"

usage() {
  cat <<'EOF'
usage: publish-release.sh [options]

Publish already-built customer delivery files from
scripts/build-full-bundle.sh to the appliance file API on the
artifact/dev registry host.

Uploads to:
  https://$DEV_REGISTRY/api/v1/files/appliance/<version>/

Required environment (same registry auth as build):
  DEV_REGISTRY              Artifact/dev registry host (no scheme)
  DEV_REGISTRY_TOKEN        Bearer token with files write access

Optional environment:
  DEV_REGISTRY_TLS_VERIFY   true|false (default: true). false → curl -k
  RELEASE_WORK_ROOT         Build root; export is $RELEASE_WORK_ROOT/export
                            (default: ${TMPDIR:-/tmp}/appliance-build)
  PRODUCT_VERSION           Override configs/default-product-version

Publishes whatever packs are listed in export/release-index.yaml from the
last build-full-bundle.sh run (default build is APPLIANCE_PACKS=all).

Options:
  --release-work-root DIR   Same as RELEASE_WORK_ROOT
  --product-version VERSION Same as PRODUCT_VERSION
  --latest-alias            Also upload under appliance/latest/
  --help                    Show this help

Example (after bootstrap + build-full-bundle on the build host):
  export DEV_REGISTRY=artifact-dns-1.example.internal
  export DEV_REGISTRY_TOKEN=…
  export DEV_REGISTRY_TLS_VERIFY=false
  export RELEASE_WORK_ROOT=/home/zonsys/appliance-build
  bash ./scripts/publish-release.sh
EOF
}

RELEASE_WORK_ROOT="${RELEASE_WORK_ROOT-}"
PRODUCT_VERSION="${PRODUCT_VERSION-}"
LATEST_ALIAS="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-work-root)
      RELEASE_WORK_ROOT="${2:-}"
      shift 2
      ;;
    --product-version)
      PRODUCT_VERSION="${2:-}"
      shift 2
      ;;
    --latest-alias)
      LATEST_ALIAS="1"
      shift 1
      ;;
    --export-dir|--mode|--server|--remote-root|--path-prefix|--public-base-url|--ssh-port)
      echo "publish-release: $1 is no longer supported." >&2
      echo "publish-release: only appliance file API publish remains; use DEV_REGISTRY + DEV_REGISTRY_TOKEN." >&2
      exit 2
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

if [[ -z "${PRODUCT_VERSION}" ]]; then
  PRODUCT_VERSION="$(tr -d '[:space:]' < "${RELEASE_REPO_DIR}/configs/default-product-version" 2>/dev/null || true)"
fi
[[ -n "${PRODUCT_VERSION}" ]] || {
  echo "publish-release: missing PRODUCT_VERSION and configs/default-product-version" >&2
  exit 2
}

if [[ -z "${RELEASE_WORK_ROOT}" ]]; then
  RELEASE_WORK_ROOT="${TMPDIR:-/tmp}/appliance-build"
fi

require_var DEV_REGISTRY
require_var DEV_REGISTRY_TOKEN

registry_host="$(printf '%s' "${DEV_REGISTRY}" | tr -d '[:space:]')"
registry_host="${registry_host#https://}"
registry_host="${registry_host#http://}"
registry_host="${registry_host%/}"
[[ -n "${registry_host}" ]] || {
  echo "publish-release: DEV_REGISTRY resolved empty" >&2
  exit 2
}

PUBLIC_BASE_URL="https://${registry_host}${PUBLISH_FILES_PATH}"
PATH_PREFIX="${PUBLISH_PATH_PREFIX}"

RELEASE_WORK_ROOT="$(cd "$(dirname "${RELEASE_WORK_ROOT}")" && pwd)/$(basename "${RELEASE_WORK_ROOT}")"
EXPORT_DIR="${RELEASE_WORK_ROOT}/export"
RELEASE_INDEX="${EXPORT_DIR}/release-index.yaml"
PUBLIC_KEY_FILE="${EXPORT_DIR}/release-signing.pub"
CHECKSUM_FILE="${EXPORT_DIR}/sha256sum.txt"
INSTALL_HELPER="${SCRIPT_DIR}/install-release.sh"
INSTALL_HELPER_PUBLISHED="install-release.sh"

if [[ ! -d "${EXPORT_DIR}" ]]; then
  echo "publish-release: export directory not found: ${EXPORT_DIR} (set RELEASE_WORK_ROOT)" >&2
  exit 1
fi

require_file "${RELEASE_INDEX}" "release index"
require_file "${PUBLIC_KEY_FILE}" "release signing public key"
require_file "${INSTALL_HELPER}" "install helper script"

mapfile -t PACK_FILENAMES < <(python3 - "${RELEASE_INDEX}" <<'PY'
from pathlib import Path
import sys

try:
    import yaml  # type: ignore
except ImportError:
    yaml = None

text = Path(sys.argv[1]).read_text(encoding="utf-8")
packs = []
if yaml is not None:
    data = yaml.safe_load(text) or {}
    for item in data.get("packs") or []:
        name = str((item or {}).get("filename") or "").strip()
        if name:
            packs.append(name)
else:
    # Minimal fallback without PyYAML: read "filename:" lines under packs.
    in_packs = False
    for line in text.splitlines():
        if line.startswith("packs:"):
            in_packs = True
            continue
        if in_packs and line and not line.startswith(" ") and not line.startswith("\t"):
            break
        if in_packs and "filename:" in line:
            packs.append(line.split("filename:", 1)[1].strip())
if not packs:
    raise SystemExit("publish-release: release-index.yaml lists no packs")
print("\n".join(packs))
PY
)

RELEASE_FILE_PAYLOADS=()
for pack_file in "${PACK_FILENAMES[@]}"; do
  require_file "${EXPORT_DIR}/${pack_file}" "pack archive ${pack_file}"
  RELEASE_FILE_PAYLOADS+=("${EXPORT_DIR}/${pack_file}")
done
RELEASE_FILE_PAYLOADS+=("${RELEASE_INDEX}" "${PUBLIC_KEY_FILE}")

CHECKSUM_TARGETS=()
for payload in "${RELEASE_FILE_PAYLOADS[@]}"; do
  CHECKSUM_TARGETS+=("$(basename "${payload}")")
done
if command -v shasum >/dev/null 2>&1; then
  (
    cd "${EXPORT_DIR}"
    shasum -a 256 "${CHECKSUM_TARGETS[@]}"
  ) > "${CHECKSUM_FILE}"
else
  (
    cd "${EXPORT_DIR}"
    sha256sum "${CHECKSUM_TARGETS[@]}"
  ) > "${CHECKSUM_FILE}"
fi

stamp_helper() {
  local src="$1" dest="$2"
  python3 - "${src}" "${dest}" "${PRODUCT_VERSION}" "${PATH_PREFIX}" "${PUBLIC_BASE_URL}" <<'PY'
from pathlib import Path
import sys

src, dest, version, path_prefix, base_url = sys.argv[1:6]
text = Path(src).read_text(encoding="utf-8")

def stamp(text: str, name: str, value: str) -> str:
    needle = f'{name}=""'
    if needle not in text:
        raise SystemExit(f"publish-release: stamp target {name}=\"\" not found in helper")
    return text.replace(needle, f'{name}="{value}"', 1)

text = stamp(text, "PRODUCT_VERSION_EMBEDDED", version)
text = stamp(text, "PATH_PREFIX_EMBEDDED", path_prefix)
text = stamp(text, "BASE_URL_EMBEDDED", base_url)
Path(dest).write_text(text, encoding="utf-8")
PY
  chmod +x "${dest}"
  if ! grep -q "PRODUCT_VERSION_EMBEDDED=\"${PRODUCT_VERSION}\"" "${dest}"; then
    echo "publish-release: failed to stamp PRODUCT_VERSION_EMBEDDED into ${dest}" >&2
    exit 1
  fi
  if ! grep -q "PATH_PREFIX_EMBEDDED=\"${PATH_PREFIX}\"" "${dest}"; then
    echo "publish-release: failed to stamp PATH_PREFIX_EMBEDDED into ${dest}" >&2
    exit 1
  fi
  if ! grep -Fq "BASE_URL_EMBEDDED=\"${PUBLIC_BASE_URL}\"" "${dest}"; then
    echo "publish-release: failed to stamp BASE_URL_EMBEDDED into ${dest}" >&2
    exit 1
  fi
}

curl_upload_file() {
  local src="$1"
  local url="$2"
  local -a curl_args=(-sS -X POST)
  local http_code body
  local tls_verify="${DEV_REGISTRY_TLS_VERIFY:-true}"
  case "$(printf '%s' "${tls_verify}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
      curl_args+=(-k)
      ;;
  esac
  if [[ -n "${PUBLISH_CACERT:-}" ]]; then
    curl_args+=(--cacert "${PUBLISH_CACERT}")
  fi
  body="$(mktemp)"
  # Stream with -T. Do not use --data-binary @file: curl loads the whole
  # payload into memory and OOMs on multi-GB appliance bundles.
  http_code="$(
    curl "${curl_args[@]}" \
      -o "${body}" -w "%{http_code}" \
      -H "Authorization: Bearer ${DEV_REGISTRY_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      -T "${src}" \
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

PUBLIC_BASE_URL="$(trim_trailing_slashes "${PUBLIC_BASE_URL}")"
PUBLISH_STAGE_DIR="$(mktemp -d "${EXPORT_DIR}/.publish-stage.XXXXXX")"
trap 'rm -rf "${PUBLISH_STAGE_DIR}"' EXIT
PUBLISHED_INSTALL_HELPER="${PUBLISH_STAGE_DIR}/${INSTALL_HELPER_PUBLISHED}"
stamp_helper "${INSTALL_HELPER}" "${PUBLISHED_INSTALL_HELPER}"
RELEASE_FILE_PAYLOADS+=(
  "${CHECKSUM_FILE}"
)
RELEASE_PAYLOADS=(
  "${RELEASE_FILE_PAYLOADS[@]}"
  "${PUBLISHED_INSTALL_HELPER}"
)

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
echo "  ${REMOTE_VERSION_DIR}/${INSTALL_HELPER_PUBLISHED}"
echo
echo "authenticated install helper example:"
echo "  curl -fsSL -H 'Authorization: Bearer <token>' -o install-release.sh ${REMOTE_VERSION_DIR}/${INSTALL_HELPER_PUBLISHED}"
echo "  bash install-release.sh --appliance-name <unique-name> [--appliance-profile <profile>]"
