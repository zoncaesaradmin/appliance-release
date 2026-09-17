#!/usr/bin/env bash
# Run a command inside the arch-matched shared tooling image (dev-build).
# Same image contract as appliance-code make dev-shell / dev-run — do not fork.
#
# Required:
#   TARGET_ARCH=amd64|arm64
# Optional:
#   DEV_IMAGE                 Full image ref (overrides composition)
#   DEV_REGISTRY / DEV_IMAGE_REPO / DEV_IMAGE_NAME / DEV_IMAGE_TAG
#     Default tag: latest → latest-${TARGET_ARCH} (bare tags are auto-suffixed)

#   DEV_REGISTRY_TLS_VERIFY   true|false (pull TLS)
#
# Usage:
#   TARGET_ARCH=arm64 bash scripts/run-in-dev-build.sh make -C deps/artifact-server-bases build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/deps-common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/target-arch.sh"

usage() {
  cat <<'EOF'
usage: run-in-dev-build.sh COMMAND [ARGS...]

Run COMMAND inside arch-matched dev-build tooling (podman run --arch TARGET_ARCH).
TARGET_ARCH is required. Image tag defaults to latest-${TARGET_ARCH}.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

target_arch_resolve
deps_require_podman
# Starting a foreign-arch tooling container needs binfmt when host ≠ TARGET_ARCH.
deps_require_build_arch_runnable "${TARGET_ARCH}"

DEV_IMAGE_NAME="${DEV_IMAGE_NAME:-dev-build}"
DEV_IMAGE_REPO="${DEV_IMAGE_REPO:-development-container}"
# Packaging configs often export bare DEV_IMAGE_TAG=latest; compose to latest-${TARGET_ARCH}
# (same contract as build-full-bundle / appliance-code DEV_IMAGE_REF_TAG).
DEV_IMAGE_TAG="${DEV_IMAGE_TAG:-latest}"
case "${DEV_IMAGE_TAG}" in
  *-amd64|*-arm64) ;;
  *)
    DEV_IMAGE_TAG="${DEV_IMAGE_TAG}-${TARGET_ARCH}"
    ;;
esac

LOCAL_TOOLING="localhost/dev-build:latest-${TARGET_ARCH}"
if [[ -n "${DEV_IMAGE:-}" ]]; then
  TOOLING_IMAGE="${DEV_IMAGE}"
elif podman image exists "${LOCAL_TOOLING}" 2>/dev/null; then
  TOOLING_IMAGE="${LOCAL_TOOLING}"
  echo "run-in-dev-build: using local ${TOOLING_IMAGE}"
else
  deps_require_var DEV_REGISTRY
  TOOLING_IMAGE="$(deps_registry_host)/${DEV_IMAGE_REPO}/${DEV_IMAGE_NAME}:${DEV_IMAGE_TAG}"
  echo "run-in-dev-build: pulling ${TOOLING_IMAGE}"
  tls="$(deps_podman_tls_flag)"
  # shellcheck disable=SC2086
  podman pull --arch "${TARGET_ARCH}" ${tls} "${TOOLING_IMAGE}"
fi

CACHE_ROOT="${DEV_CACHE_DIR:-${HOME}/.cache/appliance-release-dev-build}"
SYSTEM_STORAGE="${CACHE_ROOT}/containers/${TARGET_ARCH}/system"
mkdir -p "${SYSTEM_STORAGE}"

# Privileged + fuse + containers storage: nested podman/buildah for seed builds.
tls_run=()
if deps_tls_verify_false; then
  tls_run+=(--tls-verify=false)
fi

forward_env=(
  -e TARGET_ARCH="${TARGET_ARCH}"
  -e DEV_REGISTRY="${DEV_REGISTRY:-}"
  -e DEV_IMAGE_REPO="${DEV_IMAGE_REPO:-}"
  -e DEV_IMAGE_NAME="${DEV_IMAGE_NAME:-}"
  -e DEV_IMAGE_TAG="${DEV_IMAGE_TAG:-}"
  -e DEV_REGISTRY_USER="${DEV_REGISTRY_USER:-}"
  -e DEV_REGISTRY_TOKEN="${DEV_REGISTRY_TOKEN:-}"
  -e DEV_REGISTRY_TLS_VERIFY="${DEV_REGISTRY_TLS_VERIFY:-true}"
  -e OFFLINE_BUILD="${OFFLINE_BUILD:-0}"
  -e APPLIANCE_CODE_DIR="${APPLIANCE_CODE_DIR:-}"
  -e STORAGE_DRIVER=overlay
)

echo "run-in-dev-build: ${TOOLING_IMAGE} --arch ${TARGET_ARCH} -- $*"
# Root inside the tooling container so nested podman/buildah seed steps work
# (image default USER is non-root for interactive appliance-code dev-shell).
#
# Nested podman does not share the host auth.json written by seed-build-deps-login.
# When DEV_REGISTRY credentials are forwarded, login inside before the command
# so push/pull to the LAN registry works.
run_args=(
  --rm --privileged --device /dev/fuse
  --arch "${TARGET_ARCH}"
  --user 0
  --entrypoint ""
  "${tls_run[@]+"${tls_run[@]}"}"
  "${forward_env[@]}"
  -v "${REPO_ROOT}:/workspace:Z"
  -v "${SYSTEM_STORAGE}:/var/lib/containers:Z"
  -w /workspace
  "${TOOLING_IMAGE}"
)
if [[ -n "${DEV_REGISTRY:-}" && -n "${DEV_REGISTRY_USER:-}" && -n "${DEV_REGISTRY_TOKEN:-}" ]]; then
  # shellcheck disable=SC2086
  exec podman run "${run_args[@]}" \
    bash -c 'set -euo pipefail; source /workspace/scripts/deps-common.sh; deps_oci_login; exec "$@"' \
    bash "$@"
fi
# shellcheck disable=SC2086
exec podman run "${run_args[@]}" "$@"
