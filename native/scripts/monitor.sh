#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
load_config

NOW=$(date +%s)
HANDSHAKE_WARN_SEC=${MONITOR_HANDSHAKE_WARN_SEC:-120}
CURL_TIMEOUT=${MONITOR_CURL_TIMEOUT:-10}
URL=${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}

WG_STATE="down"
HANDSHAKE_STATE="fail"
HANDSHAKE_AGE="none"
DIRECT_STATE="fail"
DIRECT_RC="none"
DIRECT_IP="none"
WARP_STATE="fail"
WARP_RC="none"
WARP_IP_PUBLIC="none"
WARP_COLO="none"
WARP_LOC="none"
UPSTREAM_STATE="skip"
ROUTE_STATE="fail"
NFT_STATE="fail"

if ip link show "${WARP_IF}" >/dev/null 2>&1; then
  WG_STATE="up"
  LAST_HANDSHAKE=$(wg show "${WARP_IF}" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')
  if [[ ${LAST_HANDSHAKE:-0} =~ ^[0-9]+$ ]] && (( LAST_HANDSHAKE > 0 )); then
    HANDSHAKE_AGE=$((NOW - LAST_HANDSHAKE))
    if (( HANDSHAKE_AGE <= HANDSHAKE_WARN_SEC )); then
      HANDSHAKE_STATE="ok"
    else
      HANDSHAKE_STATE="stale"
    fi
  fi
fi

UPLINK_IP=$(ip -4 -o address show dev "${UPLINK_IF}" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')
if [[ -n ${UPLINK_IP} ]]; then
  DIRECT_OUTPUT=$(curl -4 --silent --interface "${UPLINK_IP}" \
    --connect-timeout "${CURL_TIMEOUT}" --max-time "${CURL_TIMEOUT}" \
    "${URL}" 2>/dev/null)
  DIRECT_RC=$?
  if (( DIRECT_RC == 0 )); then
    DIRECT_IP=$(awk -F= '$1=="ip"{print $2}' <<<"${DIRECT_OUTPUT}")
    if [[ -n ${DIRECT_IP} ]]; then
      DIRECT_STATE="ok"
    else
      DIRECT_IP="none"
    fi
  fi
fi

WARP_IP=$(warp_ipv4_address 2>/dev/null || true)
if [[ -n ${WARP_IP} ]]; then
  WARP_OUTPUT=$(curl -4 --silent --interface "${WARP_IP}" \
    --connect-timeout "${CURL_TIMEOUT}" --max-time "${CURL_TIMEOUT}" \
    "${URL}" 2>/dev/null)
  WARP_RC=$?
  if (( WARP_RC == 0 )); then
    WARP_VALUE=$(awk -F= '$1=="warp"{print $2}' <<<"${WARP_OUTPUT}")
    WARP_IP_PUBLIC=$(awk -F= '$1=="ip"{print $2}' <<<"${WARP_OUTPUT}")
    WARP_COLO=$(awk -F= '$1=="colo"{print $2}' <<<"${WARP_OUTPUT}")
    WARP_LOC=$(awk -F= '$1=="loc"{print $2}' <<<"${WARP_OUTPUT}")
    WARP_IP_PUBLIC=${WARP_IP_PUBLIC:-none}
    WARP_COLO=${WARP_COLO:-none}
    WARP_LOC=${WARP_LOC:-none}
    if [[ ${WARP_VALUE} == "on" ]]; then
      WARP_STATE="on"
    else
      WARP_STATE=${WARP_VALUE:-fail}
    fi
  fi
fi

UPSTREAM_IP=${UPSTREAM_MONITOR_IP:-auto}
if [[ ${UPSTREAM_IP} == "off" ]]; then
  UPSTREAM_IP=""
elif [[ ${UPSTREAM_IP} == "auto" ]]; then
  UPSTREAM_IP=""
  if [[ ${TRUSTED_SOURCE_CIDR} == */32 ]]; then
    UPSTREAM_IP=${TRUSTED_SOURCE_CIDR%%/*}
  fi
fi
if [[ -n ${UPSTREAM_IP} ]]; then
  UPSTREAM_STATE="fail"
  if ping -I "${TRANSIT_IF}" -c 1 -W 1 "${UPSTREAM_IP}" >/dev/null 2>&1; then
    UPSTREAM_STATE="ok"
  fi
fi

ROUTE_OUTPUT=$(ip -4 route show table "${ROUTING_TABLE_ID}" 2>/dev/null)
if grep -qE "^default dev ${WARP_IF}([[:space:]]|$)" <<<"${ROUTE_OUTPUT}"; then
  ROUTE_STATE="ok"
fi

if nft list table inet "${NFT_TABLE}" >/dev/null 2>&1; then
  NFT_STATE="ok"
fi

STATUS="OK"
if [[ ${WG_STATE} != "up" ]] ||
   [[ ${HANDSHAKE_STATE} != "ok" ]] ||
   [[ ${DIRECT_STATE} != "ok" ]] ||
   [[ ${WARP_STATE} != "on" ]] ||
   [[ ${ROUTE_STATE} != "ok" ]] ||
   [[ ${NFT_STATE} != "ok" ]] ||
   [[ ${UPSTREAM_STATE} == "fail" ]]; then
  STATUS="FAIL"
fi

logger -t warp-monitor \
  "STATUS=${STATUS} wg=${WG_STATE} handshake=${HANDSHAKE_STATE} handshake_age=${HANDSHAKE_AGE}s direct=${DIRECT_STATE} direct_rc=${DIRECT_RC} direct_ip=${DIRECT_IP} warp=${WARP_STATE} warp_rc=${WARP_RC} warp_ip=${WARP_IP_PUBLIC} colo=${WARP_COLO} loc=${WARP_LOC} upstream=${UPSTREAM_STATE} route=${ROUTE_STATE} nft=${NFT_STATE}"

exit 0
