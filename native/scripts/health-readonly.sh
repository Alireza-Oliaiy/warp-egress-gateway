#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=routing.sh
source "${SCRIPT_DIR}/routing.sh"
# shellcheck source=admin-lock.sh
source "${SCRIPT_DIR}/admin-lock.sh"
# shellcheck source=healthcheck-lib.sh
source "${SCRIPT_DIR}/healthcheck-lib.sh"
# shellcheck source=observation-entrypoints.sh
source "${SCRIPT_DIR}/observation-entrypoints.sh"

require_root
load_config

readonly_rc=0
healthcheck_readonly_public || readonly_rc=$?
if (( readonly_rc != 0 )); then
  if (( readonly_rc == ADMIN_LOCK_BUSY_RC )); then
    printf 'EVALUATION=failed reason=mutation_lock_busy\n' >&2
  else
    printf 'EVALUATION=failed reason=observation_unavailable\n' >&2
  fi
  exit "${readonly_rc}"
fi
