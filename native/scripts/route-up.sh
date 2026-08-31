#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=admin-lock.sh
source "${SCRIPT_DIR}/admin-lock.sh"
# shellcheck source=mutation-transactions.sh
source "${SCRIPT_DIR}/mutation-transactions.sh"

require_root
load_config

admin_lock_run_exclusive route_up_transaction_locked
