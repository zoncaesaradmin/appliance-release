#!/usr/bin/env bash
# install-release.sh — target-host operation helper for the three-server runner.
#
# The release runner supplies an inventory-bound `stage` or `finalize`
# operation. This helper intentionally has no standalone fresh-install,
# upgrade, agent-join, or one-host fallback path.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install-release.sh --appliance-name NAME [options]
       install-release.sh --help

This helper is run by the signed three-server release coordinator only. It
requires an inventory-bound THREE_SERVER_OPERATION of `stage` or `finalize`.
Do not run it as a standalone one-host installer or as an upgrade mechanism.

Required:
  --appliance-name NAME        Single DNS label for this appliance instance.
                               Stable for the life of the install; do not invent
                               a new name on every re-run of the same device.

Optional:
  --appliance-profile NAME     Install profile (default: core). Valid v1 values
                               include core, builder, storage, landns,
                               storage-landns, builder-landns,
                               builder-storage-landns.
  --help, -h                   Show this help

The coordinator supplies private store, inventory, and target values through
its protected release-run configuration. It does not create the first
administrator or accept a license (UI or later).
EOF
}

# ---------------------------------------------------------------------------
# Publish-stamped fields (rewritten by publish-release.sh for published copy)
# ---------------------------------------------------------------------------
PRODUCT_VERSION_EMBEDDED=""
PATH_PREFIX_EMBEDDED=""
BASE_URL_EMBEDDED=""

# =============================================================================
# Product defaults (operators usually leave alone)
# Edit only on the *downloaded* script before running, if a special site needs
# a non-default path. Not supplied via release YAML or installer CLI.
# =============================================================================
DNS_ZONE="${DNS_ZONE:-appliance.internal}"
# Product/zonctl state directory (permissions and ownership assume this path).
STATE_DIR="${STATE_DIR:-/var/lib/zon/state}"
# Leave empty to use stamp + /tmp/appliance-<version>
PRODUCT_VERSION="${PRODUCT_VERSION:-}"
PATH_PREFIX="${PATH_PREFIX:-}"
BASE_URL="${BASE_URL:-}"
OUT_DIR="${OUT_DIR:-}"
USE_LATEST="${USE_LATEST:-0}"

# Authenticated distribution (appliance_files). Open static HTTP: leave empty.
BEARER_TOKEN="${BEARER_TOKEN:-}"
TLS_INSECURE="${TLS_INSECURE:-0}"
TLS_CACERT="${TLS_CACERT:-}"

NODE_NAME="${NODE_NAME:-}"
EXTRA_TLS_SANS="${EXTRA_TLS_SANS:-}"
# Optional lab LAN image-pull (K3s registries.yaml). Empty = preload-only.
# The release skill patches host + *_ENV names and preserves credential env
# into sudo; public operators leave these empty.
IMAGE_PULL_REGISTRY="${IMAGE_PULL_REGISTRY:-}"
IMAGE_PULL_USERNAME_ENV="${IMAGE_PULL_USERNAME_ENV:-}"
IMAGE_PULL_TOKEN_ENV="${IMAGE_PULL_TOKEN_ENV:-}"
IMAGE_PULL_TLS_VERIFY_ENV="${IMAGE_PULL_TLS_VERIFY_ENV:-}"
# Coordinated three-server install mode. These are deliberately patched only
# by the release runner: the signed bundle selects the topology and zonctl
# verifies the inventory before mutation. Empty is rejected.
THREE_SERVER_OPERATION="${THREE_SERVER_OPERATION:-}"
CLUSTER_INVENTORY_FILE="${CLUSTER_INVENTORY_FILE:-}"
SERVER_ENROLLMENT_FILE="${SERVER_ENROLLMENT_FILE:-}"
DRY_RUN="${DRY_RUN:-0}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"
# =============================================================================

