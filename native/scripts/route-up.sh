#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=routing.sh
source "${SCRIPT_DIR}/routing.sh"

require_root
load_config

ip link show "${WARP_IF}" >/dev/null 2>&1 || die "WARP interface ${WARP_IF} is not present."
WARP_IPV4=$(warp_ipv4_address) || die "No IPv4 address found on ${WARP_IF}."

policy_routing_apply "${WARP_IPV4}"

log "Policy routing enabled: ${TRANSIT_IF} -> table ${ROUTING_TABLE_ID} -> ${WARP_IF}."
