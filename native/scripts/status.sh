#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
load_config

printf '===== SERVICES =====\n'
systemctl is-active "warp-gateway-firewall.service" "wg-quick@${WARP_IF}.service" "warp-gateway.service" "warp-monitor.timer" || true
printf '\n===== INTERFACES =====\n'
for interface in "${UPLINK_IF}" "${TRANSIT_IF}" "${WARP_IF}"; do
  ip -br address show dev "${interface}" 2>/dev/null || true
done
printf '\n===== MAIN DEFAULT ROUTE =====\n'
ip -4 route show default
printf '\n===== POLICY RULES =====\n'
ip -4 rule show
printf '\n===== WARP TABLE =====\n'
ip -4 route show table "${ROUTING_TABLE_ID}" || true
printf '\n===== WIREGUARD =====\n'
wg show "${WARP_IF}" || true
printf '\n===== NFTABLES =====\n'
nft list table inet "${NFT_TABLE}" || true
printf '\n===== WARP TRACE =====\n'
warp_ip=$(warp_ipv4_address 2>/dev/null || true)
if [[ -n ${warp_ip} ]]; then
  curl -4 --silent --show-error --interface "${warp_ip}" \
    --connect-timeout "${HEALTHCHECK_TIMEOUT:-15}" \
    "${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}" \
    | grep -E '^(ip|loc|colo|warp)=' || true
fi

printf '\n===== LAST MONITOR SAMPLE =====\n'
journalctl -t warp-monitor -n 1 --no-pager -o short-iso || true
