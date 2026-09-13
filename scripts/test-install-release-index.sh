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
    /^required_packs_for_profile_from_index\(\)/ {keep=1}
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
    capabilities: [base, lan-discovery, files, video]
capabilityPacks:
  base: foundation
  lan-discovery: foundation
  files: foundation
  video: foundation
  workflows: dev-platform
  build: dev-platform
  artifact: dev-platform
  dns: dev-platform
  host: deviceuser
  applications: deviceuser
  inference: inference
  future: future-package
profiles:
  core:
    capabilities: [base, lan-discovery, files, applications]
  training:
    capabilities: [base, lan-discovery, files, video]
  storage-landns:
    capabilities: [base, lan-discovery, files, artifact, dns]
  builder-lanllm-storage-landns:
    capabilities: [base, lan-discovery, host, files, workflows, build, artifact, dns, inference, applications]
  lanllm:
    capabilities: [base, lan-discovery, inference, applications]
  future-profile:
    capabilities: [base, lan-discovery, future]
EOF

cat >"${TMP}/all-packs.yaml" <<'EOF'
version: 0.1.0
packs:
  - id: foundation
    filename: appliance-0.1.0-foundation.tar.gz
    capabilities: [base, lan-discovery, files, video]
  - id: dev-platform
    filename: appliance-0.1.0-dev-platform.tar.gz
    capabilities: [artifact, dns, workflows, build]
  - id: deviceuser
    filename: appliance-0.1.0-deviceuser.tar.gz
    capabilities: [host]
  - id: inference
    filename: appliance-0.1.0-inference.tar.gz
    capabilities: [inference]
capabilityPacks:
  base: foundation
  lan-discovery: foundation
  files: foundation
  video: foundation
  workflows: dev-platform
  build: dev-platform
  artifact: dev-platform
  dns: dev-platform
  host: deviceuser
  applications: deviceuser
  inference: inference
profiles:
  core:
    capabilities: [base, lan-discovery, files, applications]
  training:
    capabilities: [base, lan-discovery, files, video]
  storage-landns:
    capabilities: [base, lan-discovery, files, artifact, dns]
  builder-lanllm-storage-landns:
    capabilities: [base, lan-discovery, host, files, workflows, build, artifact, dns, inference, applications]
  lanllm:
    capabilities: [base, lan-discovery, inference, applications]
EOF

got="$(published_pack_ids_from_index "${TMP}/foundation-only.yaml")"
[[ "${got}" == "foundation" ]] || fail "foundation-only index: got '${got}'"

got="$(published_pack_ids_from_index "${TMP}/all-packs.yaml")"
[[ "${got}" == "foundation dev-platform deviceuser inference" ]] || fail "all-packs index: got '${got}'"

pack_id_is_published foundation "${got}" || fail "foundation should be published"
pack_id_is_published dev-platform "${got}" || fail "dev-platform should be published"
pack_id_is_published deviceuser "${got}" || fail "deviceuser should be published"
pack_id_is_published inference "foundation" && fail "inference must not be published in foundation-only set"

archive="$(pack_filename_from_index "${TMP}/all-packs.yaml" "dev-platform")"
[[ "${archive}" == "appliance-0.1.0-dev-platform.tar.gz" ]] || fail "dev-platform archive: '${archive}'"
mkdir -p "${TMP}/generic-pack"
touch "${TMP}/generic-pack/manifest.json"
tar -C "${TMP}" -czf "${TMP}/generic-pack.tar.gz" generic-pack
dirname="$(pack_bundle_dirname_from_archive "${TMP}/generic-pack.tar.gz")"
[[ "${dirname}" == "generic-pack" ]] || fail "generic pack directory: '${dirname}'"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "builder-lanllm-storage-landns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "dev-platform deviceuser inference" ]] || fail "builder-lanllm-storage-landns packs: '${req}'"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "training" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ -z "${req}" ]] || fail "training packs should be empty (foundation only), got '${req}'"

req="$(required_packs_for_profile_from_index "${TMP}/foundation-only.yaml" "training" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ -z "${req}" ]] || fail "training on foundation-only index should need no optional packs, got '${req}'"

# Package IDs come from the catalog-derived index; a future package is not
# rejected by a hardcoded installer allowlist. The later published-pack check
# supplies the actionable error when that package was not released.
req="$(required_packs_for_profile_from_index "${TMP}/foundation-only.yaml" "future-profile" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "future-package" ]] || fail "future profile package: '${req}'"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "storage-landns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "dev-platform" ]] || fail "storage-landns packs: '${req}'"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "lanllm" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "deviceuser inference" ]] || fail "lanllm packs: '${req}'"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "core" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "deviceuser" ]] || fail "core packs: '${req}'"

# Simulate the install gate: profile needs dev-platform, index is foundation-only.
published="$(published_pack_ids_from_index "${TMP}/foundation-only.yaml")"
if pack_id_is_published "dev-platform" "${published}"; then
  fail "foundation-only index must not claim dev-platform"
fi

# storage-landns against foundation-only requires dev-platform; packs unpublished.
req="$(required_packs_for_profile_from_index "${TMP}/foundation-only.yaml" "storage-landns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "dev-platform" ]] || fail "storage-landns on foundation-only still derives packs: '${req}'"
published="$(published_pack_ids_from_index "${TMP}/foundation-only.yaml")"
pack_id_is_published "dev-platform" "${published}" && fail "dev-platform must not be published"
pack_id_is_published "deviceuser" "${published}" && fail "deviceuser must not be published"

echo "test-install-release-index: ok"
