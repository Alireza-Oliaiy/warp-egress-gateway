#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  echo "observation-locking: FAIL: $*" >&2
  exit 1
}

LOCK_PARENT="${TEST_ROOT}/run/warp-egress-gateway"
LOCK_PATH="${LOCK_PARENT}/admin-mutation.lock"
mkdir -m 0700 "${TEST_ROOT}/run"

# shellcheck source=../native/scripts/admin-lock.sh
source "${ROOT}/native/scripts/admin-lock.sh"

OBSERVATION_LIB="${ROOT}/native/scripts/observation-entrypoints.sh"
[[ -r ${OBSERVATION_LIB} ]] || fail "missing observation entrypoint library"
# shellcheck source=../native/scripts/observation-entrypoints.sh
source "${OBSERVATION_LIB}"

admin_lock_run_shared() {
  admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
    "$(id -u)" "$(id -g)" 0.2 "$@"
}

assert_shared_callback() {
  local label=$1
  # An exclusive probe must fail while the callback runs, while another shared
  # probe must succeed. Together these distinguish a shared lock from no lock
  # and from an accidental exclusive lock.
  if flock -x -n "${LOCK_PATH}" true; then
    fail "${label} ran without a lock"
  fi
  flock -s -n "${LOCK_PATH}" true || fail "${label} used an exclusive lock"
  printf '%s\n' "${label}"
}

healthcheck_readonly_evaluate_locked() { assert_shared_callback health; }
status_collect_locked() { assert_shared_callback status; }
monitor_sample() { assert_shared_callback monitor; }
diagnostics_collect_locked() { assert_shared_callback diagnostics; }

[[ $(healthcheck_readonly_public) == health ]] || fail "health public entrypoint failed"
[[ $(status_public) == status ]] || fail "status public entrypoint failed"
[[ $(monitor_sample_public) == monitor ]] || fail "monitor public entrypoint failed"
[[ $(diagnostics_public ignored) == diagnostics ]] || fail "diagnostics public entrypoint failed"

# A writer excludes each public reader before its observation callback begins.
READY="${TEST_ROOT}/writer-ready"
hold_writer() { : > "${READY}"; sleep 1; }
admin_lock_run_at exclusive "${LOCK_PARENT}" "${LOCK_PATH}" \
  "$(id -u)" "$(id -g)" 1 hold_writer &
WRITER_PID=$!
for _ in {1..100}; do [[ -e ${READY} ]] && break; sleep 0.01; done
[[ -e ${READY} ]] || fail "writer holder did not start"
HEALTH_RC=0
healthcheck_readonly_public >/dev/null || HEALTH_RC=$?
[[ ${HEALTH_RC} -eq 75 ]] || fail "blocked health returned ${HEALTH_RC}, expected 75"
wait "${WRITER_PID}"

echo "OBSERVATION_LOCKING_TESTS_PASSED"
