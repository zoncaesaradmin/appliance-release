#!/usr/bin/env bash
# Shared helpers for appliance-release/deps/* offline build-host packages.
# Source from package scripts:
#   source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
#
# OCI tooling: podman only (pull / build / tag / push / login).
#
# Not a standalone CLI. When executed directly:
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
usage: source scripts/deps-common.sh

Shared helpers for deps/* packages (OCI login, files API upload, image mirror).
Requires podman on PATH.
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

deps_require_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    echo "deps: podman is required on PATH" >&2
    exit 1
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

deps_tls_verify_false() {
  case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY:-true}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) return 0 ;;
    *) return 1 ;;
  esac
}

deps_podman_tls_flag() {
  if deps_tls_verify_false; then
    printf '%s' "--tls-verify=false"
  else
    printf '%s' ""
  fi
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
  # Stream with -T + -X POST. --data-binary @file loads the whole payload into
  # memory and OOMs on multi-GB files (host-packages archives, release bundles).
  # shellcheck disable=SC2086
  code="$(
    curl -sS ${insecure} -X POST \
      -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${DEV_REGISTRY_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      -T "${src}" \
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

deps_default_build_cmd() {
  deps_require_podman
  printf '%s' "podman build"
}

deps_oci_login() {
  deps_require_podman
  deps_require_var DEV_REGISTRY
  deps_require_var DEV_REGISTRY_USER
  deps_require_var DEV_REGISTRY_TOKEN
  local host tls
  host="$(deps_registry_host)"
  tls="$(deps_podman_tls_flag)"
  # shellcheck disable=SC2086
  echo "${DEV_REGISTRY_TOKEN}" | podman login ${tls} --username "${DEV_REGISTRY_USER}" --password-stdin "${host}"
}

# Pull upstream SRC into local storage as LOCAL_REF; optionally push to DEST.
deps_mirror_oci() {
  local src="$1"
  local local_ref="$2"
  local dest="${3:-}"
  local tls pull_tls=()
  local bare host

  deps_require_podman
  echo "mirror: ${src} -> ${local_ref}"
  tls="$(deps_podman_tls_flag)"
  bare="${src}"
  host="$(deps_registry_host)"
  # Public pulls verify TLS; LAN registry pulls honor DEV_REGISTRY_TLS_VERIFY.
  if [[ -n "${host}" && ( "${bare}" == "${host}/"* || "${bare}" == "${host}:"* ) ]]; then
    # shellcheck disable=SC2206
    pull_tls=(${tls})
  fi
  # shellcheck disable=SC2086
  podman pull --arch amd64 ${pull_tls[@]+"${pull_tls[@]}"} "${src}"
  podman tag "${src}" "${local_ref}"

  if [[ -n "${dest}" ]]; then
    deps_push_oci "${local_ref}" "${dest}"
  fi
}

# Push a local image reference to a remote docker registry ref.
deps_push_oci() {
  local local_ref="$1"
  local dest="$2"
  local tls

  deps_require_podman
  echo "push: ${local_ref} -> ${dest}"
  tls="$(deps_podman_tls_flag)"
  podman tag "${local_ref}" "${dest}"
  # shellcheck disable=SC2086
  podman push ${tls} "${dest}"
}

deps_build_cache_ref() {
  local short_name="$1"
  local pin="$2"
  local host
  host="$(deps_registry_host)"
  printf '%s/build-cache/%s:%s' "${host}" "${short_name}" "${pin}"
}
