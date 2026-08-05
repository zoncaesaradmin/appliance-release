#!/usr/bin/env bash
# build-and-publish-on-host.sh — run build + publish on this machine.
#
# Prefer secrets already in the environment (injected by
# run-build-and-publish-on-build-host.sh from the Mac). Optional login-profile
# load is a last resort for hand runs only.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: build-and-publish-on-host.sh --build-publish-config PATH [options]

Run bootstrap, build, and publish on *this* host.

Env must already be set (devhost e2e injects from the Mac). For hand runs,
export the DEV_* names from build-publish config plus APPLIANCE_BUILD_SUDO_PASSWORD.

Options: --build-publish-config / --config, --run-dir, command overrides.
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

for arg in "$@"; do
  case "${arg}" in
    --help|-h)
      usage
      exit 0
      ;;
  esac
done

# Soft fill from login profile only when missing (hand runs).
if [[ -z "${DEV_REGISTRY:-}" ]]; then
  load_login_profile_env
fi
if [[ -z "${DEV_REGISTRY:-}" ]]; then
  fail "DEV_REGISTRY is unset. run-release-from-devhost.sh must inject it from the Mac, or export it here for a hand run."
fi

bash "${SCRIPT_DIR}/build-and-publish.sh" --local "$@"
