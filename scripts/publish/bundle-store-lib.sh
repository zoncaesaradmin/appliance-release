#!/usr/bin/env bash
# Shared helpers for signed-bundle release distribution modes.
# Sourced by publish-release.sh and the release skill (via common.sh).

# Normalize bundle_store.mode / --mode to static_http|appliance_files.
# Empty is rejected (callers must pass an explicit mode from config or --mode).
normalize_bundle_store_mode() {
  local mode
  mode="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    static_http)
      printf 'static_http\n'
      ;;
    appliance_files)
      printf 'appliance_files\n'
      ;;
    "")
      echo "bundle_store.mode / --mode is required (static_http or appliance_files)" >&2
      return 2
      ;;
    *)
      echo "bundle_store.mode must be static_http or appliance_files (got ${mode})" >&2
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
EOF
      exit 0
      ;;
    *)
      echo "bundle-store-lib.sh: source this file; unknown argument: ${1}" >&2
      exit 2
      ;;
  esac
fi
