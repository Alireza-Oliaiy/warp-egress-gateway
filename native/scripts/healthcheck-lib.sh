#!/usr/bin/env bash

HEALTHCHECK_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F policy_routing_status >/dev/null 2>&1; then
  # shellcheck source=routing.sh
  source "${HEALTHCHECK_LIB_DIR}/routing.sh"
fi

healthcheck_wireguard_ready() {
  systemctl is-active --quiet "wg-quick@${WARP_IF}.service" \
    && ip link show "${WARP_IF}" >/dev/null 2>&1 \
    && wg show "${WARP_IF}" >/dev/null 2>&1 \
    && warp_ipv4_address >/dev/null 2>&1
}

healthcheck_probe_direct() {
  local uplink_ip output timeout url
  timeout=${HEALTHCHECK_TIMEOUT:-15}
  url=${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}
  DIRECT_RC=none

  if ! uplink_ip=$(ip -4 -o address show dev "${UPLINK_IF}" scope global 2>/dev/null \
    | awk 'NR==1 {split($4,a,"/"); print a[1]}'); then
    return 1
  fi
  [[ -n ${uplink_ip} ]] || return 1

  if output=$(curl -4 --silent --show-error --fail \
    --interface "${uplink_ip}" --connect-timeout "${timeout}" \
    --max-time "${timeout}" "${url}" 2>/dev/null); then
    DIRECT_RC=0
    grep -q '^ip=' <<<"${output}"
  else
    DIRECT_RC=$?
    return 1
  fi
}

healthcheck_probe_warp() {
  local warp_ip output timeout url
  timeout=${HEALTHCHECK_TIMEOUT:-15}
  url=${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}
  WARP_RC=none

  if ! warp_ip=$(warp_ipv4_address 2>/dev/null); then
    return 1
  fi
  if output=$(curl -4 --silent --show-error --fail \
    --interface "${warp_ip}" --connect-timeout "${timeout}" \
    --max-time "${timeout}" "${url}" 2>/dev/null); then
    WARP_RC=0
    grep -q '^warp=on$' <<<"${output}"
  else
    WARP_RC=$?
    return 1
  fi
}

healthcheck_failure_reason() {
  if [[ ${NFT_STATE} != ok ]]; then
    printf 'kill_switch\n'
  elif [[ ${DIRECT_STATE} != ok ]]; then
    printf 'direct_uplink\n'
  elif [[ ${WG_STATE} != up ]]; then
    printf 'wireguard\n'
  elif [[ ${ROUTE_STATE} != ok ]]; then
    printf 'policy_routing\n'
  else
    printf 'warp_dataplane\n'
  fi
}

healthcheck_emit() {
  local health=$1 reason=$2
  printf 'HEALTH=%s state=%s reason=%s intent=%s wg=%s direct=%s direct_rc=%s warp=%s warp_rc=%s route=%s nft=%s recovery=%s\n' \
    "${health}" "${HEALTH_STATE}" "${reason}" "${INTENT_STATE}" "${WG_STATE}" \
    "${DIRECT_STATE}" "${DIRECT_RC}" "${WARP_STATE}" "${WARP_RC}" \
    "${ROUTE_STATE}" "${NFT_STATE}" "${RECOVERY_STATE}"
}

healthcheck_observe_intent() {
  if ! ROUTE_STATE=$(policy_routing_absence_status); then
    ROUTE_STATE=rule_query_failed
  fi
  WARP_STATE=off
  WARP_RC=not_run
  RECOVERY_STATE=none

  if [[ ${INTENT_STATE} == valid && ${WG_STATE} == down \
    && ${DIRECT_STATE} == ok && ${ROUTE_STATE} == absent \
    && ${NFT_STATE} == ok ]]; then
    HEALTH_STATE=intentionally_disconnected
    healthcheck_emit OK none
    return 0
  fi

  HEALTH_STATE=failed
  if [[ ${INTENT_STATE} == valid ]]; then
    healthcheck_emit FAIL intent_inconsistent
  else
    healthcheck_emit FAIL "intent_${INTENT_STATE}"
  fi
  return 1
}

healthcheck_policy_recovery_locked() {
  mutation_lock_require_held || return
  policy_routing_intent_allows_locked || return

  WG_STATE=down
  NFT_STATE=fail
  if healthcheck_wireguard_ready; then
    WG_STATE=up
  fi
  if kill_switch_active; then
    NFT_STATE=ok
  fi
  if ! ROUTE_STATE=$(policy_routing_status); then
    ROUTE_STATE=rule_query_failed
  fi
  [[ ${ROUTE_STATE} != ok && ${WG_STATE} == up && ${NFT_STATE} == ok ]] || return 1

  policy_routing_repair_locked || return
  ROUTE_STATE=$(policy_routing_status)
  [[ ${ROUTE_STATE} == ok ]] || return 1
  RECOVERY_STATE=policy
}

