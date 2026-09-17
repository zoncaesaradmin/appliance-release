#!/usr/bin/env bash
# Durable third-party packaging freeze (product vs upstream separation).
#
# Env:
#   THIRD_PARTY_FREEZE_ROOT   Absolute cache root (e.g. /var/cache/zon-third-party).
#                             Empty disables freeze even when mode is set.
#   THIRD_PARTY_FREEZE_MODE   ignore | auto | require (default: ignore)
#   TARGET_ARCH               amd64|arm64 — required when freeze is active
#
# Layout:
#   $ROOT/$TARGET_ARCH/artifacts/<artifact_id>/<fingerprint>/
#     .fingerprint
#     files/<basename>...
#   $ROOT/$TARGET_ARCH/manifest.yaml
#
# Modes:
#   ignore  — never read/write freeze (default)
#   auto    — restore on hit; package + store on miss
#   require — restore on hit; fail closed on miss (run make freeze-third-party)
#
# Product images (control-plane, UI, host-agent, inference-manager) stay out of
# this cache. Only upstream / third-party packaging outputs belong here.

tpf_mode() {
  local mode="${THIRD_PARTY_FREEZE_MODE:-ignore}"
  mode="$(printf '%s' "${mode}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${mode}" in
    ""|ignore|off|0|false|no) printf '%s' "ignore" ;;
    auto|on|1|true|yes) printf '%s' "auto" ;;
    require|required|must) printf '%s' "require" ;;
    *)
      echo "third-party-freeze: invalid THIRD_PARTY_FREEZE_MODE=${THIRD_PARTY_FREEZE_MODE}" >&2
      return 2
      ;;
  esac
}

tpf_active() {
  local mode
  mode="$(tpf_mode)" || return 2
  [[ "${mode}" != "ignore" ]] || return 1
  [[ -n "${THIRD_PARTY_FREEZE_ROOT:-}" ]] || return 1
  [[ -n "${TARGET_ARCH:-}" ]] || {
    echo "third-party-freeze: TARGET_ARCH is required when freeze is active" >&2
    return 2
  }
  return 0
}

tpf_arch_root() {
  printf '%s/%s' "${THIRD_PARTY_FREEZE_ROOT%/}" "${TARGET_ARCH}"
}

