#!/usr/bin/env bash
# Shared helpers for signed-bundle release distribution modes.
# Sourced by publish-release.sh and the release skill (via common.sh).

# Normalize bundle_store.mode / --mode to static_http|appliance_files.
# Empty and historical aliases (http, http-static) map to static_http.
# Historical fileserver maps to appliance_files.
normalize_bundle_store_mode() {
  local mode
  mode="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    ""|static_http|http|http-static)
      printf 'static_http\n'
      ;;
    appliance_files|fileserver)
      printf 'appliance_files\n'
      ;;
    *)
      echo "bundle_store.mode must be static_http or appliance_files (got ${mode:-<empty>})" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --help|-h|"")
      cat <<'EOF'
usage: source bundle-store-lib.sh

Provides normalize_bundle_store_mode (static_http|appliance_files).
Historical aliases: http/http-static -> static_http; fileserver -> appliance_files.
EOF
      exit 0
      ;;
    *)
      echo "bundle-store-lib.sh: source this file; unknown argument: ${1}" >&2
      exit 2
      ;;
  esac
fi
