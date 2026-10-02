#!/usr/bin/env bash
# join-cluster-nodes-from-devhost.sh — Mac/devhost side (members and extra primes).
#
# After the advertised prime is installed, enrolls each additional host from
# that prime, copies the enrollment offline through this machine, runs
# install-release.sh cluster-join on the joining host, then registers the
# node on the prime. Client HTTPS and mDNS stay on the first prime.
set -euo pipefail
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
usage: join-cluster-nodes-from-devhost.sh \
  --config PATH \
  --build-publish-config PATH \
  --install-config PATH

No-op for a single implicit prime. For prime,member (and three-prime HA)
enrolls, joins, and registers each extra host using the same signed bundle
as the advertised prime.
EOF
}

DEVHOST_CONFIG=""
BUILD_PUBLISH_CONFIG=""
INSTALL_CONFIG=""
RUN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      DEVHOST_CONFIG="${2:-}"
      shift 2
      ;;
    --build-publish-config)
      BUILD_PUBLISH_CONFIG="${2:-}"
      shift 2
      ;;
    --install-config)
      INSTALL_CONFIG="${2:-}"
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
      fail "unknown argument: $1 (see --help)"
      ;;
  esac
done

[[ -n "${DEVHOST_CONFIG}" ]] || fail "requires --config PATH"
[[ -n "${BUILD_PUBLISH_CONFIG}" ]] || fail "requires --build-publish-config PATH"
[[ -n "${INSTALL_CONFIG}" ]] || fail "requires --install-config PATH"

DEVHOST_CONFIG="$(require_config_path "${DEVHOST_CONFIG}")"
BUILD_PUBLISH_CONFIG="$(require_config_path "${BUILD_PUBLISH_CONFIG}")"
INSTALL_CONFIG="$(require_config_path "${INSTALL_CONFIG}")"

require_cmd ssh
require_cmd scp
require_cmd python3

parse_target_host_cluster "${DEVHOST_CONFIG}"
if [[ "${TARGET_CLUSTER_KIND}" == "single" ]]; then
  log "cluster-join: single prime; nothing to enroll"
  exit 0
fi

RELEASE_VERSION=""
if [[ -n "${PRODUCT_VERSION:-}" ]]; then
  RELEASE_VERSION="${PRODUCT_VERSION}"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(config_get_optional "${BUILD_PUBLISH_CONFIG}" "release.version" || true)"
fi
if [[ -z "${RELEASE_VERSION}" ]]; then
  RELEASE_VERSION="$(read_default_product_version "$(skill_release_repo_root "${SCRIPT_DIR}")")"
fi
readonly PATH_PREFIX="appliance"
BUNDLE_MODE="$(resolve_bundle_store_mode "${BUILD_PUBLISH_CONFIG}")"
APPLIANCE_NAME="$(config_get "${INSTALL_CONFIG}" "install.appliance_name")"
APPLIANCE_PROFILE="$(config_get_optional "${INSTALL_CONFIG}" "install.appliance_profile" || true)"
if [[ -z "${APPLIANCE_PROFILE}" ]]; then
  APPLIANCE_PROFILE="core"
fi
DNS_ZONE="$(config_get_optional "${INSTALL_CONFIG}" "install.dns_zone" || true)"
DNS_ZONE="$(printf '%s' "${DNS_ZONE}" | tr -d '[:space:]')"
[[ -n "${DNS_ZONE}" ]] || fail "install.dns_zone is required in install config"

resolve_install_extra_tls_sans "${INSTALL_CONFIG}"
append_cluster_alias_tls_sans
resolve_install_image_pull_registry "${INSTALL_CONFIG}"

OUT_DIR="$(config_get_optional "${INSTALL_CONFIG}" "install.bundle_download_dir" || true)"
OUT_DIR="$(printf '%s' "${OUT_DIR}" | tr -d '[:space:]')"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="/tmp/appliance-${RELEASE_VERSION}"
fi

