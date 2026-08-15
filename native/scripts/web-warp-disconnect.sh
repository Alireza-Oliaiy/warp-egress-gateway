#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=web-operation-lib.sh
source "${SCRIPT_DIR}/web-operation-lib.sh"
# shellcheck source=healthcheck-lib.sh
source "${SCRIPT_DIR}/healthcheck-lib.sh"

web_operation_require_root
payload=$(web_read_bounded_input) || {
  web_emit_disconnect_failure unsafe_precondition false
  exit 0
}
if ! validated=$(printf '%s' "${payload}" | "${RUNTIME_STATE_PYTHON}" -I "${WEB_INTENT_TOOL}" validate-input 2>/dev/null); then
  web_emit_disconnect_failure unsafe_precondition false
  exit 0
fi
[[ ${validated} == '{"ok":true,"payload":'* ]] || {
  web_emit_disconnect_failure unsafe_precondition false
  exit 0
}

disconnect_consistent_locked() {
  mutation_lock_require_held || return
  [[ $(policy_routing_absence_status) == absent ]] || return 1
  ! systemctl is-active --quiet "wg-quick@${WARP_IF}.service" || return 1
  ! ip link show "${WARP_IF}" >/dev/null 2>&1 || return 1
  kill_switch_active || return 1
  healthcheck_probe_direct || return 1
  systemctl is-active --quiet warp-gateway-healthcheck.timer || return 1
  systemctl is-active --quiet warp-monitor.timer || return 1
}

disconnect_locked() {
  local intent_state writer_result main_after
  mutation_lock_require_held || return
  # Re-read the fixed root-owned configuration while holding the same lock
  # used for the complete disconnect transaction.
  load_config
  intent_state=$(intentional_disconnect_state)
  case ${intent_state} in
    valid)
      disconnect_consistent_locked || return 22
      writer_result=$("${RUNTIME_STATE_PYTHON}" -I "${WEB_INTENT_TOOL}" inspect 2>/dev/null) || return 22
      DISCONNECT_SINCE=$(sed -n 's/.*"since":"\([^"]*\)".*/\1/p' <<<"${writer_result}")
      [[ -n ${DISCONNECT_SINCE} ]] || return 22
      DISCONNECT_ALREADY=true
      return 0
      ;;
    absent) ;;
    corrupt|unsafe) return 21 ;;
    *) return 21 ;;
  esac

  kill_switch_active || return 31
  DISCONNECT_MAIN_BEFORE=$(web_main_default_snapshot) || return 31
  writer_result=$(printf '%s' "${payload}" | "${RUNTIME_STATE_PYTHON}" -I "${WEB_INTENT_TOOL}" 2>/dev/null) || return 31
  DISCONNECT_SINCE=$(sed -n 's/.*"since":"\([^"]*\)".*/\1/p' <<<"${writer_result}")
  [[ -n ${DISCONNECT_SINCE} && $(intentional_disconnect_state) == valid ]] || return 32
  DISCONNECT_INTENT_CREATED=true

  if ! policy_routing_remove_locked; then
    policy_routing_remove_locked || true
    return 32
  fi
  if ! systemctl stop "wg-quick@${WARP_IF}.service"; then
    policy_routing_remove_locked || true
    return 32
  fi

  main_after=$(web_main_default_snapshot) || return 32
  [[ ${main_after} == "${DISCONNECT_MAIN_BEFORE}" ]] || return 32
  disconnect_consistent_locked || {
    policy_routing_remove_locked || true
    return 32
  }
}

DISCONNECT_ALREADY=false
DISCONNECT_INTENT_CREATED=false
DISCONNECT_SINCE=unknown
DISCONNECT_MAIN_BEFORE=unknown
if with_mutation_lock disconnect_locked; then
  printf '{"protocol":1,"verb":"warp-disconnect","ok":true,"code":"ok","data":{"state":"intentionally_disconnected","already_disconnected":%s,"intent":{"active":true,"since":"%s"},"routing_removed":true,"wireguard_stopped":true,"killswitch":"active","transit_behavior":"blocked_by_kill_switch","main_default_changed":false,"automatic_recovery_suppressed":true,"health_timer_active":true,"monitor_timer_active":true}}\n' \
    "${DISCONNECT_ALREADY}" "${DISCONNECT_SINCE}"
else
  rc=$?
  if [[ ${DISCONNECT_INTENT_CREATED} == true ]]; then
    code=postcondition_failed
  else
    case ${rc} in
      21|22) code=intent_conflict ;;
      75) code=mutation_busy ;;
      32) code=postcondition_failed ;;
      *) code=unsafe_precondition ;;
    esac
  fi
  web_emit_disconnect_failure "${code}" "${DISCONNECT_INTENT_CREATED}"
fi
