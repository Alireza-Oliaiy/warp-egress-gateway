#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG=/etc/warp-egress-gateway-docker/guard.env
[[ -r ${CONFIG} ]] || { echo "Missing ${CONFIG}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG}"
: "${TRANSIT_IF:?TRANSIT_IF is required}"
: "${WARP_IF:=warp0}"
nft -f - <<NFT
destroy table inet warp_docker_guard
table inet warp_docker_guard {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "${TRANSIT_IF}" oifname != "${WARP_IF}" \
      counter drop comment "WARP_DOCKER_HOST_KILL_SWITCH"
  }
}
NFT

# Docker forwarding is enabled only after the host guard transaction succeeds.
sysctl -w net.ipv4.ip_forward=1 >/dev/null