BASE_URL=""
BEARER_TOKEN=""
TLS_INSECURE="0"
case "${BUNDLE_MODE}" in
  static_http)
    BASE_URL="$(resolve_static_http_base_url "${BUILD_PUBLISH_CONFIG}")"
    ;;
  appliance_files)
    BASE_URL="$(resolve_appliance_files_base_url "${BUILD_PUBLISH_CONFIG}")"
    token_env="$(bundle_store_get_optional "${BUILD_PUBLISH_CONFIG}" "token_env" || true)"
    if [[ -z "${token_env}" ]]; then
      token_env="DEV_REGISTRY_TOKEN"
    fi
    BEARER_TOKEN="$(resolve_secret "${token_env}" "Bundle store token (${token_env})")"
    tls_env="$(bundle_store_get_optional "${BUILD_PUBLISH_CONFIG}" "tls_verify_env" || true)"
    if [[ -z "${tls_env}" ]]; then
      tls_env="DEV_REGISTRY_TLS_VERIFY"
    fi
    tls_verify="$(resolve_env_value "${tls_env}" "Bundle store TLS verify (${tls_env})")"
    case "$(printf '%s' "${tls_verify}" | tr '[:upper:]' '[:lower:]')" in
      0|false|no|off) TLS_INSECURE="1" ;;
      *) TLS_INSECURE="0" ;;
    esac
    ;;
  *)
    fail "unsupported bundle_store.mode: ${BUNDLE_MODE}"
    ;;
esac

LOCAL_HELPER="$(skill_release_repo_root "${SCRIPT_DIR}")/scripts/install-release.sh"
[[ -f "${LOCAL_HELPER}" ]] || fail "local install helper missing: ${LOCAL_HELPER}"
SCRIPT_PATH="/tmp/install-release-${RELEASE_VERSION}.sh"
REMOTE_ENROLLMENT="/tmp/appliance-join.enrollment"

if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(default_release_run_dir)"
fi
ensure_release_run_dirs "${RUN_DIR}"
mkdir -p "${RUN_DIR}/enrollments"
join_log="${RUN_DIR}/logs/target-cluster-join.log"

target_sudo_password="$(resolve_secret "APPLIANCE_TARGET_SUDO_PASSWORD" "Target host sudo password")"
quoted_sudo_password="$(shell_quote "${target_sudo_password}")"
CONTROL_ENDPOINT="$(target_prime_control_endpoint)"
log "cluster-join kind=${TARGET_CLUSTER_KIND} prime=${TARGET_PRIME_HOST} endpoint=${CONTROL_ENDPOINT}"
emit_cluster_join_plan | tee -a "${join_log}"

image_pull_exports=""
sudo_preserve=""
if [[ -n "${IMAGE_PULL_REGISTRY}" ]]; then
  image_pull_exports+="${IMAGE_PULL_USERNAME_ENV}=$(shell_quote "${IMAGE_PULL_USERNAME}") export ${IMAGE_PULL_USERNAME_ENV}; "
  image_pull_exports+="${IMAGE_PULL_TOKEN_ENV}=$(shell_quote "${IMAGE_PULL_TOKEN}") export ${IMAGE_PULL_TOKEN_ENV}; "
  if [[ -n "${IMAGE_PULL_TLS_VERIFY_ENV}" ]]; then
    image_pull_exports+="${IMAGE_PULL_TLS_VERIFY_ENV}=$(shell_quote "${IMAGE_PULL_TLS_VERIFY}") export ${IMAGE_PULL_TLS_VERIFY_ENV}; "
  fi
  sudo_preserve=" --preserve-env=$(shell_quote "${IMAGE_PULL_PRESERVE_ENV}")"
fi

