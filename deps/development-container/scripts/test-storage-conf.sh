#!/usr/bin/env bash
# Static contract checks for nested containers-storage configuration in
# the shared development-container image bootstrap.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_COMMON="${ROOT}/scripts/install-common.sh"

fail() {
  echo "test-storage-conf: $*" >&2
  exit 1
}

[[ -f "${INSTALL_COMMON}" ]] || fail "missing ${INSTALL_COMMON}"

grep -q 'mount_program = "/usr/bin/fuse-overlayfs"' "${INSTALL_COMMON}" \
  || fail "expected fuse-overlayfs mount_program in storage.conf templates"

grep -q 'graphroot = "${USER_HOME}/.local/share/containers/storage"' "${INSTALL_COMMON}" \
  || fail "expected user graphroot under ~/.local/share/containers/storage"

grep -q 'graphroot = "/var/lib/containers/storage"' "${INSTALL_COMMON}" \
  || fail "expected system graphroot under /var/lib/containers/storage"

# Image default remains vfs; privileged runtimes override STORAGE_DRIVER.
grep -q 'driver = "vfs"' "${INSTALL_COMMON}" \
  || fail "expected default storage driver vfs in image storage.conf"

# profile.d must not clobber a runtime-provided STORAGE_DRIVER.
# install-common writes this via a heredoc, so the source escapes the `$`.
grep -q 'STORAGE_DRIVER:=vfs' "${INSTALL_COMMON}" \
  || fail "expected profile.d STORAGE_DRIVER default via := (non-clobbering)"

if grep -E 'export STORAGE_DRIVER=vfs' "${INSTALL_COMMON}" >/dev/null; then
  fail "profile.d must not unconditionally export STORAGE_DRIVER=vfs"
fi

bash -n "${INSTALL_COMMON}" || fail "bash -n failed for install-common.sh"

echo "test-storage-conf: ok"
