#!/usr/bin/env bash
# Unit tests for scripts/lib/third-party-freeze.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/fs-link.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/third-party-freeze.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "usage: test-third-party-freeze.sh"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
  echo "test-third-party-freeze: $*" >&2
  exit 1
}

export TARGET_ARCH=arm64
export THIRD_PARTY_FREEZE_ROOT="${TMP}/freeze"
export THIRD_PARTY_FREEZE_MODE=auto
tpf_normalize_env || fail "normalize failed"

run_dir="${TMP}/run"
mkdir -p "${run_dir}"
printf 'payload-a\n' >"${run_dir}/demo-image.tar"
printf 'registry.local/demo@sha256:abc\n' >"${run_dir}/demo-image.reference"
printf 'docker.io/demo:1@sha256:abc\n' >"${run_dir}/demo-image.source-id"

TPF_FP_INPUTS=("docker.io/demo:1" "arm64" "v1")
tpf_store_oci "demo" "${run_dir}/demo-image.tar" || fail "store failed"
[[ -f "${THIRD_PARTY_FREEZE_ROOT}/arm64/manifest.yaml" ]] || fail "manifest missing"
grep -q 'id: demo' "${THIRD_PARTY_FREEZE_ROOT}/arm64/manifest.yaml" || fail "manifest missing demo"

rm -f "${run_dir}/demo-image.tar" "${run_dir}/demo-image.reference" "${run_dir}/demo-image.source-id"
TPF_FP_INPUTS=("docker.io/demo:1" "arm64" "v1")
tpf_try_restore_oci "demo" "${run_dir}/demo-image.tar" || fail "restore miss"
[[ -f "${run_dir}/demo-image.tar" ]] || fail "tar not restored"
[[ -f "${run_dir}/demo-image.reference" ]] || fail "reference not restored"
[[ "$(tr -d '\r\n' <"${run_dir}/demo-image.reference")" == "registry.local/demo@sha256:abc" ]] || fail "reference mismatch"

# Fingerprint change → miss under auto
TPF_FP_INPUTS=("docker.io/demo:1" "arm64" "v2")
if tpf_try_restore_oci "demo" "${run_dir}/other.tar"; then
  fail "expected miss on fingerprint change"
fi

# require mode fails closed on miss
export THIRD_PARTY_FREEZE_MODE=require
tpf_normalize_env
TPF_FP_INPUTS=("docker.io/demo:1" "arm64" "v2")
set +e
tpf_try_restore_oci "demo" "${run_dir}/other.tar"
rc=$?
set -e
[[ "${rc}" -eq 2 ]] || fail "require miss should exit 2 (got ${rc})"

# ignore disables
export THIRD_PARTY_FREEZE_MODE=ignore
tpf_normalize_env
if tpf_active; then
  fail "ignore should not be active"
fi

# directory restore/store
export THIRD_PARTY_FREEZE_MODE=auto
tpf_normalize_env
host_src="${TMP}/host-packages"
host_dest="${TMP}/host-packages-restored"
mkdir -p "${host_src}/ubuntu/24.04/arm64"
printf 'deb\n' >"${host_src}/ubuntu/24.04/arm64/pkg.deb"
TPF_FP_INPUTS=("host-packages" "24.04" "arm64")
tpf_store_dir "host-packages" "${host_src}" || fail "store-dir failed"
TPF_FP_INPUTS=("host-packages" "24.04" "arm64")
tpf_try_restore_dir "host-packages" "${host_dest}" || fail "restore-dir failed"
[[ -f "${host_dest}/ubuntu/24.04/arm64/pkg.deb" ]] || fail "deb not restored"

# ensure writable root (user-owned temp path)
export THIRD_PARTY_FREEZE_ROOT="${TMP}/freeze-ensure"
tpf_normalize_env
tpf_ensure_root_writable || fail "ensure writable failed for user path"
[[ -d "${THIRD_PARTY_FREEZE_ROOT}" && -w "${THIRD_PARTY_FREEZE_ROOT}" ]] || fail "root not writable after ensure"

echo "test-third-party-freeze: ok"
