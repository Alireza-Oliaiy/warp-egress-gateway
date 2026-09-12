#!/usr/bin/env bash
set -Eeuo pipefail
# Fixed root CLI/maintenance precondition; no intent creation/clear operation.
[[ ${EUID} -eq 0 && $# -eq 0 ]] || exit 64
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=admin-lock.sh
source "${SCRIPT_DIR}/admin-lock.sh"
# shellcheck source=intent-state.sh
source "${SCRIPT_DIR}/intent-state.sh"
admin_lock_run_exclusive intent_require_absent_locked
