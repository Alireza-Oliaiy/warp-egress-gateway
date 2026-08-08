#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_root
load_config

OUT=${1:-/tmp/warp-egress-diagnostics-$(date +%Y%m%d-%H%M%S).txt}
{
  echo "Generated: $(date --iso-8601=seconds)"
  echo "===== PROJECT VERSION ====="; cat /etc/warp-egress-gateway/VERSION 2>/dev/null || echo "legacy/unknown"
  echo "===== OS ====="; cat /etc/os-release
  echo "===== KERNEL ====="; uname -a
  echo "===== ADDRESSES ====="; ip -br address
  echo "===== MAIN ROUTES ====="; ip -4 route show table main
  echo "===== RULES ====="; ip -4 rule show
  echo "===== WARP TABLE ====="; ip -4 route show table "${ROUTING_TABLE_ID}" || true
  echo "===== SERVICES ====="; systemctl status warp-gateway-firewall.service "wg-quick@${WARP_IF}.service" warp-gateway.service warp-monitor.timer --no-pager || true
  echo "===== WG ====="; wg show "${WARP_IF}" || true
  echo "===== NFT ====="; nft list table inet "${NFT_TABLE}" || true
  echo "===== SYSCTL ====="; sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
  echo "===== RECENT LOGS ====="; journalctl -u warp-gateway-firewall.service -u "wg-quick@${WARP_IF}.service" -u warp-gateway.service -u warp-gateway-healthcheck.service -u warp-monitor.service -n 200 --no-pager || true
  echo "===== MONITOR HISTORY ====="; journalctl -t warp-monitor --since "7 days ago" -n 1000 --no-pager -o short-iso || true
  echo "===== JOURNAL USAGE ====="; journalctl --disk-usage || true
} >"${OUT}"
chmod 600 "${OUT}"
printf '%s\n' "${OUT}"
