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
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation developer inference video" "empty → all packs"

APPLIANCE_PACKS="all"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation developer inference video" "all"

APPLIANCE_PACKS="foundation"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation" "foundation only"

APPLIANCE_PACKS="foundation,developer"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation developer" "foundation+developer"
appliance_pack_wanted developer || fail "developer should be wanted"
appliance_pack_wanted inference && fail "inference should not be wanted"
appliance_pack_wanted video && fail "video should not be wanted"

APPLIANCE_PACKS="inference"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation inference" "inference auto-includes foundation"

APPLIANCE_PACKS="video"
appliance_packs_resolve
assert_eq "${APPLIANCE_PACKS_RESOLVED}" "foundation video" "video auto-includes foundation"
appliance_pack_wanted video || fail "video should be wanted"

if APPLIANCE_PACKS="base" appliance_packs_resolve 2>/dev/null; then
  fail "legacy pack id base should fail (use foundation)"
fi

if APPLIANCE_PACKS="nope" appliance_packs_resolve 2>/dev/null; then
  fail "unknown pack should fail"
fi

echo "test-appliance-packs: ok"