enroll_and_join_host() {
  local alias="$1"
  local enroll_role="$2"
  local register_role="$3"
  local node_name enrollment_remote enrollment_local enroll_json fingerprint
  node_name="$(target_node_name_from_alias "${alias}")"
  enrollment_remote="/tmp/appliance-enroll-${node_name}.enrollment"
  enrollment_local="${RUN_DIR}/enrollments/${node_name}.enrollment"
  enroll_json="${RUN_DIR}/metadata/enrollment-${node_name}.json"

  log "enrolling ${enroll_role} ${alias} as ${node_name}"
  if ! run_ssh_captured "${TARGET_PRIME_HOST}" "${join_log}" "set -euo pipefail
printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' -v >/dev/null
sudo -n zonctl cluster-enrollment-create --output json \
  --worker-name $(shell_quote "${node_name}") \
  --worker-role $(shell_quote "${enroll_role}") \
  --control-endpoint $(shell_quote "${CONTROL_ENDPOINT}") \
  --enrollment-out $(shell_quote "${enrollment_remote}")
"; then
    fail "cluster-enrollment-create failed for ${node_name}; see ${join_log}"
  fi
  python3 - "${join_log}" "${enroll_json}" <<'PY'
import json
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
text = log_path.read_text(encoding="utf-8")
payload = None
for line in reversed(text.splitlines()):
    line = line.strip()
    if line.startswith("{") and '"signerFingerprint"' in line:
        payload = json.loads(line)
        break
if not payload:
    raise SystemExit("enrollment JSON with signerFingerprint not found in join log")
data = payload.get("data") or {}
if not data.get("signerFingerprint"):
    raise SystemExit("enrollment JSON missing signerFingerprint")
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(data["signerFingerprint"])
PY
  fingerprint="$(python3 - "${enroll_json}" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["data"]["signerFingerprint"])
PY
)"
  [[ -n "${fingerprint}" ]] || fail "missing enrollment signer fingerprint for ${node_name}"

  scp -q "${TARGET_PRIME_HOST}:${enrollment_remote}" "${enrollment_local}"
  scp -q "${enrollment_local}" "${alias}:${REMOTE_ENROLLMENT}"
  scp -q "${LOCAL_HELPER}" "${alias}:${SCRIPT_PATH}"
  rm -f "${enrollment_local}"

  log "joining ${alias} as ${node_name}"
  local remote_cmd="set -euo pipefail
script_path=$(shell_quote "${SCRIPT_PATH}")
enrollment_path=$(shell_quote "${REMOTE_ENROLLMENT}")
base_url=$(shell_quote "${BASE_URL}")
bearer=$(shell_quote "${BEARER_TOKEN}")
tls_insecure=$(shell_quote "${TLS_INSECURE}")
version=$(shell_quote "${RELEASE_VERSION}")
prefix=$(shell_quote "${PATH_PREFIX}")
name=$(shell_quote "${APPLIANCE_NAME}")
profile=$(shell_quote "${APPLIANCE_PROFILE}")
dns_zone=$(shell_quote "${DNS_ZONE}")
extra_tls_sans=$(shell_quote "${EXTRA_TLS_SANS}")
node_name=$(shell_quote "${node_name}")
signer=$(shell_quote "${fingerprint}")
out_dir=$(shell_quote "${OUT_DIR}")
image_pull_registry=$(shell_quote "${IMAGE_PULL_REGISTRY}")
image_pull_username_env=$(shell_quote "${IMAGE_PULL_USERNAME_ENV}")
image_pull_token_env=$(shell_quote "${IMAGE_PULL_TOKEN_ENV}")
image_pull_tls_verify_env=$(shell_quote "${IMAGE_PULL_TLS_VERIFY_ENV}")
${image_pull_exports}

if command -v zonctl >/dev/null 2>&1; then
  echo \"uninstalling existing appliance before cluster join\"
  printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' zonctl uninstall --confirm yes
elif [[ -x /usr/local/bin/zonctl ]]; then
  echo \"uninstalling existing appliance before cluster join\"
  printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' /usr/local/bin/zonctl uninstall --confirm yes
fi

chmod +x \"\${script_path}\"
chmod 600 \"\${enrollment_path}\"

python3 - \"\${script_path}\" \"\${base_url}\" \"\${bearer}\" \"\${tls_insecure}\" \"\${version}\" \"\${prefix}\" \"\${dns_zone}\" \"\${extra_tls_sans}\" \"\${out_dir}\" \"\${image_pull_registry}\" \"\${image_pull_username_env}\" \"\${image_pull_token_env}\" \"\${image_pull_tls_verify_env}\" \"\${node_name}\" \"\${enrollment_path}\" \"\${signer}\" <<'PY'
from pathlib import Path
import json
import re
import sys

