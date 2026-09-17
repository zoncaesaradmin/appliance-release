#!/usr/bin/env bash
# Smoke tests for scripts/lib/appliance-packs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/appliance-packs.sh"

fail() {
  echo "test-appliance-packs: $*" >&2
  exit 1
}

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "${got}" != "${want}" ]]; then
    fail "${label}: got '${got}' want '${want}'"
  fi
}

APPLIANCE_PACKS=""
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS}" "all" "empty defaults to all token"
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation dev-platform deviceuser std-llm" "empty → all packs"

APPLIANCE_PACKS="all"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation dev-platform deviceuser std-llm" "all"

APPLIANCE_PACKS="foundation"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation" "foundation only"

APPLIANCE_PACKS="foundation,dev-platform"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation dev-platform" "foundation+dev-platform"
appliance_pack_wanted dev-platform || fail "dev-platform should be wanted"
appliance_pack_wanted std-llm && fail "std-llm should not be wanted"

APPLIANCE_PACKS="std-llm"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation std-llm" "std-llm auto-includes foundation"

APPLIANCE_PACKS="deviceuser"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation deviceuser" "deviceuser auto-includes foundation"

if APPLIANCE_PACKS="base" appliance_packs_resolve 2>/dev/null; then
  fail "legacy pack id base should fail (use foundation)"
fi

if APPLIANCE_PACKS="nope" appliance_packs_resolve 2>/dev/null; then
  fail "unknown pack should fail"
fi

APPLIANCE_PACKS="acc-llm"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation acc-llm" "acc-llm auto-includes foundation"

if APPLIANCE_PACKS="acc-llm-amd64" appliance_packs_resolve 2>/dev/null; then
  fail "legacy pack id acc-llm-amd64 should fail (use acc-llm + TARGET_ARCH)"
fi

if APPLIANCE_PACKS="acc-llm-arm64" appliance_packs_resolve 2>/dev/null; then
  fail "legacy pack id acc-llm-arm64 should fail (use acc-llm + TARGET_ARCH)"
fi

if APPLIANCE_PACKS="std-llm-amd64" appliance_packs_resolve 2>/dev/null; then
  fail "legacy pack id std-llm-amd64 should fail (use std-llm + TARGET_ARCH)"
fi

APPLIANCE_PACKS="std-llm,acc-llm"
if appliance_packs_resolve 2>/dev/null; then
  fail "multiple inference runtime packs should fail"
fi

for unsupported in inference; do
  if APPLIANCE_PACKS="${unsupported}" appliance_packs_resolve 2>/dev/null; then
    fail "legacy capability or unimplemented package '${unsupported}' should fail"
  fi
done

echo "test-appliance-packs: ok"
APPLIANCE_PACKS=dev-platform
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation dev-platform" "dev platform only"
