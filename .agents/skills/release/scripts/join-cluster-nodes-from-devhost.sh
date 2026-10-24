#!/usr/bin/env bash
# join-cluster-nodes-from-devhost.sh — Mac/devhost side three-server coordinator.
#
# Stages the two remaining embedded-etcd servers from the bootstrap server,
# then finalizes the product only after the Kubernetes/etcd quorum gate.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: join-cluster-nodes-from-devhost.sh \
  --config PATH \
  --build-publish-config PATH \
  --install-config PATH

Stages the two peers of the required three-active-server product topology,
then runs its signed Kubernetes/etcd finalization gate.
EOF
}

DEVHOST_CONFIG=""
BUILD_PUBLISH_CONFIG=""
INSTALL_CONFIG=""
RUN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      DEVHOST_CONFIG="${2:-}"
      shift 2
      ;;
    --build-publish-config)
      BUILD_PUBLISH_CONFIG="${2:-}"
      shift 2
      ;;
    --install-config)
      INSTALL_CONFIG="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (see --help)"
      ;;
  esac
done

[[ -n "${DEVHOST_CONFIG}" ]] || fail "requires --config PATH"
[[ -n "${BUILD_PUBLISH_CONFIG}" ]] || fail "requires --build-publish-config PATH"
[[ -n "${INSTALL_CONFIG}" ]] || fail "requires --install-config PATH"

DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
BUILD_PUBLISH_CONFIG="$(require_config_path "${BUILD_PUBLISH_CONFIG}")"
INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"

require_cmd ssh
require_cmd scp
require_cmd python3

parse_target_host_cluster "${DEVHOST_CONFIG}"
require_three_server_product_targets

RELEASE_VERSION=""
if [[ -n "${PRODUCT_VERSION:-}" ]]; then
  RELEASE_VERSION="${PRODUCT_VERSION}"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(config_get_optional "${BUILD_PUBLISH_CONFIG}" "release.version" || true)"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(read_default_product_version "$(skill_release_repo_root "${SCRIPT_DIR}")")"
fi
readonly PATH_PREFIX="appliance"
BUNDLE_MODE="$(resolve_bundle_store_mode "${BUILD_PUBLISH_CONFIG}")"
APPLIANCE_NAME="$(config_get "${INSTALL_CONFIG}" "install.appliance_name")"
APPLIANCE_PROFILE="$(config_get_optional "${INSTALL_CONFIG}" "install.appliance_profile" || true)"
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi
DNS_ZONE="$(config_get_optional "${INSTALL_CONFIG}" "install.dns_zone" || true)"
DNS_ZONE="$(printf '%s' "${DNS_ZONE}" | tr -d '[:space:]')"
[[ -n "${DNS_ZONE}" ]] || fail "install.dns_zone is required in install config"

resolve_install_extra_tls_sans "${INSTALL_CONFIG}"
append_cluster_alias_tls_sans
resolve_install_image_pull_registry "${INSTALL_CONFIG}"

OUT_DIR="$(config_get_optional "${INSTALL_CONFIG}" "install.bundle_download_dir" || true)"
OUT_DIR="$(printf '%s' "${OUT_DIR}" | tr -d '[:space:]')"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="/tmp/appliance-${RELEASE_VERSION}"
fi

BASE_URL=""
BEARER_TOKEN=""
TLS_INSECURE="0"
case "${BUNDLE_MODE}" in
  static_http)
    BASE_URL="$(resolve_static_http_base_url "${BUILD_PUBLISH_CONFIG}")"
    ;;
  appliance_files)
    BASE_URL="$(resolve_appliance_files_base_url "${BUILD_PUBLISH_CONFIG}")"
    token_env="$(bundle_store_get_optional "${BUILD_PUBLISH_CONFIG}" "token_env" || true)"
    if [[ -z "${token_env}" ]]; then
      token_env="DEV_REGISTRY_TOKEN"
    fi
    BEARER_TOKEN="$(resolve_secret "${token_env}" "Bundle store token (${token_env})")"
    tls_env="$(bundle_store_get_optional "${BUILD_PUBLISH_CONFIG}" "tls_verify_env" || true)"
    if [[ -z "${tls_env}" ]]; then
      tls_env="DEV_REGISTRY_TLS_VERIFY"
    fi
    tls_verify="$(resolve_env_value "${tls_env}" "Bundle store TLS verify (${tls_env})")"
    case "$(printf '%s' "${tls_verify}" | tr '[:upper:]' '[:lower:]')" in
      0|false|no|off) TLS_INSECURE="1" ;;
      *) TLS_INSECURE="0" ;;
    esac
    ;;
  *)
    fail "unsupported bundle_store.mode: ${BUNDLE_MODE}"
    ;;
