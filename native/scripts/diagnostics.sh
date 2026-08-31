#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=admin-lock.sh
source "${SCRIPT_DIR}/admin-lock.sh"
# shellcheck source=observation-entrypoints.sh
source "${SCRIPT_DIR}/observation-entrypoints.sh"
require_root
load_config

OUT=${1:-/tmp/warp-egress-diagnostics-$(date +%Y%m%d-%H%M%S).txt}
diagnostics_public "${OUT}"
