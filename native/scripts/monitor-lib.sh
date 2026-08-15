#!/usr/bin/env bash

MONITOR_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F policy_routing_status >/dev/null 2>&1; then
  # shellcheck source=routing.sh
  source "${MONITOR_LIB_DIR}/routing.sh"
fi

monitor_status() {
  if [[ ${INTENT_STATE:-absent} != absent ]]; then
    if [[ ${INTENT_STATE} == valid && ${WG_STATE} == down \
      && ${DIRECT_STATE} == ok && ${WARP_STATE} == off \
      && ${ROUTE_STATE} == absent && ${NFT_STATE} == ok ]]; then
      printf 'OK\n'
    else
      printf 'FAIL\n'
    fi
    return 0
  fi
  if [[ ${WG_STATE} != up ]] ||
    [[ ${DIRECT_STATE} != ok ]] ||
    [[ ${WARP_STATE} != on ]] ||
    [[ ${ROUTE_STATE} != ok ]] ||
    [[ ${NFT_STATE} != ok ]] ||
    [[ ${UPSTREAM_STATE} == fail ]]; then
    printf 'FAIL\n'
  elif [[ ${HANDSHAKE_STATE} != ok ]]; then
    # An active trace reporting warp=on is stronger current dataplane evidence
    # than a passive WireGuard handshake timestamp.
    printf 'WARN\n'
  else
    printf 'OK\n'
  fi
}

monitor_sample() {
  local now handshake_warn_sec curl_timeout url
  local wg_state handshake_state handshake_age last_handshake
  local direct_state direct_rc direct_ip direct_output uplink_ip
  local warp_state warp_rc warp_ip_public warp_colo warp_loc
  local warp_ip warp_output warp_value
  local upstream_state upstream_ip route_state nft_state status state intent_state

  now=$(date +%s)
  handshake_warn_sec=${MONITOR_HANDSHAKE_WARN_SEC:-120}
  curl_timeout=${MONITOR_CURL_TIMEOUT:-10}
  url=${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}

  wg_state=down
  handshake_state=none
  handshake_age=none
  direct_state=fail
  direct_rc=none
  direct_ip=none
  warp_state=fail
  warp_rc=none
  warp_ip_public=none
  warp_colo=none
  warp_loc=none
  upstream_state=skip
  route_state=rule_query_failed
  nft_state=fail
  intent_state=$(intentional_disconnect_state)

  if ip link show "${WARP_IF}" >/dev/null 2>&1; then
    wg_state=up
    if last_handshake=$(wg show "${WARP_IF}" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}'); then
      if [[ ${last_handshake:-0} =~ ^[0-9]+$ ]] && (( last_handshake > 0 )); then
        handshake_age=$((now - last_handshake))
        if (( handshake_age <= handshake_warn_sec )); then
          handshake_state=ok
        else
          handshake_state=stale
        fi
      fi
    fi
  fi

  if uplink_ip=$(ip -4 -o address show dev "${UPLINK_IF}" scope global 2>/dev/null \
    | awk 'NR==1 {split($4,a,"/"); print a[1]}'); then
    if [[ -n ${uplink_ip} ]]; then
      if direct_output=$(curl -4 --silent --interface "${uplink_ip}" \
        --connect-timeout "${curl_timeout}" --max-time "${curl_timeout}" \
        "${url}" 2>/dev/null); then
        direct_rc=0
        direct_ip=$(awk -F= '$1=="ip"{print $2}' <<<"${direct_output}")
        if [[ -n ${direct_ip} ]]; then
          direct_state=ok
        else
          direct_ip=none
        fi
      else
        direct_rc=$?
      fi
    fi
  fi

  if [[ ${intent_state} == absent ]] && warp_ip=$(warp_ipv4_address 2>/dev/null); then
    if warp_output=$(curl -4 --silent --interface "${warp_ip}" \
      --connect-timeout "${curl_timeout}" --max-time "${curl_timeout}" \
      "${url}" 2>/dev/null); then
      warp_rc=0
      warp_value=$(awk -F= '$1=="warp"{print $2}' <<<"${warp_output}")
      warp_ip_public=$(awk -F= '$1=="ip"{print $2}' <<<"${warp_output}")
      warp_colo=$(awk -F= '$1=="colo"{print $2}' <<<"${warp_output}")
      warp_loc=$(awk -F= '$1=="loc"{print $2}' <<<"${warp_output}")
      warp_ip_public=${warp_ip_public:-none}
      warp_colo=${warp_colo:-none}
      warp_loc=${warp_loc:-none}
      if [[ ${warp_value} == on ]]; then
        warp_state=on
      else
        warp_state=${warp_value:-fail}
      fi
    else
      warp_rc=$?
    fi
  fi

  if [[ ${intent_state} != absent ]]; then
    warp_state=off
    warp_rc=not_run
  fi

  upstream_ip=${UPSTREAM_MONITOR_IP:-auto}
  if [[ ${intent_state} != absent ]]; then
    upstream_ip=off
  fi
  if [[ ${upstream_ip} == off ]]; then
    upstream_ip=
  elif [[ ${upstream_ip} == auto ]]; then
    upstream_ip=
    if [[ ${TRUSTED_SOURCE_CIDR} == */32 ]]; then
      upstream_ip=${TRUSTED_SOURCE_CIDR%%/*}
    fi
  fi
  if [[ -n ${upstream_ip} ]]; then
    upstream_state=fail
    if ping -I "${TRANSIT_IF}" -c 1 -W 1 "${upstream_ip}" >/dev/null 2>&1; then
      upstream_state=ok
    fi
  fi

  if [[ ${intent_state} == absent ]]; then
    if ! route_state=$(policy_routing_status); then
      route_state=rule_query_failed
    fi
  elif ! route_state=$(policy_routing_absence_status); then
    route_state=rule_query_failed
  fi
  if kill_switch_active; then
    nft_state=ok
  fi

  # Bash functions use dynamic scoping, so monitor_status sees these locals.
  WG_STATE=${wg_state}
  HANDSHAKE_STATE=${handshake_state}
  DIRECT_STATE=${direct_state}
  WARP_STATE=${warp_state}
  ROUTE_STATE=${route_state}
  NFT_STATE=${nft_state}
  UPSTREAM_STATE=${upstream_state}
  INTENT_STATE=${intent_state}
  status=$(monitor_status)

  if [[ ${intent_state} == valid && ${status} == OK ]]; then
    state=intentionally_disconnected
  else
    case "${status}" in
      OK) state=ok ;;
      WARN) state=degraded ;;
      *) state=failed ;;
    esac
  fi

  printf 'STATUS=%s state=%s intent=%s wg=%s handshake=%s handshake_age=%ss direct=%s direct_rc=%s direct_ip=%s warp=%s warp_rc=%s warp_ip=%s colo=%s loc=%s upstream=%s route=%s nft=%s\n' \
    "${status}" "${state}" "${intent_state}" "${wg_state}" "${handshake_state}" "${handshake_age}" \
    "${direct_state}" "${direct_rc}" "${direct_ip}" "${warp_state}" \
    "${warp_rc}" "${warp_ip_public}" "${warp_colo}" "${warp_loc}" \
    "${upstream_state}" "${route_state}" "${nft_state}"
  return 0
}
