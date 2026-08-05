#!/usr/bin/env bash
set -euo pipefail
# Secrets (tokens/passwords) may contain '!'; disable history expansion even if
# this script is ever run from an interactive shell.
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: build-and-publish.sh [options]

Run explicit build and publish commands on the remote build host (default),
or on this machine with --local (for build-host login shells where DEV_*
and APPLIANCE_BUILD_SUDO_PASSWORD are already exported).

Options:
  --config PATH                 Alias for --build-publish-config.
  --build-publish-config PATH   Build-publish role file.
  --local                       Run bootstrap/build/publish on this host
                                (no SSH). Use from the build machine, or via
                                run-build-and-publish-on-build-host.sh.
  --bootstrap-cmd CMD           Optional bootstrap command.
  --build-cmd CMD               Build command. Defaults to build_flow.build_command.
  --publish-cmd CMD             Publish command. Defaults to build_flow.publish_command.
  --remote-cwd PATH             Working directory on the build host.
                                Defaults to release_workspace.remote_repo_path.
  --remote-export-dir PATH      Export directory to collect after build.
  --release-version VERSION     Release version for metadata and filenames.
  --run-dir DIR                 Run directory for logs/metadata/artifacts.
EOF
}

CONFIG_PATH=""
LOCAL_MODE="false"
BOOTSTRAP_CMD=""
BUILD_CMD=""
PUBLISH_CMD=""
REMOTE_CWD=""
REMOTE_EXPORT_DIR=""
REMOTE_RELEASE_INPUT=""
REMOTE_BUNDLE_DIR=""
RELEASE_VERSION=""
RUN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|--build-publish-config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --local)
      LOCAL_MODE="true"
      shift
      ;;
    --bootstrap-cmd)
      BOOTSTRAP_CMD="${2:-}"
      shift 2
      ;;
    --build-cmd)
      BUILD_CMD="${2:-}"
      shift 2
      ;;
    --publish-cmd)
      PUBLISH_CMD="${2:-}"
      shift 2
      ;;
    --remote-cwd)
      REMOTE_CWD="${2:-}"
      shift 2
      ;;
    --remote-export-dir)
      REMOTE_EXPORT_DIR="${2:-}"
      shift 2
      ;;
    --release-version)
      RELEASE_VERSION="${2:-}"
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
      fail "unknown argument: $1"
      ;;
  esac
done

CONFIG_PATH="$(require_config_path "${CONFIG_PATH}")"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi

if [[ -z "${REMOTE_CWD}" ]]; then
  REMOTE_CWD="$(config_get "${CONFIG_PATH}" "release_workspace.remote_repo_path")"
fi
REMOTE_REPO_SOURCE="$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_repo_source" || true)"
REMOTE_REPO_REF="$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_repo_ref" || true)"
CODE_REPO_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.code_repo_ref" || true)"
CTL_REPO_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.ctl_repo_ref" || true)"
BUILD_K3S_BINARY_SOURCE="$(config_get_optional "${CONFIG_PATH}" "build_flow.k3s_binary_source" || true)"
BUILD_K3S_AIRGAP_IMAGES_SOURCE="$(config_get_optional "${CONFIG_PATH}" "build_flow.k3s_airgap_images_source" || true)"
if [[ -z "${BOOTSTRAP_CMD}" ]]; then
  BOOTSTRAP_CMD="$(config_get_optional "${CONFIG_PATH}" "build_flow.bootstrap_command" || true)"
fi
if [[ -z "${BUILD_CMD}" ]]; then
  BUILD_CMD="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_command" || true)"
fi
if [[ -z "${PUBLISH_CMD}" ]]; then
  PUBLISH_CMD="$(config_get_optional "${CONFIG_PATH}" "build_flow.publish_command" || true)"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(config_get_optional "${CONFIG_PATH}" "release.version" || true)"
fi
if [[ -z "${REMOTE_EXPORT_DIR}" ]]; then
  REMOTE_EXPORT_DIR="$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_export_dir" || true)"
fi

[[ -n "${BUILD_CMD}" ]] || fail "build_flow.build_command is required in config"
[[ -n "${PUBLISH_CMD}" ]] || fail "build_flow.publish_command is required in config"
[[ -n "${BUILD_K3S_BINARY_SOURCE}" ]] || fail "build_flow.k3s_binary_source is required in config"
[[ -n "${BUILD_K3S_AIRGAP_IMAGES_SOURCE}" ]] || fail "build_flow.k3s_airgap_images_source is required in config"
[[ -n "${RELEASE_VERSION}" ]] || fail "release.version is required in config"
[[ -n "${REMOTE_EXPORT_DIR}" ]] || fail "release_workspace.remote_export_dir is required in config"
if [[ -n "$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_release_input_path" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_bundle_dir" || true)" ]]; then
  fail "release_workspace.remote_release_input_path and remote_bundle_dir were removed; build-and-publish now auto-detects release-input and bundle paths from the build log"
fi

SKILL_RELEASE_REPO_ROOT="$(skill_release_repo_root "${SCRIPT_DIR}")"
if [[ -z "${REMOTE_REPO_SOURCE}" ]]; then
  REMOTE_REPO_SOURCE="$(resolve_local_git_origin "${SKILL_RELEASE_REPO_ROOT}")"
fi
[[ -n "${REMOTE_REPO_SOURCE}" ]] || fail "release_workspace.remote_repo_source is required in config (or run from a local appliance-release git checkout with an origin)"
EFFECTIVE_REMOTE_REPO_SOURCE="$(normalize_readonly_git_source "${REMOTE_REPO_SOURCE}")"
if [[ "${EFFECTIVE_REMOTE_REPO_SOURCE}" != "${REMOTE_REPO_SOURCE}" ]]; then
  log "normalizing release workspace repo source from ${REMOTE_REPO_SOURCE} to read-only ${EFFECTIVE_REMOTE_REPO_SOURCE} for build-host sync"