APPLIANCE_NAME=""
APPLIANCE_PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --appliance-name)
      APPLIANCE_NAME="${2:-}"
      shift 2
      ;;
    --appliance-profile)
      APPLIANCE_PROFILE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "install-release: unknown argument: $1" >&2
      echo "Only --appliance-name (required) and --appliance-profile (optional) are accepted." >&2
      echo "See --help." >&2
      exit 2
      ;;
  esac
done

trim_trailing_slashes() {
  local value="$1"
  while [[ "${value}" != "/" && "${value}" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "${value}"
}

require_nonempty() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "install-release: ${name} is required" >&2
    exit 2
  fi
}

print_captured_output() {
  local stdout_file="$1"
  local stderr_file="$2"
  if [[ -s "${stdout_file}" ]]; then
    sed 's/^/  /' "${stdout_file}" >&2
  fi
  if [[ -s "${stderr_file}" ]]; then
    echo "  details:" >&2
    sed 's/^/    /' "${stderr_file}" >&2
  fi
}

announce_zonctl_ready() {
  echo "zonctl is now available at /usr/local/bin/zonctl on the target host."
}

capture_zonctl_step() {
  local stdout_file="$1"
  local stderr_file="$2"
  local stdin_payload="$3"
  shift 3

  if [[ -n "${stdin_payload}" ]]; then
    printf '%s' "${stdin_payload}" | "$@" >"${stdout_file}" 2>"${stderr_file}"
    return $?
  fi

  "$@" >"${stdout_file}" 2>"${stderr_file}"
}

print_captured_failure() {
  local failure_message="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  echo "${failure_message}" >&2
  print_captured_output "${stdout_file}" "${stderr_file}"
}

if [[ -z "${APPLIANCE_NAME}" ]]; then
  echo "install-release: --appliance-name NAME is required (stable instance identity)." >&2
  usage >&2
  exit 2
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi
if [[ "${THREE_SERVER_OPERATION}" != "stage" && "${THREE_SERVER_OPERATION}" != "finalize" ]]; then
  echo "install-release: this product requires THREE_SERVER_OPERATION=stage or finalize from the three-server release coordinator" >&2
  exit 2
fi

# Optional soft env only when SETTINGS left empty (private store automation
# on a machine that already has DEV_REGISTRY_*). Public static installs leave
# both empty and need neither env nor bearer.
if [[ -z "${BEARER_TOKEN}" ]]; then
  if [[ -n "${ARTIFACT_BEARER_TOKEN:-}" ]]; then
    BEARER_TOKEN="${ARTIFACT_BEARER_TOKEN}"
  elif [[ -n "${DEV_REGISTRY_TOKEN:-}" ]]; then
    BEARER_TOKEN="${DEV_REGISTRY_TOKEN}"
  fi
fi
if [[ "${TLS_INSECURE}" != "1" && "${TLS_INSECURE}" != "true" ]]; then
  if [[ -n "${APPLIANCE_RELEASE_TLS_INSECURE:-}" ]]; then
    TLS_INSECURE="${APPLIANCE_RELEASE_TLS_INSECURE}"
  elif [[ -n "${DEV_REGISTRY_TLS_VERIFY:-}" ]]; then
    case "$(printf '%s' "${DEV_REGISTRY_TLS_VERIFY}" | tr '[:upper:]' '[:lower:]')" in
      0|false|no|off) TLS_INSECURE="1" ;;
    esac
  fi
fi

if [[ -z "${PRODUCT_VERSION}" ]]; then
  PRODUCT_VERSION="${PRODUCT_VERSION_EMBEDDED}"
fi
if [[ -z "${PATH_PREFIX}" ]]; then
  PATH_PREFIX="${PATH_PREFIX_EMBEDDED}"
fi
if [[ -z "${BASE_URL}" ]]; then
  BASE_URL="${BASE_URL_EMBEDDED}"
fi
# If stamp missing and private registry env exists on this host (automation).
if [[ -z "${BASE_URL}" && -n "${DEV_REGISTRY:-}" ]]; then
  reg="${DEV_REGISTRY#https://}"
  reg="${reg#http://}"
  reg="${reg%/}"
  BASE_URL="https://${reg}/api/v1/files"
