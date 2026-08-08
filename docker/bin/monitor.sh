#!/usr/bin/env bash
set -u

CONFIG_FILE=/etc/warp-egress-gateway/warp-gateway.env
[[ -r ${CONFIG_FILE} ]] || { echo "STATUS=FAIL reason=config_missing"; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

NOW=$(date +%s)
HANDSHAKE_WARN_SEC=${MONITOR_HANDSHAKE_WARN_SEC:-120}
CURL_TIMEOUT=${MONITOR_CURL_TIMEOUT:-10}
URL=${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}

WG_STATE="down"
HANDSHAKE_STATE="none"
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
    [[ -n ${DIRECT_IP} ]] && DIRECT_STATE="ok" || DIRECT_IP="none"
  fi
fi

WARP_IP=$(ip -4 -o address show dev "${WARP_IF}" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')
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
    [[ ${WARP_VALUE} == "on" ]] && WARP_STATE="on" || WARP_STATE=${WARP_VALUE:-fail}
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
  ping -I "${TRANSIT_IF}" -c 1 -W 1 "${UPSTREAM_IP}" >/dev/null 2>&1 && UPSTREAM_STATE="ok"
fi

ROUTE_OUTPUT=$(ip -4 route show table "${ROUTING_TABLE_ID}" 2>/dev/null)
grep -qE "^default dev ${WARP_IF}([[:space:]]|$)" <<<"${ROUTE_OUTPUT}" && ROUTE_STATE="ok"
nft list table inet warp_gateway >/dev/null 2>&1 && NFT_STATE="ok"

monitor_status() {
  if [[ ${WG_STATE} != "up" ]] ||
    [[ ${DIRECT_STATE} != "ok" ]] ||
   [[ ${WARP_STATE} != "on" ]] ||
   [[ ${ROUTE_STATE} != "ok" ]] ||
   [[ ${NFT_STATE} != "ok" ]] ||
   [[ ${UPSTREAM_STATE} == "fail" ]]; then
    printf 'FAIL\n'
  elif [[ ${HANDSHAKE_STATE} != "ok" ]]; then
    printf 'WARN\n'
  else
    printf 'OK\n'
  fi
}

STATUS=$(monitor_status)

echo "STATUS=${STATUS} wg=${WG_STATE} handshake=${HANDSHAKE_STATE} handshake_age=${HANDSHAKE_AGE}s direct=${DIRECT_STATE} direct_rc=${DIRECT_RC} direct_ip=${DIRECT_IP} warp=${WARP_STATE} warp_rc=${WARP_RC} warp_ip=${WARP_IP_PUBLIC} colo=${WARP_COLO} loc=${WARP_LOC} upstream=${UPSTREAM_STATE} route=${ROUTE_STATE} nft=${NFT_STATE}"
[[ ${STATUS} != "FAIL" ]]