fi
[[ -n "${REMOTE_REPO_REF}" ]] || fail "release_workspace.remote_repo_ref is required in config"
[[ -n "${CODE_REPO_REF}" ]] || fail "build_flow.code_repo_ref is required in config"
[[ -n "${CTL_REPO_REF}" ]] || fail "build_flow.ctl_repo_ref is required in config"

require_cmd python3
require_cmd rsync
if ! bool_true "${LOCAL_MODE}"; then
  require_cmd ssh
fi

BUILD_HOST=""
if bool_true "${LOCAL_MODE}"; then
  # build-publish role configs do not carry build_host (that lives on the
  # devhost file). Record a local marker for metadata only.
  BUILD_HOST="$(config_get_optional "${CONFIG_PATH}" "build_host.alias" || true)"
  if [[ -z "${BUILD_HOST}" ]]; then
    BUILD_HOST="local@$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo build-host)"
  fi
  log "local mode: bootstrap/build/publish run on this host (${BUILD_HOST}); expecting registry/sudo env already exported"
else
  BUILD_HOST="$(config_get "${CONFIG_PATH}" "build_host.alias")"
fi
BOOTSTRAP_NEEDS_SUDO="$(config_get_optional "${CONFIG_PATH}" "build_flow.bootstrap_needs_sudo" || true)"
BUILD_NEEDS_SUDO="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_needs_sudo" || true)"
[[ -n "${BOOTSTRAP_NEEDS_SUDO}" ]] || fail "build_flow.bootstrap_needs_sudo is required in config (true|false)"
[[ -n "${BUILD_NEEDS_SUDO}" ]] || fail "build_flow.build_needs_sudo is required in config (true|false)"

# Development-container pull/login only. Signed-bundle publish uses
# bundle_store.* + publish_command. Per-service make image defaults live in
# appliance-code build/service-image.mk — not this config.
# Fail closed on removed nested registry blocks.
if [[ -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_container_image_registry.pull_ref" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_container_image_registry.registry_user_env" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_container_image_registry.registry_token_env" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_container_image_registry.tls_insecure" || true)" ]]; then
  fail "build_flow.dev_container_image_registry.* was removed; use build_flow.dev_image_pull.*"
fi
if [[ -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.extra_oci_image_archive_sources" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.extra_oci_image_pull_refs" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.extra_oci_image_refs" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.registry_user_env" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.registry_token_env" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.registry_user" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.registry_token" || true)" ]]; then
  fail "legacy build_flow registry/image keys are no longer supported; use build_flow.dev_image_pull.*"
fi
if [[ -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.host_packages_dir_source" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.crds_dir_source" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.controller_image_archive_source" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.executor_image_archive_source" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.workspace_provisioner_image_archive_source" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.zot.image_archive_source" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.dns.image_archive_source" || true)" ]]; then
  fail "offline/local archive path inputs under build_flow were removed; package always pulls (or uses build_image_mirror + upstream). Remove host_packages_dir_source, argo.*_archive_source, argo.crds_dir_source, zot/dns/workspace_provisioner image_archive_source keys"
fi
if [[ -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.registry" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.image_repo" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.image_repo_env" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.image_name" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.image_name_env" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.image_tag" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.username_env" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.token_env" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.product_publish.tls_verify_env" || true)" ]]; then
  fail "build_flow.product_publish.* was removed (destination fields were unused). Use build_flow.dev_image_pull.* for registry login; remove the product_publish block from config"
fi
if [[ -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.image_repo" || true)" \
  || -n "$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.image_name" || true)" ]]; then
  fail "build_flow.dev_image_pull.image_repo and image_name were removed; use image_repo_env and image_name_env"
fi

DEV_PULL_REGISTRY_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.registry_env" || true)"
DEV_PULL_IMAGE_REPO_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.image_repo_env" || true)"
DEV_PULL_IMAGE_NAME_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.image_name_env" || true)"
DEV_PULL_IMAGE_TAG="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.image_tag" || true)"
DEV_PULL_USER_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.username_env" || true)"
DEV_PULL_TOKEN_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.token_env" || true)"
DEV_PULL_TLS_VERIFY_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.tls_verify_env" || true)"
[[ -n "${DEV_PULL_REGISTRY_ENV}" ]] || fail "build_flow.dev_image_pull.registry_env is required in config"
DEV_PULL_REGISTRY="$(resolve_env_value "${DEV_PULL_REGISTRY_ENV}" "Dev image pull registry env")"
[[ -n "${DEV_PULL_IMAGE_REPO_ENV}" ]] || fail "build_flow.dev_image_pull.image_repo_env is required in config"
[[ -n "${DEV_PULL_IMAGE_NAME_ENV}" ]] || fail "build_flow.dev_image_pull.image_name_env is required in config"
DEV_PULL_IMAGE_REPO="$(resolve_env_value "${DEV_PULL_IMAGE_REPO_ENV}" "Dev image pull image repo env")"
DEV_PULL_IMAGE_NAME="$(resolve_env_value "${DEV_PULL_IMAGE_NAME_ENV}" "Dev image pull image name env")"
[[ -n "${DEV_PULL_IMAGE_TAG}" ]] || fail "build_flow.dev_image_pull.image_tag is required in config"
[[ -n "${DEV_PULL_USER_ENV}" ]] || fail "build_flow.dev_image_pull.username_env is required in config"
[[ -n "${DEV_PULL_TOKEN_ENV}" ]] || fail "build_flow.dev_image_pull.token_env is required in config"
[[ -n "${DEV_PULL_TLS_VERIFY_ENV}" ]] || fail "build_flow.dev_image_pull.tls_verify_env is required in config"
IMAGE_REGISTRY_PULL_REF="${DEV_PULL_REGISTRY}/${DEV_PULL_IMAGE_REPO}/${DEV_PULL_IMAGE_NAME}:${DEV_PULL_IMAGE_TAG}"
IMAGE_REGISTRY_HOST="${DEV_PULL_REGISTRY}"

DEV_PULL_TLS_VERIFY="$(normalize_bool_value "$(resolve_env_value "${DEV_PULL_TLS_VERIFY_ENV}" "TLS verify env")")"
# Bundled/target OCI contract name (not configurable).
BUILD_EXTRA_OCI_IMAGE_REFS="registry.local/dev-build"
if bool_true "${DEV_PULL_TLS_VERIFY}"; then
  OCI_COPY_SRC_TLS_VERIFY="true"
  DEV_REGISTRY_TLS_VERIFY="true"
else
  OCI_COPY_SRC_TLS_VERIFY="false"
  DEV_REGISTRY_TLS_VERIFY="false"
fi

# Optional build-time OCI pull-through mirror (separate section from dev_image_pull).
# When enabled, builds try the mirror first (short timeout), fall back to upstream,
# then best-effort push into the mirror. Env *names* can match DEV_REGISTRY* today
# while still allowing a different Artifact Server later.
BUILD_IMAGE_MIRROR_ENABLED_CFG="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_image_mirror.enabled" || true)"
if [[ -z "${BUILD_IMAGE_MIRROR_ENABLED_CFG}" ]]; then
  BUILD_IMAGE_MIRROR_ENABLED_CFG="false"