fi
if [[ -z "${OUT_DIR}" && -n "${PRODUCT_VERSION}" ]]; then
  OUT_DIR="/tmp/appliance-${PRODUCT_VERSION}"
fi

require_nonempty "PRODUCT_VERSION (publish stamp)" "${PRODUCT_VERSION}"
require_nonempty "PATH_PREFIX (publish stamp)" "${PATH_PREFIX}"
require_nonempty "BASE_URL (publish stamp)" "${BASE_URL}"
require_nonempty "STATE_DIR" "${STATE_DIR}"
require_nonempty "OUT_DIR" "${OUT_DIR}"
require_nonempty "DNS_ZONE" "${DNS_ZONE}"

BASE_URL="$(trim_trailing_slashes "${BASE_URL}")"
PATH_PREFIX="$(trim_trailing_slashes "${PATH_PREFIX}")"
STATE_DIR="$(trim_trailing_slashes "${STATE_DIR}")"
OUT_DIR="$(trim_trailing_slashes "${OUT_DIR}")"

TLS_SANS=()
if [[ -n "${EXTRA_TLS_SANS}" ]]; then
  # shellcheck disable=SC2206
  TLS_SANS=(${EXTRA_TLS_SANS})
fi

if [[ -n "${IMAGE_PULL_REGISTRY}" ]]; then
  require_nonempty "IMAGE_PULL_USERNAME_ENV (when IMAGE_PULL_REGISTRY is set)" "${IMAGE_PULL_USERNAME_ENV}"
  require_nonempty "IMAGE_PULL_TOKEN_ENV (when IMAGE_PULL_REGISTRY is set)" "${IMAGE_PULL_TOKEN_ENV}"
  if [[ -z "${!IMAGE_PULL_USERNAME_ENV}" ]]; then
    echo "install-release: image pull username env ${IMAGE_PULL_USERNAME_ENV} is empty" >&2
    exit 2
  fi
  if [[ -z "${!IMAGE_PULL_TOKEN_ENV}" ]]; then
    echo "install-release: image pull token env ${IMAGE_PULL_TOKEN_ENV} is empty" >&2
    exit 2
  fi
  if [[ -n "${IMAGE_PULL_TLS_VERIFY_ENV}" && -z "${!IMAGE_PULL_TLS_VERIFY_ENV}" ]]; then
    echo "install-release: image pull TLS verify env ${IMAGE_PULL_TLS_VERIFY_ENV} is empty" >&2
    exit 2
  fi
fi

echo "install-release: using settings"
echo "  appliance-name:    ${APPLIANCE_NAME}"
echo "  appliance-profile: ${APPLIANCE_PROFILE}"
echo "  dns-zone:          ${DNS_ZONE}"
echo "  product-version:   ${PRODUCT_VERSION}"
echo "  path-prefix:       ${PATH_PREFIX}"
echo "  base-url:          ${BASE_URL}"
echo "  state-dir:         ${STATE_DIR}"
echo "  out-dir:           ${OUT_DIR}"
echo "  use-latest:        ${USE_LATEST}"
echo "  bearer-token:      $([[ -n "${BEARER_TOKEN}" ]] && echo set || echo empty)"
echo "  tls-insecure:      ${TLS_INSECURE}"
echo "  tls-cacert:        ${TLS_CACERT:-empty}"
echo "  image-pull-registry: ${IMAGE_PULL_REGISTRY:-disabled}"
echo "  extra-tls-sans:    ${EXTRA_TLS_SANS:-none}"
echo "  node-name:         ${NODE_NAME:-host-hostname}"

mkdir -p "${OUT_DIR}"

REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}"
if [[ "${USE_LATEST}" == "1" ]]; then
  REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/latest"
fi

