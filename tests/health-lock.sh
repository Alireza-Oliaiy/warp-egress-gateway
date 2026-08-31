#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOCK_LIB="${ROOT}/native/scripts/admin-lock.sh"

fail() {
  echo "health-lock: FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=$3
  [[ ${actual} == "${expected}" ]] ||
    fail "${label}: expected '${expected}', got '${actual}'"
}

expect_rc() {
  local expected=$1
  shift
  local actual=0

  "$@" || actual=$?
  assert_eq "${expected}" "${actual}" "exit status for $*"
}

[[ -r ${LOCK_LIB} ]] || fail "missing production lock library: ${LOCK_LIB}"
# shellcheck source=../native/scripts/admin-lock.sh
source "${LOCK_LIB}"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

TEST_UID=$(id -u)
TEST_GID=$(id -g)
LOCK_PARENT="${TEST_ROOT}/run/warp-egress-gateway"
LOCK_PATH="${LOCK_PARENT}/admin-mutation.lock"
mkdir -m 0700 "${TEST_ROOT}/run"

record_callback() {
  printf '%s\n' "$1" >> "$2"
}

ready_then_wait() {
  : > "$1"
  sleep "$2"
}

admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 1 record_callback created "${TEST_ROOT}/calls"

assert_eq "${TEST_UID}:${TEST_GID}:700:directory" \
  "$(stat -c '%u:%g:%a:%F' -- "${LOCK_PARENT}")" "lock parent metadata"
assert_eq "${TEST_UID}:${TEST_GID}:600" \
  "$(stat -c '%u:%g:%a' -- "${LOCK_PATH}")" "lock file metadata"
[[ -f ${LOCK_PATH} && ! -L ${LOCK_PATH} ]] || fail "lock is not a regular file"
assert_eq created "$(cat "${TEST_ROOT}/calls")" "lock callback execution"

# Two shared readers may overlap.
SHARED_READY="${TEST_ROOT}/shared-ready"
admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 1 ready_then_wait "${SHARED_READY}" 1 &
SHARED_PID=$!
for _ in {1..100}; do
  [[ -e ${SHARED_READY} ]] && break
  sleep 0.01
done
[[ -e ${SHARED_READY} ]] || fail "shared lock holder did not start"
admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 0.2 record_callback shared-overlap "${TEST_ROOT}/calls"
wait "${SHARED_PID}"

# An exclusive writer blocks a reader, and the fixed timeout is deterministic.
EXCLUSIVE_READY="${TEST_ROOT}/exclusive-ready"
admin_lock_run_at exclusive "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 1 ready_then_wait "${EXCLUSIVE_READY}" 1 &
EXCLUSIVE_PID=$!
for _ in {1..100}; do
  [[ -e ${EXCLUSIVE_READY} ]] && break
  sleep 0.01
done
[[ -e ${EXCLUSIVE_READY} ]] || fail "exclusive lock holder did not start"
expect_rc 75 admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"
wait "${EXCLUSIVE_PID}"
! grep -Fxq must-not-run "${TEST_ROOT}/calls" || fail "blocked reader callback ran"

# A shared reader blocks an exclusive writer.
READER_READY="${TEST_ROOT}/reader-ready"
admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 1 ready_then_wait "${READER_READY}" 1 &
READER_PID=$!
for _ in {1..100}; do
  [[ -e ${READER_READY} ]] && break
  sleep 0.01
done
[[ -e ${READER_READY} ]] || fail "reader lock holder did not start"
expect_rc 75 admin_lock_run_at exclusive "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"
wait "${READER_PID}"

# Existing unsafe metadata and symlinks fail closed and are never repaired.
chmod 0750 "${LOCK_PARENT}"
expect_rc 73 admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"
assert_eq 750 "$(stat -c '%a' -- "${LOCK_PARENT}")" "unsafe parent left unchanged"
chmod 0700 "${LOCK_PARENT}"

chmod 0640 "${LOCK_PATH}"
expect_rc 73 admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"
assert_eq 640 "$(stat -c '%a' -- "${LOCK_PATH}")" "unsafe lock left unchanged"
chmod 0600 "${LOCK_PATH}"
expect_rc 73 admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "$((TEST_UID + 1))" "${TEST_GID}" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"
assert_eq "${TEST_UID}:${TEST_GID}:600" \
  "$(stat -c '%u:%g:%a' -- "${LOCK_PATH}")" "wrong-owner lock left unchanged"
expect_rc 73 admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "$((TEST_GID + 1))" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"

expect_rc 73 admin_lock_run_at shared "${LOCK_PARENT}" \
  "${LOCK_PARENT}/caller-controlled.lock" "${TEST_UID}" "${TEST_GID}" 0.1 \
  record_callback must-not-run "${TEST_ROOT}/calls"
[[ ! -e ${LOCK_PARENT}/caller-controlled.lock ]] || fail "alternate lock path was created"

rm -f -- "${LOCK_PATH}"
mkdir "${LOCK_PATH}"
expect_rc 73 admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"
rmdir "${LOCK_PATH}"

ln -s "${TEST_ROOT}/symlink-target" "${LOCK_PATH}"
expect_rc 73 admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"
[[ ! -e ${TEST_ROOT}/symlink-target ]] || fail "lock symlink target was created or opened"

rm -f -- "${LOCK_PATH}"
rmdir "${LOCK_PARENT}"
mkdir -p "${TEST_ROOT}/unsafe-parent-target"
ln -s "${TEST_ROOT}/unsafe-parent-target" "${LOCK_PARENT}"
expect_rc 73 admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
  "${TEST_UID}" "${TEST_GID}" 0.1 record_callback must-not-run "${TEST_ROOT}/calls"
[[ ! -e ${TEST_ROOT}/unsafe-parent-target/admin-mutation.lock ]] ||
  fail "parent symlink was followed"

echo "HEALTH_LOCK_TESTS_PASSED"
