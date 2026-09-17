#!/usr/bin/env bash
# Product-level TARGET_ARCH helpers for packaging/assemble scripts.
#
# Env:
#   TARGET_ARCH   required: amd64|arm64 (no default — fail closed if unset)
#
# After target_arch_resolve:
#   TARGET_ARCH, TARGET_OS (linux), BUNDLE_IMAGE_ARCH, BUNDLE_IMAGE_OS are exported.

target_arch_resolve() {
  local raw="${TARGET_ARCH-}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ -z "${raw}" ]]; then
    echo "target-arch: TARGET_ARCH is required (amd64|arm64); no default" >&2
    return 2
  fi
  case "${raw}" in
    amd64|x86_64|x86-64)
      TARGET_ARCH="amd64"
      ;;
    arm64|aarch64)
      TARGET_ARCH="arm64"
      ;;
    *)
      echo "target-arch: unsupported TARGET_ARCH=${raw} (want amd64|arm64)" >&2
      return 2
      ;;
  esac
  TARGET_OS="${TARGET_OS:-linux}"
  BUNDLE_IMAGE_OS="${BUNDLE_IMAGE_OS:-${TARGET_OS}}"
  BUNDLE_IMAGE_ARCH="${BUNDLE_IMAGE_ARCH:-${TARGET_ARCH}}"
  export TARGET_ARCH TARGET_OS BUNDLE_IMAGE_OS BUNDLE_IMAGE_ARCH
}

# Filename for the product pack archive (pack IDs stay arch-agnostic).
appliance_pack_archive_name() {
  local product_version="$1"
  local pack_id="$2"
  local arch="${3-}"
  if [[ -z "${arch}" ]]; then
    arch="${TARGET_ARCH-}"
  fi
  if [[ -z "${arch}" ]]; then
    echo "target-arch: appliance_pack_archive_name requires TARGET_ARCH or an explicit arch argument" >&2
    return 2
  fi
  printf 'appliance-%s-%s-%s.tar.gz' "${product_version}" "${pack_id}" "${arch}"
}

# Upstream K3s binary asset name for TARGET_ARCH.
k3s_binary_asset_name() {
  if [[ -z "${TARGET_ARCH-}" ]]; then
    echo "target-arch: TARGET_ARCH is required for k3s_binary_asset_name" >&2
    return 2
  fi
  case "${TARGET_ARCH}" in
    amd64) printf 'k3s' ;;
    arm64) printf 'k3s-arm64' ;;
    *)
      echo "target-arch: unsupported TARGET_ARCH for k3s binary: ${TARGET_ARCH}" >&2
      return 2
      ;;
  esac
}
