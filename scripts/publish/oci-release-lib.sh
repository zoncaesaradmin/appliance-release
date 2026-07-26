#!/usr/bin/env bash
# Shared helpers for publishing/pulling the signed appliance release package
# via ORAS to an already-running appliance Artifact Server (distribution OCI).
#
# Sourced by publish-release.sh, install-oci-release.sh, and the release skill.
# Expects bool_true / fail / require_cmd to already be defined by the caller,
# or defines minimal fallbacks when sourced standalone.

if ! declare -F bool_true >/dev/null 2>&1; then
  bool_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|y|on) return 0 ;;
      *) return 1 ;;
    esac
  }
fi

if ! declare -F fail >/dev/null 2>&1; then
  fail() {
    echo "oci-release: $*" >&2
    exit 1
  }
fi

if ! declare -F require_cmd >/dev/null 2>&1; then
  require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found on PATH: $1"
  }
fi

require_oras() {
  require_cmd oras
}

normalize_artifact_registry_mode() {
  local mode="${1:-}"
  mode="$(printf '%s' "${mode}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    ""|http|http-static) printf 'http\n' ;;
    oci) printf 'oci\n' ;;
    *)
      fail "artifact_registry.mode must be http or oci (got ${1})"
      ;;
  esac
}

oras_login_registry() {
  local registry="$1"
  local username="$2"
  local token="$3"
  local insecure="${4:-false}"
  local -a flags=()
  if bool_true "${insecure}"; then
    flags+=(--insecure)
  fi
  printf '%s\n' "${token}" | oras login "${flags[@]}" --username "${username}" --password-stdin "${registry}"
}

oras_push_release_package() {
  local registry="$1"
  local repository="$2"
  local version="$3"
  local stage_dir="$4"
  local insecure="${5:-false}"
  local latest_alias="${6:-0}"
  local ref="${registry}/${repository}:${version}"
  local -a flags=(--artifact-type "application/vnd.zon.appliance.release.v1+json")
  local bundle_name=""
  if bool_true "${insecure}"; then
    flags+=(--insecure)
  fi
  bundle_name="$(cd "${stage_dir}" && ls appliance-*-bundle.tar.gz | head -n 1)"
  [[ -n "${bundle_name}" ]] || fail "missing appliance-*-bundle.tar.gz in ${stage_dir}"
  (
    cd "${stage_dir}"
    oras push "${flags[@]}" "${ref}" \
      "${bundle_name}" \
      "release-signing.pub" \
      "sha256sum.txt" \
      "install-oci-release.sh"
  )
  if [[ "${latest_alias}" == "1" ]]; then
    local latest_ref="${registry}/${repository}:latest"
    (
      cd "${stage_dir}"
      oras push "${flags[@]}" "${latest_ref}" \
        "${bundle_name}" \
        "release-signing.pub" \
        "sha256sum.txt" \
        "install-oci-release.sh"
    )
  fi
}

oras_pull_release_package() {
  local registry="$1"
  local repository="$2"
  local version="$3"
  local out_dir="$4"
  local insecure="${5:-false}"
  local ref="${registry}/${repository}:${version}"
  local -a flags=()
  if bool_true "${insecure}"; then
    flags+=(--insecure)
  fi
  mkdir -p "${out_dir}"
  (
    cd "${out_dir}"
    oras pull "${flags[@]}" "${ref}"
  )
}

oras_manifest_exists() {
  local registry="$1"
  local repository="$2"
  local version="$3"
  local insecure="${4:-false}"
  local ref="${registry}/${repository}:${version}"
  local -a flags=()
  if bool_true "${insecure}"; then
    flags+=(--insecure)
  fi
  oras manifest fetch "${flags[@]}" "${ref}" >/dev/null
}