fi
BUILD_IMAGE_MIRROR_ENABLED="false"
BUILD_IMAGE_MIRROR_REGISTRY=""
BUILD_IMAGE_MIRROR_REPOSITORY_PREFIX="build-cache"
BUILD_IMAGE_MIRROR_TIMEOUT_SECONDS="15"
BUILD_IMAGE_MIRROR_TLS_VERIFY="true"
BUILD_IMAGE_MIRROR_USER=""
BUILD_IMAGE_MIRROR_TOKEN=""
if bool_true "${BUILD_IMAGE_MIRROR_ENABLED_CFG}"; then
  BUILD_IMAGE_MIRROR_ENABLED="true"
  BUILD_IMAGE_MIRROR_REGISTRY_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_image_mirror.registry_env" || true)"
  BUILD_IMAGE_MIRROR_USER_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_image_mirror.username_env" || true)"
  BUILD_IMAGE_MIRROR_TOKEN_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_image_mirror.token_env" || true)"
  BUILD_IMAGE_MIRROR_TLS_VERIFY_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_image_mirror.tls_verify_env" || true)"
  BUILD_IMAGE_MIRROR_REPOSITORY_PREFIX="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_image_mirror.repository_prefix" || true)"
  BUILD_IMAGE_MIRROR_TIMEOUT_SECONDS="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_image_mirror.timeout_seconds" || true)"
  [[ -n "${BUILD_IMAGE_MIRROR_REGISTRY_ENV}" ]] || fail "build_flow.build_image_mirror.registry_env is required when build_image_mirror.enabled is true"
  [[ -n "${BUILD_IMAGE_MIRROR_USER_ENV}" ]] || fail "build_flow.build_image_mirror.username_env is required when build_image_mirror.enabled is true"
  [[ -n "${BUILD_IMAGE_MIRROR_TOKEN_ENV}" ]] || fail "build_flow.build_image_mirror.token_env is required when build_image_mirror.enabled is true"
  [[ -n "${BUILD_IMAGE_MIRROR_TLS_VERIFY_ENV}" ]] || fail "build_flow.build_image_mirror.tls_verify_env is required when build_image_mirror.enabled is true"
  [[ -n "${BUILD_IMAGE_MIRROR_REPOSITORY_PREFIX}" ]] || fail "build_flow.build_image_mirror.repository_prefix is required when build_image_mirror.enabled is true"
  [[ -n "${BUILD_IMAGE_MIRROR_TIMEOUT_SECONDS}" ]] || fail "build_flow.build_image_mirror.timeout_seconds is required when build_image_mirror.enabled is true"
  if ! [[ "${BUILD_IMAGE_MIRROR_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    fail "build_flow.build_image_mirror.timeout_seconds must be a positive integer"
  fi
  BUILD_IMAGE_MIRROR_REGISTRY="$(resolve_env_value "${BUILD_IMAGE_MIRROR_REGISTRY_ENV}" "Build image mirror registry env")"
  [[ -n "${BUILD_IMAGE_MIRROR_REGISTRY}" ]] || fail "empty value for env ${BUILD_IMAGE_MIRROR_REGISTRY_ENV} (named by build_flow.build_image_mirror.registry_env)"
  BUILD_IMAGE_MIRROR_USER="$(resolve_secret "${BUILD_IMAGE_MIRROR_USER_ENV}" "Build image mirror username")"
  [[ -n "${BUILD_IMAGE_MIRROR_USER}" ]] || fail "empty value for env ${BUILD_IMAGE_MIRROR_USER_ENV} (named by build_flow.build_image_mirror.username_env)"
  BUILD_IMAGE_MIRROR_TOKEN="$(resolve_secret "${BUILD_IMAGE_MIRROR_TOKEN_ENV}" "Build image mirror token")"
  [[ -n "${BUILD_IMAGE_MIRROR_TOKEN}" ]] || fail "empty value for env ${BUILD_IMAGE_MIRROR_TOKEN_ENV} (named by build_flow.build_image_mirror.token_env)"
  BUILD_IMAGE_MIRROR_TLS_VERIFY="$(normalize_bool_value "$(resolve_env_value "${BUILD_IMAGE_MIRROR_TLS_VERIFY_ENV}" "Build image mirror TLS verify env")")"
fi

BUILD_ARGO_ENABLED="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.enabled" || true)"
BUILD_ARGO_REQUIRED="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.required" || true)"
BUILD_ARGO_VERSION="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.version" || true)"
BUILD_ARGO_CONTROLLER_IMAGE_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.controller_image_ref" || true)"
BUILD_ARGO_EXECUTOR_IMAGE_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.executor_image_ref" || true)"
BUILD_WORKSPACE_PROVISIONER_IMAGE_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.workspace_provisioner_image_ref" || true)"
BUILD_ZOT_VERSION="$(config_get_optional "${CONFIG_PATH}" "build_flow.zot.version" || true)"
BUILD_ZOT_IMAGE_PULL_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.zot.image_pull_ref" || true)"
BUILD_DNS_VERSION="$(config_get_optional "${CONFIG_PATH}" "build_flow.dns.version" || true)"
BUILD_DNS_IMAGE_PULL_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.dns.image_pull_ref" || true)"
APPLIANCE_PROFILE="$(require_appliance_profile "${CONFIG_PATH}")"
VERIFY_ARGO_ENABLED="$(config_get_optional "${CONFIG_PATH}" "verification.argo.enabled" || true)"
if [[ -z "${VERIFY_ARGO_ENABLED}" ]]; then
  if bool_true "${LOCAL_MODE}"; then
    # Build-publish-only configs do not include verification.*; packaging is
    # always the complete product super-set, so default Argo packing checks on.
    VERIFY_ARGO_ENABLED="true"
    log "local mode: verification.argo.enabled not in config; defaulting to true for complete-product packaging"
  else
    fail "verification.argo.enabled is required in config (true|false)"
  fi
