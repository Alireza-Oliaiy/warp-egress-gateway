#!/usr/bin/env bash
set -Eeuo pipefail

PURGE_PROFILE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-profile) PURGE_PROFILE=true; shift ;;
    -h|--help)
      echo "Usage: sudo ./uninstall.sh [--purge-profile]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
CONFIG_FILE=/etc/warp-egress-gateway/warp-gateway.env
if [[ -r ${CONFIG_FILE} ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
else
  WARP_IF=warp0
  ROUTING_TABLE_ID=100
  SOURCE_RULE_PRIORITY=100
  INGRESS_RULE_PRIORITY=110
fi

systemctl disable --now warp-gateway-healthcheck.timer 2>/dev/null || true
systemctl disable --now warp-monitor.timer 2>/dev/null || true
systemctl stop warp-gateway.service 2>/dev/null || true
systemctl disable warp-gateway.service 2>/dev/null || true
systemctl disable --now "wg-quick@${WARP_IF}.service" 2>/dev/null || true
systemctl disable warp-gateway-firewall.service 2>/dev/null || true

/usr/local/lib/warp-egress-gateway/route-down.sh 2>/dev/null || true
/usr/local/lib/warp-egress-gateway/firewall-remove.sh 2>/dev/null || \
  nft delete table inet warp_gateway 2>/dev/null || true

rm -f /etc/systemd/system/warp-gateway.service \
      /etc/systemd/system/warp-gateway-firewall.service \
      /etc/systemd/system/warp-gateway-healthcheck.service \
      /etc/systemd/system/warp-gateway-healthcheck.timer \
      /etc/systemd/system/warp-monitor.service \
      /etc/systemd/system/warp-monitor.timer
rm -rf "/etc/systemd/system/wg-quick@${WARP_IF}.service.d"
rm -f /etc/sysctl.d/99-warp-egress-gateway.conf
rm -f /etc/systemd/journald.conf.d/10-warp-egress-gateway-retention.conf
rm -f /etc/iproute2/rt_tables.d/warp-egress-gateway.conf
rm -f /usr/local/sbin/warp-gateway /usr/local/sbin/warp-gateway-upgrade /usr/local/sbin/warp-gateway-rollback
rm -f /etc/warp-egress-gateway/VERSION
rm -rf /usr/local/lib/warp-egress-gateway

if [[ ${PURGE_PROFILE} == true ]]; then
  rm -f "/etc/wireguard/${WARP_IF}.conf"
  rm -rf /var/lib/warp-egress-gateway /etc/warp-egress-gateway
else
  echo "Preserved /etc/wireguard/${WARP_IF}.conf and WARP account state."
fi

systemctl daemon-reload
systemctl restart systemd-journald 2>/dev/null || true
sysctl --system >/dev/null || true
echo "Uninstall complete."
