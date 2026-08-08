#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PURGE_STATE=false
[[ ${1:-} == "--purge-state" ]] && PURGE_STATE=true
[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

cd "${ROOT_DIR}"
docker compose down --remove-orphans 2>/dev/null || true
systemctl disable --now warp-egress-docker-guard.service 2>/dev/null || true
/usr/local/sbin/warp-egress-docker-guard-remove 2>/dev/null || true
rm -f /etc/systemd/system/warp-egress-docker-guard.service
rm -f /usr/local/sbin/warp-egress-docker-guard-apply /usr/local/sbin/warp-egress-docker-guard-remove
rm -f /usr/local/sbin/warp-gateway-upgrade /usr/local/sbin/warp-gateway-rollback
rm -rf /etc/warp-egress-gateway-docker
rm -f /etc/sysctl.d/99-warp-egress-docker.conf
rm -f /etc/systemd/journald.conf.d/10-warp-egress-gateway-retention.conf
rm -f /etc/netplan/60-warp-egress-docker-transit.yaml
systemctl daemon-reload
systemctl restart systemd-journald 2>/dev/null || true
sysctl --system >/dev/null || true
rm -rf "${ROOT_DIR}/generated"
mkdir -p "${ROOT_DIR}/generated"
touch "${ROOT_DIR}/generated/.gitkeep"
if [[ ${PURGE_STATE} == true ]]; then
  rm -rf "${ROOT_DIR}/state"
  mkdir -p "${ROOT_DIR}/state"
  touch "${ROOT_DIR}/state/.gitkeep"
fi
echo "Docker edition removed. Docker Engine itself was not removed."