fi
BUNDLE_STORE_MODE="$(resolve_bundle_store_mode "${CONFIG_PATH}")"
PUBLISH_PATH_PREFIX="$(bundle_store_get_optional "${CONFIG_PATH}" "release_path_prefix" || true)"
PUBLISH_LATEST_ALIAS="$(config_get_optional "${CONFIG_PATH}" "release.publish_latest_alias" || true)"
PUBLISH_SERVER="$(bundle_store_get_optional "${CONFIG_PATH}" "publish_server_alias" || true)"
PUBLISH_REMOTE_ROOT="$(bundle_store_get_optional "${CONFIG_PATH}" "publish_remote_root" || true)"
[[ -n "${PUBLISH_PATH_PREFIX}" ]] || fail "bundle_store.release_path_prefix is required in config"
[[ -n "${PUBLISH_LATEST_ALIAS}" ]] || fail "release.publish_latest_alias is required in config (true|false)"
PUBLISH_PUBLIC_BASE_URL=""
case "${BUNDLE_STORE_MODE}" in
  static_http)
    PUBLISH_PUBLIC_BASE_URL="$(bundle_store_get_optional "${CONFIG_PATH}" "base_url" || true)"
    [[ -n "${PUBLISH_PUBLIC_BASE_URL}" ]] || fail "bundle_store.mode=static_http requires bundle_store.base_url"
    [[ -n "${PUBLISH_SERVER}" ]] || fail "bundle_store.mode=static_http requires bundle_store.publish_server_alias"
    [[ -n "${PUBLISH_REMOTE_ROOT}" ]] || fail "bundle_store.mode=static_http requires bundle_store.publish_remote_root"
    ;;
  appliance_files)
    # Host/token/TLS come from DEV_REGISTRY* (or registry_env/token_env/tls_verify_env).
    PUBLISH_PUBLIC_BASE_URL="$(resolve_appliance_files_base_url "${CONFIG_PATH}")"
    ;;
esac
ensure_release_run_dirs "${RUN_DIR}" "artifacts"

if bool_true "${LOCAL_MODE}"; then
  log "local mode: skipping Mac/devhost live-repo preflight (release checkout is managed on this host)"
else
  log "running local live-build repo preflight against release=${REMOTE_REPO_REF}, appliance-code=${CODE_REPO_REF}, appliance-ctl=${CTL_REPO_REF}"
  preflight_live_release_inputs "${SKILL_RELEASE_REPO_ROOT}" "${REMOTE_REPO_REF}" "${CODE_REPO_REF}" "${CTL_REPO_REF}"
fi

require_profile_supports_workflows "${VERIFY_ARGO_ENABLED}" "${APPLIANCE_PROFILE}" "verification.argo.enabled"

# Complete product super-set: package always includes Argo, host-packages (mdns+wifi-ap),
# and registry.local/dev-build. Install.profile / host_* flags only affect target enablement.
BUILD_COMPLETE_PRODUCT=true
if [[ -z "${BUILD_ARGO_ENABLED}" ]]; then
  BUILD_ARGO_ENABLED=true
fi
if ! bool_true "${BUILD_ARGO_ENABLED}"; then
  fail "build_flow.argo.enabled must be true for complete product packaging (install profile selects runtime modules, not package contents)"
fi
# BUILD_EXTRA_OCI_IMAGE_REFS is fixed to registry.local/dev-build above.

BUILD_ENV_PREFIX=""
BUILD_ENV_PREFIX="$(append_env_assignments "${BUILD_ENV_PREFIX}" \
  "PRODUCT_VERSION" "${RELEASE_VERSION}" \
  "BUILD_COMPLETE_PRODUCT" "${BUILD_COMPLETE_PRODUCT}" \
  "EXPORT_DIR" "${REMOTE_EXPORT_DIR}" \
  "K3S_BINARY_SOURCE" "${BUILD_K3S_BINARY_SOURCE}" \
  "K3S_AIRGAP_IMAGES_SOURCE" "${BUILD_K3S_AIRGAP_IMAGES_SOURCE}" \
  "CODE_REPO_REF" "${CODE_REPO_REF}" \
  "CTL_REPO_REF" "${CTL_REPO_REF}" \
  "ARGO_ENABLED" "${BUILD_ARGO_ENABLED}" \
  "ARGO_REQUIRED" "${BUILD_ARGO_REQUIRED}" \
  "ARGO_VERSION" "${BUILD_ARGO_VERSION}" \
  "ARGO_CONTROLLER_IMAGE_REF" "${BUILD_ARGO_CONTROLLER_IMAGE_REF}" \
  "ARGO_EXECUTOR_IMAGE_REF" "${BUILD_ARGO_EXECUTOR_IMAGE_REF}" \
  "WORKSPACE_PROVISIONER_IMAGE_REF" "${BUILD_WORKSPACE_PROVISIONER_IMAGE_REF}" \
  "ZOT_VERSION" "${BUILD_ZOT_VERSION}" \
  "ZOT_IMAGE_PULL_REF" "${BUILD_ZOT_IMAGE_PULL_REF}" \
  "DNS_VERSION" "${BUILD_DNS_VERSION}" \
  "DNS_IMAGE_PULL_REF" "${BUILD_DNS_IMAGE_PULL_REF}" \
  "EXTRA_OCI_IMAGE_REFS" "${BUILD_EXTRA_OCI_IMAGE_REFS}" \
  "EXTRA_OCI_IMAGE_PULL_REFS" "${IMAGE_REGISTRY_PULL_REF}" \
  "OCI_COPY_SRC_TLS_VERIFY" "${OCI_COPY_SRC_TLS_VERIFY}" \
  "BUILD_IMAGE_MIRROR_ENABLED" "${BUILD_IMAGE_MIRROR_ENABLED}" \
  "BUILD_IMAGE_MIRROR_REGISTRY" "${BUILD_IMAGE_MIRROR_REGISTRY}" \
  "BUILD_IMAGE_MIRROR_REPOSITORY_PREFIX" "${BUILD_IMAGE_MIRROR_REPOSITORY_PREFIX}" \
  "BUILD_IMAGE_MIRROR_TIMEOUT_SECONDS" "${BUILD_IMAGE_MIRROR_TIMEOUT_SECONDS}" \
  "BUILD_IMAGE_MIRROR_TLS_VERIFY" "${BUILD_IMAGE_MIRROR_TLS_VERIFY}")"