BUNDLE_ARCHIVE=""
RELEASE_INDEX_FILE="release-index.yaml"
PUBLIC_KEY_FILE="release-signing.pub"
CHECKSUM_FILE="sha256sum.txt"
BUNDLE_DIR=""
PUBLIC_KEY="${OUT_DIR}/release-signing.pub"
ZONCTL=""
RELEASE_METADATA_FILES=(
  "${RELEASE_INDEX_FILE}"
  "${PUBLIC_KEY_FILE}"
  "${CHECKSUM_FILE}"
)

# Optional packages required by profile, derived from the catalog-projected
# release-index profiles and capabilityPacks. Foundation is handled separately.
# Prints one package id per line, sorted for stable behavior.
required_packs_for_profile_from_index() {
  local index_path="$1"
  local profile="$2"
  python3 - "${index_path}" "${profile}" <<'PY'
from pathlib import Path
import json
import sys

index_path = Path(sys.argv[1])
profile = str(sys.argv[2] or "").strip()
if not profile:
    raise SystemExit("install-release: appliance profile must not be empty")
text = index_path.read_text(encoding="utf-8")


def parse_release_index(raw: str) -> dict:
    try:
        import yaml  # type: ignore
    except ImportError:
        yaml = None
    if yaml is not None:
        data = yaml.safe_load(raw) or {}
        if not isinstance(data, dict):
            raise SystemExit("install-release: release-index root must be a mapping")
        return data

    # Minimal fallback parser for the fixed release-index shape (no PyYAML).
    profiles = {}
    capability_packs = {}
    section = ""
    current_profile = ""
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("packs:"):
            section = "packs"
            current_profile = ""
            continue
        if line.startswith("capabilityPacks:"):
            section = "capabilityPacks"
            current_profile = ""
            if line.strip() == "capabilityPacks: {}":
                continue
            continue
        if line.startswith("profiles:"):
            section = "profiles"
            current_profile = ""
            continue
        if section == "capabilityPacks" and line.startswith("  ") and ":" in line and not line.startswith("    "):
            key, value = line.strip().split(":", 1)
            capability_packs[key.strip()] = value.strip()
            continue
        if section == "profiles":
            if line.startswith("  ") and not line.startswith("    ") and line.strip().endswith(":"):
                current_profile = line.strip().rstrip(":")
                profiles[current_profile] = {"capabilities": []}
                continue
            if current_profile and "capabilities:" in line:
                raw_caps = line.split(":", 1)[1].strip()
                if raw_caps.startswith("[") and raw_caps.endswith("]"):
                    caps = [c.strip() for c in raw_caps[1:-1].split(",") if c.strip()]
                    profiles[current_profile]["capabilities"] = caps
    return {"profiles": profiles, "capabilityPacks": capability_packs}


data = parse_release_index(text)
profiles = data.get("profiles") or {}
if not isinstance(profiles, dict) or not profiles:
    raise SystemExit(f"install-release: {index_path} is missing profiles (rebuild with a current release skill)")
entry = profiles.get(profile)
if not isinstance(entry, dict):
    known = ", ".join(sorted(profiles))
    raise SystemExit(f"install-release: unknown appliance profile {profile!r} (index profiles: {known})")
caps = entry.get("capabilities") or []
if not isinstance(caps, list) or not caps:
    raise SystemExit(f"install-release: profile {profile!r} has no capabilities in {index_path}")
capability_packs = data.get("capabilityPacks") or {}
if capability_packs is None:
    capability_packs = {}
if not isinstance(capability_packs, dict):
    raise SystemExit(f"install-release: {index_path} capabilityPacks must be a mapping")

wanted = set()
for name in caps:
    if not isinstance(name, str) or not name:
        raise SystemExit("install-release: invalid profile capability")
    package = capability_packs.get(name)
    if not isinstance(package, str) or not package or package.strip() != package or "," in package:
        raise SystemExit(f"install-release: capability {name!r} has no unambiguous delivery pack mapping")
    wanted.add(package)

# Stable optional-package order for download/verify. Package ownership comes
# from the catalog-derived index, not from a hardcoded package list.
for pack_id in sorted(wanted - {"foundation"}):
    print(pack_id)
PY
}

