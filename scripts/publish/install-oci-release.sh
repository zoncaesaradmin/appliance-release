#!/usr/bin/env bash
set -euo pipefail

# Self-contained ORAS helpers so this script works when pulled from an OCI
# release artifact without oci-release-lib.sh beside it.
bool_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_oras() {
  command -v oras >/dev/null 2>&1 || {
    echo "install-oci-release: required command not found on PATH: oras" >&2
    exit 1
  }
}

oras_login_registry() {
  local registry="$1"
  local username="$2"
  local token="$3"
  local insecure="${4:-false}"
  local -a flags=()
  if bool_true "${insecure}"; then
    flags+=(--insecure)
  fi
  printf '%s\n' "${token}" | oras login "${flags[@]}" --username "${username}" --password-stdin "${registry}"
}

oras_pull_release_package() {
  local registry="$1"
  local repository="$2"
  local version="$3"
  local out_dir="$4"
  local insecure="${5:-false}"
  local ref="${registry}/${repository}:${version}"
  local -a flags=()
  if bool_true "${insecure}"; then
    flags+=(--insecure)
  fi
  mkdir -p "${out_dir}"
  (
    cd "${out_dir}"
    oras pull "${flags[@]}" "${ref}"
  )
}

usage() {
  cat <<'EOF'
usage: install-oci-release.sh --oci-registry HOST --oci-repository REPO [options]

Download a published release package from an appliance Artifact Server via
ORAS, verify checksums, extract it locally, run zonctl preflight, and then
automatically choose install vs upgrade.

Requires `oras` on PATH. Authenticate with an appliance API token that has
pull access to the configured repository.

Required:
  --oci-registry HOST          Distribution appliance registry host
  --oci-repository REPO        OCI repository (e.g. appliance/releases)
  --oci-username USER          Registry login username

Optional:
  --product-version VERSION    Product version tag. If omitted, uses the
                               version embedded at publish time
  --use-latest                 Pull the :latest tag instead of an explicit version
  --out-dir DIR                Local download/extract directory.
                               Default: /tmp/appliance-<version>
  --oci-token-env VAR          Env var holding the API token. Default:
                               APPLIANCE_DISTRIBUTION_REGISTRY_TOKEN
  --oci-insecure               Pass --insecure to oras
  --state-dir DIR              zonctl state directory. Default: /var/lib/zon/state
  --appliance-profile NAME     Product-facing appliance profile. Default: core
  --build-catalog PATH         Target-local build catalog YAML/JSON
  --node-name NAME             Optional zonctl --node-name override
  --appliance-name NAME        Product LAN instance label (single DNS label)
  --dns-zone ZONE              LAN DNS zone (default appliance.internal)
  --tls-san SAN                Additional TLS SAN. Repeatable
  --dry-run                    Pass --dry-run to zonctl install/upgrade
  --output FORMAT              zonctl output format. Default: text
  --help                       Show this help

Example:
  export APPLIANCE_DISTRIBUTION_REGISTRY_TOKEN='...'
  bash ./scripts/publish/install-oci-release.sh \
    --oci-registry artifact-dns-1.appliance.internal \
    --oci-repository appliance/releases \
    --oci-username admin \
    --product-version 0.1.0 \
    --oci-insecure
EOF
}

# Substituted by publish-release.sh into the published copy of this script.
PRODUCT_VERSION_EMBEDDED=""

OCI_REGISTRY=""
OCI_REPOSITORY=""
OCI_USERNAME=""
OCI_TOKEN_ENV="APPLIANCE_DISTRIBUTION_REGISTRY_TOKEN"
OCI_INSECURE="false"
PRODUCT_VERSION=""
OUT_DIR=""
USE_LATEST="0"
STATE_DIR="/var/lib/zon/state"
APPLIANCE_PROFILE=""
BUILD_CATALOG_PATH=""
NODE_NAME=""
APPLIANCE_NAME=""
DNS_ZONE=""
TLS_SANS=()
DRY_RUN="0"
OUTPUT_FORMAT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --oci-registry)
      OCI_REGISTRY="${2:-}"
      shift 2
      ;;
    --oci-repository)
      OCI_REPOSITORY="${2:-}"
      shift 2
      ;;
    --oci-username)
      OCI_USERNAME="${2:-}"
      shift 2
      ;;
    --oci-token-env)
      OCI_TOKEN_ENV="${2:-}"
      shift 2
      ;;
    --oci-insecure)
      OCI_INSECURE="true"
      shift 1
      ;;
    --product-version)
      PRODUCT_VERSION="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
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
      echo "install-oci-release: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "install-oci-release: ${name} is required" >&2
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
  if [[ -s "${stdout_file}" ]]; then
    sed 's/^/  /' "${stdout_file}" >&2
  fi
  if [[ -s "${stderr_file}" ]]; then
    echo "  details:" >&2
    sed 's/^/    /' "${stderr_file}" >&2
  fi
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
  if [[ -s "${stdout_file}" ]]; then
    sed 's/^/  /' "${stdout_file}" >&2
  fi
  if [[ -s "${stderr_file}" ]]; then
    echo "  details:" >&2
    sed 's/^/    /' "${stderr_file}" >&2
  fi
}


require_var OCI_REGISTRY
require_var OCI_REPOSITORY
require_var OCI_USERNAME
require_oras

if [[ -z "${PRODUCT_VERSION}" ]]; then
  PRODUCT_VERSION="${PRODUCT_VERSION_EMBEDDED}"
fi
if [[ "${USE_LATEST}" == "1" ]]; then
  PRODUCT_VERSION="latest"
fi
require_var PRODUCT_VERSION

