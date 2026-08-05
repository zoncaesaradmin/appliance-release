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

resolve_build_catalog_path() {
  local config_path="$1"
  local build_catalog_path="${2:-}"
  if [[ -z "${build_catalog_path}" ]]; then
    build_catalog_path="$(config_get_optional "${config_path}" "install.build_catalog_path" || true)"
  fi
  if [[ -n "${build_catalog_path}" ]]; then
    ensure_file "${build_catalog_path}"
  fi
  printf '%s\n' "${build_catalog_path}"
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
  local setting_name="${3:-verification.argo.enabled}"
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

require_builder_build_catalog_path() {
  local profile="${1:-}"
  local build_catalog_path="${2:-}"
  if [[ -n "${build_catalog_path}" ]]; then
    ensure_file "${build_catalog_path}"
  fi
  if profile_supports_builder "${profile}" && [[ -z "${build_catalog_path}" ]]; then
    fail "builder appliance profile requires install.build_catalog_path or --build-catalog; start from .agents/skills/release/references/build-catalog.example.yaml"
  fi
}

validate_builder_build_catalog() {
  local script_dir="$1"
  local config_path="$2"
  local profile="$3"
  local build_catalog_path="$4"
  local run_dir="$5"
  local success_message="${6:-build-catalog validation ok}"
  local catalog_validation_log=""

  if ! profile_supports_builder "${profile}" || [[ -z "${build_catalog_path}" ]]; then
    return 0
  fi

  catalog_validation_log="${run_dir}/logs/build-catalog-validation.json"
  if ! python3 "${script_dir}/validate-build-catalog.py" \
    --config "${config_path}" \
    --build-catalog "${build_catalog_path}" \
    --output-json "${catalog_validation_log}" \
    >"${catalog_validation_log}.stdout" 2>"${catalog_validation_log}.stderr"; then
    fail "builder build catalog validation failed; see ${catalog_validation_log}"
  fi
  log "${success_message}"
}

run_ssh_logged() {
  local host="$1"
  local log_file="$2"
  local remote_command="$3"
  local quoted_remote_command=""

  ensure_dir "$(dirname "${log_file}")"
  quoted_remote_command="$(shell_quote "${remote_command}")"
  set +e
  # Non-interactive login shell: sources ~/.bash_profile or ~/.profile (not the
  # interactive-only half of ~/.bashrc). Operators should export DEV_* and
  # APPLIANCE_* there. -tt keeps a remote TTY for tools that expect one / for
  # log streaming.
  ssh -tt "${host}" "env -u BASH_ENV bash -lc ${quoted_remote_command}" 2>&1 \
    | python3 -c 'import sys; [sys.stdout.write(line) for line in sys.stdin if not line.startswith("Connection to ") or " closed." not in line]' \
    | tee "${log_file}"
  local cmd_status="${PIPESTATUS[0]}"
  set -e
  return "${cmd_status}"
}

run_ssh_captured() {
  local host="$1"
  local log_file="$2"
  local remote_command="$3"
  local quoted_remote_command=""

  ensure_dir "$(dirname "${log_file}")"
  quoted_remote_command="$(shell_quote "${remote_command}")"
  set +e
  ssh -q -T "${host}" "env -u BASH_ENV bash -lc ${quoted_remote_command}" >"${log_file}" 2>&1
  local cmd_status="$?"
  set -e
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

# Env names referenced by a build-publish config (dev_image_pull, mirror, bundle_store).
# Deduped. Includes APPLIANCE_BUILD_SUDO_PASSWORD when bootstrap/build needs sudo.
collect_build_publish_env_names() {
  local config_path="$1"
  local names=()
  local key candidate boot needs seen="|" n
  for key in \
    "build_flow.dev_image_pull.registry_env" \
    "build_flow.dev_image_pull.image_repo_env" \
    "build_flow.dev_image_pull.image_name_env" \
    "build_flow.dev_image_pull.username_env" \
    "build_flow.dev_image_pull.token_env" \
    "build_flow.dev_image_pull.tls_verify_env" \
    "build_flow.build_image_mirror.registry_env" \
    "build_flow.build_image_mirror.username_env" \
    "build_flow.build_image_mirror.token_env" \
    "build_flow.build_image_mirror.tls_verify_env" \
    "bundle_store.registry_env" \
    "bundle_store.token_env" \
    "bundle_store.tls_verify_env"
  do
    candidate="$(config_get_optional "${config_path}" "${key}" || true)"
    if [[ -n "${candidate}" ]]; then
      names+=("${candidate}")
    fi
  done
  boot="$(config_get_optional "${config_path}" "build_flow.bootstrap_needs_sudo" || true)"
  needs="$(config_get_optional "${config_path}" "build_flow.build_needs_sudo" || true)"
  if { [[ -n "${boot}" ]] && bool_true "${boot}"; } || { [[ -n "${needs}" ]] && bool_true "${needs}"; }; then
    names+=("APPLIANCE_BUILD_SUDO_PASSWORD")
  fi
  for n in "${names[@]}"; do
    case "${seen}" in
      *"|${n}|"*) continue ;;
    esac
    seen+="${n}|"
    printf '%s\n' "${n}"
  done
}

# Source login profile files the way a non-interactive `bash -l` would
# (~/.bash_profile, else ~/.bash_login, else ~/.profile). Optional convenience
# when operators run build-and-publish-on-host.sh by hand; e2e injects env from
# the devhost instead.
load_login_profile_env() {
  local saved_opts
  saved_opts="$(set +o)"
  set +e
  set +u
  if [[ -f "${HOME}/.bash_profile" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/.bash_profile" || true
  elif [[ -f "${HOME}/.bash_login" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/.bash_login" || true
  elif [[ -f "${HOME}/.profile" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/.profile" || true
  fi
  eval "${saved_opts}" 2>/dev/null || true
  set -e
  set -u
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
        fail "live release preflight: ${label} at ${repo_path} has uncommitted build-affecting changes (branch ${branch:-detached}, HEAD ${short_head:-unknown}); the remote build clones ${remote_ref} and will ignore local edits. Dirty paths: ${build_affecting_dirty[*]}. Commit/push or stash these, set APPLIANCE_RELEASE_ALLOW_DIRTY=1 to override, or run make verify-local-milestone for non-live cross-repo validation."
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

  fail "live release preflight: ${label} at ${repo_path} is ahead of ${remote_tracking} by ${ahead_count} commit(s) (branch ${branch:-detached}, HEAD ${short_head:-unknown}); the remote build uses ${remote_tracking}, so those local commits will not be included. Push them before rerunning the live release flow, or use make verify-local-milestone for non-live validation."
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
      fail "${source_label} is still an example placeholder (${1}); set it to the real appliance URL (for example https://192.168.1.103), or omit it so target-side smoke checks keep using https://127.0.0.1"
      ;;
  esac
  return 0
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


# Normalize bundle_store.mode to static_http|appliance_files. Empty is rejected.
_BUNDLE_STORE_LIB="$(cd "${SCRIPT_DIR}/../../../.." && pwd)/scripts/publish/bundle-store-lib.sh"
[[ -f "${_BUNDLE_STORE_LIB}" ]] || fail "missing shared bundle store library: ${_BUNDLE_STORE_LIB}"
# shellcheck source=/dev/null
source "${_BUNDLE_STORE_LIB}"
unset _BUNDLE_STORE_LIB

bundle_store_get_optional() {
  local config_path="$1"
  local suffix="$2"
  config_get_optional "${config_path}" "bundle_store.${suffix}"
}

resolve_bundle_store_mode() {
  local config_path="$1"
  local mode
  mode="$(bundle_store_get_optional "${config_path}" "mode" || true)"
  [[ -n "${mode}" ]] || fail "bundle_store.mode is required in config (static_http or appliance_files)"
  normalize_bundle_store_mode "${mode}" || fail "bundle_store.mode must be static_http or appliance_files"
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
      fail "bundle_store.mode=appliance_files requires base URL ending in ${files_path} (authenticated API). Traefik /files was removed; do not use unauthenticated static nginx paths."
      ;;
  esac
}

# Build https://<DEV_REGISTRY>/api/v1/files from env (preferred).
# Optional override: bundle_store.base_url (legacy / tests).
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
  [[ -n "${tls_verify}" ]] || fail "bundle_store.mode=appliance_files requires ${tls_verify_env} (or optional bundle_store.tls_insecure / cacert_path)"
  tls_verify="$(normalize_bool_value "${tls_verify}")"
  if [[ "${tls_verify}" == "false" ]]; then
    BUNDLE_STORE_CURL_TLS_ARGS+=(-k)
  fi
}

# Build a remote bash assignment like: curl_args=(-fsSIL -k)
# Mac-local --cacert paths are rewritten to -k (same as install-on-target).
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
      fail "bundle_store.mode=appliance_files requires ${token_env} (or optional bundle_store.access_token) — long-lived API token from the distributor Dashboard → API tokens"
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
