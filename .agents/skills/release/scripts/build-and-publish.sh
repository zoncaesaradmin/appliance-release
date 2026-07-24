#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: build-and-publish.sh [options]

Run explicit build and publish commands on the remote build host, stop on the
first failure, and pull back export metadata for reporting.

Options:
  --config PATH                 YAML or JSON config file. Optional if
                                APPLIANCE_RELEASE_CONFIG is set or a local
                                appliance-release.config.yaml exists.
  --git-pull-cmd CMD            Optional remote git-pull command.
  --bootstrap-cmd CMD           Optional remote bootstrap command.
  --build-cmd CMD               Remote build command. Defaults to build_flow.build_command.
  --publish-cmd CMD             Remote publish command. Defaults to build_flow.publish_command.
  --remote-cwd PATH             Remote working directory. Defaults to release_workspace.remote_repo_path.
  --remote-export-dir PATH      Optional remote export directory to rsync back locally.
  --remote-release-input PATH   Optional remote release-input file or directory to copy back.
  --remote-bundle-dir PATH      Optional remote extracted bundle directory to copy back.
  --release-version VERSION     Optional release version for metadata and filenames.
  --run-dir DIR                 Local run directory.
EOF
}

CONFIG_PATH=""
GIT_PULL_CMD=""
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
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --git-pull-cmd)
      GIT_PULL_CMD="${2:-}"
      shift 2
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
    --remote-release-input)
      REMOTE_RELEASE_INPUT="${2:-}"
      shift 2
      ;;
    --remote-bundle-dir)
      REMOTE_BUNDLE_DIR="${2:-}"
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

CONFIG_PATH="$(resolve_config_path "${CONFIG_PATH}" || true)"
[[ -n "${CONFIG_PATH}" ]] || fail "config not provided; use --config or APPLIANCE_RELEASE_CONFIG"
ensure_file "${CONFIG_PATH}"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(pwd)/.run/appliance-release/$(date -u +%Y%m%dT%H%M%SZ)"
fi

if [[ -z "${REMOTE_CWD}" ]]; then
  REMOTE_CWD="$(config_get "${CONFIG_PATH}" "release_workspace.remote_repo_path")"
fi
REMOTE_REPO_SOURCE="$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_repo_source" || true)"
REMOTE_REPO_REF="$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_repo_ref" || true)"
CODE_REPO_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.code_repo_ref" || true)"
CTL_REPO_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.ctl_repo_ref" || true)"
if [[ -z "${GIT_PULL_CMD}" ]]; then
  GIT_PULL_CMD="$(config_get_optional "${CONFIG_PATH}" "build_flow.git_pull_command" || true)"
fi
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
if [[ -z "${REMOTE_RELEASE_INPUT}" ]]; then
  REMOTE_RELEASE_INPUT="$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_release_input_path" || true)"
fi
if [[ -z "${REMOTE_BUNDLE_DIR}" ]]; then
  REMOTE_BUNDLE_DIR="$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_bundle_dir" || true)"
fi

[[ -n "${BUILD_CMD}" ]] || fail "build command not provided and build_flow.build_command is missing"
[[ -n "${PUBLISH_CMD}" ]] || fail "publish command not provided and build_flow.publish_command is missing"

SKILL_RELEASE_REPO_ROOT="$(skill_release_repo_root "${SCRIPT_DIR}")"
if [[ -z "${REMOTE_REPO_SOURCE}" ]]; then
  REMOTE_REPO_SOURCE="$(resolve_local_git_origin "${SKILL_RELEASE_REPO_ROOT}")"
fi
[[ -n "${REMOTE_REPO_SOURCE}" ]] || fail "release_workspace.remote_repo_source is required when the build host checkout is missing; set it in config or run from a local appliance-release git checkout"
EFFECTIVE_REMOTE_REPO_SOURCE="$(normalize_readonly_git_source "${REMOTE_REPO_SOURCE}")"
if [[ "${EFFECTIVE_REMOTE_REPO_SOURCE}" != "${REMOTE_REPO_SOURCE}" ]]; then
  log "normalizing release workspace repo source from ${REMOTE_REPO_SOURCE} to read-only ${EFFECTIVE_REMOTE_REPO_SOURCE} for build-host sync"
fi
if [[ -z "${REMOTE_REPO_REF}" ]]; then
  REMOTE_REPO_REF="main"
fi
if [[ -z "${CODE_REPO_REF}" ]]; then
  CODE_REPO_REF="main"
fi
if [[ -z "${CTL_REPO_REF}" ]]; then
  CTL_REPO_REF="main"
fi

require_cmd rsync
require_cmd ssh
require_cmd python3

