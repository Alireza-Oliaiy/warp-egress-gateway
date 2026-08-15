#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=routing.sh
source "${SCRIPT_DIR}/routing.sh"
# shellcheck source=healthcheck-lib.sh
source "${SCRIPT_DIR}/healthcheck-lib.sh"

require_root
load_config
healthcheck_run
