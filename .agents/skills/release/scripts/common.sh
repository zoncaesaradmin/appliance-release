#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_QUERY="${SCRIPT_DIR}/config_query.py"

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp_utc)" "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "required command not found on PATH: ${cmd}"
}

resolve_secret() {
  local env_name="$1"
  local prompt_text="$2"
  local value="${!env_name:-}"

  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
    return 0
  fi

  if [[ -t 0 ]]; then
    local entered
    read -r -s -p "${prompt_text}: " entered
    printf '\n' >&2
    printf '%s' "${entered}"
    return 0
  fi

  fail "missing secret ${env_name}; export it or run interactively"
}

resolve_env_value() {
  local env_name="$1"
  local label="${2:-environment variable}"
  local value="${!env_name:-}"
  [[ -n "${value}" ]] || fail "missing ${label} ${env_name}; export it before running"
  printf '%s' "${value}"
}

normalize_bool_value() {
  local raw="${1:-}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${raw}" in
    1|true|yes|on)
      printf 'true\n'
      ;;
    0|false|no|off)
      printf 'false\n'
      ;;
    *)
      fail "boolean value must be true or false (got ${1:-<empty>})"
      ;;
  esac
}

ensure_file() {
  local path="$1"
  [[ -f "${path}" ]] || fail "required file not found: ${path}"
}

