#!/usr/bin/env bash
# install-http-release.sh — public target-host install helper (fresh install only).
#
# Public path:
#   1) curl -fsSL -o install-http-release.sh "<distributor>/…/install-http-release.sh"
#   2) bash install-http-release.sh --appliance-name <unique-name> [--appliance-profile <profile>]
#
# This helper does not upgrade in place. If the host already has an owned
# appliance, fail and require uninstall (or factory-reset), then re-run.
# Publish stamps PRODUCT_VERSION_EMBEDDED, PATH_PREFIX_EMBEDDED, BASE_URL_EMBEDDED.
# Other paths and distributor options are product defaults below (rarely edit).
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install-http-release.sh --appliance-name NAME [options]
       install-http-release.sh --help

Public install (fresh host only):

  1) Download this script for the release version you want (version is in the
     URL; open static HTTP vs appliance_files differ only on this curl, e.g.
     Authorization header if the store requires a token):

       curl -fsSL -o install-http-release.sh \
         "https://downloads.example/appliance/0.1.0/install-http-release.sh"

  2) Run with a stable unique appliance name (required — identity, TLS SAN /
     FQDN, and registry realm all key off it):

       bash install-http-release.sh --appliance-name my-appliance-1

     Optional profile (default: core):

       bash install-http-release.sh \
         --appliance-name my-appliance-1 \
         --appliance-profile storage-landns

  If the host already has an owned appliance, uninstall first, then re-run:

       sudo zonctl uninstall --confirm yes

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

Rare site overrides (authenticated private store TLS, builder catalog path
`BUILD_CATALOG_PATH`, state dir) are product defaults near the top of this
file after download — edit those variables if needed. Not public CLI flags
and not release-orchestrator config.

Does not create the first administrator or accept a license (UI or later).

In-place upgrade is not supported by this helper.
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
DNS_ZONE="appliance.internal"
# Product/zonctl state directory (permissions and ownership assume this path).
STATE_DIR="/var/lib/zon/state"
# Leave empty to use stamp + /tmp/appliance-<version>
PRODUCT_VERSION=""
PATH_PREFIX=""
BASE_URL=""
OUT_DIR=""
USE_LATEST="0"

# Authenticated distribution (appliance_files). Open static HTTP: leave empty.
BEARER_TOKEN=""
TLS_INSECURE="0"
TLS_CACERT=""

BUILD_CATALOG_PATH=""
NODE_NAME=""
EXTRA_TLS_SANS=""
DRY_RUN="0"
OUTPUT_FORMAT="text"
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
      echo "install-http-release: unknown argument: $1" >&2
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
    echo "install-http-release: ${name} is required" >&2
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