# Point appliance-code at the pull image (DEV_*). Per-service image push
# destination is owned by appliance-code build/service-image.mk.
BUILD_ENV_PREFIX="$(append_env_assignments "${BUILD_ENV_PREFIX}" \
  "DEV_IMAGE" "${IMAGE_REGISTRY_PULL_REF}" \
  "DEV_REGISTRY_HOST" "${IMAGE_REGISTRY_HOST}" \
  "DEV_REGISTRY_TLS_VERIFY" "${DEV_REGISTRY_TLS_VERIFY}" \
  "DEV_REGISTRY" "${DEV_PULL_REGISTRY}" \
  "DEV_IMAGE_REPO" "${DEV_PULL_IMAGE_REPO}" \
  "DEV_IMAGE_NAME" "${DEV_PULL_IMAGE_NAME}" \
  "DEV_IMAGE_TAG" "${DEV_PULL_IMAGE_TAG}")"
if bool_true "${BUILD_IMAGE_MIRROR_ENABLED}"; then
  BUILD_ENV_PREFIX="$(append_env_assignments "${BUILD_ENV_PREFIX}" \
    "BUILD_IMAGE_MIRROR_USER" "${BUILD_IMAGE_MIRROR_USER}" \
    "BUILD_IMAGE_MIRROR_TOKEN" "${BUILD_IMAGE_MIRROR_TOKEN}")"
fi

PUBLISH_ENV_PREFIX=""
PUBLISH_ENV_PREFIX="$(append_env_assignments "${PUBLISH_ENV_PREFIX}" \
  "PRODUCT_VERSION" "${RELEASE_VERSION}" \
  "EXPORT_DIR" "${REMOTE_EXPORT_DIR}" \
  "PUBLISH_MODE" "${BUNDLE_STORE_MODE}" \
  "PUBLISH_PUBLIC_BASE_URL" "${PUBLISH_PUBLIC_BASE_URL}" \
  "PUBLISH_PATH_PREFIX" "${PUBLISH_PATH_PREFIX}")"
if [[ "${BUNDLE_STORE_MODE}" == "static_http" ]]; then
  PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "PUBLISH_SERVER" "${PUBLISH_SERVER}")"
  PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "PUBLISH_REMOTE_ROOT" "${PUBLISH_REMOTE_ROOT}")"
fi
if bool_true "${PUBLISH_LATEST_ALIAS:-false}"; then
  PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "PUBLISH_LATEST_ALIAS" "1")"
fi
if [[ "${BUNDLE_STORE_MODE}" == "appliance_files" ]]; then
  bundle_store_bearer_token="$(resolve_appliance_files_bearer_token "${CONFIG_PATH}" "${PUBLISH_PUBLIC_BASE_URL}")"
  PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "PUBLISH_BEARER_TOKEN" "${bundle_store_bearer_token}")"
  bundle_store_fill_curl_tls_args "${CONFIG_PATH}"
  tls_idx=0
  while [[ ${tls_idx} -lt ${#BUNDLE_STORE_CURL_TLS_ARGS[@]} ]]; do
    if [[ "${BUNDLE_STORE_CURL_TLS_ARGS[$tls_idx]}" == "--cacert" ]]; then
      PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "PUBLISH_CACERT" "${BUNDLE_STORE_CURL_TLS_ARGS[$((tls_idx + 1))]}")"
      break
    fi
    if [[ "${BUNDLE_STORE_CURL_TLS_ARGS[$tls_idx]}" == "-k" ]]; then
      PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "PUBLISH_TLS_INSECURE" "1")"
      break
    fi
    tls_idx=$((tls_idx + 1))
  done
fi

release_repo_sync_remote_cmd=""
release_repo_sync_remote_cmd="$(render_ensure_remote_release_repo_cmd "${REMOTE_CWD}" "${EFFECTIVE_REMOTE_REPO_SOURCE}" "${REMOTE_REPO_REF}")"

# Resolve registry credentials from build_flow.dev_image_pull.*_env.
BOOTSTRAP_REGISTRY_USER="$(resolve_secret "${DEV_PULL_USER_ENV}" "Dev image pull username")"
[[ -n "${BOOTSTRAP_REGISTRY_USER}" ]] || fail "empty value for env ${DEV_PULL_USER_ENV} (named by build_flow.dev_image_pull.username_env)"
BOOTSTRAP_REGISTRY_TOKEN="$(resolve_secret "${DEV_PULL_TOKEN_ENV}" "Dev image pull token")"
[[ -n "${BOOTSTRAP_REGISTRY_TOKEN}" ]] || fail "empty value for env ${DEV_PULL_TOKEN_ENV} (named by build_flow.dev_image_pull.token_env)"
BOOTSTRAP_ENV_PREFIX=""
BOOTSTRAP_ENV_PREFIX="$(append_env_assignments "${BOOTSTRAP_ENV_PREFIX}" \
  "CODE_REPO_REF" "${CODE_REPO_REF}" \
  "DEV_REGISTRY_USER" "${BOOTSTRAP_REGISTRY_USER}" \
  "DEV_REGISTRY_TOKEN" "${BOOTSTRAP_REGISTRY_TOKEN}" \
  "DEV_IMAGE" "${IMAGE_REGISTRY_PULL_REF}" \
  "DEV_REGISTRY_HOST" "${IMAGE_REGISTRY_HOST}" \
  "DEV_REGISTRY_TLS_VERIFY" "${DEV_REGISTRY_TLS_VERIFY}" \
  "DEV_REGISTRY" "${DEV_PULL_REGISTRY}" \
  "DEV_IMAGE_REPO" "${DEV_PULL_IMAGE_REPO}" \
  "DEV_IMAGE_NAME" "${DEV_PULL_IMAGE_NAME}" \
  "DEV_IMAGE_TAG" "${DEV_PULL_IMAGE_TAG}")"
# Same auth for the build so skopeo/podman can use it after login.
BUILD_ENV_PREFIX="$(append_env_assignments "${BUILD_ENV_PREFIX}" \
  "DEV_REGISTRY_USER" "${BOOTSTRAP_REGISTRY_USER}" \
  "DEV_REGISTRY_TOKEN" "${BOOTSTRAP_REGISTRY_TOKEN}")"

# Non-interactive host bootstrap (make dev-sudo-setup) reads this instead of a TTY prompt.
if bool_true "${BOOTSTRAP_NEEDS_SUDO:-false}" || bool_true "${BUILD_NEEDS_SUDO:-false}"; then
  build_sudo_password_for_env="$(resolve_secret "APPLIANCE_BUILD_SUDO_PASSWORD" "Build host sudo password")"
  BOOTSTRAP_ENV_PREFIX="$(append_env_assignment "${BOOTSTRAP_ENV_PREFIX}" "APPLIANCE_BUILD_SUDO_PASSWORD" "${build_sudo_password_for_env}")"
  BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "APPLIANCE_BUILD_SUDO_PASSWORD" "${build_sudo_password_for_env}")"
