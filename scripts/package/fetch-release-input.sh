#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: fetch-release-input.sh --workdir DIR [--source PATH_OR_URL | --version VERSION --template TEMPLATE]

Fetches or imports a release-input artifact and imports it into the
workspace's release-input/ directory.

Examples:
  --source /path/to/release-input-0.1.0.tar.gz
  --source https://example.invalid/release-input-0.1.0.tar.gz
  --version 0.1.0 --template /artifacts/release-input-{version}.tar.gz
  --version latest --template https://example.invalid/release-input-{version}.tar.gz
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR=""
SOURCE=""
VERSION=""
TEMPLATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --template)
      TEMPLATE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "fetch-release-input: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${WORKDIR}" ]]; then
  echo "fetch-release-input: --workdir is required" >&2
  usage >&2
  exit 2
fi

if [[ -n "${SOURCE}" && -n "${VERSION}" ]]; then
  echo "fetch-release-input: choose either --source or --version/--template, not both" >&2
  exit 2
fi

if [[ -z "${SOURCE}" ]]; then
  if [[ -z "${VERSION}" || -z "${TEMPLATE}" ]]; then
    echo "fetch-release-input: either --source or both --version and --template are required" >&2
    usage >&2
    exit 2
  fi
  if [[ "${TEMPLATE}" != *"{version}"* ]]; then
    echo "fetch-release-input: --template must contain {version}" >&2
    exit 2
  fi
  SOURCE="${TEMPLATE//\{version\}/${VERSION}}"
fi

WORKDIR="$(cd "$(dirname "${WORKDIR}")" && pwd)/$(basename "${WORKDIR}")"
CACHE_DIR="${WORKDIR}/downloads"
RELEASE_INPUT_DIR="${WORKDIR}/release-input"
mkdir -p "${CACHE_DIR}"

is_url() {
  [[ "$1" =~ ^https?:// ]] || [[ "$1" =~ ^file:// ]]
}

download_to_cache() {
  local src="$1"
  local dest="$2"
  if [[ "${src}" =~ ^file:// ]]; then
    local local_path="${src#file://}"
    cp "${local_path}" "${dest}"
    return 0
  fi
  curl -fsSL "${src}" -o "${dest}"
}

LOCAL_SOURCE=""
if is_url "${SOURCE}"; then
  filename="$(basename "${SOURCE}")"
  if [[ -z "${filename}" || "${filename}" == "/" ]]; then
    filename="release-input-${VERSION:-fetched}.tar.gz"
  fi
  LOCAL_SOURCE="${CACHE_DIR}/${filename}"
  download_to_cache "${SOURCE}" "${LOCAL_SOURCE}"
else
  mkdir -p "$(dirname "${SOURCE}")"
  LOCAL_SOURCE="$(cd "$(dirname "${SOURCE}")" && pwd)/$(basename "${SOURCE}")"
fi

if [[ ! -d "${WORKDIR}" ]]; then
  echo "fetch-release-input: workspace does not exist: ${WORKDIR}" >&2
  echo "run init-simple-workspace first" >&2
  exit 1
fi

mkdir -p "${RELEASE_INPUT_DIR}"
find "${RELEASE_INPUT_DIR}" -mindepth 1 -delete

case "${LOCAL_SOURCE}" in
  *.tar.gz|*.tgz)
    tar -xzf "${LOCAL_SOURCE}" -C "${RELEASE_INPUT_DIR}"
    ;;
  *.tar)
    tar -xf "${LOCAL_SOURCE}" -C "${RELEASE_INPUT_DIR}"
    ;;
  *)
    if [[ -d "${LOCAL_SOURCE}" ]]; then
      cp -R "${LOCAL_SOURCE}/." "${RELEASE_INPUT_DIR}/"
    else
      echo "fetch-release-input: unsupported source: ${LOCAL_SOURCE}" >&2
      exit 1
    fi
    ;;
esac

if [[ ! -f "${RELEASE_INPUT_DIR}/release-input.json" ]]; then
  echo "fetch-release-input: imported content does not contain release-input.json at the root" >&2
  exit 1
fi

echo "imported release-input into:"
echo "  ${RELEASE_INPUT_DIR}"