# Print space-separated pack ids listed in release-index.yaml (fail closed).
published_pack_ids_from_index() {
  local index_path="$1"
  python3 - "${index_path}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
ids = []
try:
    import yaml  # type: ignore
except ImportError:
    yaml = None
if yaml is not None:
    data = yaml.safe_load(text) or {}
    for item in data.get("packs") or []:
        pack_id = str((item or {}).get("id") or "").strip()
        if pack_id:
            ids.append(pack_id)
else:
    in_packs = False
    current_id = ""
    for line in text.splitlines():
        if line.startswith("packs:"):
            in_packs = True
            continue
        if in_packs and line and not line.startswith(" ") and not line.startswith("\t"):
            break
        if not in_packs:
            continue
        stripped = line.strip()
        if stripped.startswith("- id:"):
            current_id = stripped.split(":", 1)[1].strip()
            if current_id:
                ids.append(current_id)
        elif stripped.startswith("id:") and current_id == "":
            current_id = stripped.split(":", 1)[1].strip()
            if current_id:
                ids.append(current_id)
if not ids:
    raise SystemExit(f"install-release: {path} lists no packs")
if len(ids) != len(set(ids)):
    raise SystemExit("install-release: duplicate delivery package in release index")
print(" ".join(ids))
PY
}

# Print the archive filename for a published package from the signed release
# index. Archive selection is therefore driven by catalog-derived metadata.
pack_filename_from_index() {
  local index_path="$1"
  local wanted_pack="$2"
  python3 - "${index_path}" "${wanted_pack}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
wanted = str(sys.argv[2] or "").strip()
try:
    import yaml  # type: ignore
except ImportError:
    yaml = None

filename = ""
if yaml is not None:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    for item in data.get("packs") or []:
        if isinstance(item, dict) and str(item.get("id") or "").strip() == wanted:
            filename = str(item.get("filename") or "").strip()
            break
else:
    in_packs = False
    current_id = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("packs:"):
            in_packs = True
            continue
        if in_packs and line and not line.startswith((" ", "\t")):
            break
        if not in_packs:
            continue
        stripped = line.strip()
        if stripped.startswith("- id:"):
            current_id = stripped.split(":", 1)[1].strip()
        elif current_id == wanted and stripped.startswith("filename:"):
            filename = stripped.split(":", 1)[1].strip()
            break
if not filename:
    raise SystemExit(f"install-release: package {wanted!r} is not published in {path}")
if "/" in filename or filename in (".", ".."):
    raise SystemExit(f"install-release: invalid archive filename for package {wanted!r}")
print(filename)
PY
}

# Return the one top-level directory in a verified pack archive. This avoids
# encoding package-specific extraction paths in the installer.
pack_bundle_dirname_from_archive() {
  local archive_path="$1"
  python3 - "${archive_path}" <<'PY'
from pathlib import PurePosixPath
import sys
import tarfile

archive = sys.argv[1]
roots = set()
with tarfile.open(archive, "r:gz") as tar:
    for member in tar.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise SystemExit(f"install-release: unsafe pack archive member {member.name!r}")
        # BSD tar on macOS writes AppleDouble sidecars for local test archives.
        # They are metadata, not a second bundle root.
        if any(part.startswith("._") for part in path.parts):
            continue
        roots.add(path.parts[0])
if len(roots) != 1:
    raise SystemExit(f"install-release: pack archive {archive} must contain exactly one top-level directory")
print(next(iter(roots)))
PY
}

pack_id_is_published() {
  local want="$1"
  local published="$2"
  local item=""
  # shellcheck disable=SC2086
  for item in ${published}; do
    if [[ "${item}" == "${want}" ]]; then
      return 0
    fi
  done
  return 1
}