fi

bootstrap_remote_cmd=""
if [[ -n "${BOOTSTRAP_CMD}" ]]; then
  bootstrap_remote_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${BOOTSTRAP_ENV_PREFIX}${BOOTSTRAP_CMD}"
fi
build_remote_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${BUILD_ENV_PREFIX}${BUILD_CMD}"
publish_remote_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${PUBLISH_ENV_PREFIX}${PUBLISH_CMD}"

release_repo_sync_log="${RUN_DIR}/logs/release-repo-sync.log"
bootstrap_log="${RUN_DIR}/logs/bootstrap.log"
build_log="${RUN_DIR}/logs/build.log"
publish_log="${RUN_DIR}/logs/publish.log"

run_build_step_logged() {
  local label="$1"
  local log_file="$2"
  local command="$3"
  if bool_true "${LOCAL_MODE}"; then
    log "running ${label} on this host"
    run_local_logged "${log_file}" "${command}"
  else
    log "running remote ${label} on ${BUILD_HOST}"
    run_ssh_logged "${BUILD_HOST}" "${log_file}" "${command}"
  fi
}

if [[ -n "${release_repo_sync_remote_cmd}" ]]; then
  if bool_true "${LOCAL_MODE}"; then
    log "ensuring appliance-release checkout at ${REMOTE_CWD}"
  else
    log "ensuring remote appliance-release checkout on ${BUILD_HOST} (${REMOTE_CWD})"
  fi
  run_build_step_logged "release-repo-sync" "${release_repo_sync_log}" "${release_repo_sync_remote_cmd}"
fi

if bool_true "${BOOTSTRAP_NEEDS_SUDO:-false}" || bool_true "${BUILD_NEEDS_SUDO:-false}"; then
  build_sudo_password="$(resolve_secret "APPLIANCE_BUILD_SUDO_PASSWORD" "Build host sudo password")"
fi

# Pre-cache sudo credentials for nested sudo in toolchains that still call plain
# `sudo`. Host bootstrap itself prefers APPLIANCE_BUILD_SUDO_PASSWORD + sudo -S.
wrap_remote_cmd_with_sudo() {
  local remote_cmd="$1"
  local sudo_password="$2"
  local quoted_password
  quoted_password="$(shell_quote "${sudo_password}")"
  printf '%s' "printf '%s\n' ${quoted_password} | sudo -S -p '' -v >/dev/null 2>&1 || true; export APPLIANCE_BUILD_SUDO_PASSWORD=${quoted_password}; ${remote_cmd}"
}

if [[ -n "${bootstrap_remote_cmd}" ]]; then
  if bool_true "${BOOTSTRAP_NEEDS_SUDO:-false}"; then
    bootstrap_remote_cmd="$(wrap_remote_cmd_with_sudo "${bootstrap_remote_cmd}" "${build_sudo_password}")"
  fi
  run_build_step_logged "bootstrap" "${bootstrap_log}" "${bootstrap_remote_cmd}"
fi

if bool_true "${BUILD_NEEDS_SUDO:-false}"; then
  build_remote_cmd="$(wrap_remote_cmd_with_sudo "${build_remote_cmd}" "${build_sudo_password}")"
fi

run_build_step_logged "build" "${build_log}" "${build_remote_cmd}"
run_build_step_logged "publish" "${publish_log}" "${publish_remote_cmd}"

eval "$(
  python3 - "${build_log}" <<'PY'
from pathlib import Path
import shlex
import sys

log_path = Path(sys.argv[1])
lines = log_path.read_text(encoding="utf-8").splitlines()

def collect_block(label: str):
    collected = []
    capture = False
    for line in lines:
        if capture:
            if line.startswith("  "):
                value = line.strip()
                if value:
                    collected.append(value)
                continue
            if not line.strip():
                break
            if not line.startswith("  "):
                break
        if line.strip() == label:
            capture = True
    return collected

