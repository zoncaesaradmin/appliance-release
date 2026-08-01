#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install-http-release.sh --base-url URL [options]

Download a published release bundle from a plain HTTP/HTTPS location, verify
checksums, extract it locally, run zonctl preflight, and then automatically
choose the right appliance lifecycle action:

- fresh host: run `zonctl install`
- existing owned appliance: switch to `zonctl upgrade`

For a fresh install, appliance setup now continues in a separate step after the
platform is installed:

- primary path: open the appliance UI and create the first administrator there
- automation/headless path: run a separate explicit bootstrap step

Required:
  --base-url URL               Base URL that serves the appliance path, for
                               example:
                               http://downloads.example.internal/releases

Required (or stamped into the published helper at publish time):
  --product-version VERSION    Product version to install. Published helpers
                               stamp this; otherwise pass explicitly.
  --path-prefix PATH           Path under base URL (from
                               bundle_store.release_path_prefix). Published
                               helpers stamp this; otherwise pass explicitly.
  --state-dir DIR              zonctl state directory (from
                               target_host.state_dir).
  --appliance-profile NAME     Appliance profile (from
                               install.appliance_profile).
  --appliance-name NAME        Product LAN instance label (single DNS label).
                               FQDN becomes <name>.<dns-zone> for TLS,
                               canonicalOrigin, and registry realm.
  --dns-zone ZONE              LAN DNS zone (from install.dns_zone).

Optional:
  --out-dir DIR                Local download/extract directory (from
                               install.bundle_download_dir when using the
                               release skill).
  --use-latest                 Fetch from <base-url>/<path-prefix>/latest/
                               instead of the explicit version directory
  --build-catalog PATH         Target-local build catalog YAML/JSON passed to
                               zonctl install/upgrade as control-plane config
  --node-name NAME             Optional zonctl --node-name override
  --tls-san SAN                Additional TLS SAN to include on the appliance
                               certificate. Repeatable. The helper also adds
                               the current host's hostname.local name
                               automatically when it is a valid DNS label.
  --dry-run                    Pass --dry-run to zonctl install/upgrade
  --output FORMAT              zonctl output format. Default: text
  --help                       Show this help

Example (piped; version and path-prefix are stamped at publish; pass target flags):
  curl -fsSL http://downloads.example.internal/releases/appliance/0.1.0/install-http-release.sh \
    | bash -s -- --base-url http://downloads.example.internal/releases \
      --out-dir /tmp/appliance-0.1.0 --state-dir /var/lib/zon/state \
      --appliance-profile storage-landns --appliance-name storage-landns-1 \
      --dns-zone appliance.internal

If the distribution endpoint requires appliance authentication, export:
  ARTIFACT_BEARER_TOKEN=<appliance API token>

The release skill sets this from bundle_store.access_token when installing.

For HTTPS with a self-signed distributor cert, export:
  APPLIANCE_RELEASE_TLS_INSECURE=1
or set APPLIANCE_RELEASE_CACERT=/path/to/ca.pem
EOF
}

# Substituted by publish-release.sh into the published copy of this script,
# so the version travels with the file's content rather than relying on the
# filename. That keeps the public helper URL stable as install-http-release.sh
# under each versioned release directory and also works when the script is
# piped straight into `bash` (curl ... | bash). Left empty in the tracked source copy;
# publish-release.sh's sed substitution is the only thing that sets it.
PRODUCT_VERSION_EMBEDDED=""
# Stamped by publish-release.sh from bundle_store.release_path_prefix.
PATH_PREFIX_EMBEDDED=""