curl_download() {
  local out_file="$1"
  local url="$2"
  local -a curl_args=(
    -fLo "${out_file}"
    # Force HTTP/1.1. Large multi-GB GETs over Traefik HTTP/2 fail mid-stream
    # with: curl: (92) HTTP/2 stream 1 was not closed cleanly: PROTOCOL_ERROR.
    --http1.1
  )
  if [[ -n "${TLS_CACERT}" ]]; then
    curl_args+=(--cacert "${TLS_CACERT}")
  elif [[ "${TLS_INSECURE}" == "1" || "${TLS_INSECURE}" == "true" ]]; then
    curl_args+=(-k)
  fi
  if [[ -n "${BEARER_TOKEN}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${BEARER_TOKEN}")
  fi
  curl "${curl_args[@]}" "${url}"
}

echo "[1/5] Downloading release metadata from ${REMOTE_DIR} ..."
for payload in "${RELEASE_METADATA_FILES[@]}"; do
  curl_download "${OUT_DIR}/${payload}" "${REMOTE_DIR}/${payload}"
done

BUNDLE_ARCHIVE="$(pack_filename_from_index "${OUT_DIR}/${RELEASE_INDEX_FILE}" "foundation")"

REQUIRED_PACKS_TEXT="$(required_packs_for_profile_from_index "${OUT_DIR}/${RELEASE_INDEX_FILE}" "${APPLIANCE_PROFILE}")"
REQUIRED_PACKS=()
while IFS= read -r pack_id; do
  [[ -n "${pack_id}" ]] || continue
  REQUIRED_PACKS+=("${pack_id}")
done <<<"${REQUIRED_PACKS_TEXT}"

PUBLISHED_PACKS="$(published_pack_ids_from_index "${OUT_DIR}/${RELEASE_INDEX_FILE}")"
if ! pack_id_is_published "foundation" "${PUBLISHED_PACKS}"; then
  echo "install-release: release ${PRODUCT_VERSION} is missing required foundation pack (index packs: ${PUBLISHED_PACKS})" >&2
  exit 1
fi
for pack_id in "${REQUIRED_PACKS[@]}"; do
  if ! pack_id_is_published "${pack_id}" "${PUBLISHED_PACKS}"; then
    echo "install-release: profile '${APPLIANCE_PROFILE}' requires delivery pack '${pack_id}', but release ${PRODUCT_VERSION} only publishes: ${PUBLISHED_PACKS}" >&2
    echo "install-release: rebuild/publish with APPLIANCE_PACKS including '${pack_id}', or choose a profile that only needs those packs" >&2
    exit 1
  fi
done

REQUIRED_PACK_ARCHIVES=()
for pack_id in "${REQUIRED_PACKS[@]}"; do
  REQUIRED_PACK_ARCHIVES+=("$(pack_filename_from_index "${OUT_DIR}/${RELEASE_INDEX_FILE}" "${pack_id}")")
done

echo "[1/5] Downloading delivery packs from ${REMOTE_DIR} ..."
curl_download "${OUT_DIR}/${BUNDLE_ARCHIVE}" "${REMOTE_DIR}/${BUNDLE_ARCHIVE}"
for archive in "${REQUIRED_PACK_ARCHIVES[@]}"; do
  curl_download "${OUT_DIR}/${archive}" "${REMOTE_DIR}/${archive}"
done
echo "[1/5] Release files downloaded (packs: foundation${REQUIRED_PACKS[*]:+ ${REQUIRED_PACKS[*]}})."

echo "[2/5] Verifying release checksums..."
# Verify only the files we downloaded (foundation + pubkey + index + needed packs).
VERIFY_LIST=(
  "${BUNDLE_ARCHIVE}"
  "${RELEASE_INDEX_FILE}"
  "${PUBLIC_KEY_FILE}"
)
for archive in "${REQUIRED_PACK_ARCHIVES[@]}"; do
  VERIFY_LIST+=("${archive}")
done
tmp_checksums="${OUT_DIR}/.sha256sum.selected"
: > "${tmp_checksums}"
for payload in "${VERIFY_LIST[@]}"; do
  if ! awk -v f="${payload}" '$2 == f { print; found=1 } END { exit(found ? 0 : 1) }' "${OUT_DIR}/${CHECKSUM_FILE}" >> "${tmp_checksums}"; then
    echo "install-release: checksum entry missing for ${payload}" >&2
    exit 1
  fi
done
if command -v sha256sum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && sha256sum -c "$(basename "${tmp_checksums}")")
else
  if ! command -v shasum >/dev/null 2>&1; then
    echo "install-release: need sha256sum or shasum to verify checksums" >&2
    exit 1
  fi
  awk '{print $1 "  " $2}' "${tmp_checksums}" > "${OUT_DIR}/.sha256sum.tmp"
  (cd "${OUT_DIR}" && shasum -a 256 -c .sha256sum.tmp)
  rm -f "${OUT_DIR}/.sha256sum.tmp"
