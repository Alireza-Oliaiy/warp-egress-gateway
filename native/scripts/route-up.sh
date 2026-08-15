#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=routing.sh
source "${SCRIPT_DIR}/routing.sh"

require_root
load_config

if ! policy_routing_activate; then
  die "Policy-routing activation failed; kill switch remains active (outcome=${POLICY_ROUTING_OUTCOME:-failed})."
fi

if [[ ${POLICY_ROUTING_OUTCOME} == intentionally_disconnected ]]; then
  log "intentional_disconnect: policy routing remains absent by explicit runtime intent."
  exit 0
fi

log "Policy routing enabled: ${TRANSIT_IF} -> table ${ROUTING_TABLE_ID} -> ${WARP_IF}."
