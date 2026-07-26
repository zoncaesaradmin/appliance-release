#!/usr/bin/env bash
# Shared helpers for signed-bundle release distribution modes.
# Sourced by publish-release.sh and the release skill (via common.sh).

# Normalize artifact_registry.mode / --mode to http|fileserver.
# Empty and historical http-static alias map to http.
normalize_artifact_registry_mode() {
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
      echo "artifact_registry.mode must be http or fileserver (got ${mode:-<empty>})" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --help|-h|"")
      cat <<'EOF'
usage: source artifact-registry-lib.sh

Provides normalize_artifact_registry_mode (http|fileserver).
EOF
      exit 0
      ;;
    *)
      echo "artifact-registry-lib.sh: source this file; unknown argument: ${1}" >&2
      exit 2
      ;;
  esac
fi
