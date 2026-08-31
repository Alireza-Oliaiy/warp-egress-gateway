#!/usr/bin/env bash

OBSERVATION_ENTRYPOINTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F warp_ipv4_address >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${OBSERVATION_ENTRYPOINTS_DIR}/common.sh"
fi
if ! declare -F admin_lock_run_shared >/dev/null 2>&1; then
  # shellcheck source=admin-lock.sh
  source "${OBSERVATION_ENTRYPOINTS_DIR}/admin-lock.sh"
fi

healthcheck_readonly_public() {
  admin_lock_run_shared healthcheck_readonly_evaluate_locked
}

status_collect_locked() {
  printf '===== VERSION =====\n'
  if [[ -r /etc/warp-egress-gateway/VERSION ]]; then
    cat /etc/warp-egress-gateway/VERSION
  else
    echo "legacy/unknown"
  fi
  printf '\n===== SERVICES =====\n'
  systemctl is-active "warp-gateway-firewall.service" \
    "wg-quick@${WARP_IF}.service" "warp-gateway.service" \
    "warp-monitor.timer" || true
  printf '\n===== INTERFACES =====\n'
  local interface warp_ip
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
}

status_public() {
  admin_lock_run_shared status_collect_locked
}

monitor_sample_public() {
  admin_lock_run_shared monitor_sample
}

diagnostics_collect_locked() {
  local out=$1
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
  } >"${out}"
  chmod 600 "${out}"
  printf '%s\n' "${out}"
}

diagnostics_public() {
  admin_lock_run_shared diagnostics_collect_locked "$@"
}