tpf_fingerprint() {
  local parts=("tpf-v1")
  local input digest
  for input in "$@"; do
    if [[ -f "${input}" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum "${input}" | awk '{print $1}')"
      else
        digest="$(shasum -a 256 "${input}" | awk '{print $1}')"
      fi
      parts+=("file:${input}:${digest}")
    elif [[ -d "${input}" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        digest="$(find "${input}" -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
      else
        digest="$(find "${input}" -type f -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}')"
      fi
      parts+=("dir:${input}:${digest}")
    else
      parts+=("str:${input}")
    fi
  done
  local joined
  joined="$(printf '%s\n' "${parts[@]}")"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${joined}" | sha256sum | awk '{print $1}'
  else
    printf '%s' "${joined}" | shasum -a 256 | awk '{print $1}'
  fi
}

tpf_artifact_dir() {
  local artifact_id="$1"
  local fp="$2"
  printf '%s/artifacts/%s/%s' "$(tpf_arch_root)" "${artifact_id}" "${fp}"
}

tpf_miss_message() {
  local artifact_id="$1"
  cat >&2 <<EOF
third-party-freeze: miss for ${artifact_id} (mode=$(tpf_mode) arch=${TARGET_ARCH})
third-party-freeze: populate with:
third-party-freeze:   TARGET_ARCH=${TARGET_ARCH} THIRD_PARTY_FREEZE_ROOT=${THIRD_PARTY_FREEZE_ROOT} make freeze-third-party
EOF
}

tpf_fp_inputs_or_die() {
  local label="$1"
  if ! declare -p TPF_FP_INPUTS >/dev/null 2>&1 || [[ ${#TPF_FP_INPUTS[@]} -eq 0 ]]; then
    echo "third-party-freeze: ${label}: TPF_FP_INPUTS empty" >&2
    return 2
  fi
  return 0
}

tpf_link_or_copy() {
  local src="$1"
  local dest="$2"
  if declare -F link_or_copy_file >/dev/null 2>&1; then
    link_or_copy_file "${src}" "${dest}"
    return $?
  fi
  mkdir -p "$(dirname "${dest}")"
  rm -f "${dest}"
  if ln "${src}" "${dest}" 2>/dev/null; then
    return 0
  fi
  if cp --reflink=auto "${src}" "${dest}" 2>/dev/null; then
    return 0
  fi
  cp -f "${src}" "${dest}"
}

# Restore files named as basenames of the given paths into the same directories.
# Returns 0 on hit, 1 on miss (or ignore), 2 on hard error.
# Caller sets TPF_FP_INPUTS=(...) before calling.
tpf_try_restore_files() {
  local artifact_id="$1"
  shift
  local files=("$@")
  local mode fp cache_root stamp f base payload_file

  if ! tpf_active; then
    return 1
  fi
  mode="$(tpf_mode)" || return 2
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "third-party-freeze: restore ${artifact_id}: no files" >&2
    return 2
  fi
  tpf_fp_inputs_or_die "restore ${artifact_id}" || return 2

  fp="$(tpf_fingerprint "${TPF_FP_INPUTS[@]}")"
  cache_root="$(tpf_artifact_dir "${artifact_id}" "${fp}")"
  stamp="${cache_root}/.fingerprint"
  if [[ ! -f "${stamp}" ]] || [[ "$(tr -d '[:space:]' <"${stamp}")" != "${fp}" ]]; then
    if [[ "${mode}" == "require" ]]; then
      tpf_miss_message "${artifact_id}"
      return 2
    fi
    return 1
  fi

  for f in "${files[@]}"; do
    base="$(basename "${f}")"
    payload_file="${cache_root}/files/${base}"
    if [[ ! -f "${payload_file}" ]]; then
      if [[ "${mode}" == "require" ]]; then
        echo "third-party-freeze: incomplete cache for ${artifact_id}: missing ${base}" >&2
        tpf_miss_message "${artifact_id}"
        return 2
      fi
      return 1
    fi
  done

  for f in "${files[@]}"; do
    base="$(basename "${f}")"
    payload_file="${cache_root}/files/${base}"
    tpf_link_or_copy "${payload_file}" "${f}"
  done
  echo "third-party-freeze: hit ${artifact_id} (${fp:0:12}…)" >&2
  return 0
}

tpf_store_files() {
  local artifact_id="$1"
  shift
  local files=("$@")
  local mode fp cache_root f base

  if ! tpf_active; then
    return 0
  fi
  mode="$(tpf_mode)" || return 2
  [[ "${mode}" != "ignore" ]] || return 0
  tpf_fp_inputs_or_die "store ${artifact_id}" || return 2

  for f in "${files[@]}"; do
    if [[ ! -f "${f}" ]]; then
      echo "third-party-freeze: store ${artifact_id}: missing file ${f}" >&2
      return 2
    fi
  done

  fp="$(tpf_fingerprint "${TPF_FP_INPUTS[@]}")"
  cache_root="$(tpf_artifact_dir "${artifact_id}" "${fp}")"
  rm -rf "${cache_root}"
  mkdir -p "${cache_root}/files"
  for f in "${files[@]}"; do
    base="$(basename "${f}")"
    tpf_link_or_copy "${f}" "${cache_root}/files/${base}"
  done
  printf '%s\n' "${fp}" >"${cache_root}/.fingerprint"
  echo "third-party-freeze: stored ${artifact_id} (${fp:0:12}…)" >&2
  tpf_refresh_manifest || true
  return 0
}

# Restore a directory tree (e.g. host-packages).
tpf_try_restore_dir() {
  local artifact_id="$1"
  local dest="$2"
  local mode fp cache_root stamp payload

  if ! tpf_active; then
    return 1
  fi
  mode="$(tpf_mode)" || return 2
  tpf_fp_inputs_or_die "restore-dir ${artifact_id}" || return 2

  fp="$(tpf_fingerprint "${TPF_FP_INPUTS[@]}")"
  cache_root="$(tpf_artifact_dir "${artifact_id}" "${fp}")"
  stamp="${cache_root}/.fingerprint"
  payload="${cache_root}/files"
  if [[ ! -f "${stamp}" || ! -d "${payload}" ]] || [[ "$(tr -d '[:space:]' <"${stamp}")" != "${fp}" ]]; then
    if [[ "${mode}" == "require" ]]; then
      tpf_miss_message "${artifact_id}"
      return 2
    fi
    return 1
  fi
  if declare -F link_or_copy_tree >/dev/null 2>&1; then
    link_or_copy_tree "${payload}" "${dest}"
  else
    rm -rf "${dest}"
    mkdir -p "${dest}"
    cp -a "${payload}/." "${dest}/"
  fi
  echo "third-party-freeze: hit ${artifact_id} (${fp:0:12}…)" >&2
  return 0
}

tpf_store_dir() {
  local artifact_id="$1"
  local source="$2"
  local mode fp cache_root

  if ! tpf_active; then
    return 0
  fi
  mode="$(tpf_mode)" || return 2
  [[ "${mode}" != "ignore" ]] || return 0
  if [[ ! -d "${source}" ]]; then
    echo "third-party-freeze: store-dir skipped (not a directory): ${source}" >&2
    return 0
  fi
  tpf_fp_inputs_or_die "store-dir ${artifact_id}" || return 2

  fp="$(tpf_fingerprint "${TPF_FP_INPUTS[@]}")"
  cache_root="$(tpf_artifact_dir "${artifact_id}" "${fp}")"
  rm -rf "${cache_root}"
  mkdir -p "${cache_root}/files"
  cp -a "${source}/." "${cache_root}/files/"
  printf '%s\n' "${fp}" >"${cache_root}/.fingerprint"
  echo "third-party-freeze: stored ${artifact_id} (${fp:0:12}…)" >&2
  tpf_refresh_manifest || true
  return 0
}

# OCI archive helpers: out.tar plus optional .reference / .source-id siblings.
tpf_oci_sibling_paths() {
  local out_tar="$1"
  local stem="${out_tar%.tar}"
  local paths=("${out_tar}")
  [[ -f "${stem}.reference" ]] && paths+=("${stem}.reference")
  [[ -f "${stem}.source-id" ]] && paths+=("${stem}.source-id")
  printf '%s\n' "${paths[@]}"
}

tpf_try_restore_oci() {
  local artifact_id="$1"
  local out_tar="$2"
  local stem="${out_tar%.tar}"
  local present=()
  local mode fp cache_root

  if ! tpf_active; then
    return 1
  fi
  mode="$(tpf_mode)" || return 2
  tpf_fp_inputs_or_die "restore-oci ${artifact_id}" || return 2

  fp="$(tpf_fingerprint "${TPF_FP_INPUTS[@]}")"
  cache_root="$(tpf_artifact_dir "${artifact_id}" "${fp}")"
  if [[ ! -f "${cache_root}/files/$(basename "${out_tar}")" ]]; then
    if [[ "${mode}" == "require" ]]; then
      tpf_miss_message "${artifact_id}"
      return 2
    fi
    return 1
  fi
  present=("${out_tar}")
  local c
  for c in "${stem}.reference" "${stem}.source-id"; do
    if [[ -f "${cache_root}/files/$(basename "${c}")" ]]; then
      present+=("${c}")
    fi
  done
  tpf_try_restore_files "${artifact_id}" "${present[@]}"
}

tpf_store_oci() {
  local artifact_id="$1"
  local out_tar="$2"
  local paths=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && paths+=("${line}")
  done < <(tpf_oci_sibling_paths "${out_tar}")
  tpf_store_files "${artifact_id}" "${paths[@]}"
}

tpf_refresh_manifest() {
  local arch_root manifest
  if ! tpf_active; then
    return 0
  fi
  arch_root="$(tpf_arch_root)"
  manifest="${arch_root}/manifest.yaml"
  mkdir -p "${arch_root}"
  python3 - "${arch_root}" "${TARGET_ARCH}" "${manifest}" <<'PY'
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

arch_root = Path(sys.argv[1])
target_arch = sys.argv[2]
manifest = Path(sys.argv[3])
artifacts_root = arch_root / "artifacts"
entries = []
if artifacts_root.is_dir():
    for artifact_dir in sorted(p for p in artifacts_root.iterdir() if p.is_dir()):
        for fp_dir in sorted(p for p in artifact_dir.iterdir() if p.is_dir()):
            stamp = fp_dir / ".fingerprint"
            files_dir = fp_dir / "files"
            if not stamp.is_file() or not files_dir.is_dir():
                continue
            fp = stamp.read_text(encoding="utf-8").strip()
            files = sorted(p.name for p in files_dir.iterdir() if p.is_file())
            entries.append(
                {
                    "id": artifact_dir.name,
                    "fingerprint": fp,
                    "files": files,
                }
            )

lines = [
    "schema_version: 1",
    f"target_arch: {target_arch}",
    f"updated_at: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
    "artifacts:",
]
if not entries:
    lines.append("  []")
else:
    for entry in entries:
        lines.append(f"  - id: {entry['id']}")
        lines.append(f"    fingerprint: {entry['fingerprint']}")
        lines.append("    files:")
        for name in entry["files"]:
            lines.append(f"      - {name}")
manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

# Resolve optional config-style defaults for callers that only have env.
tpf_normalize_env() {
  THIRD_PARTY_FREEZE_MODE="$(tpf_mode)"
  export THIRD_PARTY_FREEZE_MODE
  if [[ "${THIRD_PARTY_FREEZE_MODE}" != "ignore" && -z "${THIRD_PARTY_FREEZE_ROOT:-}" ]]; then
    echo "third-party-freeze: THIRD_PARTY_FREEZE_ROOT is required when mode=${THIRD_PARTY_FREEZE_MODE}" >&2
    return 2
  fi
  if [[ -n "${THIRD_PARTY_FREEZE_ROOT:-}" && "${THIRD_PARTY_FREEZE_ROOT}" != /* ]]; then
    echo "third-party-freeze: THIRD_PARTY_FREEZE_ROOT must be absolute (got ${THIRD_PARTY_FREEZE_ROOT})" >&2
    return 2
  fi
  return 0
}

# Ensure THIRD_PARTY_FREEZE_ROOT exists and is writable by the current user.
# /var/cache/... normally needs root once; use passwordless sudo when available.
tpf_ensure_root_writable() {
  local root owner
  root="${THIRD_PARTY_FREEZE_ROOT:-}"
  [[ -n "${root}" ]] || return 0
  if [[ -d "${root}" && -w "${root}" ]]; then
    mkdir -p "${root}/${TARGET_ARCH:-}" 2>/dev/null || true
    return 0
  fi
  if mkdir -p "${root}" 2>/dev/null && [[ -w "${root}" ]]; then
    return 0
  fi
  owner="$(id -u):$(id -g)"
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    if sudo -n mkdir -p "${root}" \
      && sudo -n chown "${owner}" "${root}" \
      && sudo -n chmod 0755 "${root}"; then
      if [[ -d "${root}" && -w "${root}" ]]; then
        echo "third-party-freeze: prepared writable root ${root} (owner ${owner})" >&2
        return 0
      fi
    fi
  fi
  cat >&2 <<EOF
third-party-freeze: cannot create or write ${root}
third-party-freeze: prepare it once as root, then rerun:
third-party-freeze:   sudo mkdir -p ${root}
third-party-freeze:   sudo chown $(id -un):$(id -gn) ${root}
third-party-freeze: or point THIRD_PARTY_FREEZE_ROOT at a user-writable path
EOF
  return 1
}
