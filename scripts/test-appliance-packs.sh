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
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "base developer inference" "empty → all packs"

APPLIANCE_PACKS="all"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "base developer inference" "all"

APPLIANCE_PACKS="base"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "base" "base only"

APPLIANCE_PACKS="base,developer"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "base developer" "base+developer"
appliance_pack_wanted developer || fail "developer should be wanted"
appliance_pack_wanted inference && fail "inference should not be wanted"

APPLIANCE_PACKS="inference"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "base inference" "inference auto-includes base"

if APPLIANCE_PACKS="nope" appliance_packs_resolve 2>/dev/null; then
  fail "unknown pack should fail"
fi

echo "test-appliance-packs: ok"
