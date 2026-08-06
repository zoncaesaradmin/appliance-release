#!/usr/bin/env bash
# Shared helpers for signed-bundle release distribution.
# Sourced by the release skill (via common.sh).
# Publish itself is always the appliance file API (see publish-release.sh).

# Normalize / accept only appliance_files. Empty → appliance_files.
# static_http and other modes are rejected.
normalize_bundle_store_mode() {
  local mode
  mode="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    ""|appliance_files)
      printf 'appliance_files\n'
      ;;
    static_http)
      echo "bundle_store.mode=static_http was removed; only appliance_files (DEV_REGISTRY file API) is supported" >&2
      return 2
      ;;
    *)
      echo "bundle_store.mode must be appliance_files (got ${mode})" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --help|-h|"")
      cat <<'EOF'
usage: source bundle-store-lib.sh

Provides normalize_bundle_store_mode (appliance_files only).
EOF
      exit 0
      ;;
    *)
      echo "bundle-store-lib.sh: source this file; unknown argument: ${1}" >&2
      exit 2
      ;;
  esac
fi
