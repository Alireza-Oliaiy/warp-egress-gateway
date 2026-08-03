#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
load_config

remove_rule_priority "${INGRESS_RULE_PRIORITY}"
remove_rule_priority "${SOURCE_RULE_PRIORITY}"
ip -4 route flush table "${ROUTING_TABLE_ID}" 2>/dev/null || true
ip -4 route flush cache

# The firewall is intentionally left loaded. Traffic entering TRANSIT_IF remains
# blocked from every egress except WARP_IF, preventing fallback/leak via UPLINK_IF.
log "Policy routing removed; kill switch remains active."