BUILD_HOST="$(config_get "${CONFIG_PATH}" "build_host.alias")"
BOOTSTRAP_NEEDS_SUDO="$(config_get_optional "${CONFIG_PATH}" "build_flow.bootstrap_needs_sudo" || true)"
BUILD_NEEDS_SUDO="$(config_get_optional "${CONFIG_PATH}" "build_flow.build_needs_sudo" || true)"
BOOTSTRAP_REGISTRY_USER="$(config_get_optional "${CONFIG_PATH}" "build_flow.registry_user" || true)"
BOOTSTRAP_REGISTRY_TOKEN_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.registry_token_env" || true)"
BOOTSTRAP_REGISTRY_TOKEN="$(config_get_optional "${CONFIG_PATH}" "build_flow.registry_token" || true)"
BUILD_ARGO_ENABLED="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.enabled" || true)"
BUILD_ARGO_REQUIRED="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.required" || true)"
BUILD_ARGO_VERSION="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.version" || true)"
BUILD_ARGO_CRDS_DIR_SOURCE="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.crds_dir_source" || true)"
BUILD_ARGO_CONTROLLER_IMAGE_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.controller_image_ref" || true)"
BUILD_ARGO_EXECUTOR_IMAGE_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.executor_image_ref" || true)"
BUILD_ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.controller_image_archive_source" || true)"
BUILD_ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE="$(config_get_optional "${CONFIG_PATH}" "build_flow.argo.executor_image_archive_source" || true)"
BUILD_WORKSPACE_PROVISIONER_IMAGE_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.workspace_provisioner_image_ref" || true)"
BUILD_WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE="$(config_get_optional "${CONFIG_PATH}" "build_flow.workspace_provisioner_image_archive_source" || true)"
BUILD_ZOT_VERSION="$(config_get_optional "${CONFIG_PATH}" "build_flow.zot.version" || true)"
BUILD_ZOT_IMAGE_PULL_REF="$(config_get_optional "${CONFIG_PATH}" "build_flow.zot.image_pull_ref" || true)"
BUILD_ZOT_IMAGE_ARCHIVE_SOURCE="$(config_get_optional "${CONFIG_PATH}" "build_flow.zot.image_archive_source" || true)"
BUILD_EXTRA_OCI_IMAGE_ARCHIVE_SOURCES="$(config_get_optional "${CONFIG_PATH}" "build_flow.extra_oci_image_archive_sources" || true)"
BUILD_EXTRA_OCI_IMAGE_REFS="$(config_get_optional "${CONFIG_PATH}" "build_flow.extra_oci_image_refs" || true)"
BUILD_EXTRA_OCI_IMAGE_PULL_REFS="$(config_get_optional "${CONFIG_PATH}" "build_flow.extra_oci_image_pull_refs" || true)"
APPLIANCE_PROFILE="$(config_get_optional "${CONFIG_PATH}" "install.appliance_profile" || true)"
VERIFY_ARGO_ENABLED="$(config_get_optional "${CONFIG_PATH}" "verification.argo.enabled" || true)"
PUBLISH_PUBLIC_BASE_URL="$(config_get_optional "${CONFIG_PATH}" "artifact_registry.base_url" || true)"
if [[ -z "${BOOTSTRAP_REGISTRY_TOKEN_ENV}" ]]; then
  BOOTSTRAP_REGISTRY_TOKEN_ENV="REGISTRY_TOKEN"
fi
ensure_dir "${RUN_DIR}"
ensure_dir "${RUN_DIR}/logs"
ensure_dir "${RUN_DIR}/artifacts"
ensure_dir "${RUN_DIR}/metadata"

log "running local live-build repo preflight against release=${REMOTE_REPO_REF}, appliance-code=${CODE_REPO_REF}, appliance-ctl=${CTL_REPO_REF}"
preflight_live_release_inputs "${SKILL_RELEASE_REPO_ROOT}" "${REMOTE_REPO_REF}" "${CODE_REPO_REF}" "${CTL_REPO_REF}"

append_env_assignment() {
  local current="$1"
  local name="$2"
  local value="$3"
  if [[ -z "${value}" ]]; then
    printf '%s' "${current}"
    return 0
  fi
  printf '%s%s=%s ' "${current}" "${name}" "$(shell_quote "${value}")"
}

profile_supports_workflows() {
  case "$1" in
    core|builder) return 0 ;;
    *) return 1 ;;
  esac
}

EFFECTIVE_VERIFY_ARGO_ENABLED="${VERIFY_ARGO_ENABLED}"
if [[ -z "${EFFECTIVE_VERIFY_ARGO_ENABLED}" ]]; then
  if profile_supports_workflows "${APPLIANCE_PROFILE}"; then
    EFFECTIVE_VERIFY_ARGO_ENABLED="true"
  else
    EFFECTIVE_VERIFY_ARGO_ENABLED="false"
  fi
