#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=routing.sh
source "${SCRIPT_DIR}/routing.sh"

require_root
load_config

policy_routing_remove

# The firewall is intentionally left loaded. Traffic entering TRANSIT_IF remains
# blocked from every egress except WARP_IF, preventing fallback/leak via UPLINK_IF.
log "Policy routing removed; kill switch remains active."