fi
rm -f "${tmp_checksums}"
echo "[2/5] Release checksums verified."

echo "[3/5] Extracting packs..."
foundation_dirname="$(pack_bundle_dirname_from_archive "${OUT_DIR}/${BUNDLE_ARCHIVE}")"
BUNDLE_DIR="${OUT_DIR}/${foundation_dirname}"
ZONCTL="${BUNDLE_DIR}/zonctl"
rm -rf "${BUNDLE_DIR}"
tar -C "${OUT_DIR}" -xzf "${OUT_DIR}/${BUNDLE_ARCHIVE}"
PACK_DIRS=()
for archive in "${REQUIRED_PACK_ARCHIVES[@]}"; do
  pack_dirname="$(pack_bundle_dirname_from_archive "${OUT_DIR}/${archive}")"
  rm -rf "${OUT_DIR:?}/${pack_dirname}"
  tar -C "${OUT_DIR}" -xzf "${OUT_DIR}/${archive}"
  PACK_DIRS+=("${OUT_DIR}/${pack_dirname}")
done
echo "[3/5] Bundle extracted to ${BUNDLE_DIR}."

chmod +x "${ZONCTL}"

# cluster-server-stage performs the signed topology-specific host preflight;
# finalize performs its stricter live Kubernetes/etcd gate. Do not run the old
# single-host preflight against an already staged server.
echo "[4/5] Three-server operation uses its topology-specific preflight/gate."

lifecycle_args=(
  --bundle-dir "${BUNDLE_DIR}"
  --public-key "${PUBLIC_KEY}"
  --state-dir "${STATE_DIR}"
  --output "${OUTPUT_FORMAT}"
  --appliance-profile "${APPLIANCE_PROFILE}"
  --appliance-name "${APPLIANCE_NAME}"
  --dns-zone "${DNS_ZONE}"
)
for pack_dir in "${PACK_DIRS[@]}"; do
  lifecycle_args+=(--pack-dir "${pack_dir}")
done
if [[ -n "${NODE_NAME}" ]]; then
  lifecycle_args+=(--node-name "${NODE_NAME}")
