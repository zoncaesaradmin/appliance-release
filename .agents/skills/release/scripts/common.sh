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

config_keys() {
  local config_path="$1"
  local query="$2"
  python3 "${CONFIG_QUERY}" --keys "${config_path}" "${query}"
}

resolve_config_path() {
  local explicit_path="${1:-}"

  if [[ -n "${explicit_path}" ]]; then
    printf '%s\n' "${explicit_path}"
    return 0
  fi

  if [[ -n "${APPLIANCE_RELEASE_CONFIG:-}" ]]; then
    printf '%s\n' "${APPLIANCE_RELEASE_CONFIG}"
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

bool_true() {
  local value="${1:-}"
  local normalized
  normalized="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${normalized}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

run_logged() {
  local log_file="$1"
  shift

  ensure_dir "$(dirname "${log_file}")"
  set +e
  "$@" 2>&1 | tee "${log_file}"
  local cmd_status="${PIPESTATUS[0]}"
  set -e
  return "${cmd_status}"
}

run_ssh_logged() {
  local host="$1"
  local log_file="$2"
  local remote_command="$3"

  ensure_dir "$(dirname "${log_file}")"
  set +e
  ssh -tt "${host}" "env -u BASH_ENV PS1='' bash -lc $(shell_quote "${remote_command}")" 2>&1 \
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

  ensure_dir "$(dirname "${log_file}")"
  set +e
  ssh -q -T "${host}" "env -u BASH_ENV PS1='' bash -lc $(shell_quote "${remote_command}")" >"${log_file}" 2>&1
  local cmd_status="$?"
  set -e
  return "${cmd_status}"
}

# Copy the linux/amd64 ORAS CLI produced by build-full-bundle on the build host
# (${export_dir}/tools/oras) onto the target. The Mac only orchestrates scp; it
# never downloads ORAS. Target never apt-installs ORAS or fetches it from the
# public internet.
bootstrap_oras_from_build_host_to_target() {
  local build_host="$1"
  local export_dir="$2"
  local target_host="$3"
  local log_file="${4:-}"
  local remote_src remote_dir remote_dest cmd_status=0
  require_cmd scp
  [[ -n "${build_host}" ]] || fail "build host is required to bootstrap ORAS onto the target"
  [[ -n "${export_dir}" ]] || fail "release_workspace.remote_export_dir is required to bootstrap ORAS onto the target"
  remote_src="${export_dir%/}/tools/oras"
  remote_dir="${ORAS_REMOTE_TOOLS_DIR:-/tmp/appliance-release-tools}"
  remote_dest="${remote_dir}/oras"

  log "copying build-host ORAS ${build_host}:${remote_src} -> ${target_host}:${remote_dest}"
  if [[ -n "${log_file}" ]]; then
    ensure_dir "$(dirname "${log_file}")"
    : >"${log_file}"
  fi

  set +e
  if [[ -n "${log_file}" ]]; then
    ssh -q -T "${build_host}" "env -u BASH_ENV PS1='' bash -lc $(shell_quote "test -x $(shell_quote "${remote_src}")")" >>"${log_file}" 2>&1
  else
    ssh -q -T "${build_host}" "env -u BASH_ENV PS1='' bash -lc $(shell_quote "test -x $(shell_quote "${remote_src}")")"
  fi
  cmd_status="$?"
  set -e
  if [[ "${cmd_status}" -ne 0 ]]; then
    fail "ORAS CLI missing on build host at ${remote_src}; run build-full-bundle on the build host first"
  fi

  set +e
  if [[ -n "${log_file}" ]]; then
    ssh -q -T "${target_host}" "env -u BASH_ENV PS1='' bash -lc $(shell_quote "mkdir -p $(shell_quote "${remote_dir}")")" >>"${log_file}" 2>&1
    cmd_status="$?"
    [[ "${cmd_status}" -eq 0 ]] || {
      set -e
      fail "failed to create ${remote_dir} on ${target_host}; see ${log_file}"
    }
    scp -q "${build_host}:${remote_src}" "${target_host}:${remote_dest}" >>"${log_file}" 2>&1
    cmd_status="$?"
    [[ "${cmd_status}" -eq 0 ]] || {
      set -e
      fail "failed to scp ORAS from build host to target; see ${log_file}"
    }
    ssh -q -T "${target_host}" "env -u BASH_ENV PS1='' bash -lc $(shell_quote "chmod +x $(shell_quote "${remote_dest}") && $(shell_quote "${remote_dest}") version >/dev/null")" >>"${log_file}" 2>&1
    cmd_status="$?"
  else
    ssh -q -T "${target_host}" "env -u BASH_ENV PS1='' bash -lc $(shell_quote "mkdir -p $(shell_quote "${remote_dir}")")"
    scp -q "${build_host}:${remote_src}" "${target_host}:${remote_dest}"
    ssh -q -T "${target_host}" "env -u BASH_ENV PS1='' bash -lc $(shell_quote "chmod +x $(shell_quote "${remote_dest}") && $(shell_quote "${remote_dest}") version >/dev/null")"
    cmd_status="$?"
  fi
  set -e
  [[ "${cmd_status}" -eq 0 ]] || fail "ORAS bootstrap onto ${target_host} failed${log_file:+; see ${log_file}}"
  printf '%s\n' "${remote_dest}"
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

# Normalize artifact_registry.mode to http|oci. Empty defaults to http.
# Full ORAS helpers live in scripts/publish/oci-release-lib.sh.
_OCI_RELEASE_LIB="$(cd "${SCRIPT_DIR}/../../../.." && pwd)/scripts/publish/oci-release-lib.sh"
if [[ -f "${_OCI_RELEASE_LIB}" ]]; then
  # shellcheck source=/dev/null
  source "${_OCI_RELEASE_LIB}"
fi
unset _OCI_RELEASE_LIB

resolve_artifact_registry_mode() {
  local config_path="$1"
  local mode
  mode="$(config_get_optional "${config_path}" "artifact_registry.mode" || true)"
  if declare -F normalize_artifact_registry_mode >/dev/null 2>&1; then
    normalize_artifact_registry_mode "${mode}"
  else
    mode="$(printf '%s' "${mode}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "${mode}" in
      ""|http|http-static) printf 'http\n' ;;
      oci) printf 'oci\n' ;;
      *) fail "artifact_registry.mode must be http or oci (got ${mode})" ;;
    esac
  fi
}

render_ensure_remote_release_repo_cmd() {
  local remote_cwd="$1"
  local repo_source="$2"
  local repo_ref="$3"
  # pull_cmd is retained for callers/metadata compatibility but intentionally
  # unused: the build-host checkout is skill-managed and must sync to the
  # configured ref even when the working tree is dirty (for example after an
  # accidental scp during debugging).
  local _pull_cmd="${4:-}"

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
