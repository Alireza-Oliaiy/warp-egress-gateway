#!/usr/bin/env bash

ROUTING_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F warp_ipv4_address >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${ROUTING_SCRIPT_DIR}/common.sh"
fi
if ! declare -F with_mutation_lock >/dev/null 2>&1; then
  # shellcheck source=runtime-state.sh
  source "${ROUTING_SCRIPT_DIR}/runtime-state.sh"
fi

routing_diagnostic() {
  if declare -F warn >/dev/null 2>&1; then
    warn "$*"
  else
    printf 'WARNING: %s\n' "$*" >&2
  fi
}

policy_routing_status() {
  local warp_ipv4 rules source_state ingress_state routes default_state

  warp_ipv4=$(warp_ipv4_address 2>/dev/null) || {
    printf 'warp_ipv4_missing\n'
    return 0
  }

  if ! rules=$(ip -4 rule show 2>/dev/null); then
    printf 'rule_query_failed\n'
    return 0
  fi

  source_state=$(awk \
    -v priority="${SOURCE_RULE_PRIORITY}:" \
    -v source_ip="${warp_ipv4}" \
    -v table_id="${ROUTING_TABLE_ID}" \
    -v table_name="${ROUTING_TABLE_NAME:-}" '
      $1 == priority {
        count++
        table_ok = ($5 == table_id) || (table_name != "" && $5 == table_name)
        if (NF == 5 && $2 == "from" && ($3 == source_ip || $3 == source_ip "/32") && $4 == "lookup" && table_ok) {
          matches++
        }
      }
      END {
        if (count == 0) print "missing"
        else if (count == 1 && matches == 1) print "ok"
        else print "mismatch"
      }
    ' <<<"${rules}")
  if [[ ${source_state} != ok ]]; then
    printf 'source_rule_%s\n' "${source_state}"
    return 0
  fi

  ingress_state=$(awk \
    -v priority="${INGRESS_RULE_PRIORITY}:" \
    -v transit_if="${TRANSIT_IF}" \
    -v table_id="${ROUTING_TABLE_ID}" \
    -v table_name="${ROUTING_TABLE_NAME:-}" '
      $1 == priority {
        count++
        table_ok = ($7 == table_id) || (table_name != "" && $7 == table_name)
        if (NF == 7 && $2 == "from" && $3 == "all" && $4 == "iif" && $5 == transit_if && $6 == "lookup" && table_ok) {
          matches++
        }
      }
      END {
        if (count == 0) print "missing"
        else if (count == 1 && matches == 1) print "ok"
        else print "mismatch"
      }
    ' <<<"${rules}")
  if [[ ${ingress_state} != ok ]]; then
    printf 'ingress_rule_%s\n' "${ingress_state}"
    return 0
  fi

  if ! routes=$(ip -4 route show table "${ROUTING_TABLE_ID}" default 2>/dev/null); then
    printf 'default_route_query_failed\n'
    return 0
  fi
  default_state=$(awk -v warp_if="${WARP_IF}" '
    $1 == "default" {
      count++
      if ($2 == "dev" && $3 == warp_if) matches++
    }
    END {
      if (count == 0) print "missing"
      else if (count == 1 && matches == 1) print "ok"
      else print "mismatch"
    }
  ' <<<"${routes}")
  if [[ ${default_state} != ok ]]; then
    printf 'default_route_%s\n' "${default_state}"
    return 0
  fi

  printf 'ok\n'
}

policy_routing_absence_status() {
  local rules routes
  if ! rules=$(ip -4 rule show 2>/dev/null); then
    printf 'rule_query_failed\n'
    return 0
  fi
  if awk -v source_priority="${SOURCE_RULE_PRIORITY}:" \
    -v ingress_priority="${INGRESS_RULE_PRIORITY}:" \
    '$1 == source_priority || $1 == ingress_priority { found=1 } END { exit(found ? 0 : 1) }' \
    <<<"${rules}"; then
    printf 'present\n'
    return 0
  fi
  if ! routes=$(ip -4 route show table "${ROUTING_TABLE_ID}" 2>/dev/null); then
    printf 'route_query_failed\n'
    return 0
  fi
  if [[ -n ${routes//[[:space:]]/} ]]; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

kill_switch_active() {
  local rules
  if ! rules=$(nft list table inet "${NFT_TABLE}" 2>/dev/null); then
    return 1
  fi
  awk -v ingress="\"${TRANSIT_IF}\"" -v warp="\"${WARP_IF}\"" '
    /comment "WARP_KILL_SWITCH"/ {
      iif_ok = 0
      oif_ok = 0
      drop_ok = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "iifname" && $(i + 1) == ingress) iif_ok = 1
        if ($i == "oifname" && $(i + 1) == "!=" && $(i + 2) == warp) oif_ok = 1
        if ($i == "drop") drop_ok = 1
      }
      if (iif_ok && oif_ok && drop_ok) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' <<<"${rules}"
}

policy_routing_intent_allows_locked() {
  local state
  mutation_lock_require_held || return
  state=$(intentional_disconnect_state)
  INTENT_STATE=${state}
  case "${state}" in
    absent) return 0 ;;
    valid)
      routing_diagnostic "intentional_disconnect: policy-routing mutation refused"
      return 20
      ;;
    corrupt|unsafe)
      routing_diagnostic "intent_${state}: policy-routing mutation refused fail closed"
      return 21
      ;;
    *)
      routing_diagnostic "intent_unknown: policy-routing mutation refused fail closed"
      INTENT_STATE=unsafe
      return 21
      ;;
  esac
}

policy_routing_apply_locked() {
  local warp_ipv4=${1:-} state
  mutation_lock_require_held || return
  if [[ -z ${warp_ipv4} ]]; then
    warp_ipv4=$(warp_ipv4_address) || {
      routing_diagnostic "Cannot apply policy routing without an IPv4 address on ${WARP_IF}."
      return 1
    }
  fi

  ip -4 route replace default dev "${WARP_IF}" table "${ROUTING_TABLE_ID}"
  remove_rule_priority "${SOURCE_RULE_PRIORITY}"
  remove_rule_priority "${INGRESS_RULE_PRIORITY}"
  ip -4 rule add pref "${SOURCE_RULE_PRIORITY}" from "${warp_ipv4}/32" lookup "${ROUTING_TABLE_ID}"
  ip -4 rule add pref "${INGRESS_RULE_PRIORITY}" iif "${TRANSIT_IF}" lookup "${ROUTING_TABLE_ID}"
  ip -4 route flush cache

  state=$(policy_routing_status)
  if [[ ${state} != ok ]]; then
    routing_diagnostic "Policy routing verification failed after apply: ${state}."
    return 1
  fi
}

policy_routing_apply_allowed_locked() {
  mutation_lock_require_held || return
  policy_routing_intent_allows_locked || return
  policy_routing_apply_locked "${1:-}"
}

policy_routing_apply() {
  local rc
  POLICY_ROUTING_OUTCOME=failed
  if with_mutation_lock policy_routing_apply_allowed_locked "${1:-}"; then
    POLICY_ROUTING_OUTCOME=applied
    return 0
  else
    rc=$?
  fi
  return "${rc}"
}

policy_routing_activate_locked() {
  local warp_ipv4
  mutation_lock_require_held || return
  policy_routing_intent_allows_locked || {
    local rc=$?
    if [[ ${rc} -eq 20 ]]; then
      POLICY_ROUTING_OUTCOME=intentionally_disconnected
      return 0
    fi
    POLICY_ROUTING_OUTCOME="intent_${INTENT_STATE:-unsafe}"
    return "${rc}"
  }
  ip link show "${WARP_IF}" >/dev/null 2>&1 || {
    routing_diagnostic "Cannot activate policy routing: WARP interface ${WARP_IF} is down."
    return 1
  }
  kill_switch_active || {
    routing_diagnostic "Cannot activate policy routing: nftables kill switch is not active."
    return 1
  }
  warp_ipv4=$(warp_ipv4_address) || {
    routing_diagnostic "Cannot activate policy routing without an IPv4 address on ${WARP_IF}."
    return 1
  }
  policy_routing_apply_locked "${warp_ipv4}"
  POLICY_ROUTING_OUTCOME=applied
}

policy_routing_activate() {
  # shellcheck disable=SC2034 # route-up.sh consumes this sourced-library result
  POLICY_ROUTING_OUTCOME=failed
  with_mutation_lock policy_routing_activate_locked
}

policy_routing_repair_locked() {
  local state warp_ipv4
  mutation_lock_require_held || return

  ip link show "${WARP_IF}" >/dev/null 2>&1 || {
    routing_diagnostic "Policy repair refused: WARP interface ${WARP_IF} is down."
    return 1
  }
  wg show "${WARP_IF}" >/dev/null 2>&1 || {
    routing_diagnostic "Policy repair refused: WireGuard interface ${WARP_IF} is not healthy."
    return 1
  }
  warp_ipv4=$(warp_ipv4_address) || {
    routing_diagnostic "Policy repair refused: ${WARP_IF} has no IPv4 address."
    return 1
  }
  kill_switch_active || {
    routing_diagnostic "Policy repair refused: nftables kill switch is not active."
    return 1
  }

  state=$(policy_routing_status)
  if [[ ${state} == ok ]]; then
    return 0
  fi

  routing_diagnostic "Policy-routing drift detected (${state}); reapplying project-owned rules only."
  policy_routing_apply_locked "${warp_ipv4}"
}

policy_routing_repair_allowed_locked() {
  mutation_lock_require_held || return
  policy_routing_intent_allows_locked || return
  policy_routing_repair_locked
}

policy_routing_repair() {
  with_mutation_lock policy_routing_repair_allowed_locked
}

policy_routing_remove_locked() {
  mutation_lock_require_held || return
  remove_rule_priority "${INGRESS_RULE_PRIORITY}"
  remove_rule_priority "${SOURCE_RULE_PRIORITY}"
  ip -4 route flush table "${ROUTING_TABLE_ID}" 2>/dev/null || true
  ip -4 route flush cache
}

policy_routing_remove() {
  with_mutation_lock policy_routing_remove_locked
}

policy_routing_remove_for_shutdown() {
  local intent_state absence_state
  intent_state=$(intentional_disconnect_state)
  if [[ ${intent_state} == valid ]]; then
    absence_state=$(policy_routing_absence_status)
    if [[ ${absence_state} == absent ]]; then
      # The disconnect transaction already established the postcondition.
      # This systemd indirect-stop path performs no mutation and therefore
      # must not contend for the lock already held by that transaction.
      return 0
    fi
  fi
  policy_routing_remove
}