elif bool_true "${EFFECTIVE_VERIFY_ARGO_ENABLED}" && ! profile_supports_workflows "${APPLIANCE_PROFILE}"; then
  EFFECTIVE_VERIFY_ARGO_ENABLED="false"
  log "skipping Argo release-artifact requirement because appliance profile ${APPLIANCE_PROFILE:-unknown} does not enable workflows"
fi

BUILD_ENV_PREFIX=""
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "PRODUCT_VERSION" "${RELEASE_VERSION}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "EXPORT_DIR" "${REMOTE_EXPORT_DIR}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "CODE_REPO_REF" "${CODE_REPO_REF}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "CTL_REPO_REF" "${CTL_REPO_REF}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ARGO_ENABLED" "${BUILD_ARGO_ENABLED}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ARGO_REQUIRED" "${BUILD_ARGO_REQUIRED}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ARGO_VERSION" "${BUILD_ARGO_VERSION}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ARGO_CRDS_DIR_SOURCE" "${BUILD_ARGO_CRDS_DIR_SOURCE}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ARGO_CONTROLLER_IMAGE_REF" "${BUILD_ARGO_CONTROLLER_IMAGE_REF}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ARGO_EXECUTOR_IMAGE_REF" "${BUILD_ARGO_EXECUTOR_IMAGE_REF}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE" "${BUILD_ARGO_CONTROLLER_IMAGE_ARCHIVE_SOURCE}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE" "${BUILD_ARGO_EXECUTOR_IMAGE_ARCHIVE_SOURCE}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "WORKSPACE_PROVISIONER_IMAGE_REF" "${BUILD_WORKSPACE_PROVISIONER_IMAGE_REF}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE" "${BUILD_WORKSPACE_PROVISIONER_IMAGE_ARCHIVE_SOURCE}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ZOT_VERSION" "${BUILD_ZOT_VERSION}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ZOT_IMAGE_PULL_REF" "${BUILD_ZOT_IMAGE_PULL_REF}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "ZOT_IMAGE_ARCHIVE_SOURCE" "${BUILD_ZOT_IMAGE_ARCHIVE_SOURCE}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "EXTRA_OCI_IMAGE_ARCHIVE_SOURCES" "${BUILD_EXTRA_OCI_IMAGE_ARCHIVE_SOURCES}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "EXTRA_OCI_IMAGE_REFS" "${BUILD_EXTRA_OCI_IMAGE_REFS}")"
BUILD_ENV_PREFIX="$(append_env_assignment "${BUILD_ENV_PREFIX}" "EXTRA_OCI_IMAGE_PULL_REFS" "${BUILD_EXTRA_OCI_IMAGE_PULL_REFS}")"

PUBLISH_ENV_PREFIX=""
PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "PRODUCT_VERSION" "${RELEASE_VERSION}")"
PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "EXPORT_DIR" "${REMOTE_EXPORT_DIR}")"
PUBLISH_ENV_PREFIX="$(append_env_assignment "${PUBLISH_ENV_PREFIX}" "PUBLISH_PUBLIC_BASE_URL" "${PUBLISH_PUBLIC_BASE_URL}")"

release_repo_sync_remote_cmd=""
release_repo_sync_remote_cmd="$(render_ensure_remote_release_repo_cmd "${REMOTE_CWD}" "${EFFECTIVE_REMOTE_REPO_SOURCE}" "${REMOTE_REPO_REF}" "${GIT_PULL_CMD}")"
bootstrap_remote_cmd=""
if [[ -n "${BOOTSTRAP_CMD}" ]]; then
  bootstrap_remote_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${BOOTSTRAP_CMD}"
fi
build_remote_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${BUILD_ENV_PREFIX}${BUILD_CMD}"
publish_remote_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${PUBLISH_ENV_PREFIX}${PUBLISH_CMD}"

git_pull_log="${RUN_DIR}/logs/git-pull.log"
bootstrap_log="${RUN_DIR}/logs/bootstrap.log"
build_log="${RUN_DIR}/logs/build.log"
publish_log="${RUN_DIR}/logs/publish.log"

if [[ -n "${release_repo_sync_remote_cmd}" ]]; then
  log "ensuring remote appliance-release checkout on ${BUILD_HOST} (${REMOTE_CWD})"
  run_ssh_logged "${BUILD_HOST}" "${git_pull_log}" "${release_repo_sync_remote_cmd}"
fi

build_sudo_password=""
if bool_true "${BOOTSTRAP_NEEDS_SUDO:-false}" || bool_true "${BUILD_NEEDS_SUDO:-false}"; then
  build_sudo_password="$(resolve_secret "APPLIANCE_BUILD_SUDO_PASSWORD" "Build host sudo password")"
