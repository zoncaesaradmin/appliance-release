#!/usr/bin/env bash
# build-and-publish.sh — thin build-host worker (always local).
#
# Resolves build-publish YAML to env, then runs the fixed product sequence:
#   scripts/bootstrap-build-host.sh
#   scripts/build-full-bundle.sh
#   scripts/publish-release.sh
#
# Mac e2e uses run-build-and-publish-on-build-host.sh (repo sync + SSH + env
# inject) which invokes this script with --local on the build host.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: build-and-publish.sh --local --build-publish-config PATH [options]

Run on the build host only (--local required). Product implementation is the
three product scripts under scripts/.

Options:
  --build-publish-config PATH   Build-publish role file (required).
  --config PATH                 Alias for --build-publish-config.
  --local                       Required (this worker never SSHs).
  --release-version VERSION     Optional PRODUCT_VERSION override.
  --run-dir DIR                 Logs/metadata/artifacts directory.
EOF
}

CONFIG_PATH=""
LOCAL_MODE="false"
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
    --release-version)
      RELEASE_VERSION="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    --bootstrap-cmd|--build-cmd|--publish-cmd|--remote-cwd|--remote-export-dir)
      fail "$1 was removed; this worker only runs the fixed product script sequence on --local"
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

[[ -n "${CONFIG_PATH}" ]] || fail "requires --build-publish-config PATH"
bool_true "${LOCAL_MODE}" || fail "requires --local (use run-build-and-publish-on-build-host.sh from the Mac)"

CONFIG_PATH="$(require_config_path "${CONFIG_PATH}")"

readonly BOOTSTRAP_CMD="bash scripts/bootstrap-build-host.sh"
readonly BUILD_CMD="bash scripts/build-full-bundle.sh"
readonly PUBLISH_CMD="bash scripts/publish-release.sh"
readonly BUILDER_LOCAL_REF="registry.local/dev-build"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}" "artifacts"

REMOTE_BUILD_ROOT="$(resolve_build_publish_remote_build_root "${CONFIG_PATH}")"
REMOTE_CWD="$(derive_remote_repo_path_from_build_root "${REMOTE_BUILD_ROOT}")"
REMOTE_EXPORT_DIR="$(derive_remote_export_dir_from_build_root "${REMOTE_BUILD_ROOT}")"
REMOTE_REPO_REF="$(config_get "${CONFIG_PATH}" "release_workspace.remote_repo_ref")"
REMOTE_REPO_SOURCE="$(config_get_optional "${CONFIG_PATH}" "release_workspace.remote_repo_source" || true)"

SKILL_RELEASE_REPO_ROOT="$(skill_release_repo_root "${SCRIPT_DIR}")"
if [[ -z "${RELEASE_VERSION}" && -n "${PRODUCT_VERSION:-}" ]]; then
  RELEASE_VERSION="${PRODUCT_VERSION}"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(config_get_optional "${CONFIG_PATH}" "release.version" || true)"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(read_default_product_version "${SKILL_RELEASE_REPO_ROOT}")"
fi
if [[ -z "${REMOTE_REPO_SOURCE}" ]]; then
  REMOTE_REPO_SOURCE="$(resolve_local_git_origin "${SKILL_RELEASE_REPO_ROOT}")"
fi
[[ -n "${REMOTE_REPO_SOURCE}" ]] || fail "release_workspace.remote_repo_source is required (or run from a checkout with origin)"
EFFECTIVE_REMOTE_REPO_SOURCE="$(normalize_readonly_git_source "${REMOTE_REPO_SOURCE}")"

# Fail closed on removed / packaging-owned knobs (product scripts own defaults).
reject_removed_build_publish_packaging_keys "${CONFIG_PATH}"
resolve_bundle_store_mode "${CONFIG_PATH}" >/dev/null

DEV_PULL_REGISTRY_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.registry_env" || true)"
DEV_PULL_IMAGE_REPO_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.image_repo_env" || true)"
DEV_PULL_IMAGE_NAME_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.image_name_env" || true)"
DEV_PULL_IMAGE_TAG="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.image_tag" || true)"
DEV_PULL_USER_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.username_env" || true)"
DEV_PULL_TOKEN_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.token_env" || true)"
DEV_PULL_TLS_VERIFY_ENV="$(config_get_optional "${CONFIG_PATH}" "build_flow.dev_image_pull.tls_verify_env" || true)"
[[ -n "${DEV_PULL_REGISTRY_ENV}" ]] || fail "build_flow.dev_image_pull.registry_env is required"
[[ -n "${DEV_PULL_IMAGE_REPO_ENV}" ]] || fail "build_flow.dev_image_pull.image_repo_env is required"
[[ -n "${DEV_PULL_IMAGE_NAME_ENV}" ]] || fail "build_flow.dev_image_pull.image_name_env is required"
[[ -n "${DEV_PULL_IMAGE_TAG}" ]] || fail "build_flow.dev_image_pull.image_tag is required"
[[ -n "${DEV_PULL_USER_ENV}" ]] || fail "build_flow.dev_image_pull.username_env is required"
[[ -n "${DEV_PULL_TOKEN_ENV}" ]] || fail "build_flow.dev_image_pull.token_env is required"
[[ -n "${DEV_PULL_TLS_VERIFY_ENV}" ]] || fail "build_flow.dev_image_pull.tls_verify_env is required"

