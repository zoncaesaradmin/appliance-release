#!/usr/bin/env bash
# Shared identity for the offline control-plane UI dependency image.

ui_npm_deps_source_dir() {
  local release_repo_dir="$1"
  local parent grandparent candidate
  if [[ -n "${UI_NPM_SOURCE_DIR:-}" ]]; then
    ui_npm_deps_require_source "${UI_NPM_SOURCE_DIR}" || return 1
    printf '%s\n' "${UI_NPM_SOURCE_DIR}"
    return 0
  fi
  if [[ -n "${APPLIANCE_CODE_DIR:-}" ]]; then
    candidate="${APPLIANCE_CODE_DIR}/services/controlplane-ui"
    ui_npm_deps_require_source "${candidate}" || return 1
    printf '%s\n' "${candidate}"
    return 0
  fi
  if [[ -n "${RELEASE_WORK_ROOT:-}" ]]; then
    candidate="${RELEASE_WORK_ROOT}/repos/appliance-code/services/controlplane-ui"
    ui_npm_deps_require_source "${candidate}" || return 1
    printf '%s\n' "${candidate}"
    return 0
  fi
  parent="$(dirname "${release_repo_dir}")"
  grandparent="$(dirname "${parent}")"
  for candidate in "${parent}/appliance-code/services/controlplane-ui" \
    "${parent}/appliance-build/repos/appliance-code/services/controlplane-ui" \
    "${grandparent}/appliance-build/repos/appliance-code/services/controlplane-ui"; do
    if [[ -f "${candidate}/package.json" && -f "${candidate}/package-lock.json" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  echo "UI npm dependency source not found; set APPLIANCE_CODE_DIR to the appliance-code checkout used for the release" >&2
  return 1
}

ui_npm_deps_require_source() {
  local source_dir="$1"
  local file
  for file in package.json package-lock.json; do
    if [[ ! -f "${source_dir}/${file}" ]]; then
      echo "UI npm dependency source is missing ${source_dir}/${file}; set UI_NPM_SOURCE_DIR to the synchronized appliance-code controlplane-ui directory" >&2
      return 1
    fi
  done
}

ui_npm_deps_lock_digest() {
  local source_dir="$1"
  ui_npm_deps_require_source "${source_dir}"
  sha256sum "${source_dir}/package-lock.json" | awk '{print $1}'
}

ui_npm_deps_cache_tag() {
  local source_dir="$1"
  local target_arch="$2"
  local digest
  digest="$(ui_npm_deps_lock_digest "${source_dir}")"
  printf 'lockfile-%s-%s\n' "${digest:0:12}" "${target_arch}"
}
