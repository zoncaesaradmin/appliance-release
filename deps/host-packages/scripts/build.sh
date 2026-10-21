#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/target-arch.sh"
target_arch_resolve
STAGE="${ROOT}/.staging"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/payload"

EXPORT_SCRIPT=""
# Resolve the same appliance-code checkout used by the release workflow.  A
# standalone seed run should not require an operator to rediscover that path:
# the standard build-host layout is <workspace>/appliance-build/repos while a
# developer checkout normally keeps appliance-code beside appliance-release.
RELEASE_REPO_DIR="$(cd "${ROOT}/../.." && pwd)"
WORKSPACE_PARENT="$(dirname "${RELEASE_REPO_DIR}")"
WORKSPACE_GRANDPARENT="$(dirname "${WORKSPACE_PARENT}")"
# Prefer an explicit path, then the build-flow root, then the two documented
# local workspace layouts. Every candidate is checked before use.
for candidate in \
  "${APPLIANCE_CODE_DIR:-}/scripts/package/export-host-packages.sh" \
  "${RELEASE_WORK_ROOT:-}/repos/appliance-code/scripts/package/export-host-packages.sh" \
  "${WORKSPACE_PARENT}/appliance-code/scripts/package/export-host-packages.sh" \
  "${WORKSPACE_PARENT}/appliance-build/repos/appliance-code/scripts/package/export-host-packages.sh" \
  "${WORKSPACE_GRANDPARENT}/appliance-build/repos/appliance-code/scripts/package/export-host-packages.sh"
do
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    EXPORT_SCRIPT="${candidate}"
    break
  elif [[ -n "${candidate}" && -f "${candidate}" ]]; then
    EXPORT_SCRIPT="${candidate}"
    break
  fi
done

if [[ -z "${EXPORT_SCRIPT}" ]]; then
  echo "host-packages: could not find appliance-code; set APPLIANCE_CODE_DIR to a checkout containing export-host-packages.sh" >&2
  exit 2
fi
echo "host-packages: using ${EXPORT_SCRIPT}"

# Fail closed with a clear sync hint if the sibling tree is older than arm64 support.
if grep -q 'only amd64 is supported' "${EXPORT_SCRIPT}" 2>/dev/null; then
  echo "host-packages: ${EXPORT_SCRIPT} is amd64-only; update appliance-code (main has arm64) and re-run" >&2
  exit 2
fi

IFS=',' read -r -a caps <<< "${CAPABILITIES}"
cap_args=()
for c in "${caps[@]}"; do
  c="$(printf '%s' "${c}" | tr -d '[:space:]')"
  [[ -z "${c}" ]] && continue
  cap_args+=(--capability "${c}")
done

bash "${EXPORT_SCRIPT}" \
  --out-dir "${STAGE}/payload" \
  --os-version "${OS_VERSION}" \
  --arch "${TARGET_ARCH}" \
  "${cap_args[@]}"

archive="${STAGE}/host-packages.tar.zst"
tar -C "${STAGE}/payload" -cf - . | zstd -T0 -19 -o "${archive}"
sha256sum "${archive}" | awk '{print $1}' > "${STAGE}/host-packages.tar.zst.sha256"
echo "built ${archive}"