DEV_PULL_REGISTRY="$(resolve_env_value "${DEV_PULL_REGISTRY_ENV}" "Dev image pull registry")"
DEV_PULL_IMAGE_REPO="$(resolve_env_value "${DEV_PULL_IMAGE_REPO_ENV}" "Dev image pull image repo")"
DEV_PULL_IMAGE_NAME="$(resolve_env_value "${DEV_PULL_IMAGE_NAME_ENV}" "Dev image pull image name")"
DEV_PULL_TLS_VERIFY="$(normalize_bool_value "$(resolve_env_value "${DEV_PULL_TLS_VERIFY_ENV}" "TLS verify")")"
if bool_true "${DEV_PULL_TLS_VERIFY}"; then
  DEV_REGISTRY_TLS_VERIFY="true"
else
  DEV_REGISTRY_TLS_VERIFY="false"
fi
IMAGE_REGISTRY_PULL_REF="${DEV_PULL_REGISTRY}/${DEV_PULL_IMAGE_REPO}/${DEV_PULL_IMAGE_NAME}:${DEV_PULL_IMAGE_TAG}"

PUBLISH_LATEST_ALIAS="$(config_get_optional "${CONFIG_PATH}" "release.publish_latest_alias" || true)"
if [[ -z "${PUBLISH_LATEST_ALIAS}" ]]; then
  PUBLISH_LATEST_ALIAS="false"
fi

BOOTSTRAP_REGISTRY_USER="$(resolve_secret "${DEV_PULL_USER_ENV}" "Dev image pull username")"
BOOTSTRAP_REGISTRY_TOKEN="$(resolve_secret "${DEV_PULL_TOKEN_ENV}" "Dev image pull token")"
[[ -n "${BOOTSTRAP_REGISTRY_USER}" ]] || fail "empty ${DEV_PULL_USER_ENV}"
[[ -n "${BOOTSTRAP_REGISTRY_TOKEN}" ]] || fail "empty ${DEV_PULL_TOKEN_ENV}"

# Shared env for the three product scripts (they own workflows engine/Artifact Server/DNS/provisioner defaults).
PRODUCT_ENV_PREFIX=""
PRODUCT_ENV_PREFIX="$(append_env_assignments "${PRODUCT_ENV_PREFIX}" \
  "PRODUCT_VERSION" "${RELEASE_VERSION}" \
  "RELEASE_WORK_ROOT" "${REMOTE_BUILD_ROOT}" \
  "DEV_IMAGE" "${IMAGE_REGISTRY_PULL_REF}" \
  "DEV_REGISTRY_HOST" "${DEV_PULL_REGISTRY}" \
  "DEV_REGISTRY_TLS_VERIFY" "${DEV_REGISTRY_TLS_VERIFY}" \
  "DEV_REGISTRY" "${DEV_PULL_REGISTRY}" \
  "DEV_IMAGE_REPO" "${DEV_PULL_IMAGE_REPO}" \
  "DEV_IMAGE_NAME" "${DEV_PULL_IMAGE_NAME}" \
  "DEV_IMAGE_TAG" "${DEV_PULL_IMAGE_TAG}" \
  "DEV_REGISTRY_USER" "${BOOTSTRAP_REGISTRY_USER}" \
  "DEV_REGISTRY_TOKEN" "${BOOTSTRAP_REGISTRY_TOKEN}")"

EFFECTIVE_PUBLISH_CMD="${PUBLISH_CMD}"
if bool_true "${PUBLISH_LATEST_ALIAS}"; then
  EFFECTIVE_PUBLISH_CMD="${PUBLISH_CMD} --latest-alias"
fi

build_sudo_password="$(resolve_secret "APPLIANCE_BUILD_SUDO_PASSWORD" "Build host sudo password")"
wrap_with_sudo() {
  local remote_cmd="$1"
  local quoted_password
  quoted_password="$(shell_quote "${build_sudo_password}")"
  printf '%s' "printf '%s\n' ${quoted_password} | sudo -S -p '' -v >/dev/null && ${remote_cmd}"
}

bootstrap_log="${RUN_DIR}/logs/bootstrap.log"
build_log="${RUN_DIR}/logs/build.log"
publish_log="${RUN_DIR}/logs/publish.log"

run_step() {
  local label="$1"
  local log_file="$2"
  local command="$3"
  log "running ${label} on this host"
  run_local_logged "${log_file}" "${command}"
}

bootstrap_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${PRODUCT_ENV_PREFIX}${BOOTSTRAP_CMD}"
build_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${PRODUCT_ENV_PREFIX}${BUILD_CMD}"
publish_cmd="cd $(shell_quote "${REMOTE_CWD}") && set -euo pipefail && ${PRODUCT_ENV_PREFIX}${EFFECTIVE_PUBLISH_CMD}"

