#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/deps-common.sh"
source "${ROOT}/pins.env"
STAGE="${ROOT}/.staging"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/payload"

EXPORT_SCRIPT=""
# Prefer sibling appliance-code checkout when present.
for candidate in \
  "${APPLIANCE_CODE_DIR:-}/scripts/package/export-host-packages.sh" \
  "$(cd "${ROOT}/../../.." && pwd)/appliance-code/scripts/package/export-host-packages.sh"
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
  echo "host-packages: set APPLIANCE_CODE_DIR to appliance-code checkout containing export-host-packages.sh" >&2
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
  --arch "${ARCH}" \
  "${cap_args[@]}"

archive="${STAGE}/host-packages.tar.zst"
tar -C "${STAGE}/payload" -cf - . | zstd -T0 -19 -o "${archive}"
sha256sum "${archive}" | awk '{print $1}' > "${STAGE}/host-packages.tar.zst.sha256"
echo "built ${archive}"