if [[ -z "${OUT_DIR}" ]]; then
  if [[ "${PRODUCT_VERSION}" == "latest" ]]; then
    OUT_DIR="/tmp/appliance-latest"
  else
    OUT_DIR="/tmp/appliance-${PRODUCT_VERSION}"
  fi
fi
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi

STATE_DIR="$(trim_trailing_slashes "${STATE_DIR}")"
mkdir -p "${OUT_DIR}"

OCI_TOKEN="${!OCI_TOKEN_ENV:-}"
if [[ -z "${OCI_TOKEN}" ]]; then
  echo "install-oci-release: missing token in env ${OCI_TOKEN_ENV}" >&2
  exit 2
fi

PULL_TAG="${PRODUCT_VERSION}"
echo "[1/5] Pulling release package ${OCI_REGISTRY}/${OCI_REPOSITORY}:${PULL_TAG}..."
oras_login_registry "${OCI_REGISTRY}" "${OCI_USERNAME}" "${OCI_TOKEN}" "${OCI_INSECURE}"
oras_pull_release_package "${OCI_REGISTRY}" "${OCI_REPOSITORY}" "${PULL_TAG}" "${OUT_DIR}" "${OCI_INSECURE}"
echo "[1/5] Release files pulled."

# Resolve actual bundle archive name (versioned filename) after pull.
BUNDLE_ARCHIVE="$(cd "${OUT_DIR}" && ls appliance-*-bundle.tar.gz | head -n 1)"
if [[ -z "${BUNDLE_ARCHIVE}" ]]; then
  echo "install-oci-release: pulled artifact is missing appliance-*-bundle.tar.gz" >&2
  exit 1
fi
# Prefer version from archive name when pulling :latest.
if [[ "${PULL_TAG}" == "latest" ]]; then
  if [[ "${BUNDLE_ARCHIVE}" =~ appliance-(.+)-bundle\.tar\.gz ]]; then
    PRODUCT_VERSION="${BASH_REMATCH[1]}"
  fi
fi
PUBLIC_KEY_FILE="release-signing.pub"
CHECKSUM_FILE="sha256sum.txt"
BUNDLE_DIR="${OUT_DIR}/appliance-${PRODUCT_VERSION}-bundle"
PUBLIC_KEY="${OUT_DIR}/release-signing.pub"
ZONCTL="${BUNDLE_DIR}/zonctl"

echo "[2/5] Verifying release checksums..."
if command -v sha256sum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && sha256sum -c "${CHECKSUM_FILE}")
else
  if ! command -v shasum >/dev/null 2>&1; then
    echo "install-oci-release: need sha256sum or shasum to verify checksums" >&2
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

install_args=(
  --bundle-dir "${BUNDLE_DIR}"
  --public-key "${PUBLIC_KEY}"
  --state-dir "${STATE_DIR}"
  --output "${OUTPUT_FORMAT}"
)
if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  install_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
fi
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  install_args+=(--build-catalog "${BUILD_CATALOG_PATH}")
fi
if [[ -n "${NODE_NAME}" ]]; then
  install_args+=(--node-name "${NODE_NAME}")
fi
if [[ -n "${APPLIANCE_NAME}" ]]; then
  install_args+=(--appliance-name "${APPLIANCE_NAME}")
fi
if [[ -n "${DNS_ZONE}" ]]; then
  install_args+=(--dns-zone "${DNS_ZONE}")
fi
if ((${#TLS_SANS[@]} > 0)); then
  for tls_san in "${TLS_SANS[@]}"; do
    install_args+=(--tls-san "${tls_san}")
  done
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  install_args+=(--dry-run)
fi
upgrade_args=(
  --bundle-dir "${BUNDLE_DIR}"
  --public-key "${PUBLIC_KEY}"
  --state-dir "${STATE_DIR}"
  --output "${OUTPUT_FORMAT}"
)
if [[ -n "${APPLIANCE_PROFILE}" ]]; then
  upgrade_args+=(--appliance-profile "${APPLIANCE_PROFILE}")
fi
if [[ -n "${BUILD_CATALOG_PATH}" ]]; then
  upgrade_args+=(--build-catalog "${BUILD_CATALOG_PATH}")
fi
if [[ -n "${NODE_NAME}" ]]; then
  upgrade_args+=(--node-name "${NODE_NAME}")
fi
if [[ -n "${APPLIANCE_NAME}" ]]; then
  upgrade_args+=(--appliance-name "${APPLIANCE_NAME}")
fi
if [[ -n "${DNS_ZONE}" ]]; then
  upgrade_args+=(--dns-zone "${DNS_ZONE}")
fi
if ((${#TLS_SANS[@]} > 0)); then
  for tls_san in "${TLS_SANS[@]}"; do
    upgrade_args+=(--tls-san "${tls_san}")
  done
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  upgrade_args+=(--dry-run)
fi

install_stdout="$(mktemp "${OUT_DIR}/.zonctl-install-stdout.XXXXXX")"
install_stderr="$(mktemp "${OUT_DIR}/.zonctl-install-stderr.XXXXXX")"

echo "[5/5] Installing appliance platform. This can take several minutes."
if capture_zonctl_step "${install_stdout}" "${install_stderr}" "" sudo "${ZONCTL}" install "${install_args[@]}"; then
  echo "[5/5] Appliance installation completed."
  rm -f "${install_stdout}" "${install_stderr}"
  echo "zonctl is now available at /usr/local/bin/zonctl on the target host."
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
    sudo "${ZONCTL}" upgrade "${upgrade_args[@]}"
  echo "zonctl is now available at /usr/local/bin/zonctl on the target host."
  exit 0
fi

print_captured_failure "[5/5] Appliance installation failed." "${install_stdout}" "${install_stderr}"
rm -f "${install_stdout}" "${install_stderr}"
exit 1
