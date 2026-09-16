#!/usr/bin/env bash
# Smoke tests for hardlink/reflink helpers used by packaging and release collection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/fs-link.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
  echo "test-fs-link: $*" >&2
  exit 1
}

src_file="${TMP}/src.bin"
dest_file="${TMP}/dest.bin"
printf 'payload-%s\n' "$(date +%s)" >"${src_file}"

link_or_copy_file "${src_file}" "${dest_file}"
[[ -f "${dest_file}" ]] || fail "dest file missing after link_or_copy_file"

src_inode="$(stat -c '%i' "${src_file}" 2>/dev/null || stat -f '%i' "${src_file}")"
dest_inode="$(stat -c '%i' "${dest_file}" 2>/dev/null || stat -f '%i' "${dest_file}")"
src_dev="$(stat -c '%d' "${src_file}" 2>/dev/null || stat -f '%d' "${src_file}")"
dest_dev="$(stat -c '%d' "${dest_file}" 2>/dev/null || stat -f '%d' "${dest_file}")"
if [[ "${src_dev}" == "${dest_dev}" && "${src_inode}" != "${dest_inode}" ]]; then
  fail "expected hard-linked file on same filesystem (src=${src_inode} dest=${dest_inode})"
fi

src_tree="${TMP}/src-tree"
dest_tree="${TMP}/dest-tree"
mkdir -p "${src_tree}/nested"
printf 'tree-payload\n' >"${src_tree}/nested/blob.bin"
link_or_copy_tree "${src_tree}" "${dest_tree}"
[[ -f "${dest_tree}/nested/blob.bin" ]] || fail "dest tree missing nested blob"

src_tree_inode="$(stat -c '%i' "${src_tree}/nested/blob.bin" 2>/dev/null || stat -f '%i' "${src_tree}/nested/blob.bin")"
dest_tree_inode="$(stat -c '%i' "${dest_tree}/nested/blob.bin" 2>/dev/null || stat -f '%i' "${dest_tree}/nested/blob.bin")"
if [[ "${src_tree_inode}" != "${dest_tree_inode}" ]]; then
  fail "expected hard-linked tree blob (src=${src_tree_inode} dest=${dest_tree_inode})"
fi

echo "test-fs-link: ok"

# create_gzip_tarball must produce a readable .tar.gz (pigz or gzip).
gzip_src="${TMP}/gzip-src"
gzip_archive="${TMP}/pack.tar.gz"
mkdir -p "${gzip_src}/nested"
printf 'gzip-payload\n' >"${gzip_src}/nested/blob.bin"
create_gzip_tarball "${gzip_archive}" "${TMP}" "gzip-src"
[[ -f "${gzip_archive}" ]] || fail "gzip archive missing"
tar -tzf "${gzip_archive}" | grep -q 'gzip-src/nested/blob.bin' || fail "gzip archive missing expected entry"

echo "test-fs-link: gzip ok"
