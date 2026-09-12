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
  DIRECT_WARP_STATE=unknown

  if ! uplink_ip=$(ip -4 -o address show dev "${UPLINK_IF}" scope global 2>/dev/null \
    | awk 'NR==1 {split($4,a,"/"); print a[1]}'); then
    return 1
  fi
  [[ -n ${uplink_ip} ]] || return 1

  if output=$(curl -4 --silent --show-error --fail \
    --interface "${uplink_ip}" --connect-timeout "${timeout}" \
    --max-time "${timeout}" "${url}" 2>/dev/null); then
    DIRECT_RC=0
    if grep -qx 'warp=off' <<<"${output}"; then DIRECT_WARP_STATE=off; fi
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
  printf 'HEALTH=%s reason=%s wg=%s direct=%s direct_rc=%s warp=%s warp_rc=%s route=%s nft=%s recovery=%s\n' \
    "${health}" "${reason}" "${WG_STATE}" "${DIRECT_STATE}" "${DIRECT_RC}" \
    "${WARP_STATE}" "${WARP_RC}" "${ROUTE_STATE}" "${NFT_STATE}" "${RECOVERY_STATE}"
}

healthcheck_is_healthy() {
  [[ ${WG_STATE} == up && ${DIRECT_STATE} == ok && ${WARP_STATE} == on \
    && ${ROUTE_STATE} == ok && ${NFT_STATE} == ok ]]
}

healthcheck_reset_state() {
  INTENT_STATE=absent
  INTENT_MATCH=false
  DIRECT_WARP_STATE=unknown
  WG_STATE=down
  DIRECT_STATE=fail
  DIRECT_RC=none
  WARP_STATE=fail
  WARP_RC=none
  ROUTE_STATE=rule_query_failed
  NFT_STATE=fail
  RECOVERY_STATE=none
}

# Internal observation primitive. Callers are responsible for acquiring the
# appropriate shared or exclusive lock before entering this function.
healthcheck_observe_locked() {
  healthcheck_reset_state

  INTENT_STATE=$(intent_state_locked) || INTENT_STATE=unsafe
  if [[ ${INTENT_STATE} != absent ]]; then
    if [[ ${INTENT_STATE} == valid ]] && intent_disconnected_locked; then
      INTENT_MATCH=true
      WG_STATE=down
      ROUTE_STATE=absent
      NFT_STATE=ok
      WARP_STATE=off
      if healthcheck_probe_direct && [[ ${DIRECT_WARP_STATE} == off ]]; then
        DIRECT_STATE=ok
      fi
    fi
    return 0
  fi

  if healthcheck_wireguard_ready; then
    WG_STATE=up
  fi
  if healthcheck_probe_direct; then
    DIRECT_STATE=ok
  fi
  if kill_switch_active; then
    NFT_STATE=ok
  fi
  if ! ROUTE_STATE=$(policy_routing_status); then
    ROUTE_STATE=rule_query_failed
  fi
  if [[ ${WG_STATE} == up && ${ROUTE_STATE} == ok && ${NFT_STATE} == ok ]] \
    && healthcheck_probe_warp; then
    WARP_STATE=on
  fi
}

