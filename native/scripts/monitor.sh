#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=routing.sh
source "${SCRIPT_DIR}/routing.sh"
# shellcheck source=monitor-lib.sh
source "${SCRIPT_DIR}/monitor-lib.sh"

require_root
load_config

SAMPLE=$(monitor_sample)
logger -t warp-monitor "${SAMPLE}"
exit 0
