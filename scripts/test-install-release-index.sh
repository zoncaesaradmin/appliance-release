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
architecture: amd64
packs:
  - id: foundation
    filename: appliance-0.1.0-foundation-amd64.tar.gz
    capabilities: [base, actions, lan-discovery, files, video, application-auth]
capabilityPacks:
  base: foundation
  actions: foundation
  lan-discovery: foundation
  files: foundation
  video: foundation
  application-auth: foundation
  artifact: storage-network
  dns: deviceuser
  host: deviceuser
  applications: deviceuser
  future: future-package
profiles:
  core:
    capabilities: [base, actions, lan-discovery, files, applications]
  training:
    capabilities: [base, actions, lan-discovery, files, video]
  storage-landns:
    capabilities: [base, actions, lan-discovery, files, artifact, dns]
  lanllm:
    capabilities: [base, actions, lan-discovery, inference, applications]
  future-profile:
    capabilities: [base, actions, lan-discovery, future]
  application-core:
    capabilities: [base, channel-integrations, commerce, application-auth]
EOF

cat >"${TMP}/all-packs.yaml" <<'EOF'
version: 0.1.0
architecture: amd64
packs:
  - id: foundation
    filename: appliance-0.1.0-foundation-amd64.tar.gz
    capabilities: [base, actions, lan-discovery, files, video, application-auth]
  - id: app-stack
    filename: appliance-0.1.0-app-stack-amd64.tar.gz
    capabilities: [channel-integrations, commerce, application-identity]
  - id: geo-stack
    filename: appliance-0.1.0-geo-stack-amd64.tar.gz
    capabilities: [geo-spatial-store, geo-data-api, geo-basemap, geo-zone-editor]
  - id: storage-network
    filename: appliance-0.1.0-storage-network-amd64.tar.gz
    capabilities: [artifact]
  - id: deviceuser
    filename: appliance-0.1.0-deviceuser-amd64.tar.gz
    capabilities: [host, dns]
  - id: std-llm
    filename: appliance-0.1.0-std-llm-amd64.tar.gz
    capabilities: [inference]
capabilityPacks:
  base: foundation
  actions: foundation
  lan-discovery: foundation
  files: foundation
  video: foundation
  artifact: storage-network
  dns: deviceuser
  host: deviceuser
  applications: deviceuser
  inference: std-llm
  channel-integrations: app-stack
  commerce: app-stack
  application-identity: app-stack
  application-auth: foundation
  geo-spatial-store: geo-stack
  geo-data-api: geo-stack
  geo-basemap: geo-stack
  geo-zone-editor: geo-stack
profiles:
  core:
    capabilities: [base, actions, lan-discovery, files, applications]
  training:
    capabilities: [base, actions, lan-discovery, files, video]
  storage-landns:
    capabilities: [base, actions, lan-discovery, files, artifact, dns]
  lanllm:
    capabilities: [base, actions, lan-discovery, inference, applications]
  application-core:
    capabilities: [base, channel-integrations, commerce, application-identity, application-auth]
  geo-zone:
    capabilities: [base, application-auth, geo-spatial-store, geo-data-api, geo-basemap, geo-zone-editor]
EOF

got="$(published_pack_ids_from_index "${TMP}/foundation-only.yaml")"
[[ "${got}" == "foundation" ]] || fail "foundation-only index: got '${got}'"

got="$(published_pack_ids_from_index "${TMP}/all-packs.yaml")"
[[ "${got}" == "foundation app-stack geo-stack storage-network deviceuser std-llm" ]] || fail "all-packs index: got '${got}'"

pack_id_is_published foundation "${got}" || fail "foundation should be published"
pack_id_is_published storage-network "${got}" || fail "storage-network should be published"
pack_id_is_published deviceuser "${got}" || fail "deviceuser should be published"
pack_id_is_published std-llm "foundation" && fail "std-llm must not be published in foundation-only set"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "application-core" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "app-stack" ]] || fail "application-core packs: '${req}'"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "geo-zone" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "geo-stack" ]] || fail "geo-zone packs: '${req}'"

archive="$(pack_filename_from_index "${TMP}/all-packs.yaml" "storage-network")"
[[ "${archive}" == "appliance-0.1.0-storage-network-amd64.tar.gz" ]] || fail "storage-network archive: '${archive}'"
mkdir -p "${TMP}/generic-pack"
touch "${TMP}/generic-pack/manifest.json"
tar -C "${TMP}" -czf "${TMP}/generic-pack.tar.gz" generic-pack
dirname="$(pack_bundle_dirname_from_archive "${TMP}/generic-pack.tar.gz")"
[[ "${dirname}" == "generic-pack" ]] || fail "generic pack directory: '${dirname}'"

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
[[ "${req}" == "deviceuser storage-network" ]] || fail "storage-landns packs: '${req}'"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "lanllm" | tr '\n' ' ' | sed 's/[[:space:]]*$//' )"
[[ "${req}" == "deviceuser std-llm" ]] || fail "lanllm packs: '${req}'"

req="$(required_packs_for_profile_from_index "${TMP}/all-packs.yaml" "core" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "deviceuser" ]] || fail "core packs: '${req}'"

# Simulate the install gate: profile needs optional packs, index is foundation-only.
published="$(published_pack_ids_from_index "${TMP}/foundation-only.yaml")"
if pack_id_is_published "storage-network" "${published}"; then
  fail "foundation-only index must not claim storage-network"
fi

# storage-landns against foundation-only requires storage-network and deviceuser; packs unpublished.
req="$(required_packs_for_profile_from_index "${TMP}/foundation-only.yaml" "storage-landns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "${req}" == "deviceuser storage-network" ]] || fail "storage-landns on foundation-only still derives packs: '${req}'"
published="$(published_pack_ids_from_index "${TMP}/foundation-only.yaml")"
pack_id_is_published "storage-network" "${published}" && fail "storage-network must not be published"
pack_id_is_published "deviceuser" "${published}" && fail "deviceuser must not be published"

echo "test-install-release-index: ok"
