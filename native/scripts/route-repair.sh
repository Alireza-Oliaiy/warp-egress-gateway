#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=routing.sh
source "${SCRIPT_DIR}/routing.sh"

require_root
load_config

before=$(policy_routing_status)
if ! policy_routing_repair; then
  die "Policy-routing repair failed; kill switch remains active (state=${before})."
fi
after=$(policy_routing_status)
[[ ${after} == ok ]] || die "Policy-routing repair verification failed: ${after}."

if [[ ${before} == ok ]]; then
  log "Policy routing already matches the configured runtime state."
else
  log "Policy routing repaired successfully (previous_state=${before})."
fi