ensure_dir() {
  local path="$1"
  mkdir -p "${path}"
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

# Fixed product appliance state directory (matches zonctl default and
# scripts/install-release.sh STATE_DIR). Not release config —
# operators override only by editing that product install script after download.
default_appliance_state_dir() {
  printf '%s\n' "/var/lib/zon/state"
}

config_get() {
  local config_path="$1"
  local query="$2"
  python3 "${CONFIG_QUERY}" "${config_path}" "${query}"
}

config_get_optional() {
  local config_path="$1"
  local query="$2"
  if python3 "${CONFIG_QUERY}" "${config_path}" "${query}" >/dev/null 2>&1; then
    python3 "${CONFIG_QUERY}" "${config_path}" "${query}"
  else
    return 1
  fi
}

resolve_config_path() {
  local explicit_path="${1:-}"

  if [[ -n "${explicit_path}" ]]; then
    printf '%s\n' "${explicit_path}"
    return 0
  fi

  local search_dirs=(
    "${PWD}"
  )
  local config_dir=""
  config_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd 2>/dev/null || true)"
  if [[ -n "${config_dir}" ]]; then
    search_dirs+=("${config_dir}")
  fi

  local candidate
  local dir
  for dir in "${search_dirs[@]}"; do
    for candidate in \
      "${dir}/appliance-release.config.yaml" \
      "${dir}/.codex/appliance-release.config.yaml" \
      "${dir}/appliance-release.config.json"; do
      if [[ -f "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done
  done

  return 1
}

require_config_path() {
  local config_path=""
  config_path="$(resolve_config_path "${1:-}" || true)"
  [[ -n "${config_path}" ]] || fail "config not provided; use --config PATH"
  ensure_file "${config_path}"
  printf '%s\n' "${config_path}"
}

default_release_run_dir() {
  printf '%s/.run/appliance-release/%s\n' "${PWD}" "$(date -u +%Y%m%dT%H%M%SZ)"
}

default_release_run_root() {
  printf '%s/.run/appliance-release\n' "${PWD}"
}

# Return the .../.run/appliance-release root for a run dir, or empty if the path
# is not under that fixed layout (refuse to rm -rf arbitrary trees).
appliance_release_run_root_from_run_dir() {
  local run_dir="${1:-}"
  [[ -n "${run_dir}" ]] || return 0
  local resolved
  resolved="$(cd "$(dirname "${run_dir}")" 2>/dev/null && pwd)/$(basename "${run_dir}")" || resolved="${run_dir}"
  case "${resolved}" in
    */.run/appliance-release)
      printf '%s\n' "${resolved}"
      ;;
    */.run/appliance-release/*)
      printf '%s\n' "${resolved%/.run/appliance-release/*}/.run/appliance-release"
      ;;
  esac
}

# Delete prior skill run artifacts under .../.run/appliance-release.
# Optional keep_run_dir is preserved (used when a parent already created this run).
prune_appliance_release_run_root() {
  local root="${1:-}"
  local keep_run_dir="${2:-}"
  local reason="${3:-fresh build}"
  [[ -n "${root}" ]] || return 0
  case "${root}" in
    */.run/appliance-release) ;;
    *)
      fail "refusing to prune unexpected release run root: ${root}"
      ;;
  esac
  if [[ ! -d "${root}" ]]; then
    return 0
  fi
  local keep_resolved=""
  if [[ -n "${keep_run_dir}" && -e "${keep_run_dir}" ]]; then
    keep_resolved="$(cd "${keep_run_dir}" && pwd)"
  fi
  log "pruning prior release run artifacts under ${root} (${reason})"
  local child child_resolved
  shopt -s nullglob
  for child in "${root}"/*; do
    [[ -e "${child}" ]] || continue
    if [[ -n "${keep_resolved}" ]]; then
      child_resolved="$(cd "${child}" && pwd)"
      if [[ "${child_resolved}" == "${keep_resolved}" ]]; then
        continue
      fi
    fi
    rm -rf "${child}"
  done
  shopt -u nullglob
}

ensure_release_run_dirs() {
  local run_dir="$1"
  shift
  ensure_dir "${run_dir}"
  ensure_dir "${run_dir}/logs"
  ensure_dir "${run_dir}/metadata"
  while [[ $# -gt 0 ]]; do
    ensure_dir "${run_dir}/$1"
    shift
  done
}

require_appliance_profile() {
  local config_path="$1"
  local appliance_profile="${2:-}"
  if [[ -z "${appliance_profile}" ]]; then
    appliance_profile="$(config_get_optional "${config_path}" "install.appliance_profile" || true)"
  fi
  # Omit defaults to the built-in base profile (core). Licensing is post-install only.
  if [[ -z "${appliance_profile}" ]]; then
    appliance_profile="core"
  fi
  printf '%s\n' "${appliance_profile}"
}

bool_true() {
  local value="${1:-}"
  local normalized
  normalized="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${normalized}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Read a required boolean config key; print "true" or "false". Fail closed.
config_require_bool() {
  local config_path="$1"
  local query="$2"
  local value=""
  if ! value="$(config_get "${config_path}" "${query}" 2>/dev/null)"; then
    fail "missing required config key: ${query} (must be true or false)"
  fi
  local normalized
  normalized="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${normalized}" in
    1|true|yes|on)
      printf 'true\n'
      ;;
    0|false|no|off)
      printf 'false\n'
      ;;
    *)
      fail "${query} must be a boolean (true/false), got: ${value}"
      ;;
  esac
}

profile_supports_builder() {
  case "${1:-}" in
    builder|builder-landns|builder-storage-landns) return 0 ;;
    *) return 1 ;;
  esac
}

profile_supports_artifacts() {
  case "${1:-}" in
    storage|builder|storage-landns|builder-landns|builder-storage-landns) return 0 ;;
    *) return 1 ;;
  esac
}

profile_supports_workflows() {
  case "${1:-}" in
    core|builder|builder-landns|builder-storage-landns) return 0 ;;
    *) return 1 ;;
  esac
}

csv_items_trimmed() {
  local input="${1:-}"
  local item=""
  local csv_items=()
  [[ -n "${input}" ]] || return 0
  IFS=',' read -r -a csv_items <<<"${input}"
  for item in "${csv_items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "${item}" ]] && printf '%s\n' "${item}"
  done
}

require_profile_supports_workflows() {
  local enabled_value="${1:-}"
  local profile="${2:-}"
  local setting_name="${3:-verification.workflows.enabled}"
  if bool_true "${enabled_value}" && ! profile_supports_workflows "${profile}"; then
    fail "${setting_name}=true but install.appliance_profile=${profile} does not enable workflows; set ${setting_name}=false in config"
  fi
}

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

append_env_assignments() {
  local current="$1"
  local name=""
  local value=""
  shift
  if (( $# % 2 != 0 )); then
    fail "append_env_assignments requires NAME VALUE pairs"
  fi
  while [[ $# -gt 0 ]]; do
    name="$1"
    value="$2"
    current="$(append_env_assignment "${current}" "${name}" "${value}")"
    shift 2
  done
  printf '%s' "${current}"
}

inject_env_path_after_sudo() {
  local command="${1:-}"
  local env_path="${2:-}"
  if [[ -z "${env_path}" ]]; then
    printf '%s\n' "${command}"
    return 0
  fi
  printf '%s\n' "${command//sudo /sudo env PATH=${env_path} }"
}

run_ssh_logged() {
  local host="$1"
  local log_file="$2"
  local remote_command="$3"
  local quoted_remote_command=""
  local cmd_status=0

  ensure_dir "$(dirname "${log_file}")"
  quoted_remote_command="$(shell_quote "${remote_command}")"
  set +e
  # Non-interactive login shell: sources ~/.bash_profile or ~/.profile (not the
  # interactive-only half of ~/.bashrc). Operators should export DEV_* and
  # APPLIANCE_* there.
  #
  # Use -tt so the remote has a real TTY. That is required for the long-standing
  # build-host path: wrap_remote_cmd_with_sudo does `sudo -S -v` and later plain
  # `sudo` / `sudo -n` rely on a TTY-bound credential cache. Switching this to
  # -T broke that (password prompts, false "host bootstrap missing").
  #
  # Redirect local stdin from /dev/null so ssh does not wait on the Mac TTY after
  # short commands finish (that hung install post-stages: bootstrap admin/license).
  ssh -tt "${host}" "env -u BASH_ENV bash -lc ${quoted_remote_command}" </dev/null 2>&1 \
    | python3 -c 'import sys; [sys.stdout.write(line) for line in sys.stdin if not line.startswith("Connection to ") or " closed." not in line]' \
    | tee "${log_file}"
  # Capture status before any other command overwrites PIPESTATUS (incl. `local`).
  cmd_status=${PIPESTATUS[0]}
  # Do not re-enable set -e here: a non-zero return would exit the *caller*
  # under set -e before it can capture $? (e.g. bootstrap "already initialized").
  return "${cmd_status}"
}

run_ssh_captured() {
  local host="$1"
  local log_file="$2"
  local remote_command="$3"
  local quoted_remote_command=""
  local cmd_status=0
  # Optional hard cap (seconds). Default 0 = no extra timeout beyond OpenSSH.
  # Used for short post-install kubectl stages so a stuck attach cannot stall e2e forever.
  local timeout_sec="${RUN_SSH_CAPTURED_TIMEOUT_SEC:-0}"

  ensure_dir "$(dirname "${log_file}")"
  quoted_remote_command="$(shell_quote "${remote_command}")"
  set +e
  if [[ "${timeout_sec}" =~ ^[1-9][0-9]*$ ]]; then
    # portable timeout (macOS has no GNU timeout by default)
    python3 - "${timeout_sec}" "${host}" "${log_file}" "env -u BASH_ENV bash -lc ${quoted_remote_command}" <<'PY'
import subprocess
import sys

timeout_sec = int(sys.argv[1])
host = sys.argv[2]
log_file = sys.argv[3]
remote = sys.argv[4]
with open(log_file, "wb") as handle:
    try:
        completed = subprocess.run(
            [
                "ssh",
                "-q",
                "-T",
                "-o",
                "BatchMode=yes",
                "-o",
                "ServerAliveInterval=15",
                "-o",
                "ServerAliveCountMax=4",
                host,
                remote,
            ],
            stdout=handle,
            stderr=subprocess.STDOUT,
            timeout=timeout_sec,
        )
    except subprocess.TimeoutExpired:
        handle.write(
            f"\nrun_ssh_captured: timed out after {timeout_sec}s\n".encode()
        )
        sys.exit(124)
    sys.exit(completed.returncode)
PY
    cmd_status=$?
  else
    ssh -q -T \
      -o BatchMode=yes \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=4 \
      "${host}" "env -u BASH_ENV bash -lc ${quoted_remote_command}" >"${log_file}" 2>&1
    cmd_status=$?
  fi
  # Leave set -e off (see run_ssh_logged). Caller decides whether non-zero is fatal.
  return "${cmd_status}"
}

# Build a bash fragment that exports the given env var names from *this* process
# (devhost). Fails if any name is missing or empty. Values are shell-quoted.
# Example result:  DEV_REGISTRY='…' export DEV_REGISTRY; …
render_export_assignments_from_current_env() {
  local name value fragment=""
  for name in "$@"; do
    [[ -n "${name}" ]] || continue
    value="${!name:-}"
    [[ -n "${value}" ]] || fail "missing env ${name} on the devhost; export it before run-release-from-devhost.sh"
    fragment+="${name}=$(shell_quote "${value}") export ${name}; "
  done
  printf '%s' "${fragment}"
}

# Product-fixed control-plane identity (not operator install YAML).
# Namespace:  appliance-ctl cmd/zonctl/main.go defaultChartNamespace = "control"
# Deployment: appliance-code deploy/charts/appliance-control-plane:
#   templates/_helpers.tpl nameOverride|default "api-server"
#   chart_test.go controlPlaneDeploymentName
#   selectorLabels app.kubernetes.io/name (same basename)
# zonctl install/upgrade always use defaultChartNamespace; bootstrap scripts
# must match so kubectl exec targets the product workload, not skill invention.
PRODUCT_CONTROL_PLANE_NAMESPACE="control"
PRODUCT_CONTROL_PLANE_DEPLOYMENT="api-server"

reject_removed_install_control_plane_identity_keys() {
  local config_path="$1"
  local removed=()
  if [[ -n "$(config_get_optional "${config_path}" "install.kubernetes_namespace" || true)" ]]; then
    removed+=("install.kubernetes_namespace")
  fi
  if [[ -n "$(config_get_optional "${config_path}" "install.control_plane_deployment" || true)" ]]; then
    removed+=("install.control_plane_deployment")
  fi
  if ((${#removed[@]} > 0)); then
    fail "removed install identity keys: ${removed[*]}. Control-plane namespace is product-fixed (${PRODUCT_CONTROL_PLANE_NAMESPACE}; zonctl defaultChartNamespace) and deployment is product-fixed (${PRODUCT_CONTROL_PLANE_DEPLOYMENT}; chart appliance-control-plane fullname). Remove them from install config."
  fi
}

# Hard-cut rename: verification.argo.* → verification.workflows.*
reject_removed_verification_argo_keys() {
  local config_path="$1"
  if [[ -n "$(config_get_optional "${config_path}" "verification.argo.enabled" || true)" \
    || -n "$(config_get_optional "${config_path}" "verification.argo.namespaces_command" || true)" \
    || -n "$(config_get_optional "${config_path}" "verification.argo.crds_command" || true)" \
    || -n "$(config_get_optional "${config_path}" "verification.argo.controller_command" || true)" ]]; then
    fail "verification.argo.* was renamed to verification.workflows.* (Argo → generic workflows). Rename verification.argo to verification.workflows in the install config (see .agents/skills/release/references/config.install.example.yaml)."
  fi
}

# Literal install.image_pull_registry.registry was removed; host comes from registry_env.
reject_removed_install_image_pull_literal_registry() {
  local config_path="$1"
  if [[ -n "$(config_get_optional "${config_path}" "install.image_pull_registry.registry" || true)" ]]; then
    fail "install.image_pull_registry.registry was removed; use install.image_pull_registry.registry_env (for example DEV_REGISTRY)"
  fi
}

# Optional K3s image-pull registry for public-helper install.
# Sets globals (empty IMAGE_PULL_REGISTRY = disabled / preload-only):
#   IMAGE_PULL_REGISTRY, IMAGE_PULL_USERNAME_ENV, IMAGE_PULL_TOKEN_ENV,
#   IMAGE_PULL_TLS_VERIFY_ENV, IMAGE_PULL_USERNAME, IMAGE_PULL_TOKEN,
#   IMAGE_PULL_TLS_VERIFY, IMAGE_PULL_PRESERVE_ENV
resolve_install_image_pull_registry() {
  local config_path="$1"
  local registry_env=""
  local username_env=""
  local token_env=""
  local tls_verify_env=""

  reject_removed_install_image_pull_literal_registry "${config_path}"

  IMAGE_PULL_REGISTRY=""
  IMAGE_PULL_USERNAME_ENV=""
  IMAGE_PULL_TOKEN_ENV=""
  IMAGE_PULL_TLS_VERIFY_ENV=""
  IMAGE_PULL_USERNAME=""
  IMAGE_PULL_TOKEN=""
  IMAGE_PULL_TLS_VERIFY=""
  IMAGE_PULL_PRESERVE_ENV=""

  registry_env="$(config_get_optional "${config_path}" "install.image_pull_registry.registry_env" || true)"
  username_env="$(config_get_optional "${config_path}" "install.image_pull_registry.username_env" || true)"
  token_env="$(config_get_optional "${config_path}" "install.image_pull_registry.token_env" || true)"
  tls_verify_env="$(config_get_optional "${config_path}" "install.image_pull_registry.tls_verify_env" || true)"
  registry_env="$(printf '%s' "${registry_env}" | tr -d '[:space:]')"
  username_env="$(printf '%s' "${username_env}" | tr -d '[:space:]')"
  token_env="$(printf '%s' "${token_env}" | tr -d '[:space:]')"
  tls_verify_env="$(printf '%s' "${tls_verify_env}" | tr -d '[:space:]')"

  if [[ -z "${registry_env}" ]]; then
    if [[ -n "${username_env}" || -n "${token_env}" || -n "${tls_verify_env}" ]]; then
      fail "install.image_pull_registry.registry_env is required when username_env/token_env/tls_verify_env are set"
    fi
    return 0
  fi

  [[ -n "${username_env}" ]] || fail "install.image_pull_registry.username_env is required when registry_env is set"
  [[ -n "${token_env}" ]] || fail "install.image_pull_registry.token_env is required when registry_env is set"

  IMAGE_PULL_REGISTRY="$(resolve_env_value "${registry_env}" "Image pull registry env")"
  IMAGE_PULL_USERNAME="$(resolve_env_value "${username_env}" "Image pull registry username env")"
  IMAGE_PULL_TOKEN="$(resolve_secret "${token_env}" "Image pull registry token env")"
  IMAGE_PULL_USERNAME_ENV="${username_env}"
  IMAGE_PULL_TOKEN_ENV="${token_env}"
  IMAGE_PULL_PRESERVE_ENV="${username_env},${token_env}"
  if [[ -n "${tls_verify_env}" ]]; then
    IMAGE_PULL_TLS_VERIFY="$(resolve_env_value "${tls_verify_env}" "Image pull registry TLS verify env")"
    IMAGE_PULL_TLS_VERIFY_ENV="${tls_verify_env}"
    IMAGE_PULL_PRESERVE_ENV="${IMAGE_PULL_PRESERVE_ENV},${tls_verify_env}"
  fi
}

# Space-separated EXTRA_TLS_SANS from install.additional_tls_sans_csv (empty OK).
resolve_install_extra_tls_sans() {
  local config_path="$1"
  local csv=""
  local -a items=()
  local item=""
  EXTRA_TLS_SANS=""
  csv="$(config_get_optional "${config_path}" "install.additional_tls_sans_csv" || true)"
  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    items+=("${item}")
  done < <(csv_items_trimmed "${csv}")
  if ((${#items[@]} > 0)); then
    EXTRA_TLS_SANS="${items[*]}"
  fi
}

product_control_plane_namespace() {
  printf '%s\n' "${PRODUCT_CONTROL_PLANE_NAMESPACE}"
}

product_control_plane_deployment() {
  printf '%s\n' "${PRODUCT_CONTROL_PLANE_DEPLOYMENT}"
}

# Env names referenced by a build-publish config (mode + image pull + bundle_store).
# Deduped. Always includes APPLIANCE_BUILD_SUDO_PASSWORD.
# Skill-fixed layout under release_workspace.remote_build_root (build host only).
SKILL_REMOTE_BUILD_ROOT_CHECKOUT_SUBDIR="release"
SKILL_REMOTE_BUILD_ROOT_EXPORT_SUBDIR="export"

skill_remote_build_root_layout_message() {
  cat <<'EOF'
Skill-fixed layout under release_workspace.remote_build_root:
  release/ — appliance-release git checkout (REMOTE_CWD)
  export/ — bundle export output ($RELEASE_WORK_ROOT/export)
  inputs/ — local staging for scripts/fetch-k3s-inputs.sh
Packaging mode (build_flow.mode) selects which pull block to read:
  online  — online_image_pull (ONLINE_*) → unified to DEV_* for packaging
  offline — offline_image_pull (DEV_* LAN; same as publish — no OFFLINE_* family)
After that mapping, bootstrap/build use only DEV_* + OFFLINE_BUILD.
Publish uses bundle_store (also DEV_*) for publish-release.sh.
EOF
}

# Normalize build_flow.mode → online|offline (fail closed).
resolve_build_flow_mode() {
  local config_path="$1"
  local mode=""
  mode="$(config_get_optional "${config_path}" "build_flow.mode" || true)"
  mode="$(printf '%s' "${mode}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    online|offline)
      printf '%s\n' "${mode}"
      ;;
    "")
      fail "build_flow.mode is required (online|offline). Exactly one packaging source policy — no mix of LAN and public pulls."
      ;;
    *)
      fail "build_flow.mode must be online or offline (got: ${mode:-empty})"
      ;;
  esac
}

# Resolve pack selection for product scripts.
# Config: build_flow.appliance_packs (literal value, like build_flow.mode).
# Empty/omitted → all. Skill exports APPLIANCE_PACKS into product scripts.
resolve_appliance_packs_from_config() {
  local config_path="$1"
  local value=""
  value="$(config_get_optional "${config_path}" "build_flow.appliance_packs" || true)"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ -z "${value}" ]]; then
    value="all"
  fi
  printf '%s' "${value}"
}

# Repo-owned default product version (configs/default-product-version).
# PRODUCT_VERSION / release.version may override it.
read_default_product_version() {
  local repo_root="$1"
  local version_file="${repo_root}/configs/default-product-version"
  local version=""
  [[ -f "${version_file}" ]] || fail "missing ${version_file}"
  version="$(tr -d '[:space:]' < "${version_file}")"
  [[ -n "${version}" ]] || fail "empty product version in ${version_file}"
  printf '%s\n' "${version}"
}

join_remote_build_root_path() {
  local root="$1"
  local subpath="$2"
  root="${root%/}"
  printf '%s/%s\n' "${root}" "${subpath}"
}

reject_removed_build_publish_path_keys() {
  local config_path="$1"
  local removed=()
  if [[ -n "$(config_get_optional "${config_path}" "release_workspace.remote_repo_path" || true)" ]]; then
    removed+=("release_workspace.remote_repo_path")
  fi
  if [[ -n "$(config_get_optional "${config_path}" "release_workspace.remote_export_dir" || true)" ]]; then
    removed+=("release_workspace.remote_export_dir")
  fi
  if ((${#removed[@]} > 0)); then
    fail "removed build-publish path keys: ${removed[*]}. Set release_workspace.remote_build_root only. $(skill_remote_build_root_layout_message)"
  fi
}

# Fail closed on knobs the skill no longer forwards. Product scripts own
# workflows engine/Artifact Server/DNS/provisioner defaults; install-role owns verification.*.
reject_removed_build_publish_packaging_keys() {
  local config_path="$1"

  if [[ -n "$(config_get_optional "${config_path}" "build_flow.bootstrap_command" || true)" ]]; then
    fail "build_flow.bootstrap_command was removed; skill always runs: bash scripts/bootstrap-build-host.sh"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.build_command" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.publish_command" || true)" ]]; then
    fail "build_flow.build_command and build_flow.publish_command were removed; skill always runs: bash scripts/build-full-bundle.sh then bash scripts/publish-release.sh"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.bootstrap_needs_sudo" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.build_needs_sudo" || true)" ]]; then
    fail "build_flow.bootstrap_needs_sudo and build_flow.build_needs_sudo were removed; skill always wraps bootstrap/build with sudo (APPLIANCE_BUILD_SUDO_PASSWORD)"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "release_workspace.remote_release_input_path" || true)" \
    || -n "$(config_get_optional "${config_path}" "release_workspace.remote_bundle_dir" || true)" ]]; then
    fail "release_workspace.remote_release_input_path and remote_bundle_dir were removed; build-and-publish now auto-detects release-input and bundle paths from the build log"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.dev_container_image_registry.pull_ref" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_container_image_registry.registry_user_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_container_image_registry.registry_token_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_container_image_registry.tls_insecure" || true)" ]]; then
    fail "build_flow.dev_container_image_registry.* was removed; use build_flow.mode plus online_image_pull or offline_image_pull"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.registry_user_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.registry_token_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.registry_user" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.registry_token" || true)" ]]; then
    fail "legacy build_flow.registry_* keys are no longer supported; use build_flow.mode plus online_image_pull or offline_image_pull"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.registry_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.image_repo_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.image_name_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.image_tag" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.username_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.token_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.tls_verify_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.image_repo" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dev_image_pull.image_name" || true)" ]]; then
    fail "build_flow.dev_image_pull.* was removed; set build_flow.mode (online|offline) and use online_image_pull / offline_image_pull (skill unifies to DEV_* for packaging)"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.online_image_pull.image_tag" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.offline_image_pull.image_tag" || true)" ]]; then
    fail "build_flow.*.image_tag literal was removed; use image_tag_env (ONLINE_IMAGE_TAG or DEV_IMAGE_TAG)"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.host_packages_dir_source" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.argo.crds_dir_source" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.argo.controller_image_archive_source" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.argo.executor_image_archive_source" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.workspace_provisioner_image_archive_source" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.zot.image_archive_source" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dns.image_archive_source" || true)" ]]; then
    fail "offline/local archive path inputs under build_flow were removed; package always pulls from the network. Remove host_packages_dir_source, legacy build_flow.argo.* archive/crds sources, and zot/dns/workspace_provisioner image_archive_source keys"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.product_publish.registry" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.product_publish.image_repo" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.product_publish.image_repo_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.product_publish.image_name" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.product_publish.image_name_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.product_publish.image_tag" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.product_publish.username_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.product_publish.token_env" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.product_publish.tls_verify_env" || true)" ]]; then
    fail "build_flow.product_publish.* was removed (destination fields were unused). Publish uses bundle_store / DEV_* (LAN Artifact Server); remove the product_publish block from config"
  fi
  # Packaging pins / install-role keys must not appear on build-publish YAML.
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.argo.enabled" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.argo.required" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.argo.version" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.argo.controller_image_ref" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.argo.executor_image_ref" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.workspace_provisioner_image_ref" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.zot.version" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.zot.image_pull_ref" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dns.version" || true)" \
    || -n "$(config_get_optional "${config_path}" "build_flow.dns.image_pull_ref" || true)" ]]; then
    fail "build_flow workflows engine/Zot/DNS/provisioner pin keys were removed from build-publish config; product scripts/build-full-bundle.sh owns those defaults"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "build_flow.appliance_packs_env" || true)" ]]; then
    fail "build_flow.appliance_packs_env was removed; set build_flow.appliance_packs to a literal value (all|foundation|foundation,developer|foundation,inference)"
  fi
  if [[ -n "$(config_get_optional "${config_path}" "verification.workflows.enabled" || true)" \
    || -n "$(config_get_optional "${config_path}" "install.appliance_profile" || true)" ]]; then
    fail "verification.* and install.* belong on the install-role config, not build-publish"
  fi
}

resolve_build_publish_remote_build_root() {
  local config_path="$1"
  local root=""
  reject_removed_build_publish_path_keys "${config_path}"
  root="$(config_get "${config_path}" "release_workspace.remote_build_root")"
  [[ -n "${root}" ]] || fail "release_workspace.remote_build_root is required in config. $(skill_remote_build_root_layout_message)"
  printf '%s\n' "${root}"
}

derive_remote_repo_path_from_build_root() {
  join_remote_build_root_path "$1" "${SKILL_REMOTE_BUILD_ROOT_CHECKOUT_SUBDIR}"
}

derive_remote_export_dir_from_build_root() {
  join_remote_build_root_path "$1" "${SKILL_REMOTE_BUILD_ROOT_EXPORT_SUBDIR}"
}

collect_build_publish_env_names() {
  local config_path="$1"
  local names=()
  local key candidate seen="|" n
  local mode=""
  mode="$(resolve_build_flow_mode "${config_path}")"

  # Collect *_env names from the active pull block + bundle_store (no hardcoded family).
  if [[ "${mode}" == "online" ]]; then
    for key in \
      "build_flow.online_image_pull.registry_env" \
      "build_flow.online_image_pull.image_repo_env" \
      "build_flow.online_image_pull.image_name_env" \
      "build_flow.online_image_pull.image_tag_env" \
      "build_flow.online_image_pull.username_env" \
      "build_flow.online_image_pull.token_env" \
      "build_flow.online_image_pull.tls_verify_env"
    do
      candidate="$(config_get_optional "${config_path}" "${key}" || true)"
      if [[ -n "${candidate}" ]]; then
        names+=("${candidate}")
      fi
    done
  else
    for key in \
      "build_flow.offline_image_pull.registry_env" \
      "build_flow.offline_image_pull.image_repo_env" \
      "build_flow.offline_image_pull.image_name_env" \
      "build_flow.offline_image_pull.image_tag_env" \
      "build_flow.offline_image_pull.username_env" \
      "build_flow.offline_image_pull.token_env" \
      "build_flow.offline_image_pull.tls_verify_env"
    do
      candidate="$(config_get_optional "${config_path}" "${key}" || true)"
      if [[ -n "${candidate}" ]]; then
        names+=("${candidate}")
      fi
    done
  fi

  for key in \
    "bundle_store.registry_env" \
    "bundle_store.username_env" \
    "bundle_store.token_env" \
    "bundle_store.tls_verify_env"
  do
    candidate="$(config_get_optional "${config_path}" "${key}" || true)"
    if [[ -n "${candidate}" ]]; then
      names+=("${candidate}")
    fi
  done

  # Bootstrap/build always use sudo on the build host.
  names+=("APPLIANCE_BUILD_SUDO_PASSWORD")
  for n in "${names[@]}"; do
    case "${seen}" in
      *"|${n}|"*) continue ;;
    esac
    seen+="${n}|"
    printf '%s\n' "${n}"
  done
}

# Run a command on this host, teeing stdout/stderr into log_file.
run_local_logged() {
  local log_file="$1"
  local command="$2"

  ensure_dir "$(dirname "${log_file}")"
  set +e
  bash -c "${command}" 2>&1 | tee "${log_file}"
  local cmd_status="${PIPESTATUS[0]}"
  set -e
  return "${cmd_status}"
}

skill_release_repo_root() {
  local script_dir="$1"
  (cd "${script_dir}/../../../.." && pwd)
}

resolve_local_git_origin() {
  local repo_root="$1"
  if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${repo_root}" remote get-url origin 2>/dev/null || true
  fi
}

normalize_readonly_git_source() {
  local source="${1:-}"
  case "${source}" in
    git@github.com:*)
      printf 'https://github.com/%s\n' "${source#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      printf 'https://github.com/%s\n' "${source#ssh://git@github.com/}"
      ;;
    ssh://git@github.com:22/*)
      printf 'https://github.com/%s\n' "${source#ssh://git@github.com:22/}"
      ;;
    *)
      printf '%s\n' "${source}"
      ;;
  esac
}

default_local_sibling_repo_dir() {
  local release_repo_root="$1"
  local repo_name="$2"
  printf '%s/%s\n' "$(cd "${release_repo_root}/.." && pwd)" "${repo_name}"
}

# Returns 0 when a dirty path could change what the remote live build/install
# clones from git (bundle scripts, configs, product code, Makefiles, etc.).
# Docs, Cursor rules, run artifacts, and the locally executed skill scripts
# return 1: those either do not ship into the remote build, or (for
# .agents/skills/*/scripts) already run from this working tree by design.
live_release_path_affects_remote_build() {
  local path="${1#./}"
  path="${path//\"/}"
  case "${path}" in
    .agents/skills/*/scripts/*|.agents/skills/*/references/*|.agents/skills/*/SKILL.md)
      return 1
      ;;
    docs/*|.cursor/*|.run/*)
      return 1
      ;;
    scripts/*|configs/*|cmd/*|internal/*|pkg/*|schemas/*|deploy/*|services/*|tests/*|test/*)
      return 0
      ;;
    Makefile|makefile|go.mod|go.sum|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock)
      return 0
      ;;
    *.go|*.sh|*.py|*.mk)
      return 0
      ;;
    Dockerfile|Dockerfile.*|*.dockerfile)
      return 0
      ;;
  esac
  return 1
}

assert_local_repo_clean_for_remote_ref() {
  local repo_path="$1"
  local label="$2"
  local remote_ref="${3:-main}"

  if [[ ! -d "${repo_path}" ]]; then
    log "live release preflight: ${label} not found at ${repo_path}; skipping local repo guard"
    return 0
  fi
  if ! git -C "${repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "live release preflight: ${label} at ${repo_path} is not a git checkout; skipping local repo guard"
    return 0
  fi

  local head branch short_head status_lines remote_tracking ahead_count
  local allow_dirty build_affecting_dirty=() local_only_dirty=()
  head="$(git -C "${repo_path}" rev-parse HEAD 2>/dev/null || true)"
  short_head="${head:0:12}"
  branch="$(git -C "${repo_path}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  status_lines="$(git -C "${repo_path}" status --short 2>/dev/null || true)"
  allow_dirty="$(printf '%s' "${APPLIANCE_RELEASE_ALLOW_DIRTY:-}" | tr '[:upper:]' '[:lower:]')"

  if [[ -n "${status_lines}" ]]; then
    if [[ "${allow_dirty}" == "1" || "${allow_dirty}" == "true" || "${allow_dirty}" == "yes" ]]; then
      log "live release preflight: ${label} has uncommitted changes; continuing because APPLIANCE_RELEASE_ALLOW_DIRTY=${APPLIANCE_RELEASE_ALLOW_DIRTY} (remote build still clones ${remote_ref} and ignores local edits)"
    else
      local line path
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        path="${line:3}"
        if [[ "${path}" == *" -> "* ]]; then
          path="${path##* -> }"
        fi
        path="${path#\"}"
        path="${path%\"}"
        if live_release_path_affects_remote_build "${path}"; then
          build_affecting_dirty+=("${path}")
        else
          local_only_dirty+=("${path}")
        fi
      done <<< "${status_lines}"

      if ((${#build_affecting_dirty[@]} > 0)); then
        fail "live release preflight: ${label} at ${repo_path} has uncommitted build-affecting changes (branch ${branch:-detached}, HEAD ${short_head:-unknown}); the remote build clones ${remote_ref} and will ignore local edits. Dirty paths: ${build_affecting_dirty[*]}. Commit/push or stash these, or set APPLIANCE_RELEASE_ALLOW_DIRTY=1 to override."
      fi
      if ((${#local_only_dirty[@]} > 0)); then
        log "live release preflight: ${label} has local-only uncommitted changes that do not affect the remote ${remote_ref} build (e.g. docs/.cursor/.run); continuing. Paths: ${local_only_dirty[*]}"
      fi
    fi
  fi

  remote_tracking="origin/${remote_ref}"
  if ! git -C "${repo_path}" rev-parse --verify --quiet "${remote_tracking}^{commit}" >/dev/null 2>&1; then
    log "live release preflight: ${label} has no local ${remote_tracking} ref; skipping ahead-of-remote check"
    return 0
  fi

  ahead_count="$(git -C "${repo_path}" rev-list --count "${remote_tracking}..HEAD" 2>/dev/null || true)"
  if [[ -z "${ahead_count}" || "${ahead_count}" == "0" ]]; then
    return 0
  fi

  fail "live release preflight: ${label} at ${repo_path} is ahead of ${remote_tracking} by ${ahead_count} commit(s) (branch ${branch:-detached}, HEAD ${short_head:-unknown}); the remote build uses ${remote_tracking}, so those local commits will not be included. Push them before rerunning the live release flow."
}

preflight_live_release_inputs() {
  local release_repo_root="$1"
  local release_ref="${2:-main}"
  local code_ref="${3:-main}"
  local ctl_ref="${4:-main}"
  local code_repo_dir="${APPLIANCE_CODE_DIR:-$(default_local_sibling_repo_dir "${release_repo_root}" appliance-code)}"
  local ctl_repo_dir="${APPLIANCE_CTL_DIR:-$(default_local_sibling_repo_dir "${release_repo_root}" appliance-ctl)}"

  assert_local_repo_clean_for_remote_ref "${release_repo_root}" "appliance-release" "${release_ref}"
  assert_local_repo_clean_for_remote_ref "${code_repo_dir}" "appliance-code" "${code_ref}"
  assert_local_repo_clean_for_remote_ref "${ctl_repo_dir}" "appliance-ctl" "${ctl_ref}"
}

# Fail closed when client_verification.base_url is still the example placeholder
# (or similarly unusable). A set-but-wrong URL rewrites working target-local
# https://127.0.0.1 smoke checks into curl failures against a fake hostname.
reject_placeholder_client_base_url() {
  local base_url="$1"
  local source_label="${2:-client_verification.base_url}"
  base_url="$(printf '%s' "${base_url}" | tr '[:upper:]' '[:lower:]')"
  case "${base_url}" in
    ""|https://127.0.0.1|http://127.0.0.1|https://localhost|http://localhost)
      return 0
      ;;
    *target-ip-or-dns*|*example.invalid*|*example.com*|*replace-me*|*changeme*)
      fail "${source_label} is still an example placeholder (${1}); set it to the real appliance URL (for example https://192.168.1.103 or https://name.appliance.internal with target_host IP for --resolve), or omit it so target-side smoke checks keep using https://127.0.0.1"
      ;;
  esac
  return 0
}

# Extract IPv4 from SSH targets like "user@192.168.1.151" or bare IPs.
# Returns 1 when the alias is a hostname without a literal IPv4 (e.g. ssh config Host).
ssh_target_ipv4() {
  local alias="$1"
  local host=""
  alias="$(printf '%s' "${alias}" | tr -d '[:space:]')"
  [[ -n "${alias}" ]] || return 1
  host="${alias##*@}"
  if [[ "${host}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "${host}"
    return 0
  fi
  return 1
}

# Print host and port for a URL (default ports 443/80). Used for curl --resolve.
client_url_host_port() {
  local base_url="$1"
  python3 - "${base_url}" <<'PY'
import sys
from urllib.parse import urlparse

raw = sys.argv[1].strip()
parsed = urlparse(raw if "://" in raw else f"https://{raw}")
host = parsed.hostname or ""
if not host:
    raise SystemExit(f"client URL has no host: {raw!r}")
if parsed.port:
    port = parsed.port
elif (parsed.scheme or "https").lower() == "http":
    port = 80
else:
    port = 443
print(f"{host}\n{port}")
PY
}

# True when the name is a literal IPv4.
is_ipv4_literal() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# Map FQDN client URLs to a connect IP for Mac-side curls/python when the
# landns name is not in the Mac's global resolver (normal lab case).
# Sets CLIENT_CURL_EXTRA (array of curl args) and CLIENT_CONNECT_IP / HOST / PORT.
CLIENT_CURL_EXTRA=()
CLIENT_CONNECT_IP=""
CLIENT_RESOLVE_HOST=""
CLIENT_RESOLVE_PORT=""
setup_client_connect_resolve() {
  local base_url="$1"
  local connect_ip="${2:-}"
  local host=""
  local port=""
  local hp=""

  CLIENT_CURL_EXTRA=()
  CLIENT_CONNECT_IP=""
  CLIENT_RESOLVE_HOST=""
  CLIENT_RESOLVE_PORT=""

  hp="$(client_url_host_port "${base_url}")"
  host="$(printf '%s\n' "${hp}" | sed -n '1p')"
  port="$(printf '%s\n' "${hp}" | sed -n '2p')"
  CLIENT_RESOLVE_HOST="${host}"
  CLIENT_RESOLVE_PORT="${port}"

  if is_ipv4_literal "${host}"; then
    CLIENT_CONNECT_IP="${host}"
    return 0
  fi

  connect_ip="$(printf '%s' "${connect_ip}" | tr -d '[:space:]')"
  if [[ -z "${connect_ip}" ]]; then
    # Try OS resolver first (operator already pointed DNS at landns).
    if getent hosts "${host}" >/dev/null 2>&1 \
      || host "${host}" >/dev/null 2>&1 \
      || dig +short "${host}" A 2>/dev/null | grep -Eq '^[0-9.]+$'; then
      return 0
    fi
    fail "client_verification base URL host ${host} does not resolve on this machine. For landns profiles the Mac usually is not using the appliance as DNS. Pass --connect-ip <target-ip> (or use run-release-from-devhost with target_host.alias user@IP), or set client_verification.connect_ip. Optionally point Mac DNS at the appliance landns."
  fi
  if ! is_ipv4_literal "${connect_ip}"; then
    fail "client connect IP must be an IPv4 address (got: ${connect_ip})"
  fi
  CLIENT_CONNECT_IP="${connect_ip}"
  CLIENT_CURL_EXTRA=(--resolve "${host}:${port}:${connect_ip}")
  # Also map default https when base_url used a non-default port for odd tests.
  if [[ "${port}" != "443" ]]; then
    CLIENT_CURL_EXTRA+=(--resolve "${host}:443:${connect_ip}")
  fi
  if [[ "${port}" != "80" ]]; then
    CLIENT_CURL_EXTRA+=(--resolve "${host}:80:${connect_ip}")
  fi
}

derive_client_base_url_from_install() {
  local install_config="$1"
  local name=""
  local zone=""
  name="$(config_get_optional "${install_config}" "install.appliance_name" || true)"
  zone="$(config_get_optional "${install_config}" "install.dns_zone" || true)"
  name="$(printf '%s' "${name}" | tr -d '[:space:]')"
  zone="$(printf '%s' "${zone}" | tr -d '[:space:]')"
  if [[ -n "${name}" && -n "${zone}" ]]; then
    printf 'https://%s.%s\n' "${name}" "${zone}"
    return 0
  fi
  return 1
}

derive_mdns_tls_san_from_hostname() {
  local raw_hostname="${1:-}"
  local short_hostname=""
  if [[ -z "${raw_hostname}" ]]; then
    return 1
  fi
  short_hostname="${raw_hostname%%.*}"
  short_hostname="$(printf '%s' "${short_hostname}" | tr '[:upper:]' '[:lower:]')"
  if [[ ! "${short_hostname}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    return 1
  fi
  printf '%s.local\n' "${short_hostname}"
}

# Rewrite https?://<any-host><path> → <client_base><path> inside a shell command.
# Used so verification curls follow client_verification.base_url instead of a
# stale hardcoded target IP left in config.
rewrite_command_url_path_to_base() {
  local command="$1"
  local client_base="$2"
  local api_path="$3"
  python3 - "${command}" "${client_base}" "${api_path}" <<'PY'
import re
import sys

command = sys.argv[1]
client_base = sys.argv[2].rstrip("/")
api_path = sys.argv[3]
if not api_path.startswith("/"):
    api_path = "/" + api_path
pattern = re.compile(r"https?://[^/\s'\"\\]+" + re.escape(api_path))
replacement = client_base + api_path
print(pattern.sub(replacement, command), end="")
PY
}

expand_legacy_ui_home_command_for_spa() {
  local command="$1"
  local legacy_markers="Zon Appliance|Sign in to continue|Appliance status|Create first administrator"
  local spa_markers="Appliance Control Plane UI|appliance-controlplane-ui|/src/main.tsx|/assets/index-"
  if [[ "${command}" == *"${legacy_markers}"* ]]; then
    command="${command//${legacy_markers}/${legacy_markers}|${spa_markers}}"
  fi
  printf '%s' "${command}"
}


# Normalize / accept only appliance_files. Empty → appliance_files.
# static_http and other modes are rejected.
normalize_bundle_store_mode() {
  local mode
  mode="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    ""|appliance_files)
      printf 'appliance_files\n'
      ;;
    static_http)
      echo "bundle_store.mode=static_http was removed; only appliance_files (DEV_REGISTRY file API) is supported" >&2
      return 2
      ;;
    *)
      echo "bundle_store.mode must be appliance_files (got ${mode})" >&2
      return 2
      ;;
  esac
}

bundle_store_get_optional() {
  local config_path="$1"
  local suffix="$2"
  config_get_optional "${config_path}" "bundle_store.${suffix}"
}

resolve_bundle_store_mode() {
  local config_path="$1"
  local mode
  mode="$(bundle_store_get_optional "${config_path}" "mode" || true)"
  if [[ -n "$(bundle_store_get_optional "${config_path}" "publish_server_alias" || true)" || \
        -n "$(bundle_store_get_optional "${config_path}" "publish_remote_root" || true)" ]]; then
    fail "bundle_store.publish_server_alias / publish_remote_root were removed with static_http; publish uses DEV_REGISTRY file API only"
  fi
  normalize_bundle_store_mode "${mode}" || fail "bundle_store.mode must be appliance_files (or omitted)"
}

# Fixed path prefix under the file API (matches publish-release.sh).
resolve_bundle_store_release_path_prefix() {
  local config_path="$1"
  local prefix=""
  prefix="$(bundle_store_get_optional "${config_path}" "release_path_prefix" || true)"
  prefix="$(printf '%s' "${prefix}" | tr -d '[:space:]')"
  if [[ -z "${prefix}" ]]; then
    prefix="appliance"
  fi
  if [[ "${prefix}" != "appliance" ]]; then
    fail "bundle_store.release_path_prefix must be 'appliance' (or omitted); got ${prefix}"
  fi
  printf '%s\n' "${prefix}"
}

# Path suffix for the authenticated files API (default /api/v1/files).
resolve_appliance_files_files_path() {
  local config_path="$1"
  local files_path=""
  files_path="$(bundle_store_get_optional "${config_path}" "files_path" || true)"
  files_path="$(printf '%s' "${files_path}" | tr -d '[:space:]')"
  if [[ -z "${files_path}" ]]; then
    files_path="/api/v1/files"
  fi
  case "${files_path}" in
    /*) ;;
    *) files_path="/${files_path}" ;;
  esac
  # Strip trailing slash for stable join/compare.
  printf '%s' "${files_path%/}"
}

require_appliance_files_base_url() {
  local base_url="$1"
  local files_path="${2:-/api/v1/files}"
  files_path="$(printf '%s' "${files_path}" | tr -d '[:space:]')"
  files_path="${files_path%/}"
  case "${base_url}" in
    *"${files_path}"|*"${files_path}/")
      return 0
      ;;
    *)
      fail "bundle_store requires base URL ending in ${files_path} (authenticated API). Got: ${base_url}. Omit bundle_store.base_url so the skill derives https://\$DEV_REGISTRY${files_path}."
      ;;
  esac
}

# Build https://<DEV_REGISTRY>/api/v1/files from env (preferred).
# Optional override: bundle_store.base_url ONLY when it already ends in files_path
# (tests/advanced).
# Optional: bundle_store.registry_env (default DEV_REGISTRY), bundle_store.files_path.
resolve_appliance_files_base_url() {
  local config_path="$1"
  local base_url=""
  local files_path=""
  local registry_env=""
  local registry_host=""

  files_path="$(resolve_appliance_files_files_path "${config_path}")"

  base_url="$(bundle_store_get_optional "${config_path}" "base_url" || true)"
  base_url="$(printf '%s' "${base_url}" | tr -d '[:space:]')"
  if [[ -n "${base_url}" ]]; then
    require_appliance_files_base_url "${base_url}" "${files_path}"
    printf '%s' "${base_url%/}"
    return 0
  fi

  registry_env="$(bundle_store_get_optional "${config_path}" "registry_env" || true)"
  registry_env="$(printf '%s' "${registry_env}" | tr -d '[:space:]')"
  if [[ -z "${registry_env}" ]]; then
    registry_env="DEV_REGISTRY"
  fi
  registry_host="$(resolve_env_value "${registry_env}" "bundle_store registry env")"
  registry_host="$(printf '%s' "${registry_host}" | tr -d '[:space:]')"
  registry_host="${registry_host#https://}"
  registry_host="${registry_host#http://}"
  registry_host="${registry_host%/}"
  [[ -n "${registry_host}" ]] || fail "bundle_store registry env ${registry_env} resolved empty"
  base_url="https://${registry_host}${files_path}"
  require_appliance_files_base_url "${base_url}" "${files_path}"
  printf '%s' "${base_url}"
}

# Fill BUNDLE_STORE_CURL_TLS_ARGS for appliance_files HTTPS curls.
# Prefer cacert_path when set; else optional tls_insecure override; else
# invert tls_verify_env (default DEV_REGISTRY_TLS_VERIFY): false → -k.
# Uses a global array because macOS ships bash 3.2 (no namerefs).
BUNDLE_STORE_CURL_TLS_ARGS=()
bundle_store_fill_curl_tls_args() {
  local config_path="$1"
  local cacert=""
  local insecure=""
  local tls_verify_env=""
  local tls_verify=""
  BUNDLE_STORE_CURL_TLS_ARGS=()
  cacert="$(bundle_store_get_optional "${config_path}" "cacert_path" || true)"
  insecure="$(bundle_store_get_optional "${config_path}" "tls_insecure" || true)"
  if [[ -n "${cacert}" ]]; then
    ensure_file "${cacert}"
    BUNDLE_STORE_CURL_TLS_ARGS+=(--cacert "${cacert}")
    return 0
  fi
  if [[ -n "${insecure}" ]]; then
    if bool_true "${insecure}"; then
      BUNDLE_STORE_CURL_TLS_ARGS+=(-k)
    fi
    return 0
  fi
  tls_verify_env="$(bundle_store_get_optional "${config_path}" "tls_verify_env" || true)"
  tls_verify_env="$(printf '%s' "${tls_verify_env}" | tr -d '[:space:]')"
  if [[ -z "${tls_verify_env}" ]]; then
    tls_verify_env="DEV_REGISTRY_TLS_VERIFY"
  fi
  tls_verify="$(printf '%s' "${!tls_verify_env:-}" | tr -d '[:space:]')"
  [[ -n "${tls_verify}" ]] || fail "bundle_store requires ${tls_verify_env} (or optional bundle_store.tls_insecure / cacert_path)"
  tls_verify="$(normalize_bool_value "${tls_verify}")"
  if [[ "${tls_verify}" == "false" ]]; then
    BUNDLE_STORE_CURL_TLS_ARGS+=(-k)
  fi
}

# Build a remote bash assignment like: curl_args=(-fsSIL -k)
# Mac-local --cacert paths are rewritten to -k for remote curl.
bundle_store_remote_curl_array_init() {
  local array_name="$1"
  shift
  local init="${array_name}=("
  local arg=""
  local tls_joined=""
  for arg in "$@"; do
    init+=" $(shell_quote "${arg}")"
  done
  if [[ ${#BUNDLE_STORE_CURL_TLS_ARGS[@]} -gt 0 ]]; then
    tls_joined="${BUNDLE_STORE_CURL_TLS_ARGS[*]}"
    if [[ "${tls_joined}" == *"--cacert"* ]]; then
      init+=" -k"
    else
      for arg in "${BUNDLE_STORE_CURL_TLS_ARGS[@]}"; do
        init+=" $(shell_quote "${arg}")"
      done
    fi
  fi
  init+=")"
  printf '%s' "${init}"
}

# Resolve the bearer token for appliance_files publish/install.
# Prefer optional bundle_store.access_token; otherwise read token_env
# (default DEV_REGISTRY_TOKEN — same long-lived distributor API token).
resolve_appliance_files_bearer_token() {
  local config_path="$1"
  local base_url="${2:-}"
  local token=""
  local token_env=""
  local files_path=""

  if [[ -z "${base_url}" ]]; then
    base_url="$(resolve_appliance_files_base_url "${config_path}")"
  else
    files_path="$(resolve_appliance_files_files_path "${config_path}")"
    require_appliance_files_base_url "${base_url}" "${files_path}"
  fi
  token="$(bundle_store_get_optional "${config_path}" "access_token" || true)"
  token="$(printf '%s' "${token}" | tr -d '[:space:]')"
  if [[ -z "${token}" ]]; then
    token_env="$(bundle_store_get_optional "${config_path}" "token_env" || true)"
    token_env="$(printf '%s' "${token_env}" | tr -d '[:space:]')"
    if [[ -z "${token_env}" ]]; then
      token_env="DEV_REGISTRY_TOKEN"
    fi
    token="$(printf '%s' "${!token_env:-}" | tr -d '[:space:]')"
    if [[ -z "${token}" ]]; then
      fail "bundle_store requires ${token_env} (or optional bundle_store.access_token) — long-lived API token from the distributor Dashboard → API tokens"

    fi
  fi
  printf '%s' "${token}"
}

render_ensure_remote_release_repo_cmd() {
  local remote_cwd="$1"
  local repo_source="$2"
  local repo_ref="$3"

  local quoted_cwd quoted_source quoted_ref
  quoted_cwd="$(shell_quote "${remote_cwd}")"
  quoted_source="$(shell_quote "${repo_source}")"
  quoted_ref="$(shell_quote "${repo_ref}")"

  cat <<EOF
set -euo pipefail
repo_path=${quoted_cwd}
repo_source=${quoted_source}
repo_ref=${quoted_ref}

sync_existing_release_repo() {
  cd "\${repo_path}"
  git remote set-url origin "\${repo_source}"
  # Shallow-friendly update: fetch the configured ref and make the working
  # tree match it exactly. Discard local modifications/untracked files so a
  # previous manual copy or interrupted edit cannot block the release flow.
  if [[ -n "\${repo_ref}" ]]; then
    if ! git fetch --prune --depth 1 origin "\${repo_ref}"; then
      echo "ensure remote release repo: fetch failed for \${repo_source} ref \${repo_ref}; recloning" >&2
      return 1
    fi
  else
    if ! git fetch --prune --depth 1 origin; then
      echo "ensure remote release repo: fetch failed for \${repo_source}; recloning" >&2
      return 1
    fi
  fi
  git reset --hard FETCH_HEAD
  git clean -fd
  echo "ensure remote release repo: synced \${repo_path} to \$(git rev-parse --short HEAD)"
}

clone_release_repo() {
  mkdir -p "\$(dirname "\${repo_path}")"
  rm -rf "\${repo_path}"
  if [[ -n "\${repo_ref}" ]]; then
    git clone --depth 1 --branch "\${repo_ref}" "\${repo_source}" "\${repo_path}"
  else
    git clone --depth 1 "\${repo_source}" "\${repo_path}"
  fi
  echo "ensure remote release repo: cloned \${repo_source} into \${repo_path}"
}

if [[ -d "\${repo_path}/.git" ]]; then
  if ! sync_existing_release_repo; then
    echo "ensure remote release repo: removing unusable checkout at \${repo_path}" >&2
    rm -rf "\${repo_path}"
    clone_release_repo
  fi
elif [[ -e "\${repo_path}" ]]; then
  echo "ensure remote release repo: path exists but is not a git checkout; replacing \${repo_path}" >&2
  rm -rf "\${repo_path}"
  clone_release_repo
else
  clone_release_repo
fi
EOF
}