healthcheck_tunnel_recovery_locked() {
  local warp_ipv4
  mutation_lock_require_held || return
  policy_routing_intent_allows_locked || return

  DIRECT_STATE=fail
  NFT_STATE=fail
  if healthcheck_probe_direct; then
    DIRECT_STATE=ok
  fi
  if kill_switch_active; then
    NFT_STATE=ok
  fi
  [[ ${DIRECT_STATE} == ok && ${NFT_STATE} == ok ]] || return 1

  if systemctl restart "wg-quick@${WARP_IF}.service"; then
    sleep 3
    if healthcheck_wireguard_ready; then
      WG_STATE=up
      warp_ipv4=$(warp_ipv4_address) || return 1
      if policy_routing_apply_locked "${warp_ipv4}"; then
        ROUTE_STATE=$(policy_routing_status)
        if [[ ${ROUTE_STATE} == ok ]] && healthcheck_probe_warp; then
          WARP_STATE=on
          RECOVERY_STATE=tunnel
          return 0
        fi
      fi
    fi
  fi
  return 1
}

healthcheck_is_healthy() {
  [[ ${WG_STATE} == up && ${DIRECT_STATE} == ok && ${WARP_STATE} == on \
    && ${ROUTE_STATE} == ok && ${NFT_STATE} == ok ]]
}

healthcheck_run() {
  local auto_recover=${AUTO_RECOVER:-false} recovery_rc

  WG_STATE=down
  DIRECT_STATE=fail
  DIRECT_RC=none
  WARP_STATE=fail
  WARP_RC=none
  ROUTE_STATE=rule_query_failed
  NFT_STATE=fail
  RECOVERY_STATE=none
  HEALTH_STATE=failed
  INTENT_STATE=$(intentional_disconnect_state)

  if healthcheck_wireguard_ready; then
    WG_STATE=up
  fi
  if healthcheck_probe_direct; then
    DIRECT_STATE=ok
  fi
  if kill_switch_active; then
    NFT_STATE=ok
  fi

  if [[ ${INTENT_STATE} != absent ]]; then
    healthcheck_observe_intent
    return
  fi

  if ! ROUTE_STATE=$(policy_routing_status); then
    ROUTE_STATE=rule_query_failed
  fi

  # Project-owned policy routing is safe to restore independently of
  # AUTO_RECOVER, but only while WireGuard and the fail-closed guard are ready.
  if [[ ${ROUTE_STATE} != ok && ${WG_STATE} == up && ${NFT_STATE} == ok ]]; then
    if with_mutation_lock healthcheck_policy_recovery_locked; then
      :
    else
      recovery_rc=$?
      if [[ ${recovery_rc} -eq 20 || ${recovery_rc} -eq 21 ]]; then
        INTENT_STATE=$(intentional_disconnect_state)
        healthcheck_observe_intent
        return
      elif [[ ${recovery_rc} -eq 75 ]]; then
        RECOVERY_STATE=mutation_busy
      fi
    fi
  fi

  if [[ ${WG_STATE} == up && ${ROUTE_STATE} == ok && ${NFT_STATE} == ok ]] \
    && healthcheck_probe_warp; then
    WARP_STATE=on
  fi

  if healthcheck_is_healthy; then
    HEALTH_STATE=ok
    healthcheck_emit OK none
    return 0
  fi

  # A full tunnel restart is reserved for tunnel-specific evidence. Direct,
  # kill-switch, or unresolved policy failures cannot trigger it.
  if [[ ${auto_recover} == true && ${DIRECT_STATE} == ok && ${NFT_STATE} == ok ]] &&
    { [[ ${WG_STATE} != up ]] || [[ ${ROUTE_STATE} == ok && ${WARP_STATE} != on ]]; }; then
    if with_mutation_lock healthcheck_tunnel_recovery_locked; then
      :
    else
      recovery_rc=$?
      if [[ ${recovery_rc} -eq 20 || ${recovery_rc} -eq 21 ]]; then
        INTENT_STATE=$(intentional_disconnect_state)
        healthcheck_observe_intent
        return
      elif [[ ${recovery_rc} -eq 75 ]]; then
        RECOVERY_STATE=mutation_busy
      fi
    fi
  fi

  if healthcheck_is_healthy; then
    HEALTH_STATE=ok
    healthcheck_emit OK none
    return 0
  fi

  HEALTH_STATE=failed
  healthcheck_emit FAIL "$(healthcheck_failure_reason)"
  return 1
}