fi
if ((${#TLS_SANS[@]} > 0)); then
  for tls_san in "${TLS_SANS[@]}"; do
    lifecycle_args+=(--tls-san "${tls_san}")
  done
fi
if [[ -n "${IMAGE_PULL_REGISTRY}" ]]; then
  lifecycle_args+=(--image-pull-registry "${IMAGE_PULL_REGISTRY}")
  lifecycle_args+=(--image-pull-registry-username-env "${IMAGE_PULL_USERNAME_ENV}")
  lifecycle_args+=(--image-pull-registry-token-env "${IMAGE_PULL_TOKEN_ENV}")
  if [[ -n "${IMAGE_PULL_TLS_VERIFY_ENV}" ]]; then
    lifecycle_args+=(--image-pull-registry-tls-verify-env "${IMAGE_PULL_TLS_VERIFY_ENV}")
  fi
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  lifecycle_args+=(--dry-run)
fi

zonctl_sudo=(sudo)
if [[ -n "${IMAGE_PULL_REGISTRY}" ]]; then
  preserve_env="${IMAGE_PULL_USERNAME_ENV},${IMAGE_PULL_TOKEN_ENV}"
  if [[ -n "${IMAGE_PULL_TLS_VERIFY_ENV}" ]]; then
    preserve_env="${preserve_env},${IMAGE_PULL_TLS_VERIFY_ENV}"
  fi
  zonctl_sudo+=(--preserve-env="${preserve_env}")
fi

install_stdout="$(mktemp "${OUT_DIR}/.zonctl-install-stdout.XXXXXX")"
install_stderr="$(mktemp "${OUT_DIR}/.zonctl-install-stderr.XXXXXX")"

case "${THREE_SERVER_OPERATION}" in
  stage)
    require_nonempty "CLUSTER_INVENTORY_FILE" "${CLUSTER_INVENTORY_FILE}"
    [[ -f "${CLUSTER_INVENTORY_FILE}" ]] || { echo "install-release: cluster inventory is not a file: ${CLUSTER_INVENTORY_FILE}" >&2; exit 2; }
    stage_args=(cluster-server-stage "${lifecycle_args[@]}" --cluster-inventory "${CLUSTER_INVENTORY_FILE}")
    if [[ -n "${SERVER_ENROLLMENT_FILE}" ]]; then
      require_nonempty "CLUSTER_SIGNER_FINGERPRINT" "${CLUSTER_SIGNER_FINGERPRINT}"
      stage_args+=(--enrollment-file "${SERVER_ENROLLMENT_FILE}" --cluster-signer-fingerprint "${CLUSTER_SIGNER_FINGERPRINT}")
    elif [[ -n "${CLUSTER_SIGNER_FINGERPRINT}" ]]; then
      echo "install-release: CLUSTER_SIGNER_FINGERPRINT requires SERVER_ENROLLMENT_FILE for a staged peer" >&2
      exit 2
    fi
    echo "[5/5] Staging this host as an embedded-etcd K3s server."
    if capture_zonctl_step "${install_stdout}" "${install_stderr}" "" "${zonctl_sudo[@]}" "${ZONCTL}" "${stage_args[@]}"; then
      echo "[5/5] K3s server staging completed; appliance finalization remains pending."
      rm -f "${install_stdout}" "${install_stderr}"
      exit 0
    fi
    print_captured_failure "[5/5] K3s server staging failed." "${install_stdout}" "${install_stderr}"
    rm -f "${install_stdout}" "${install_stderr}"
    exit 1
    ;;
  finalize)
    require_nonempty "CLUSTER_INVENTORY_FILE" "${CLUSTER_INVENTORY_FILE}"
    [[ -f "${CLUSTER_INVENTORY_FILE}" ]] || { echo "install-release: cluster inventory is not a file: ${CLUSTER_INVENTORY_FILE}" >&2; exit 2; }
    finalize_args=(cluster-finalize "${lifecycle_args[@]}" --cluster-inventory "${CLUSTER_INVENTORY_FILE}")
    echo "[5/5] Finalizing the three-server Kubernetes/etcd substrate."
    if capture_zonctl_step "${install_stdout}" "${install_stderr}" "" "${zonctl_sudo[@]}" "${ZONCTL}" "${finalize_args[@]}"; then
      echo "[5/5] Three-server appliance finalization completed."
      rm -f "${install_stdout}" "${install_stderr}"
      announce_zonctl_ready
      exit 0
    fi
    print_captured_failure "[5/5] Three-server appliance finalization failed." "${install_stdout}" "${install_stderr}"
    rm -f "${install_stdout}" "${install_stderr}"
    exit 1
    ;;
  *)
    echo "install-release: THREE_SERVER_OPERATION must be stage or finalize" >&2
    exit 2
    ;;
esac