(
    path,
    base_url,
    bearer,
    tls_insecure,
    version,
    prefix,
    dns_zone,
    extra_tls_sans,
    out_dir,
    image_pull_registry,
    image_pull_username_env,
    image_pull_token_env,
    image_pull_tls_verify_env,
    node_name,
    enrollment_path,
    signer,
) = sys.argv[1:17]
text = Path(path).read_text(encoding=\"utf-8\")

def set_assign(text, name, value):
    pat = re.compile(r\"^\" + re.escape(name) + r\"=.*$\", re.M)
    repl = f\"{name}={json.dumps(value)}\"
    if pat.search(text):
        return pat.sub(repl, text, count=1)
    return text + (\"\" if text.endswith(\"\\n\") else \"\\n\") + repl + \"\\n\"

text = set_assign(text, \"BASE_URL_EMBEDDED\", base_url)
text = set_assign(text, \"BASE_URL\", base_url)
text = set_assign(text, \"PRODUCT_VERSION_EMBEDDED\", version)
text = set_assign(text, \"PRODUCT_VERSION\", version)
text = set_assign(text, \"PATH_PREFIX_EMBEDDED\", prefix)
text = set_assign(text, \"PATH_PREFIX\", prefix)
text = set_assign(text, \"BEARER_TOKEN\", bearer)
text = set_assign(text, \"TLS_INSECURE\", tls_insecure)
text = set_assign(text, \"DNS_ZONE\", dns_zone)
text = set_assign(text, \"EXTRA_TLS_SANS\", extra_tls_sans)
text = set_assign(text, \"OUT_DIR\", out_dir)
text = set_assign(text, \"IMAGE_PULL_REGISTRY\", image_pull_registry)
text = set_assign(text, \"IMAGE_PULL_USERNAME_ENV\", image_pull_username_env)
text = set_assign(text, \"IMAGE_PULL_TOKEN_ENV\", image_pull_token_env)
text = set_assign(text, \"IMAGE_PULL_TLS_VERIFY_ENV\", image_pull_tls_verify_env)
text = set_assign(text, \"NODE_NAME\", node_name)
text = set_assign(text, \"CLUSTER_INIT\", \"0\")
text = set_assign(text, \"JOIN_ENROLLMENT_FILE\", enrollment_path)
text = set_assign(text, \"CLUSTER_SIGNER_FINGERPRINT\", signer)
Path(path).write_text(text, encoding=\"utf-8\")
PY

echo \"running install-release.sh cluster-join as \${node_name}\"
printf '%s\\n' ${quoted_sudo_password} | sudo -S -p ''${sudo_preserve} bash \"\${script_path}\" --appliance-name \"\${name}\" --appliance-profile \"\${profile}\"
rm -f \"\${enrollment_path}\"
"

  if ! run_ssh_logged "${alias}" "${join_log}" "${remote_cmd}"; then
    fail "cluster join failed on ${alias}; see ${join_log}"
  fi

  log "registering ${node_name} as ${register_role} on advertised prime"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if run_ssh_captured "${TARGET_PRIME_HOST}" "${join_log}" "set -euo pipefail
printf '%s\\n' ${quoted_sudo_password} | sudo -S -p '' -v >/dev/null
sudo -n zonctl cluster-node-register --output json \
  --worker-name $(shell_quote "${node_name}") \
  --worker-role $(shell_quote "${register_role}")
"; then
      return 0
    fi
    sleep 6
  done
  fail "cluster-node-register failed for ${node_name}; see ${join_log}"
}

while IFS= read -r alias; do
  [[ -n "${alias}" ]] || continue
  enroll_and_join_host "${alias}" "prime" "prime"
done <<<"${TARGET_PEER_PRIME_ALIASES:-}"

while IFS= read -r alias; do
  [[ -n "${alias}" ]] || continue
  enroll_and_join_host "${alias}" "worker" "worker"
done <<<"${TARGET_MEMBER_ALIASES:-}"

log "cluster join finished; log: ${join_log}"