release_input_paths = collect_block("release-input tarball:")
bundle_paths = collect_block("final bundle:")
export_paths = collect_block("exported customer delivery files:")

export_dir = ""
bundle_archive = ""
for path in export_paths:
    candidate = Path(path)
    if not export_dir:
      export_dir = str(candidate.parent)
    if candidate.name.endswith("-bundle.tar.gz") and not bundle_archive:
      bundle_archive = str(candidate)

def emit(name: str, value: str):
    print(f"{name}={shlex.quote(value)}")

emit("DETECTED_RELEASE_INPUT_TAR", release_input_paths[0] if release_input_paths else "")
emit("DETECTED_BUNDLE_DIR", bundle_paths[0] if bundle_paths else "")
emit("DETECTED_EXPORT_DIR", export_dir)
emit("DETECTED_BUNDLE_ARCHIVE", bundle_archive)
PY
)"

if [[ -n "${DETECTED_EXPORT_DIR}" ]]; then
  REMOTE_EXPORT_DIR="${DETECTED_EXPORT_DIR}"
  log "using remote export directory from build log: ${REMOTE_EXPORT_DIR}"
fi
if [[ -n "${DETECTED_RELEASE_INPUT_TAR}" ]]; then
  REMOTE_RELEASE_INPUT="${DETECTED_RELEASE_INPUT_TAR}"
  log "using remote release-input tarball from build log: ${REMOTE_RELEASE_INPUT}"
fi
if [[ -n "${DETECTED_BUNDLE_DIR}" ]]; then
  REMOTE_BUNDLE_DIR="${DETECTED_BUNDLE_DIR}"
  log "using remote bundle directory from build log: ${REMOTE_BUNDLE_DIR}"
fi

copy_remote_path() {
  local remote_path="$1"
  local local_path="$2"
  [[ -n "${remote_path}" ]] || return 0

  if bool_true "${LOCAL_MODE}"; then
    if [[ -d "${remote_path}" ]]; then
      ensure_dir "${local_path}"
      rsync -az "${remote_path}/" "${local_path}/"
      return 0
    fi
    if [[ -e "${remote_path}" ]]; then
      ensure_dir "${local_path}"
      rsync -az "${remote_path}" "${local_path}/"
      return 0
    fi
    log "warning: path not found for local collection: ${remote_path}"
    return 0
  fi

  if ssh "${BUILD_HOST}" "test -d $(shell_quote "${remote_path}")"; then
    ensure_dir "${local_path}"
    rsync -az "${BUILD_HOST}:${remote_path}/" "${local_path}/"
    return 0
  fi
  ensure_dir "${local_path}"
  rsync -az "${BUILD_HOST}:${remote_path}" "${local_path}/"
}

extract_archive_into_dir() {
  local archive_path="$1"
  local output_dir="$2"
  rm -rf "${output_dir}"
  ensure_dir "${output_dir}"
  tar -C "${output_dir}" -xzf "${archive_path}"
}

find_first_file() {
  local search_dir="$1"
  local pattern="$2"
  python3 - "${search_dir}" "${pattern}" <<'PY'
from pathlib import Path
import sys

search_dir = Path(sys.argv[1])
pattern = sys.argv[2]

if not search_dir.is_dir():
    raise SystemExit(0)

matches = sorted(search_dir.glob(pattern))
if matches:
    print(matches[0])
PY
}

if [[ -n "${REMOTE_EXPORT_DIR}" ]]; then
  log "collecting remote export directory ${REMOTE_EXPORT_DIR}"
  copy_remote_path "${REMOTE_EXPORT_DIR}" "${RUN_DIR}/artifacts/export"
fi

if [[ -n "${REMOTE_RELEASE_INPUT}" ]]; then
  log "collecting remote release input ${REMOTE_RELEASE_INPUT}"
  copy_remote_path "${REMOTE_RELEASE_INPUT}" "${RUN_DIR}/artifacts/release-input-src"
fi

local_release_input_archive="$(find_first_file "${RUN_DIR}/artifacts/release-input-src" "*.tar.gz")"
if [[ -z "${local_release_input_archive}" ]]; then
  local_release_input_archive="$(find_first_file "${RUN_DIR}/artifacts/release-input-src" "*.tgz")"
fi
if [[ -n "${local_release_input_archive}" ]]; then
  log "extracting copied release-input archive ${local_release_input_archive}"
  extract_archive_into_dir "${local_release_input_archive}" "${RUN_DIR}/artifacts/release-input"
elif [[ -d "${RUN_DIR}/artifacts/release-input-src" ]]; then
  rm -rf "${RUN_DIR}/artifacts/release-input"
  mv "${RUN_DIR}/artifacts/release-input-src" "${RUN_DIR}/artifacts/release-input"
fi

local_bundle_archive=""
if [[ -n "${DETECTED_BUNDLE_ARCHIVE}" ]]; then
  local_bundle_archive="${RUN_DIR}/artifacts/export/$(basename "${DETECTED_BUNDLE_ARCHIVE}")"
fi
if [[ -z "${local_bundle_archive}" || ! -f "${local_bundle_archive}" ]]; then
  local_bundle_archive="$(find_first_file "${RUN_DIR}/artifacts/export" "*-bundle.tar.gz")"
fi
if [[ -n "${local_bundle_archive}" && -f "${local_bundle_archive}" ]]; then
  log "extracting copied bundle archive ${local_bundle_archive}"
  extract_archive_into_dir "${local_bundle_archive}" "${RUN_DIR}/artifacts/bundle"
elif [[ -n "${REMOTE_BUNDLE_DIR}" ]]; then
  log "collecting remote bundle directory ${REMOTE_BUNDLE_DIR}"
  copy_remote_path "${REMOTE_BUNDLE_DIR}" "${RUN_DIR}/artifacts/bundle"
fi

