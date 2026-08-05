#!/usr/bin/env bash
# Component rebuild cache for appliance full-bundle builds (Phase C).
#
# When COMPONENT_CACHE_DIR is set, component recipes may skip a build if a
# matching input fingerprint is already cached, and restore prior outputs.
# Assemble + sign of the final super-bundle remains unconditional in the
# caller (build-full-bundle always re-runs assemble).
#
# Safe no-ops when COMPONENT_CACHE_DIR is empty or unset.

if [[ -n "${COMPONENT_CACHE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
COMPONENT_CACHE_SOURCED=1

# component_fingerprint ID input...
# Prints a stable hex digest of the component id plus listed inputs (file
# content digests for paths that exist; otherwise the literal string).
component_fingerprint() {
  local component_id="$1"
  shift
  local parts=("${component_id}")
  local input path digest
  for input in "$@"; do
    if [[ -f "${input}" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum "${input}" | awk '{print $1}')"
      else
        digest="$(shasum -a 256 "${input}" | awk '{print $1}')"
      fi
      parts+=("file:${input}:${digest}")
    elif [[ -d "${input}" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        digest="$(find "${input}" -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
      else
        digest="$(find "${input}" -type f -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}')"
      fi
      parts+=("dir:${input}:${digest}")
    else
      parts+=("str:${input}")
    fi
  done
  local joined
  joined="$(printf '%s\n' "${parts[@]}")"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${joined}" | sha256sum | awk '{print $1}'
  else
    printf '%s' "${joined}" | shasum -a 256 | awk '{print $1}'
  fi
}

# component_cache_try_restore ID dest [inputs...]
# Returns 0 if cache hit and dest was restored; 1 if rebuild needed.
component_cache_try_restore() {
  local component_id="$1"
  local dest="$2"
  shift 2
  if [[ -z "${COMPONENT_CACHE_DIR:-}" ]]; then
    return 1
  fi
  local fp cache_root stamp payload
  fp="$(component_fingerprint "${component_id}" "$@")"
  cache_root="${COMPONENT_CACHE_DIR}/${component_id}/${fp}"
  stamp="${cache_root}/.fingerprint"
  payload="${cache_root}/payload"
  if [[ ! -f "${stamp}" || ! -d "${payload}" ]]; then
    return 1
  fi
  if [[ "$(tr -d '[:space:]' <"${stamp}")" != "${fp}" ]]; then
    return 1
  fi
  rm -rf "${dest}"
  mkdir -p "${dest}"
  cp -a "${payload}/." "${dest}/"
  echo "component-cache: hit ${component_id} (${fp:0:12}…)" >&2
  return 0
}

# component_cache_store ID source [inputs...]
# Stores source directory under the fingerprint of ID + inputs.
component_cache_store() {
  local component_id="$1"
  local source="$2"
  shift 2
  if [[ -z "${COMPONENT_CACHE_DIR:-}" ]]; then
    return 0
  fi
  if [[ ! -d "${source}" ]]; then
    echo "component-cache: store skipped (not a directory): ${source}" >&2
    return 0
  fi
  local fp cache_root
  fp="$(component_fingerprint "${component_id}" "$@")"
  cache_root="${COMPONENT_CACHE_DIR}/${component_id}/${fp}"
  rm -rf "${cache_root}"
  mkdir -p "${cache_root}/payload"
  cp -a "${source}/." "${cache_root}/payload/"
  printf '%s\n' "${fp}" >"${cache_root}/.fingerprint"
  echo "component-cache: stored ${component_id} (${fp:0:12}…)" >&2
}
