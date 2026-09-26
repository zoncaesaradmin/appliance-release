#!/usr/bin/env bash
# Shared APPLIANCE_PACKS selector for product build/assemble/publish scripts.
#
# Env:
#   APPLIANCE_PACKS   CSV or single token. Default: all
#                     Values: all | foundation | dev-platform | deviceuser | std-llm | acc-llm | open-webui
#                     Examples: all ; foundation ; foundation,dev-platform ; foundation,acc-llm
#                     Chat showcase: foundation,std-llm,open-webui
#
# After appliance_packs_resolve:
#   APPLIANCE_PACKS_RESOLVED   space-separated, stable order:
#     foundation [dev-platform] [deviceuser] [std-llm|acc-llm] [open-webui]
#   appliance_pack_wanted ID   returns 0 when ID is selected
#
# foundation is always included (required deliverable). Unknown ids fail closed.
# open-webui requires std-llm or acc-llm in the same selection.
# Compatible with Bash 3.2 (no associative arrays).
# Pack id is "foundation" (not "base") so it does not collide with capability "base".
# Architecture is product-level (TARGET_ARCH), not encoded in pack IDs.

appliance_packs_resolve() {
  local raw="${APPLIANCE_PACKS-}"
  local token=""
  local want_all=0
  local want_foundation=0
  local want_dev_platform=0
  local want_deviceuser=0
  local want_std_llm=0
  local want_acc_llm=0
  local want_open_webui=0
  local IFS=','

  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ -z "${raw}" ]]; then
    raw="all"
  fi
  APPLIANCE_PACKS="${raw}"

  # shellcheck disable=SC2086
  set -- ${raw}
  for token in "$@"; do
    [[ -n "${token}" ]] || continue
    case "${token}" in
      all)
        want_all=1
        ;;
      foundation)
        want_foundation=1
        ;;
      dev-platform)
        want_dev_platform=1
        ;;
      deviceuser)
        want_deviceuser=1
        ;;
      std-llm)
        want_std_llm=1
        ;;
      acc-llm)
        want_acc_llm=1
        ;;
      open-webui)
        want_open_webui=1
        ;;
      std-llm-amd64|acc-llm-amd64|acc-llm-arm64)
        echo "appliance-packs: pack id '${token}' was renamed; use std-llm or acc-llm (architecture is TARGET_ARCH)" >&2
        return 2
        ;;
      inference)
        echo "appliance-packs: pack id 'inference' was renamed to 'std-llm' (capability 'inference')" >&2
        return 2
        ;;
      base)
        echo "appliance-packs: pack id 'base' was renamed to 'foundation' (capability 'base' is unchanged)" >&2
        return 2
        ;;
      *)
        echo "appliance-packs: unknown pack id '${token}' (want all|foundation|dev-platform|deviceuser|std-llm|acc-llm|open-webui)" >&2
        return 2
        ;;
    esac
  done

  if [[ "${want_all}" -eq 1 ]]; then
    want_foundation=1
    want_dev_platform=1
    want_deviceuser=1
    want_std_llm=1
    # open-webui stays opt-in even for "all": integrated SKUs are inference-capable
    # without the temporary chat UI; showcase builds add open-webui explicitly.
  fi

  if (( want_std_llm + want_acc_llm > 1 )); then
    echo "appliance-packs: select only one inference runtime pack" >&2
    return 2
  fi

  if [[ "${want_open_webui}" -eq 1 ]] && (( want_std_llm + want_acc_llm < 1 )); then
    echo "appliance-packs: open-webui requires std-llm or acc-llm in APPLIANCE_PACKS" >&2
    return 2
  fi

  if [[ "${want_foundation}" -eq 0 ]]; then
    echo "appliance-packs: including foundation (required)" >&2
    want_foundation=1
  fi

  APPLIANCE_PACKS_RESOLVED="foundation"
  if [[ "${want_dev_platform}" -eq 1 ]]; then
    APPLIANCE_PACKS_RESOLVED="${APPLIANCE_PACKS_RESOLVED} dev-platform"
  fi
  if [[ "${want_deviceuser}" -eq 1 ]]; then
    APPLIANCE_PACKS_RESOLVED="${APPLIANCE_PACKS_RESOLVED} deviceuser"
  fi
  if [[ "${want_std_llm}" -eq 1 ]]; then
    APPLIANCE_PACKS_RESOLVED="${APPLIANCE_PACKS_RESOLVED} std-llm"
  fi
  if [[ "${want_acc_llm}" -eq 1 ]]; then
    APPLIANCE_PACKS_RESOLVED="${APPLIANCE_PACKS_RESOLVED} acc-llm"
  fi
  if [[ "${want_open_webui}" -eq 1 ]]; then
    APPLIANCE_PACKS_RESOLVED="${APPLIANCE_PACKS_RESOLVED} open-webui"
  fi

  export APPLIANCE_PACKS
  export APPLIANCE_PACKS_RESOLVED
}

appliance_pack_wanted() {
  local id="$1"
  local item=""
  # shellcheck disable=SC2086
  for item in ${APPLIANCE_PACKS_RESOLVED:-}; do
    if [[ "${item}" == "${id}" ]]; then
      return 0
    fi
  done
  return 1
}

# True when catalog-derived PACK_REQUIRED_ARTIFACTS includes the artifact id.
pack_artifact_needed() {
  local id="$1"
  local item=""
  # shellcheck disable=SC2086
  for item in ${PACK_REQUIRED_ARTIFACTS:-}; do
    if [[ "${item}" == "${id}" ]]; then
      return 0
    fi
  done
  return 1
}
