#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: assemble-simple-bundle.sh --workdir DIR --zonctl-binary PATH [--config PATH]

Validates the simple bundle workspace and assembles the final bundle via
the appliance-release Makefile.
EOF
}

WORKDIR=""
CONFIG_PATH=""
ZONCTL_BINARY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --zonctl-binary)
      ZONCTL_BINARY="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "assemble-simple-bundle: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${WORKDIR}" ]]; then
  echo "assemble-simple-bundle: --workdir is required" >&2
  usage >&2
  exit 2
fi
if [[ -z "${ZONCTL_BINARY}" ]]; then
  echo "assemble-simple-bundle: --zonctl-binary is required" >&2
  usage >&2
  exit 2
fi

WORKDIR="$(cd "$(dirname "${WORKDIR}")" && pwd)/$(basename "${WORKDIR}")"
ZONCTL_BINARY="$(cd "$(dirname "${ZONCTL_BINARY}")" && pwd)/$(basename "${ZONCTL_BINARY}")"
if [[ -z "${CONFIG_PATH}" ]]; then
  CONFIG_PATH="${WORKDIR}/bundle-assembly.simple.json"
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "assemble-simple-bundle: missing config: ${CONFIG_PATH}" >&2
  exit 1
fi

extract_json_string() {
  local key="$1"
  local path="$2"
  sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" "${path}" | head -n 1
}

RELEASE_INPUT_DIR="$(extract_json_string releaseInputDir "${CONFIG_PATH}")"
if [[ -z "${RELEASE_INPUT_DIR}" ]]; then
  echo "assemble-simple-bundle: could not read releaseInputDir from ${CONFIG_PATH}" >&2
  exit 1
fi

if [[ ! -f "${RELEASE_INPUT_DIR}/release-input.json" ]]; then
  echo "assemble-simple-bundle: missing ${RELEASE_INPUT_DIR}/release-input.json" >&2
  echo "populate the release-input handoff from appliance-code first" >&2
  exit 1
fi
if [[ ! -x "${ZONCTL_BINARY}" ]]; then
  echo "assemble-simple-bundle: zonctl binary is missing or not executable: ${ZONCTL_BINARY}" >&2
  exit 1
fi

"${ZONCTL_BINARY}" assemble-bundle --config "${CONFIG_PATH}"
