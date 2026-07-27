#!/usr/bin/env bash
# Shared helpers for signed-bundle release distribution modes.
# Sourced by publish-release.sh and the release skill (via common.sh).

# Normalize bundle_store.mode / --mode to http|fileserver.
# Empty and historical http-static alias map to http.
normalize_bundle_store_mode() {
  local mode
  mode="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    ""|http|http-static)
      printf 'http\n'
      ;;
    fileserver)
      printf 'fileserver\n'
      ;;
    *)
      echo "bundle_store.mode must be http or fileserver (got ${mode:-<empty>})" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --help|-h|"")
      cat <<'EOF'
usage: source bundle-store-lib.sh

Provides normalize_bundle_store_mode (http|fileserver).
EOF
      exit 0
      ;;
    *)
      echo "bundle-store-lib.sh: source this file; unknown argument: ${1}" >&2
      exit 2
      ;;
  esac
fi
