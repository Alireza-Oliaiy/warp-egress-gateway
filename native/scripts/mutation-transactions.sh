#!/usr/bin/env bash

MUTATION_TRANSACTIONS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F warp_ipv4_address >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${MUTATION_TRANSACTIONS_DIR}/common.sh"
fi
if ! declare -F policy_routing_apply_locked >/dev/null 2>&1; then
  # shellcheck source=routing.sh
  source "${MUTATION_TRANSACTIONS_DIR}/routing.sh"
fi

route_up_transaction_locked() {
  intent_require_absent_locked || return 1
  local warp_ipv4

  ip link show "${WARP_IF}" >/dev/null 2>&1 || {
    routing_diagnostic "WARP interface ${WARP_IF} is not present."
    return 1
  }
  warp_ipv4=$(warp_ipv4_address) || {
    routing_diagnostic "No IPv4 address found on ${WARP_IF}."
    return 1
  }

  policy_routing_apply_locked "${warp_ipv4}"
  log "Policy routing enabled: ${TRANSIT_IF} -> table ${ROUTING_TABLE_ID} -> ${WARP_IF}."
}

route_down_transaction_locked() {
  intent_require_absent_locked || return 1
  remove_rule_priority "${INGRESS_RULE_PRIORITY}"
  remove_rule_priority "${SOURCE_RULE_PRIORITY}"
  ip -4 route flush table "${ROUTING_TABLE_ID}" 2>/dev/null || true
  ip -4 route flush cache

  # The firewall is intentionally left loaded. Traffic entering TRANSIT_IF
  # remains blocked from every egress except WARP_IF.
  log "Policy routing removed; kill switch remains active."
}

route_repair_transaction_locked() {
  intent_require_absent_locked || return 1
  local before after

  before=$(policy_routing_status)
  if ! policy_routing_repair_locked; then
    routing_diagnostic "Policy-routing repair failed; kill switch remains active (state=${before})."
    return 1
  fi
  after=$(policy_routing_status)
  if [[ ${after} != ok ]]; then
    routing_diagnostic "Policy-routing repair verification failed: ${after}."
    return 1
  fi

  if [[ ${before} == ok ]]; then
    log "Policy routing already matches the configured runtime state."
  else
    log "Policy routing repaired successfully (previous_state=${before})."
  fi
}

firewall_apply_transaction_locked() {
  intent_require_absent_locked || return 1
  local tcp_mss=${TCP_MSS:-1240}

  nft -f - <<EOF_NFT
destroy table inet ${NFT_TABLE}
table inet ${NFT_TABLE} {
    chain forward_mangle {
        type filter hook forward priority mangle; policy accept;
        iifname "${TRANSIT_IF}" oifname "${WARP_IF}" tcp flags syn \
            tcp option maxseg size set ${tcp_mss} \
            counter comment "WARP_MSS_CLAMP"
    }

    chain forward {
        type filter hook forward priority filter; policy accept;

        iifname "${TRANSIT_IF}" ct state invalid \
            counter drop comment "WARP_INVALID_DROP"

        iifname "${TRANSIT_IF}" meta nfproto ipv6 \
            counter drop comment "WARP_IPV6_TRANSIT_DISABLED"

        iifname "${TRANSIT_IF}" ip saddr != ${TRUSTED_SOURCE_CIDR} \
            counter drop comment "WARP_UNTRUSTED_SOURCE"

        iifname "${TRANSIT_IF}" oifname != "${WARP_IF}" \
            counter drop comment "WARP_KILL_SWITCH"

        iifname "${TRANSIT_IF}" oifname "${WARP_IF}" \
            ip saddr ${TRUSTED_SOURCE_CIDR} \
            counter accept comment "WARP_TRANSIT_ACCEPT"

        iifname "${WARP_IF}" oifname "${TRANSIT_IF}" \
            ct state established,related \
            counter accept comment "WARP_RETURN_ACCEPT"
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "${WARP_IF}" ip saddr ${TRUSTED_SOURCE_CIDR} \
            counter masquerade comment "WARP_MASQUERADE"
    }
}
EOF_NFT

  # Forwarding remains disabled until the atomic fail-closed ruleset exists.
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  log "Scoped nftables kill switch and NAT loaded in table inet ${NFT_TABLE}."
}

firewall_remove_transaction_locked() {
  intent_require_absent_locked || return 1
  nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
  log "Removed nftables table inet ${NFT_TABLE}."
}

wg_quick_command_locked() {
  /usr/bin/wg-quick "$@"
}

wg_quick_reload_command_locked() {
  local interface=$1
  /usr/bin/wg syncconf "${interface}" <(/usr/bin/wg-quick strip "${interface}")
}

wg_quick_transaction_locked() {
  intent_require_absent_locked || return 1
  local action=$1
  local interface=$2

  [[ ${action} == up || ${action} == down || ${action} == reload ]] || {
    routing_diagnostic "Invalid WireGuard lifecycle action."
    return 2
  }
  [[ ${interface} == "${WARP_IF}" ]] || {
    routing_diagnostic "WireGuard lifecycle interface mismatch."
    return 2
  }

  if [[ ${action} == reload ]]; then
    wg_quick_reload_command_locked "${interface}"
  else
    wg_quick_command_locked "${action}" "${interface}"
  fi
}
