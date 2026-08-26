#!/usr/bin/env bash
# Smoke tests for install-release release-index pack gating helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Extract and eval only the helper functions from install-release.sh without running it.
# shellcheck disable=SC1091
eval "$(
  awk '
    /^required_packs_for_profile\(\)/ {keep=1}
    /^curl_download\(\)/ {keep=0}
    keep {print}
  ' "${SCRIPT_DIR}/install-release.sh"
)"

fail() {
  echo "test-install-release-index: $*" >&2
  exit 1
}

cat >"${TMP}/foundation-only.yaml" <<'EOF'
version: 0.1.0
packs:
  - id: foundation
    filename: appliance-0.1.0-foundation.tar.gz
    capabilities: [base, files, video]
capabilityPacks: {}
EOF

cat >"${TMP}/all-packs.yaml" <<'EOF'
version: 0.1.0
packs:
  - id: foundation
    filename: appliance-0.1.0-foundation.tar.gz
    capabilities: [base, files, video]
  - id: developer
    filename: appliance-0.1.0-developer.tar.gz
    capabilities: [workflows, build, artifact, dns]
  - id: deviceuser
    filename: appliance-0.1.0-deviceuser.tar.gz
    capabilities: [host]
  - id: inference
    filename: appliance-0.1.0-inference.tar.gz
    capabilities: [inference]
capabilityPacks:
  workflows: developer
  build: developer
  artifact: developer
  dns: developer
  host: deviceuser
  inference: inference
EOF

got="$(published_pack_ids_from_index "${TMP}/foundation-only.yaml")"
[[ "${got}" == "foundation" ]] || fail "foundation-only index: got '${got}'"

got="$(published_pack_ids_from_index "${TMP}/all-packs.yaml")"
[[ "${got}" == "foundation developer deviceuser inference" ]] || fail "all-packs index: got '${got}'"

pack_id_is_published foundation "${got}" || fail "foundation should be published"
pack_id_is_published developer "${got}" || fail "developer should be published"
pack_id_is_published deviceuser "${got}" || fail "deviceuser should be published"
pack_id_is_published inference "foundation" && fail "inference must not be published in foundation-only set"

req="$(required_packs_for_profile "builder-lanllm-storage-landns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "developer deviceuser inference" ]] || fail "builder-lanllm-storage-landns packs: '${req}'"

req="$(required_packs_for_profile "training" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "deviceuser" ]] || fail "training packs: '${req}'"

req="$(required_packs_for_profile "storage-landns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "developer deviceuser" ]] || fail "storage-landns packs: '${req}'"

# Simulate the install gate: profile needs developer, index is foundation-only.
published="$(published_pack_ids_from_index "${TMP}/foundation-only.yaml")"
if pack_id_is_published "developer" "${published}"; then
  fail "foundation-only index must not claim developer"
fi

echo "test-install-release-index: ok"
