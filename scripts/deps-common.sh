#!/usr/bin/env bash
# Shared helpers for appliance-release/deps/* offline build-host packages.
# Source from package scripts:
#   source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
#
# Not a standalone CLI. When executed directly:
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
usage: source scripts/deps-common.sh

Shared helpers for deps/* packages (OCI login, files API upload, image mirror).
EOF
    exit 0
  fi
  echo "deps-common: source this file from deps package scripts; it is not a CLI" >&2
  exit 2
fi

set -euo pipefail

deps_require_var() {
  local n="$1"
  if [[ -z "${!n:-}" ]]; then
    echo "deps: ${n} is required" >&2
    exit 2
  fi
}

deps_registry_host() {
  local registry="${DEV_REGISTRY:-}"
  registry="${registry#https://}"
  registry="${registry#http://}"
  registry="${registry%/}"
  printf '%s' "${registry}"
}

deps_tls_insecure_curl() {
  case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) printf '%s' "-k" ;;
    *) printf '%s' "" ;;
  esac
}

deps_buildah_tls_flag() {
  case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) printf '%s' "--tls-verify=false" ;;
    *) printf '%s' "" ;;
  esac
}

deps_skopeo_tls_flag() {
  case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) printf '%s' "--dest-tls-verify=false --src-tls-verify=false" ;;
    *) printf '%s' "" ;;
  esac
}

deps_files_api_base() {
  local host
  host="$(deps_registry_host)"
  if [[ -z "${host}" ]]; then
    echo "deps: DEV_REGISTRY is required for files API" >&2
    exit 2
  fi
  printf 'https://%s/api/v1/files' "${host}"
}

deps_files_upload() {
  local src="$1"
  local remote_path="$2" # path after /api/v1/files/
  deps_require_var DEV_REGISTRY_TOKEN
  local insecure
  insecure="$(deps_tls_insecure_curl)"
  local url
  url="$(deps_files_api_base)/${remote_path#/}"
  local code
  # shellcheck disable=SC2086
  code="$(
    curl -sS ${insecure} -X POST \
      -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${DEV_REGISTRY_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary @"${src}" \
      "${url}"
  )"
  case "${code}" in
    200|201|204) echo "uploaded ${src} -> ${url} (${code})" ;;
    *)
      echo "deps: files upload failed HTTP ${code} for ${url}" >&2
      exit 1
      ;;
  esac
}

deps_oci_login() {
  deps_require_var DEV_REGISTRY
  deps_require_var DEV_REGISTRY_USER
  deps_require_var DEV_REGISTRY_TOKEN
  local host tls
  host="$(deps_registry_host)"
  tls="$(deps_buildah_tls_flag)"
  # shellcheck disable=SC2086
  echo "${DEV_REGISTRY_TOKEN}" | buildah login ${tls} --username "${DEV_REGISTRY_USER}" --password-stdin "${host}"
}

# Pull docker://SRC and tag as containers-storage LOCAL, then optionally push to DEST.
deps_mirror_oci() {
  local src="$1"
  local local_ref="$2"
  local dest="${3:-}"
  local tls
  tls="$(deps_skopeo_tls_flag)"
  if ! command -v skopeo >/dev/null 2>&1; then
    echo "deps: skopeo is required on PATH" >&2
    exit 1
  fi
  echo "mirror: ${src} -> ${local_ref}"
  # shellcheck disable=SC2086
  skopeo copy --override-os linux --override-arch amd64 \
    ${tls} \
    "docker://${src}" "containers-storage:${local_ref}"
  if [[ -n "${dest}" ]]; then
    echo "push: ${local_ref} -> ${dest}"
    # shellcheck disable=SC2086
    skopeo copy --override-os linux --override-arch amd64 \
      ${tls} \
      "containers-storage:${local_ref}" "docker://${dest}"
  fi
}

deps_build_cache_ref() {
  local short_name="$1"
  local pin="$2"
  local host
  host="$(deps_registry_host)"
  printf '%s/build-cache/%s:%s' "${host}" "${short_name}" "${pin}"
}
