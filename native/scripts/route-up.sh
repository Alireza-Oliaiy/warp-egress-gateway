#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
load_config

ip link show "${WARP_IF}" >/dev/null 2>&1 || die "WARP interface ${WARP_IF} is not present."
WARP_IPV4=$(warp_ipv4_address) || die "No IPv4 address found on ${WARP_IF}."

ip -4 route replace default dev "${WARP_IF}" table "${ROUTING_TABLE_ID}"
remove_rule_priority "${SOURCE_RULE_PRIORITY}"
remove_rule_priority "${INGRESS_RULE_PRIORITY}"
ip -4 rule add pref "${SOURCE_RULE_PRIORITY}" from "${WARP_IPV4}/32" lookup "${ROUTING_TABLE_ID}"
ip -4 rule add pref "${INGRESS_RULE_PRIORITY}" iif "${TRANSIT_IF}" lookup "${ROUTING_TABLE_ID}"
ip -4 route flush cache

log "Policy routing enabled: ${TRANSIT_IF} -> table ${ROUTING_TABLE_ID} -> ${WARP_IF}."
