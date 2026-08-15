#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=web-operation-lib.sh
source "${SCRIPT_DIR}/web-operation-lib.sh"

web_operation_require_root
load_config
if ! web_require_empty_input; then
  web_emit_failure routing-repair unsafe_precondition
  exit 0
fi

repair_locked() {
  local main_before main_after nft_before nft_after wg_before wg_after
  mutation_lock_require_held || return
  policy_routing_intent_allows_locked || return
  REPAIR_BEFORE=$(policy_routing_status)
  main_before=$(web_main_default_snapshot) || return 31
  nft_before=$(web_nft_snapshot) || return 31
  wg_before=$(web_wg_activation_snapshot) || return 31
  policy_routing_repair_locked || return 31
  REPAIR_AFTER=$(policy_routing_status)
  main_after=$(web_main_default_snapshot) || return 31
  nft_after=$(web_nft_snapshot) || return 31
  wg_after=$(web_wg_activation_snapshot) || return 31
  [[ ${REPAIR_AFTER} == ok ]] || return 32
  [[ ${main_after} == "${main_before}" ]] || return 32
  [[ ${nft_after} == "${nft_before}" ]] || return 32
  [[ ${wg_after} == "${wg_before}" ]] || return 32
}

REPAIR_BEFORE=unknown
REPAIR_AFTER=unknown
if with_mutation_lock repair_locked; then
  changed=true
  [[ ${REPAIR_BEFORE} == ok ]] && changed=false
  printf '{"protocol":1,"verb":"routing-repair","ok":true,"code":"ok","data":{"state":"ok","changed":%s,"before":"%s","after":"ok","wireguard_restarted":false,"killswitch_changed":false,"main_default_changed":false}}\n' \
    "${changed}" "${REPAIR_BEFORE}"
else
  rc=$?
  case ${rc} in
    20|21) code=intent_conflict ;;
    75) code=mutation_busy ;;
    32) code=postcondition_failed ;;
    *) code=unsafe_precondition ;;
  esac
  web_emit_failure routing-repair "${code}"
fi
