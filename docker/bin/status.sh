#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG_FILE=/etc/warp-egress-gateway/warp-gateway.env
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
echo "===== INTERFACES ====="
ip -br address show "${UPLINK_IF}" "${TRANSIT_IF}" "${WARP_IF}" 2>/dev/null || true
echo "===== MAIN ROUTE ====="
ip -4 route show default
echo "===== POLICY RULES ====="
ip -4 rule show
echo "===== WARP TABLE ====="
ip -4 route show table "${ROUTING_TABLE_ID}" || true
echo "===== WIREGUARD ====="
wg show "${WARP_IF}" || true
echo "===== FIREWALL ====="
nft list table inet warp_gateway || true
echo "===== TRACE ====="
/app/bin/healthcheck.sh && {
  warp_ip=$(ip -4 -o address show dev "${WARP_IF}" | awk 'NR==1 {split($4,a,"/"); print a[1]}')
  curl -4 --silent --interface "${warp_ip}" "${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}" \
    | grep -E '^(ip|loc|colo|warp)='
}