VALIDATE_RELEASE_ARTIFACTS_ARGS=(--require-argo)
# Host mDNS / Wi-Fi AP enablement is day-2 (Admin UI); package always has host-packages.
EXPECTED_EXTRA_OCI_IMAGE_REFS="${BUILD_EXTRA_OCI_IMAGE_REFS}"
if [[ "${BUILD_WORKSPACE_PROVISIONER_IMAGE_REF}" == *@sha256:* ]]; then
  if [[ -n "${EXPECTED_EXTRA_OCI_IMAGE_REFS}" ]]; then
    EXPECTED_EXTRA_OCI_IMAGE_REFS+=","
  fi
  EXPECTED_EXTRA_OCI_IMAGE_REFS+="${BUILD_WORKSPACE_PROVISIONER_IMAGE_REF}"
fi
if [[ -n "${EXPECTED_EXTRA_OCI_IMAGE_REFS}" ]]; then
  VALIDATE_RELEASE_ARTIFACTS_ARGS+=(--expected-extra-oci-image-refs "${EXPECTED_EXTRA_OCI_IMAGE_REFS}")
fi
if [[ -d "${RUN_DIR}/artifacts/release-input" && -d "${RUN_DIR}/artifacts/bundle" ]]; then
  log "validating copied release-input artifacts against final bundle manifest"
  python3 "${SCRIPT_DIR}/validate-release-artifacts.py" \
    --release-input-root "${RUN_DIR}/artifacts/release-input" \
    --bundle-root "${RUN_DIR}/artifacts/bundle" \
    "${VALIDATE_RELEASE_ARTIFACTS_ARGS[@]}" \
    >"${RUN_DIR}/logs/release-artifact-validation.json"
  log "release artifact validation completed; log: ${RUN_DIR}/logs/release-artifact-validation.json"
elif [[ ${#VALIDATE_RELEASE_ARTIFACTS_ARGS[@]} -gt 0 ]]; then
  fail "Argo validation requested but copied release-input or bundle metadata is missing"
fi

remote_release_commit=""
if bool_true "${LOCAL_MODE}"; then
  remote_release_commit="$(git -C "${REMOTE_CWD}" rev-parse HEAD 2>/dev/null || true)"
else
  remote_release_commit_cmd="cd $(shell_quote "${REMOTE_CWD}") && git rev-parse HEAD"
  remote_release_commit="$(ssh "${BUILD_HOST}" "bash -lc $(shell_quote "${remote_release_commit_cmd}")" 2>/dev/null || true)"
fi

python3 - "${RUN_DIR}" "${CONFIG_PATH}" "${BUILD_HOST}" "${REMOTE_CWD}" "${RELEASE_VERSION}" "${BOOTSTRAP_CMD}" "${BUILD_CMD}" "${PUBLISH_CMD}" "${remote_release_commit}" "${REMOTE_REPO_SOURCE}" "${EFFECTIVE_REMOTE_REPO_SOURCE}" "${REMOTE_REPO_REF}" <<'PY'
import json
from pathlib import Path
import sys

run_dir = Path(sys.argv[1])
(
    config_path,
    build_host,
    remote_cwd,
    release_version,
    bootstrap_cmd,
    build_cmd,
    publish_cmd,
    remote_release_commit,
    remote_repo_source,
    effective_remote_repo_source,
    remote_repo_ref,
) = sys.argv[2:13]

def read_text(path: Path):
    if path.is_file():
        return path.read_text(encoding="utf-8")
    return None

def read_json(path: Path):
    if path.is_file():
        return json.loads(path.read_text(encoding="utf-8"))
    return None

def read_json_named(root: Path, name: str):
    if not root.is_dir():
        return None
    matches = sorted(root.rglob(name))
    if not matches:
        return None
    return json.loads(matches[0].read_text(encoding="utf-8"))

export_dir = run_dir / "artifacts" / "export"
release_input_dir = run_dir / "artifacts" / "release-input"
bundle_dir = run_dir / "artifacts" / "bundle"

checksums_text = read_text(export_dir / "sha256sum.txt")
release_input = read_json_named(release_input_dir, "release-input.json")
release_manifest = read_json_named(bundle_dir, "release-manifest.json")

artifact_checksums = []
if checksums_text:
    for raw_line in checksums_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2:
            artifact_checksums.append({"digest": parts[0], "path": parts[-1]})

image_digests = {}
if release_input and isinstance(release_input.get("artifacts"), dict):
    for key, value in release_input["artifacts"].items():
        if isinstance(value, dict):
            digest = value.get("digest") or value.get("manifestDigest")
            if digest:
                image_digests[key] = {
                    "path": value.get("path"),
                    "digest": digest,
                }

bundle_entries = []
if release_manifest and isinstance(release_manifest.get("entries"), list):
    for entry in release_manifest["entries"]:
        if isinstance(entry, dict):
            bundle_entries.append(
                {
                    "path": entry.get("targetPath") or entry.get("path"),
                    "digest": entry.get("digest"),
                    "sizeBytes": entry.get("sizeBytes"),
                }
            )

payload = {
    "configPath": config_path,
    "buildHost": build_host,
    "remoteWorkingDirectory": remote_cwd,
    "releaseVersion": release_version or None,
    "remoteReleaseCommit": remote_release_commit or None,
    "remoteRepoSource": remote_repo_source or None,
    "effectiveRemoteRepoSource": effective_remote_repo_source or None,
    "remoteRepoRef": remote_repo_ref or None,
    "bootstrapCommand": bootstrap_cmd or None,
    "buildCommand": build_cmd,
    "publishCommand": publish_cmd,
    "artifactChecksums": artifact_checksums,
    "releaseInputArtifacts": image_digests,
    "bundleEntries": bundle_entries,
    "logs": {
        "releaseRepoSync": str(run_dir / "logs" / "release-repo-sync.log"),
        "bootstrap": str(run_dir / "logs" / "bootstrap.log"),
        "build": str(run_dir / "logs" / "build.log"),
        "publish": str(run_dir / "logs" / "publish.log"),
        "releaseArtifactValidation": str(run_dir / "logs" / "release-artifact-validation.json"),
    },
}

out_path = run_dir / "metadata" / "build-publish.json"
out_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log "build/publish metadata written to ${RUN_DIR}/metadata/build-publish.json"
