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
  local code response_file response_body
  response_file="$(mktemp)"
  trap 'rm -f "${response_file}"' RETURN
  # Stream with -T + -X POST. --data-binary @file loads the whole payload into
  # memory and OOMs on multi-GB files (host-packages archives, release bundles).
  # shellcheck disable=SC2086
  code="$(
    curl -sS ${insecure} -X POST \
      -o "${response_file}" -w "%{http_code}" \
      -H "Authorization: Bearer ${DEV_REGISTRY_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      -T "${src}" \
      "${url}"
  )"
  case "${code}" in
    200|201|204) echo "uploaded ${src} -> ${url} (${code})" ;;
    *)
      response_body="$(tr '\n' ' ' <"${response_file}" | sed 's/[[:space:]]\+/ /g' | cut -c1-512)"
      if [[ -n "${response_body}" ]]; then
        echo "deps: files upload failed HTTP ${code} for ${url}: ${response_body}" >&2
      else
        echo "deps: files upload failed HTTP ${code} for ${url}" >&2
      fi
      exit 1
      ;;
  esac
}

deps_host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *)
      echo "deps-common: unsupported host machine $(uname -m) (want x86_64|aarch64)" >&2
      return 2
      ;;
  esac
}

# Containerfile RUN steps must execute on the host (or via qemu/binfmt).
# Call before podman build --arch when the build has RUN instructions
# (includes bootstrapping the first foreign-arch dev-build image).
deps_require_build_arch_runnable() {
  local want="${1-}"
  local host=""
  local binfmt=""
  if [[ -z "${want}" ]]; then
    want="${TARGET_ARCH-}"
  fi
  if [[ -z "${want}" ]]; then
    echo "deps-common: deps_require_build_arch_runnable requires TARGET_ARCH or an arch argument" >&2
    return 2
  fi
  host="$(deps_host_arch)" || return 2
  if [[ "${want}" == "${host}" ]]; then
    return 0
  fi
  case "${want}" in
    arm64) binfmt=/proc/sys/fs/binfmt_misc/qemu-aarch64 ;;
    amd64) binfmt=/proc/sys/fs/binfmt_misc/qemu-x86_64 ;;
    *)
      echo "deps-common: unsupported TARGET_ARCH=${want}" >&2
      return 2
      ;;
  esac
  if [[ -e "${binfmt}" ]] && grep -q '^enabled$' "${binfmt}" 2>/dev/null; then
    return 0
  fi
  echo "deps-common: cannot run Containerfile steps for TARGET_ARCH=${want} on this host (${host})." >&2
  echo "deps-common: that causes 'Exec format error' without qemu-user-static/binfmt." >&2
  if [[ -e "${binfmt}" ]]; then
    echo "deps-common: found ${binfmt} but it is not enabled." >&2
  else
    echo "deps-common: missing ${binfmt}." >&2
  fi
  echo "deps-common: either:" >&2
  echo "deps-common:   1) seed matching this host: TARGET_ARCH=${host} make seed-build-deps" >&2
  echo "deps-common:   2) on Ubuntu, enable ${want} emulation then re-run:" >&2
  echo "deps-common:        sudo apt-get install -y qemu-user-static binfmt-support" >&2
  echo "deps-common:        sudo systemctl restart systemd-binfmt || true" >&2
  echo "deps-common:        # confirm: test -e ${binfmt} && grep enabled ${binfmt}" >&2
  echo "deps-common:        TARGET_ARCH=${want} make seed-build-deps" >&2
  echo "deps-common: (first foreign-arch build of deps/development-container also needs this;" >&2
  echo "deps-common:  cross-arch RUN-heavy seeds use the same host+qemu path.)" >&2
  return 2
}

deps_default_build_cmd() {
  # Product-arch local builds must pass --arch so seed/build never silently
  # uses the host architecture when TARGET_ARCH differs.
  local architecture="${1-}"
  if [[ -z "${architecture}" ]]; then
    architecture="${TARGET_ARCH-}"
  fi
  if [[ -z "${architecture}" ]]; then
    echo "deps-common: deps_default_build_cmd requires TARGET_ARCH or an arch argument" >&2
    return 2
  fi
  case "${architecture}" in
    amd64|arm64) ;;
    *)
      echo "deps-common: unsupported architecture ${architecture} (want amd64|arm64)" >&2
      return 2
      ;;
  esac
  deps_require_podman
  printf 'podman build --arch %s' "${architecture}"
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
# ARCHITECTURE is required (amd64|arm64) — no default.
deps_mirror_oci() {
  local src="$1"
  local local_ref="$2"
  local dest="${3:-}"
  local architecture="${4-}"
  local tls pull_tls=()
  local bare host

  if [[ -z "${architecture}" ]]; then
    echo "deps-common: deps_mirror_oci requires architecture (amd64|arm64) as 4th argument" >&2
    return 2
  fi
  case "${architecture}" in
    amd64|arm64) ;;
    *)
      echo "deps-common: unsupported architecture ${architecture} (want amd64|arm64)" >&2
      return 2
      ;;
  esac

  deps_require_podman
  echo "mirror: ${src} -> ${local_ref} (arch=${architecture})"
  tls="$(deps_podman_tls_flag)"
  bare="${src}"
  host="$(deps_registry_host)"
  # Public pulls verify TLS; LAN registry pulls honor DEV_REGISTRY_TLS_VERIFY.
  if [[ -n "${host}" && ( "${bare}" == "${host}/"* || "${bare}" == "${host}:"* ) ]]; then
    # shellcheck disable=SC2206
    pull_tls=(${tls})
  fi
  # shellcheck disable=SC2086
  podman pull --arch "${architecture}" ${pull_tls[@]+"${pull_tls[@]}"} "${src}"
  podman tag "${src}" "${local_ref}"

  if [[ -n "${dest}" ]]; then
    deps_push_oci "${local_ref}" "${dest}"
  fi
}

# Push a local image reference to a remote docker registry ref.
# Logs in when DEV_REGISTRY_USER/TOKEN are set so nested tooling pushes work
# even when the host's podman login is not visible inside the container.
deps_push_oci() {
  local local_ref="$1"
  local dest="$2"
  local tls

  deps_require_podman
  if [[ -n "${DEV_REGISTRY_USER:-}" && -n "${DEV_REGISTRY_TOKEN:-}" ]]; then
    deps_oci_login
  fi
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