esac

LOCAL_HELPER="$(skill_release_repo_root "${SCRIPT_DIR}")/scripts/install-release.sh"
[[ -f "${LOCAL_HELPER}" ]] || fail "local install helper missing: ${LOCAL_HELPER}"
SCRIPT_PATH="/tmp/install-release-${RELEASE_VERSION}.sh"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"
mkdir -p "${RUN_DIR}/enrollments"
three_server_log="${RUN_DIR}/logs/target-three-server-coordinator.log"

target_sudo_password="$(resolve_secret "APPLIANCE_TARGET_SUDO_PASSWORD" "Target host sudo password")"
quoted_sudo_password="$(shell_quote "${target_sudo_password}")"
log "three-server stage/finalize kind=${TARGET_CLUSTER_KIND} bootstrap=${TARGET_PRIME_HOST}"
emit_three_server_stage_plan | tee -a "${three_server_log}"

# New signed releases use exactly three active embedded-etcd servers. Reuse
# the public helper's download path but select its explicit stage/finalize
# operations; do not invoke the legacy prime/member registration protocol.
run_three_server_flow() {
  local inventory_local="${RUN_DIR}/metadata/three-server-inventory.json"
  local inventory_remote="/tmp/appliance-three-server-inventory-${RELEASE_VERSION}.json"
  local bootstrap_node bootstrap_zonctl enrollment_remote enrollment_local fingerprint alias node_name
  local enroll_log stage_log finalize_log chmod_log remote_cmd helper_env node_helper_env enrollment_file_q
  local -a peers=()

  write_three_server_inventory "${inventory_local}"
  bootstrap_node="$(target_node_name_from_alias "${TARGET_PRIME_HOST}")"
  bootstrap_zonctl="${OUT_DIR}/appliance-${RELEASE_VERSION}-foundation/zonctl"
  snapshot_newline_list "${TARGET_PEER_PRIME_ALIASES:-}" peers
  ((${#peers[@]} == 2)) || fail "three-server topology requires two peer servers"
  scp -q "${inventory_local}" "${TARGET_PRIME_HOST}:${inventory_remote}"

  helper_env=""
  helper_env="$(append_env_assignments "${helper_env}" BASE_URL "${BASE_URL}" BEARER_TOKEN "${BEARER_TOKEN}" TLS_INSECURE "${TLS_INSECURE}" PRODUCT_VERSION "${RELEASE_VERSION}" PATH_PREFIX "${PATH_PREFIX}" DNS_ZONE "${DNS_ZONE}" EXTRA_TLS_SANS "${EXTRA_TLS_SANS}" OUT_DIR "${OUT_DIR}" IMAGE_PULL_REGISTRY "${IMAGE_PULL_REGISTRY}" IMAGE_PULL_USERNAME_ENV "${IMAGE_PULL_USERNAME_ENV}" IMAGE_PULL_TOKEN_ENV "${IMAGE_PULL_TOKEN_ENV}" IMAGE_PULL_TLS_VERIFY_ENV "${IMAGE_PULL_TLS_VERIFY_ENV}")"
  if [[ -n "${IMAGE_PULL_REGISTRY}" ]]; then
    helper_env="$(append_env_assignments "${helper_env}" "${IMAGE_PULL_USERNAME_ENV}" "${IMAGE_PULL_USERNAME}" "${IMAGE_PULL_TOKEN_ENV}" "${IMAGE_PULL_TOKEN}" "${IMAGE_PULL_TLS_VERIFY_ENV}" "${IMAGE_PULL_TLS_VERIFY}")"
  fi

  for alias in "${peers[@]}"; do
    node_name="$(target_node_name_from_alias "${alias}")"
    enrollment_remote="/tmp/appliance-three-server-${node_name}.enrollment"
    enrollment_local="${RUN_DIR}/enrollments/${node_name}.enrollment"
    enroll_log="${RUN_DIR}/logs/target-three-server-enroll-${node_name}.log"
    stage_log="${RUN_DIR}/logs/target-three-server-stage-${node_name}.log"
    log "creating signed server enrollment for ${alias} as ${node_name}"
    if ! run_ssh_captured "${TARGET_PRIME_HOST}" "${enroll_log}" "set -euo pipefail; test -x $(shell_quote "${bootstrap_zonctl}"); rm -f -- $(shell_quote "${enrollment_remote}"); printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' $(shell_quote "${bootstrap_zonctl}") cluster-server-enrollment-create --output json --cluster-inventory $(shell_quote "${inventory_remote}") --node-name $(shell_quote "${bootstrap_node}") --server-name $(shell_quote "${node_name}") --enrollment-out $(shell_quote "${enrollment_remote}"); printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' chown \"\$(id -un):\$(id -gn)\" $(shell_quote "${enrollment_remote}"); printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' chmod 0600 $(shell_quote "${enrollment_remote}")"; then
      fail "three-server enrollment failed for ${node_name}; see ${enroll_log}"
    fi
    fingerprint="$(python3 -c 'import json,sys; lines=open(sys.argv[1], encoding="utf-8").read().splitlines(); hits=[json.loads(x).get("data",{}).get("signerFingerprint","") for x in lines if x.strip().startswith("{") and "signerFingerprint" in x]; print(next((x for x in reversed(hits) if x), ""))' "${enroll_log}")"
    [[ -n "${fingerprint}" ]] || fail "three-server enrollment missing signer fingerprint for ${node_name}"
    mkdir -p "${RUN_DIR}/enrollments"
    scp -q "${TARGET_PRIME_HOST}:${enrollment_remote}" "${enrollment_local}" </dev/null
    # scp does not preserve the remote 0600 mode unless explicitly asked.
    # The artifact holds a K3s server token, so make the devhost staging copy
    # private before moving it onward.
    chmod 0600 "${enrollment_local}"
    scp -q "${enrollment_local}" "${alias}:${enrollment_remote}" </dev/null
    chmod_log="${RUN_DIR}/logs/target-three-server-enrollment-mode-${node_name}.log"
    if ! run_ssh_captured "${alias}" "${chmod_log}" "chmod 0600 $(shell_quote "${enrollment_remote}")"; then
      rm -f "${enrollment_local}"
      fail "could not protect three-server enrollment on ${alias}; see ${chmod_log}"
    fi
    if ! run_ssh_captured "${TARGET_PRIME_HOST}" "${RUN_DIR}/logs/target-three-server-enroll-cleanup-${node_name}.log" "rm -f -- $(shell_quote "${enrollment_remote}")"; then
      rm -f "${enrollment_local}"
      fail "could not remove transferred three-server enrollment from ${TARGET_PRIME_HOST}"
    fi
    rm -f "${enrollment_local}"
    scp -q "${inventory_local}" "${alias}:${inventory_remote}" </dev/null
    scp -q "${LOCAL_HELPER}" "${alias}:${SCRIPT_PATH}" </dev/null
    node_helper_env="$(append_env_assignments "${helper_env}" NODE_NAME "${node_name}" THREE_SERVER_OPERATION stage CLUSTER_INVENTORY_FILE "${inventory_remote}" SERVER_ENROLLMENT_FILE "${enrollment_remote}" CLUSTER_SIGNER_FINGERPRINT "${fingerprint}")"
    enrollment_file_q="$(shell_quote "${enrollment_remote}")"
    # Always remove the remote token envelope, including a failed stage. The
    # stage receipt/K3s token-file are the only durable, protected state; a
    # rerun obtains a fresh signed envelope.
    remote_cmd="set -euo pipefail; trap \"rm -f -- ${enrollment_file_q}\" EXIT; chmod +x $(shell_quote "${SCRIPT_PATH}"); printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' env ${node_helper_env} bash $(shell_quote "${SCRIPT_PATH}") --appliance-name $(shell_quote "${APPLIANCE_NAME}") --appliance-profile $(shell_quote "${APPLIANCE_PROFILE}")"
    log "staging embedded-etcd server ${alias}"
    if ! run_ssh_logged "${alias}" "${stage_log}" "${remote_cmd}"; then
      fail "three-server staging failed for ${alias}; see ${stage_log}"
    fi
  done

  finalize_log="${RUN_DIR}/logs/target-three-server-finalize.log"
  scp -q "${LOCAL_HELPER}" "${TARGET_PRIME_HOST}:${SCRIPT_PATH}"
  helper_env="$(append_env_assignments "${helper_env}" NODE_NAME "${bootstrap_node}" THREE_SERVER_OPERATION finalize CLUSTER_INVENTORY_FILE "${inventory_remote}")"
  remote_cmd="set -euo pipefail; chmod +x $(shell_quote "${SCRIPT_PATH}"); printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' env ${helper_env} bash $(shell_quote "${SCRIPT_PATH}") --appliance-name $(shell_quote "${APPLIANCE_NAME}") --appliance-profile $(shell_quote "${APPLIANCE_PROFILE}")"
  log "finalizing three-server Kubernetes/etcd substrate on ${TARGET_PRIME_HOST}"
  if ! run_ssh_logged "${TARGET_PRIME_HOST}" "${finalize_log}" "${remote_cmd}"; then
    fail "three-server finalization failed; see ${finalize_log}"
  fi
  log "three-server staging and finalization completed; application HA remains pending"
}

run_three_server_flow
log "three-server stage/finalize finished; log: ${three_server_log}"