run_zonctl_step() {
  local start_message="$1"
  local success_message="$2"
  local failure_message="$3"
  shift 3

  local stdout_file
  local stderr_file
  stdout_file="$(mktemp "${OUT_DIR}/.zonctl-stdout.XXXXXX")"
  stderr_file="$(mktemp "${OUT_DIR}/.zonctl-stderr.XXXXXX")"

  echo "${start_message}"
  if "$@" >"${stdout_file}" 2>"${stderr_file}"; then
    echo "${success_message}"
    rm -f "${stdout_file}" "${stderr_file}"
    return 0
  fi

  echo "${failure_message}" >&2
  print_captured_output "${stdout_file}" "${stderr_file}"
  rm -f "${stdout_file}" "${stderr_file}"
  exit 1
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
  echo "install-http-release: --appliance-name NAME is required (stable instance identity)." >&2
  usage >&2
  exit 2
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
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

echo "install-http-release: using settings"
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
echo "  build-catalog:     ${BUILD_CATALOG_PATH:-empty}"

mkdir -p "${OUT_DIR}"

REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/${PRODUCT_VERSION}"
if [[ "${USE_LATEST}" == "1" ]]; then
  REMOTE_DIR="${BASE_URL}/${PATH_PREFIX}/latest"
fi

BUNDLE_ARCHIVE="appliance-${PRODUCT_VERSION}-bundle.tar.gz"
PUBLIC_KEY_FILE="release-signing.pub"
CHECKSUM_FILE="sha256sum.txt"
BUNDLE_DIR="${OUT_DIR}/appliance-${PRODUCT_VERSION}-bundle"
PUBLIC_KEY="${OUT_DIR}/release-signing.pub"
ZONCTL="${BUNDLE_DIR}/zonctl"
RELEASE_PAYLOAD_FILES=(
  "${BUNDLE_ARCHIVE}"
  "${PUBLIC_KEY_FILE}"
  "${CHECKSUM_FILE}"
)

curl_download() {
  local out_file="$1"
  local url="$2"
  local -a curl_args=(-fLo "${out_file}")
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

echo "[1/5] Downloading release files from ${REMOTE_DIR} ..."
for payload in "${RELEASE_PAYLOAD_FILES[@]}"; do
  curl_download "${OUT_DIR}/${payload}" "${REMOTE_DIR}/${payload}"
done
echo "[1/5] Release files downloaded."

echo "[2/5] Verifying release checksums..."
if command -v sha256sum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && sha256sum -c "${CHECKSUM_FILE}")
else
  if ! command -v shasum >/dev/null 2>&1; then
    echo "install-http-release: need sha256sum or shasum to verify checksums" >&2
    exit 1
  fi
  tmp_checksums="${OUT_DIR}/.sha256sum.tmp"
  awk '{print $1 "  " $2}' "${OUT_DIR}/${CHECKSUM_FILE}" > "${tmp_checksums}"
  (cd "${OUT_DIR}" && shasum -a 256 -c "$(basename "${tmp_checksums}")")
  rm -f "${tmp_checksums}"
fi
echo "[2/5] Release checksums verified."

echo "[3/5] Extracting bundle..."
rm -rf "${OUT_DIR:?}/$(basename "${BUNDLE_DIR}")"
tar -C "${OUT_DIR}" -xzf "${OUT_DIR}/${BUNDLE_ARCHIVE}"
echo "[3/5] Bundle extracted to ${BUNDLE_DIR}."

chmod +x "${ZONCTL}"

run_zonctl_step \
  "[4/5] Running host preflight..." \
  "[4/5] Host preflight passed." \
  "[4/5] Host preflight failed." \
  sudo "${ZONCTL}" preflight --output "${OUTPUT_FORMAT}"

lifecycle_args=(
  --bundle-dir "${BUNDLE_DIR}"
  --public-key "${PUBLIC_KEY}"
  --state-dir "${STATE_DIR}"
  --output "${OUTPUT_FORMAT}"
  --appliance-profile "${APPLIANCE_PROFILE}"
  --appliance-name "${APPLIANCE_NAME}"
  --dns-zone "${DNS_ZONE}"
)
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  lifecycle_args+=(--build-catalog "${BUILD_CATALOG_PATH}")
fi
if [[ -n "${NODE_NAME}" ]]; then
  lifecycle_args+=(--node-name "${NODE_NAME}")
fi
if ((${#TLS_SANS[@]} > 0)); then
  for tls_san in "${TLS_SANS[@]}"; do
    lifecycle_args+=(--tls-san "${tls_san}")
  done
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  lifecycle_args+=(--dry-run)
fi

install_stdout="$(mktemp "${OUT_DIR}/.zonctl-install-stdout.XXXXXX")"
install_stderr="$(mktemp "${OUT_DIR}/.zonctl-install-stderr.XXXXXX")"

echo "[5/5] Installing appliance platform. This can take several minutes."
if capture_zonctl_step "${install_stdout}" "${install_stderr}" "" sudo "${ZONCTL}" install "${lifecycle_args[@]}"; then
  echo "[5/5] Appliance installation completed."
  rm -f "${install_stdout}" "${install_stderr}"
  announce_zonctl_ready
  echo "If this is a fresh install, open the appliance UI to create the first administrator."
  exit 0
fi

install_output="$(cat "${install_stdout}" "${install_stderr}")"
if [[ "${install_output}" == *"refusing to install (reuse-owned)"* || "${install_output}" == *"refusing to install (upgrade-owned)"* ]]; then
  print_captured_failure "[5/5] Existing owned appliance detected; install refused." "${install_stdout}" "${install_stderr}"
  rm -f "${install_stdout}" "${install_stderr}"
  cat >&2 <<'EOF'
install-http-release: this helper performs a fresh install only.
Uninstall the appliance on this host, then re-run install:

  sudo zonctl uninstall --confirm yes

In-place upgrade is not supported by the public install path for now.
EOF
  exit 1
fi

print_captured_failure "[5/5] Appliance installation failed." "${install_stdout}" "${install_stderr}"
rm -f "${install_stdout}" "${install_stderr}"
exit 1
