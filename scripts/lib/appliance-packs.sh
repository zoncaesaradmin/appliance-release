#!/usr/bin/env bash
# Shared APPLIANCE_PACKS selector for product build/assemble/publish scripts.
#
# Env:
#   APPLIANCE_PACKS   CSV or single token. Default: all
#                     Values: all | base | developer | inference
#                     Examples: all ; base ; base,developer ; base,inference
#
# After appliance_packs_resolve:
#   APPLIANCE_PACKS_RESOLVED   space-separated, stable order: base [developer] [inference]
#   appliance_pack_wanted ID   returns 0 when ID is selected
#
# base is always included (required deliverable). Unknown ids fail closed.
# Compatible with Bash 3.2 (no associative arrays).

appliance_packs_resolve() {
  local raw="${APPLIANCE_PACKS-}"
  local token=""
  local want_all=0
  local want_base=0
  local want_developer=0
  local want_inference=0
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
      base)
        want_base=1
        ;;
      developer)
        want_developer=1
        ;;
      inference)
        want_inference=1
        ;;
      *)
        echo "appliance-packs: unknown pack id '${token}' (want all|base|developer|inference)" >&2
        return 2
        ;;
    esac
  done

  if [[ "${want_all}" -eq 1 ]]; then
    want_base=1
    want_developer=1
    want_inference=1
  fi

  if [[ "${want_base}" -eq 0 ]]; then
    echo "appliance-packs: including base (required)" >&2
    want_base=1
  fi

  APPLIANCE_PACKS_RESOLVED="base"
  if [[ "${want_developer}" -eq 1 ]]; then
    APPLIANCE_PACKS_RESOLVED="${APPLIANCE_PACKS_RESOLVED} developer"
  fi
  if [[ "${want_inference}" -eq 1 ]]; then
    APPLIANCE_PACKS_RESOLVED="${APPLIANCE_PACKS_RESOLVED} inference"
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
