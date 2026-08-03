#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG=/etc/warp-egress-gateway-docker/guard.env
[[ -r ${CONFIG} ]] || { echo "Missing ${CONFIG}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG}"
: "${TRANSIT_IF:?TRANSIT_IF is required}"
: "${WARP_IF:=warp0}"
nft delete table inet warp_docker_guard 2>/dev/null || true
nft -f - <<NFT
table inet warp_docker_guard {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "${TRANSIT_IF}" oifname != "${WARP_IF}" \
      counter drop comment "WARP_DOCKER_HOST_KILL_SWITCH"
  }
}
NFT
