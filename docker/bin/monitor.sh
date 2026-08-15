#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME_LIB_DIR=${WARP_GATEWAY_LIB_DIR:-/app/scripts}
export WARP_GATEWAY_CONFIG_FILE=${WARP_GATEWAY_CONFIG_FILE:-/etc/warp-egress-gateway/warp-gateway.env}
# shellcheck source=../../native/scripts/common.sh
source "${RUNTIME_LIB_DIR}/common.sh"
# shellcheck source=../../native/scripts/routing.sh
source "${RUNTIME_LIB_DIR}/routing.sh"
# shellcheck source=../../native/scripts/monitor-lib.sh
source "${RUNTIME_LIB_DIR}/monitor-lib.sh"

load_config
monitor_sample
exit 0