run_step "bootstrap" "${bootstrap_log}" "$(wrap_with_sudo "${bootstrap_cmd}")"
run_step "build" "${build_log}" "$(wrap_with_sudo "${build_cmd}")"
run_step "publish" "${publish_log}" "${publish_cmd}"

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
            break
        if line.strip() == label:
            capture = True
    return collected

export_paths = collect_block("exported customer delivery files:")
release_input_paths = collect_block("release-input tarball:")
bundle_paths = collect_block("final bundle:")
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

copy_local_path() {
  local src="$1"
  local dest="$2"
  [[ -n "${src}" ]] || return 0
  if [[ -d "${src}" ]]; then
    ensure_dir "${dest}"
    rsync -az "${src}/" "${dest}/"
    return 0
  fi
  if [[ -e "${src}" ]]; then
    ensure_dir "${dest}"
    rsync -az "${src}" "${dest}/"
    return 0
  fi
  log "warning: path not found for collection: ${src}"
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
if search_dir.is_dir():
    matches = sorted(search_dir.glob(pattern))
    if matches:
        print(matches[0])
PY
}

if [[ -n "${DETECTED_EXPORT_DIR}" ]]; then
  REMOTE_EXPORT_DIR="${DETECTED_EXPORT_DIR}"
fi
copy_local_path "${REMOTE_EXPORT_DIR}" "${RUN_DIR}/artifacts/export"
if [[ -n "${DETECTED_RELEASE_INPUT_TAR}" ]]; then
  copy_local_path "${DETECTED_RELEASE_INPUT_TAR}" "${RUN_DIR}/artifacts/release-input-src"
fi

local_release_input_archive="$(find_first_file "${RUN_DIR}/artifacts/release-input-src" "*.tar.gz")"
if [[ -z "${local_release_input_archive}" ]]; then
  local_release_input_archive="$(find_first_file "${RUN_DIR}/artifacts/release-input-src" "*.tgz")"
fi
if [[ -n "${local_release_input_archive}" ]]; then
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
  extract_archive_into_dir "${local_bundle_archive}" "${RUN_DIR}/artifacts/bundle"
elif [[ -n "${DETECTED_BUNDLE_DIR}" ]]; then
  copy_local_path "${DETECTED_BUNDLE_DIR}" "${RUN_DIR}/artifacts/bundle"
fi

if [[ -d "${RUN_DIR}/artifacts/release-input" && -d "${RUN_DIR}/artifacts/bundle" ]]; then
  log "validating release-input against bundle"
  python3 "${SCRIPT_DIR}/validate-release-artifacts.py" \
    --release-input-root "${RUN_DIR}/artifacts/release-input" \
    --bundle-root "${RUN_DIR}/artifacts/bundle" \
    --require-workflows \
    --expected-extra-oci-image-refs "${BUILDER_LOCAL_REF}" \
    >"${RUN_DIR}/logs/release-artifact-validation.json"
else
  fail "missing release-input or bundle artifacts for validation under ${RUN_DIR}/artifacts"
fi

remote_release_commit="$(git -C "${REMOTE_CWD}" rev-parse HEAD 2>/dev/null || true)"
BUILD_HOST="local@$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo build-host)"

python3 - "${RUN_DIR}" "${CONFIG_PATH}" "${BUILD_HOST}" "${REMOTE_CWD}" "${RELEASE_VERSION}" \
  "${BOOTSTRAP_CMD}" "${BUILD_CMD}" "${EFFECTIVE_PUBLISH_CMD}" "${remote_release_commit}" \
  "${REMOTE_REPO_SOURCE}" "${EFFECTIVE_REMOTE_REPO_SOURCE}" "${REMOTE_REPO_REF}" <<'PY'
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
    return path.read_text(encoding="utf-8") if path.is_file() else None

def read_json_named(root: Path, name: str):
    if not root.is_dir():
        return None
    matches = sorted(root.rglob(name))
    if not matches:
        return None
    return json.loads(matches[0].read_text(encoding="utf-8"))

export_dir = run_dir / "artifacts" / "export"
release_input = read_json_named(run_dir / "artifacts" / "release-input", "release-input.json")
release_manifest = read_json_named(run_dir / "artifacts" / "bundle", "release-manifest.json")
checksums_text = read_text(export_dir / "sha256sum.txt")
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
                image_digests[key] = {"path": value.get("path"), "digest": digest}

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
    "bootstrapCommand": bootstrap_cmd,
    "buildCommand": build_cmd,
    "publishCommand": publish_cmd,
    "artifactChecksums": artifact_checksums,
    "releaseInputArtifacts": image_digests,
    "bundleEntries": bundle_entries,
    "logs": {
        "bootstrap": str(run_dir / "logs" / "bootstrap.log"),
        "build": str(run_dir / "logs" / "build.log"),
        "publish": str(run_dir / "logs" / "publish.log"),
        "releaseArtifactValidation": str(run_dir / "logs" / "release-artifact-validation.json"),
    },
}
(run_dir / "metadata" / "build-publish.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

log "build/publish metadata written to ${RUN_DIR}/metadata/build-publish.json"