BASE_URL=""
PRODUCT_VERSION=""
OUT_DIR=""
PATH_PREFIX=""
USE_LATEST="0"
STATE_DIR=""
APPLIANCE_PROFILE=""
BUILD_CATALOG_PATH=""
NODE_NAME=""
APPLIANCE_NAME=""
DNS_ZONE=""
TLS_SANS=()
DRY_RUN="0"
OUTPUT_FORMAT="text"
# The release skill injects ARTIFACT_BEARER_TOKEN from bundle_store.access_token.
ARTIFACT_BEARER_TOKEN="${ARTIFACT_BEARER_TOKEN:-}"
TLS_INSECURE="${APPLIANCE_RELEASE_TLS_INSECURE:-}"
TLS_CACERT="${APPLIANCE_RELEASE_CACERT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --product-version)
      PRODUCT_VERSION="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --path-prefix)
      PATH_PREFIX="${2:-}"
      shift 2
      ;;
    --use-latest)
      USE_LATEST="1"
      shift 1
      ;;
    --state-dir)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --appliance-profile)
      APPLIANCE_PROFILE="${2:-}"
      shift 2
      ;;
    --build-catalog)
      BUILD_CATALOG_PATH="${2:-}"
      shift 2
      ;;
    --node-name)
      NODE_NAME="${2:-}"
      shift 2
      ;;
    --appliance-name)
      APPLIANCE_NAME="${2:-}"
      shift 2
      ;;
    --dns-zone)
      DNS_ZONE="${2:-}"
      shift 2
      ;;
    --tls-san)
      TLS_SANS+=("${2:-}")
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift 1
      ;;
    --output)
      OUTPUT_FORMAT="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "install-http-release: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "install-http-release: ${name} is required" >&2
    usage >&2
    exit 2
  fi
}

trim_trailing_slashes() {
  local value="$1"
  while [[ "${value}" != "/" && "${value}" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "${value}"
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

append_unique_tls_san() {
  local value="$1"
  local existing=""
  [[ -n "${value}" ]] || return 1
  for existing in "${TLS_SANS[@]}"; do
    if [[ "${existing}" == "${value}" ]]; then
      return 1
    fi
  done
  TLS_SANS+=("${value}")
  return 0
}

derive_mdns_tls_san() {
  local hostname_output=""
  local short_hostname=""
  hostname_output="$(hostname 2>/dev/null || true)"
  [[ -n "${hostname_output}" ]] || return 0
  short_hostname="${hostname_output%%.*}"
  short_hostname="$(printf '%s' "${short_hostname}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${short_hostname}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    printf '%s.local\n' "${short_hostname}"
  fi
}

curl_download() {
  local out_file="$1"
  local url="$2"
  local -a curl_args=(-fLo "${out_file}")
  if [[ -n "${TLS_CACERT}" ]]; then
    curl_args+=(--cacert "${TLS_CACERT}")
  elif [[ "${TLS_INSECURE}" == "1" ]] || [[ "${TLS_INSECURE}" == "true" ]]; then
    curl_args+=(-k)
  fi
  if [[ -n "${ARTIFACT_BEARER_TOKEN}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${ARTIFACT_BEARER_TOKEN}")
  fi
  curl "${curl_args[@]}" "${url}"
}

require_var BASE_URL

if [[ -z "${PRODUCT_VERSION}" ]]; then
  PRODUCT_VERSION="${PRODUCT_VERSION_EMBEDDED}"
fi
require_var PRODUCT_VERSION

if [[ -z "${PATH_PREFIX}" ]]; then
  PATH_PREFIX="${PATH_PREFIX_EMBEDDED}"
fi
require_var PATH_PREFIX
require_var STATE_DIR
require_var APPLIANCE_PROFILE
require_var APPLIANCE_NAME
require_var DNS_ZONE
require_var OUT_DIR

BASE_URL="$(trim_trailing_slashes "${BASE_URL}")"
PATH_PREFIX="$(trim_trailing_slashes "${PATH_PREFIX}")"
STATE_DIR="$(trim_trailing_slashes "${STATE_DIR}")"
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

echo "[1/5] Downloading release files..."
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
default_mdns_tls_san="$(derive_mdns_tls_san)"
if append_unique_tls_san "${default_mdns_tls_san}"; then
  echo "install-http-release: adding default mDNS TLS SAN ${default_mdns_tls_san}"
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
  rm -f "${install_stdout}" "${install_stderr}"
  run_zonctl_step \
    "[5/5] Existing owned appliance detected. Switching to in-place upgrade/reconcile." \
    "[5/5] Appliance upgrade/reconcile completed." \
    "[5/5] Appliance upgrade/reconcile failed." \
    sudo "${ZONCTL}" upgrade "${lifecycle_args[@]}"
  announce_zonctl_ready
  exit 0
fi

print_captured_failure "[5/5] Appliance installation failed." "${install_stdout}" "${install_stderr}"
rm -f "${install_stdout}" "${install_stderr}"
exit 1