healthcheck_observe_upstream_locked() {
  local upstream_ip=${UPSTREAM_MONITOR_IP:-auto}

  UPSTREAM_STATE=skip
  if [[ ${upstream_ip} == off ]]; then
    return 0
  fi
  if [[ ${upstream_ip} == auto ]]; then
    upstream_ip=
    if [[ ${TRUSTED_SOURCE_CIDR} == */32 ]]; then
      upstream_ip=${TRUSTED_SOURCE_CIDR%%/*}
    fi
  fi
  [[ -n ${upstream_ip} ]] || return 0

  UPSTREAM_STATE=fail
  if ping -I "${TRANSIT_IF}" -c 1 -W 1 "${upstream_ip}" >/dev/null 2>&1; then
    UPSTREAM_STATE=ok
  fi
}

healthcheck_observe_units_locked() {
  SERVICE_STATE=fail
  TIMER_STATE=fail

  if [[ ${INTENT_MATCH:-false} == true ]]; then
    # The intent observer already proved WARP/routing units are stopped.
    if systemctl is-active --quiet warp-gateway-firewall.service; then SERVICE_STATE=ok; fi
    if systemctl is-active --quiet warp-gateway-healthcheck.timer warp-monitor.timer; then TIMER_STATE=ok; fi
    return 0
  fi

  if systemctl is-active --quiet \
    warp-gateway-firewall.service \
    "wg-quick@${WARP_IF}.service" \
    warp-gateway.service; then
    SERVICE_STATE=ok
  fi
  if systemctl is-active --quiet \
    warp-gateway-healthcheck.timer \
    warp-monitor.timer; then
    TIMER_STATE=ok
  fi
}

healthcheck_readonly_reason() {
  if [[ ${SERVICE_STATE} != ok ]]; then
    printf 'services\n'
  elif [[ ${TIMER_STATE} != ok ]]; then
    printf 'monitoring\n'
  elif [[ ${UPSTREAM_STATE} == fail ]]; then
    printf 'upstream\n'
  else
    healthcheck_failure_reason
  fi
}

healthcheck_readonly_is_healthy() {
  healthcheck_is_healthy \
    && [[ ${UPSTREAM_STATE} != fail ]] \
    && [[ ${SERVICE_STATE} == ok ]] \
    && [[ ${TIMER_STATE} == ok ]]
}

# Structurally read-only evaluator. It has no recovery mode, recovery callback,
# mutation adapter, or AUTO_RECOVER branch. Gateway failure is a completed
# evaluation and therefore returns success with HEALTH=FAIL.
healthcheck_readonly_evaluate_locked() {
  local health=FAIL reason

  healthcheck_observe_locked
  healthcheck_observe_upstream_locked
  healthcheck_observe_units_locked

  reason=$(healthcheck_readonly_reason)
  if healthcheck_readonly_is_healthy; then
    health=OK
    reason=none
  fi
  if [[ ${INTENT_STATE} != absent ]]; then
    reason=intent_unsafe
    if [[ ${INTENT_STATE} == valid ]]; then reason=intent_mismatch; fi
    if [[ ${INTENT_MATCH} == true && ${DIRECT_STATE} == ok \
        && ${SERVICE_STATE} == ok && ${TIMER_STATE} == ok && ${UPSTREAM_STATE} != fail ]]; then
      health=INTENTIONALLY_DISCONNECTED
      reason=intentionally_disconnected
    fi
  fi

  printf 'EVALUATION=completed HEALTH=%s reason=%s wg=%s direct=%s direct_rc=%s warp=%s warp_rc=%s route=%s nft=%s upstream=%s services=%s timers=%s recovery=none\n' \
    "${health}" "${reason}" "${WG_STATE}" "${DIRECT_STATE}" "${DIRECT_RC}" \
    "${WARP_STATE}" "${WARP_RC}" "${ROUTE_STATE}" "${NFT_STATE}" \
    "${UPSTREAM_STATE}" "${SERVICE_STATE}" "${TIMER_STATE}"
  return 0
}

healthcheck_policy_repair_transaction_locked() {
  intent_require_absent_locked || return 1
  if policy_routing_repair_locked; then
    ROUTE_STATE=$(policy_routing_status)
    if [[ ${ROUTE_STATE} == ok ]]; then
      RECOVERY_STATE=policy
      if healthcheck_probe_warp; then
        WARP_STATE=on
      fi
    fi
  fi
}

healthcheck_tunnel_finalize_locked() {
  intent_require_absent_locked || return 1
  local warp_ipv4

  if ! healthcheck_wireguard_ready; then
    WG_STATE=down
    return 1
  fi
  WG_STATE=up
  warp_ipv4=$(warp_ipv4_address) || return 1
  policy_routing_apply_locked "${warp_ipv4}" || return 1
  ROUTE_STATE=$(policy_routing_status)
  [[ ${ROUTE_STATE} == ok ]] || return 1
  if healthcheck_probe_warp; then
    WARP_STATE=on
    RECOVERY_STATE=tunnel
    return 0
  fi
  return 1
}

healthcheck_run() {
  local auto_recover=${AUTO_RECOVER:-false}

  if ! admin_lock_run_shared healthcheck_observe_locked; then
    healthcheck_reset_state
    healthcheck_emit FAIL observation_unavailable
    return 1
  fi

  if [[ ${INTENT_STATE} != absent ]]; then
    if [[ ${INTENT_MATCH} == true && ${DIRECT_STATE} == ok ]]; then
      healthcheck_emit INTENTIONALLY_DISCONNECTED intentionally_disconnected
      return 0
    fi
    healthcheck_emit FAIL intent_unsafe_or_mismatch
    return 1
  fi

  # Project-owned policy routing is safe to restore independently of
  # AUTO_RECOVER, but only while WireGuard and the fail-closed guard are ready.
  if [[ ${ROUTE_STATE} != ok && ${WG_STATE} == up && ${NFT_STATE} == ok ]]; then
    admin_lock_run_exclusive healthcheck_policy_repair_transaction_locked || true
  fi

  if healthcheck_is_healthy; then
    healthcheck_emit OK none
    return 0
  fi

  # A full tunnel restart is reserved for tunnel-specific evidence. Direct,
  # kill-switch, or unresolved policy failures cannot trigger it.
  if [[ ${auto_recover} == true && ${DIRECT_STATE} == ok && ${NFT_STATE} == ok ]] &&
    { [[ ${WG_STATE} != up ]] || [[ ${ROUTE_STATE} == ok && ${WARP_STATE} != on ]]; }; then
    # Recheck after the earlier observation/repair. The systemd ExecStop and
    # ExecStart wrappers independently check again under their own same-inode
    # exclusive lock, closing the decision-to-dispatch race without nesting
    # flock across systemctl (which would deadlock its unit callbacks).
    if admin_lock_run_exclusive intent_require_absent_locked \
      && systemctl restart "wg-quick@${WARP_IF}.service"; then
      sleep 3
      admin_lock_run_exclusive healthcheck_tunnel_finalize_locked || true
    fi
  fi

  if healthcheck_is_healthy; then
    healthcheck_emit OK none
    return 0
  fi

  healthcheck_emit FAIL "$(healthcheck_failure_reason)"
  return 1
}
