#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE=/etc/warp-egress-gateway/warp-gateway.env
STATE_DIR=/var/lib/warp-egress-gateway
RUN_DIR=/run/warp-egress-gateway
mkdir -p "${STATE_DIR}" "${RUN_DIR}"

[[ -r ${CONFIG_FILE} ]] || { echo "Missing ${CONFIG_FILE}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${TRANSIT_IF:?TRANSIT_IF is required}"
: "${UPLINK_IF:?UPLINK_IF is required}"
: "${WARP_IF:=warp0}"
: "${TRUSTED_SOURCE_CIDR:?TRUSTED_SOURCE_CIDR is required}"
: "${ROUTING_TABLE_ID:=100}"
: "${SOURCE_RULE_PRIORITY:=100}"
: "${INGRESS_RULE_PRIORITY:=110}"

export TRANSIT_IF UPLINK_IF WARP_IF TRUSTED_SOURCE_CIDR ROUTING_TABLE_ID \
  SOURCE_RULE_PRIORITY INGRESS_RULE_PRIORITY

log() { printf '[docker-gateway] %s\n' "$*"; }

cleanup() {
  trap - TERM INT EXIT
  log "Stopping policy routing and WARP interface; host kill switch remains loaded."
  /app/scripts/route-down.sh || true
  if [[ -f ${RUN_DIR}/${WARP_IF}.conf ]]; then
    wg-quick down "${RUN_DIR}/${WARP_IF}.conf" 2>/dev/null || ip link delete "${WARP_IF}" 2>/dev/null || true
  else
    ip link delete "${WARP_IF}" 2>/dev/null || true
  fi
  nft delete table inet warp_gateway 2>/dev/null || true
}
trap cleanup TERM INT EXIT

ip link show "${UPLINK_IF}" >/dev/null 2>&1 || { echo "Uplink interface ${UPLINK_IF} not found" >&2; exit 1; }
ip link show "${TRANSIT_IF}" >/dev/null 2>&1 || { echo "Transit interface ${TRANSIT_IF} not found" >&2; exit 1; }

create_profile() {
  cd "${STATE_DIR}"
  if [[ ! -f wgcf-account.toml ]]; then
    [[ ${ACCEPT_CLOUDFLARE_TOS:-no} == yes ]] || {
      echo "Set ACCEPT_CLOUDFLARE_TOS=yes after reviewing Cloudflare terms." >&2
      exit 1
    }
    log "Registering a new free WARP account with wgcf."
    printf 'y\n' | wgcf register
  fi
  log "Generating WireGuard profile."
  wgcf generate
}

[[ -f ${STATE_DIR}/wgcf-profile.conf ]] || create_profile
PROFILE_SOURCE=${EXISTING_WARP_PROFILE:-${STATE_DIR}/wgcf-profile.conf}
[[ -r ${PROFILE_SOURCE} ]] || { echo "WARP profile not readable: ${PROFILE_SOURCE}" >&2; exit 1; }

tmp_profile=${RUN_DIR}/${WARP_IF}.conf
cp "${PROFILE_SOURCE}" "${tmp_profile}"
log "Normalizing WARP profile for the IPv4-only gateway path."
/app/bin/normalize-warp-profile-ipv4.sh "${tmp_profile}"
sed -i -E '/^(DNS|MTU|Table|PersistentKeepalive)[[:space:]]*=/d' "${tmp_profile}"
sed -i "/^\[Peer\]/i MTU = ${WARP_MTU:-1280}\nTable = off" "${tmp_profile}"
sed -i "/^Endpoint[[:space:]]*=/a PersistentKeepalive = ${PERSISTENT_KEEPALIVE:-25}" "${tmp_profile}"
chmod 600 "${tmp_profile}"

start_tunnel() {
  /app/scripts/route-down.sh || true
  ip link delete "${WARP_IF}" 2>/dev/null || true
  /app/scripts/firewall-apply.sh
  wg-quick up "${tmp_profile}"
  /app/scripts/route-up.sh
}

start_tunnel
log "Docker WARP gateway is active."

interval=${MONITOR_INTERVAL:-60}
while true; do
  sleep "${interval}" & wait $!
  if ! /app/bin/monitor.sh; then
    log "Passive monitor reported failure; kill switch remains active."
    if [[ ${AUTO_RECOVER:-false} == true ]]; then
      log "AUTO_RECOVER=true; attempting recovery."
      start_tunnel || true
    fi
  fi
done
