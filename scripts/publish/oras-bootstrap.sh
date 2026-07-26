#!/usr/bin/env bash
# Fetch a pinned linux/amd64 ORAS CLI on a networked build host and stage it
# for bundle packaging / OCI publish.
#
# Intended to run on the build host during build-full-bundle.sh (Ubuntu amd64
# targets for now). The Mac/orchestrator never downloads ORAS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ORAS_VERSION="${ORAS_VERSION:-1.3.3}"
ORAS_OS="linux"
ORAS_ARCH="amd64"
# sha256 of oras_${ORAS_VERSION}_${ORAS_OS}_${ORAS_ARCH}.tar.gz from the
# upstream checksums.txt for this release.
ORAS_TARBALL_SHA256="${ORAS_TARBALL_SHA256:-9ce999f8d2de03fc03968b29d743077a58783e545e5eaa53917ca177352d0e59}"
ORAS_RELEASE_BASE_URL="${ORAS_RELEASE_BASE_URL:-https://github.com/oras-project/oras/releases/download}"

usage() {
  cat <<'EOF'
usage: oras-bootstrap.sh [--print-path|--install-to DIR|--help]

Ensure a pinned linux/amd64 ORAS CLI exists in the local cache and either
print its path or install it to DIR/oras.

Run this on the build host (or any networked Linux amd64 builder). Do not run
it on the air-gapped install target.

Environment:
  ORAS_VERSION           Default: 1.3.3
  ORAS_TARBALL_SHA256    Expected sha256 of the upstream tarball
  ORAS_CACHE_DIR         Override cache directory
EOF
}

oras_cache_dir() {
  if [[ -n "${ORAS_CACHE_DIR:-}" ]]; then
    printf '%s\n' "${ORAS_CACHE_DIR}"
    return 0
  fi
  printf '%s\n' "${REPO_ROOT}/.cache/oras/v${ORAS_VERSION}/${ORAS_OS}-${ORAS_ARCH}"
}

oras_local_bin_path() {
  printf '%s/oras\n' "$(oras_cache_dir)"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    echo "oras-bootstrap: need sha256sum or shasum" >&2
    return 1
  fi
}

ensure_local_oras_linux_amd64() {
  local cache_dir bin_path tarball_name tarball_path url actual
  cache_dir="$(oras_cache_dir)"
  bin_path="$(oras_local_bin_path)"
  mkdir -p "${cache_dir}"
  if [[ -x "${bin_path}" ]]; then
    printf '%s\n' "${bin_path}"
    return 0
  fi

  tarball_name="oras_${ORAS_VERSION}_${ORAS_OS}_${ORAS_ARCH}.tar.gz"
  tarball_path="${cache_dir}/${tarball_name}"
  url="${ORAS_RELEASE_BASE_URL}/v${ORAS_VERSION}/${tarball_name}"

  if [[ ! -f "${tarball_path}" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "oras-bootstrap: curl is required on the build host to fetch ${tarball_name}" >&2
      return 1
    fi
    echo "oras-bootstrap: downloading ${url}" >&2
    curl -fL --retry 3 --retry-delay 2 -o "${tarball_path}.partial" "${url}"
    mv "${tarball_path}.partial" "${tarball_path}"
  fi

  actual="$(sha256_file "${tarball_path}")"
  if [[ "${actual}" != "${ORAS_TARBALL_SHA256}" ]]; then
    echo "oras-bootstrap: checksum mismatch for ${tarball_path}" >&2
    echo "oras-bootstrap: expected ${ORAS_TARBALL_SHA256}" >&2
    echo "oras-bootstrap: actual   ${actual}" >&2
    rm -f "${tarball_path}"
    return 1
  fi

  tar -C "${cache_dir}" -xzf "${tarball_path}" oras
  chmod +x "${bin_path}"
  rm -f "${tarball_path}"
  printf '%s\n' "${bin_path}"
}

install_oras_to() {
  local dest_dir="$1"
  local src_bin dest_bin
  [[ -n "${dest_dir}" ]] || {
    echo "oras-bootstrap: --install-to requires a directory" >&2
    return 2
  }
  src_bin="$(ensure_local_oras_linux_amd64)"
  dest_bin="${dest_dir%/}/oras"
  mkdir -p "${dest_dir}"
  cp -f "${src_bin}" "${dest_bin}"
  chmod +x "${dest_bin}"
  printf '%s\n' "${dest_bin}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
    ""|--print-path)
      ensure_local_oras_linux_amd64
      ;;
    --install-to)
      install_oras_to "${2:-}"
      ;;
    *)
      echo "oras-bootstrap: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
fi
