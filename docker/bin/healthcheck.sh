#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE=/etc/warp-egress-gateway/warp-gateway.env
[[ -r ${CONFIG_FILE} ]] || exit 1
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

ip link show "${WARP_IF}" >/dev/null 2>&1 || exit 1
warp_ip=$(ip -4 -o address show dev "${WARP_IF}" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')
[[ -n ${warp_ip} ]] || exit 1
ip -4 rule show | grep -qE "^[0-9]+:.*iif ${TRANSIT_IF}.*lookup (${ROUTING_TABLE_ID}|${ROUTING_TABLE_NAME})" || exit 1
ip -4 route show table "${ROUTING_TABLE_ID}" | grep -qE "^default dev ${WARP_IF}( |$)" || exit 1

output=$(curl -4 --silent --show-error --fail \
  --interface "${warp_ip}" \
  --connect-timeout "${HEALTHCHECK_TIMEOUT:-15}" \
  --max-time "${HEALTHCHECK_TIMEOUT:-15}" \
  "${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}") || exit 1
grep -q '^warp=on$' <<<"${output}"