fi

if [[ -n "${bootstrap_remote_cmd}" ]]; then
  bootstrap_env_prefix=""
  if [[ -n "${CODE_REPO_REF}" ]]; then
    bootstrap_env_prefix="${bootstrap_env_prefix}export CODE_REPO_REF=$(shell_quote "${CODE_REPO_REF}") ; "
  fi
  if [[ -n "${BOOTSTRAP_REGISTRY_USER}" ]]; then
    bootstrap_env_prefix="${bootstrap_env_prefix}export REGISTRY_USER=$(shell_quote "${BOOTSTRAP_REGISTRY_USER}") ; "
  fi
  if [[ -z "${BOOTSTRAP_REGISTRY_TOKEN}" && -n "${BOOTSTRAP_REGISTRY_TOKEN_ENV}" ]]; then
    BOOTSTRAP_REGISTRY_TOKEN="$(resolve_secret "${BOOTSTRAP_REGISTRY_TOKEN_ENV}" "Build host registry token")"
  fi
  if [[ -n "${BOOTSTRAP_REGISTRY_TOKEN}" ]]; then
    bootstrap_env_prefix="${bootstrap_env_prefix}export REGISTRY_TOKEN=$(shell_quote "${BOOTSTRAP_REGISTRY_TOKEN}") ; "
  fi
  if [[ -n "${bootstrap_env_prefix}" ]]; then
    bootstrap_remote_cmd="${bootstrap_env_prefix}${bootstrap_remote_cmd}"
  fi
  if bool_true "${BOOTSTRAP_NEEDS_SUDO:-false}"; then
    bootstrap_remote_cmd="printf '%s\n' $(shell_quote "${build_sudo_password}") | sudo -S -p '' -v >/dev/null && ${bootstrap_remote_cmd}"
  fi
  log "running remote bootstrap on ${BUILD_HOST}"
  run_ssh_logged "${BUILD_HOST}" "${bootstrap_log}" "${bootstrap_remote_cmd}"
fi

if bool_true "${BUILD_NEEDS_SUDO:-false}"; then
  build_remote_cmd="printf '%s\n' $(shell_quote "${build_sudo_password}") | sudo -S -p '' -v >/dev/null && ${build_remote_cmd}"
fi

log "running remote build on ${BUILD_HOST}"
run_ssh_logged "${BUILD_HOST}" "${build_log}" "${build_remote_cmd}"

log "running remote publish on ${BUILD_HOST}"
run_ssh_logged "${BUILD_HOST}" "${publish_log}" "${publish_remote_cmd}"

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

VALIDATE_RELEASE_ARTIFACTS_ARGS=()
if bool_true "${BUILD_ARGO_ENABLED:-false}" || bool_true "${EFFECTIVE_VERIFY_ARGO_ENABLED:-false}"; then
  VALIDATE_RELEASE_ARTIFACTS_ARGS+=(--require-argo)
fi
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

remote_release_commit_cmd="cd $(shell_quote "${REMOTE_CWD}") && git rev-parse HEAD"
remote_release_commit="$(ssh "${BUILD_HOST}" "bash -lc $(shell_quote "${remote_release_commit_cmd}")" 2>/dev/null || true)"

python3 - "${RUN_DIR}" "${CONFIG_PATH}" "${BUILD_HOST}" "${REMOTE_CWD}" "${RELEASE_VERSION}" "${GIT_PULL_CMD}" "${BOOTSTRAP_CMD}" "${BUILD_CMD}" "${PUBLISH_CMD}" "${remote_release_commit}" "${REMOTE_REPO_SOURCE}" "${EFFECTIVE_REMOTE_REPO_SOURCE}" "${REMOTE_REPO_REF}" <<'PY'
import json
from pathlib import Path
import sys

run_dir = Path(sys.argv[1])
(
    config_path,
    build_host,
    remote_cwd,
    release_version,
    git_pull_cmd,
    bootstrap_cmd,
    build_cmd,
    publish_cmd,
    remote_release_commit,
    remote_repo_source,
    effective_remote_repo_source,
    remote_repo_ref,
) = sys.argv[2:14]

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
    "gitPullCommand": git_pull_cmd or None,
    "bootstrapCommand": bootstrap_cmd or None,
    "buildCommand": build_cmd,
    "publishCommand": publish_cmd,
    "artifactChecksums": artifact_checksums,
    "releaseInputArtifacts": image_digests,
    "bundleEntries": bundle_entries,
    "logs": {
        "gitPull": str(run_dir / "logs" / "git-pull.log"),
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
