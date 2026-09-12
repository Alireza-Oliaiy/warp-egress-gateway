#!/usr/bin/env bash
# shellcheck disable=SC2034 # fixture state is consumed by sourced production callbacks
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
"${WARP_GATEWAY_PYTHON3:-python3}" -B "${ROOT}/tests/intent_state_test.py"
"${WARP_GATEWAY_PYTHON3:-python3}" -B "${ROOT}/tests/admin_intent_test.py"
area=$(mktemp -d)
trap 'rm -rf -- "${area}"' EXIT
mkdir -m 0700 "${area}/run"
mutations=${area}/mutations
: >"${mutations}"
fail() { printf 'FAIL intent recovery: %s\n' "$*" >&2; exit 1; }
# shellcheck source=../native/scripts/mutation-transactions.sh
source "${ROOT}/native/scripts/mutation-transactions.sh"
# shellcheck source=../native/scripts/healthcheck-lib.sh
source "${ROOT}/native/scripts/healthcheck-lib.sh"
# shellcheck source=../native/scripts/monitor-lib.sh
source "${ROOT}/native/scripts/monitor-lib.sh"
admin_lock_run_shared() { admin_lock_run_at shared "${area}/run" "${area}/run/admin-mutation.lock" "$(id -u)" "$(id -g)" 1 "$@"; }
admin_lock_run_exclusive() { admin_lock_run_at exclusive "${area}/run" "${area}/run/admin-mutation.lock" "$(id -u)" "$(id -g)" 1 "$@"; }

# Prove the real shell/descriptor fast path under the actual shared lock.
[[ $(admin_lock_run_shared intent_state_locked) == absent ]] || fail 'absent fast path'
if intent_state_locked >/dev/null; then fail 'unlocked lifecycle read accepted'; fi
descriptor_fixture() {
  python3 -B - "${ADMIN_LOCK_HELD_FD}" <<'PY'
import pathlib, sys
assert 'FLOCK' in pathlib.Path(f'/proc/self/fdinfo/{int(sys.argv[1])}').read_text()
PY
}
admin_lock_run_shared descriptor_fixture

# Dependency injection only within this shell fixture; all guards, transaction
# bodies and lock callbacks are production functions. Any escaped command fails.
intent_state_locked() {
  [[ -n ${ADMIN_LOCK_HELD_FD:-} ]] || fail 'intent read outside shared lock'
  if flock -x -n "${area}/run/admin-mutation.lock" true; then fail 'intent read without flock'; fi
  printf '%s\n' "${fixture_intent}"
}
intent_disconnected_locked() { [[ ${fixture_match} == true ]]; }
ip() { printf 'ip\n' >>"${mutations}"; return 97; }
nft() { printf 'nft\n' >>"${mutations}"; return 97; }
wg_quick_command_locked() { printf 'wg\n' >>"${mutations}"; return 97; }
wg_quick_reload_command_locked() { printf 'wg reload\n' >>"${mutations}"; return 97; }
systemctl() { printf 'systemctl\n' >>"${mutations}"; return 97; }
sysctl() { printf 'sysctl\n' >>"${mutations}"; return 97; }
healthcheck_probe_direct() { DIRECT_WARP_STATE=off; DIRECT_RC=0; return 0; }
healthcheck_observe_upstream_locked() { UPSTREAM_STATE=ok; }
healthcheck_observe_units_locked() { SERVICE_STATE=ok; TIMER_STATE=ok; }
WARP_IF=warp0
AUTO_RECOVER=true
fixture_match=false
for fixture_intent in valid unsafe; do
  for function in route_up_transaction_locked route_down_transaction_locked route_repair_transaction_locked \
      policy_routing_apply_locked policy_routing_repair_locked healthcheck_policy_repair_transaction_locked \
      healthcheck_tunnel_finalize_locked firewall_apply_transaction_locked firewall_remove_transaction_locked; do
    if admin_lock_run_exclusive "${function}"; then fail "${function} allowed ${fixture_intent}"; fi
  done
  for action in up down reload; do
    if admin_lock_run_exclusive wg_quick_transaction_locked "${action}" warp0; then fail "WG ${action} allowed ${fixture_intent}"; fi
  done
  if sample=$(healthcheck_run); then fail "mismatched/unsafe intent passed health (${fixture_intent})"; fi
  [[ ${sample} == 'HEALTH=FAIL '* ]] || fail 'missing bounded health failure'
  sample=$(admin_lock_run_shared monitor_sample)
  [[ ${sample} == 'STATUS=FAIL '* ]] || fail 'unsafe/mismatched monitor state not FAIL'
done
fixture_intent=valid
fixture_match=true
sample=$(healthcheck_run)
[[ ${sample} == 'HEALTH=INTENTIONALLY_DISCONNECTED '* ]] || fail 'valid health intent classification'
sample=$(admin_lock_run_shared healthcheck_readonly_evaluate_locked)
[[ ${sample} == *'HEALTH=INTENTIONALLY_DISCONNECTED '* && ${sample} == *'route=absent '* && ${sample} == *'recovery=none' ]] || fail 'read-only classification'
sample=$(admin_lock_run_shared monitor_sample)
[[ ${sample} == 'STATUS=INTENTIONALLY_DISCONNECTED '* ]] || fail 'monitor classification'
[[ ! -s ${mutations} ]] || fail 'a suppressed writer/probe mutated state'
printf 'PASS intent recovery suppression, shared-lock observation, monitor and zero-mutation tripwires\n'
