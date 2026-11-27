#!/usr/bin/env bash
# Shared identity for the offline control-plane UI dependency image.

ui_npm_deps_source_dir() {
  local release_repo_dir="$1"
  printf '%s\n' "${UI_NPM_SOURCE_DIR:-$(cd "${release_repo_dir}/.." && pwd)/appliance-code/services/controlplane-ui}"
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
