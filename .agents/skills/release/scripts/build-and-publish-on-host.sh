#!/usr/bin/env bash
# build-and-publish-on-host.sh — run build + publish on this machine.
#
# Intended to run *on the build host*, with build_flow secrets already
# exported in the environment (DEV_REGISTRY*, DEV_IMAGE_*, APPLIANCE_BUILD_SUDO_PASSWORD).
#
# The build-publish YAML is normally produced on a Mac/devhost and either:
#   - scp'd here by run-build-and-publish-on-build-host.sh, or
#   - placed manually under $HOME/.config/appliance-release/
#
# This wrapper keeps the operator-facing name separate from the SSH-driven
# build-and-publish.sh (which still runs from the Mac with --config).
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: build-and-publish-on-host.sh --build-publish-config PATH [options]

Run bootstrap, build, and publish on *this* host using a build-publish role
config (the same schema as references/config.build-publish.example.yaml).

Required:
  --build-publish-config PATH   Build-publish YAML/JSON (role keys only:
                                release_workspace, release, build_flow, bundle_store).
                                --config is accepted as an alias.

Optional (forwarded to build-and-publish.sh --local):
  --run-dir DIR
  --bootstrap-cmd / --build-cmd / --publish-cmd / --remote-cwd /
  --remote-export-dir / --release-version

Environment (must already be set on this host; names come from config *_env keys):
  DEV_REGISTRY, DEV_IMAGE_REPO, DEV_IMAGE_NAME, DEV_IMAGE_TAG (optional),
  DEV_REGISTRY_USER, DEV_REGISTRY_TOKEN, DEV_REGISTRY_TLS_VERIFY,
  APPLIANCE_BUILD_SUDO_PASSWORD   (when bootstrap_needs_sudo or build_needs_sudo)

Example (already logged into the build host):
  export APPLIANCE_BUILD_SUDO_PASSWORD=…
  # DEV_* already exported in ~/.bashrc or similar
  bash /home/zonsys/ws/appliance-release/.agents/skills/release/scripts/build-and-publish-on-host.sh \
    --build-publish-config "$HOME/.config/appliance-release/build-publish.yaml"

From a Mac/devhost (copies config and SSHs):
  bash …/run-build-and-publish-on-build-host.sh \
    --config ~/151-devhost.yaml \
    --build-publish-config ~/151-build-publish.yaml
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

# Prefer a login-like profile so DEV_* exports from ~/.profile / ~/.bashrc apply
# when invoked over non-interactive SSH without an outer bash -lc.
if [[ -f "${HOME}/.profile" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.profile" 2>/dev/null || true
fi
if [[ -f "${HOME}/.bashrc" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.bashrc" 2>/dev/null || true
fi

exec bash "${SCRIPT_DIR}/build-and-publish.sh" --local "$@"
