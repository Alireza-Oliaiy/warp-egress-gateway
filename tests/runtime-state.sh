#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUNTIME_LIB="${ROOT}/native/scripts/runtime-state.sh"
VALIDATOR="${ROOT}/native/scripts/runtime-state-validate.py"
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}

[[ -r ${RUNTIME_LIB} ]] || {
  echo "Runtime-state library is missing: ${RUNTIME_LIB}" >&2
  exit 1
}
[[ -r ${VALIDATOR} ]] || {
  echo "Intent validator is missing: ${VALIDATOR}" >&2
  exit 1
}

TEST_DIR=$(mktemp -d)
holder_pid=
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n ${holder_pid} ]]; then
    if kill -0 "${holder_pid}" 2>/dev/null; then
      kill "${holder_pid}" 2>/dev/null || true
    fi
    wait "${holder_pid}" 2>/dev/null || true
  fi
  rm -rf "${TEST_DIR}"
  exit "${rc}"
}
trap cleanup EXIT
chmod 700 "${TEST_DIR}"

grep -q '^RUNTIME_STATE_FIXED_DIR=/run/warp-egress-gateway$' "${RUNTIME_LIB}"
grep -q '^MUTATION_LOCK_TIMEOUT_SECONDS=5$' "${RUNTIME_LIB}"
[[ $(head -n 1 "${VALIDATOR}") == '#!/usr/bin/python3 -I' ]]

validator_fixture="${TEST_DIR}/intent.json"
cat >"${validator_fixture}" <<'JSON'
{"version":1,"state":"intentionally_disconnected","created_at":"2026-01-02T03:04:05Z","request_id":"0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7","actor":"admin-example"}
JSON
"${PYTHON3_BIN}" -I "${VALIDATOR}" "${validator_fixture}"
printf '%s\n' '{"version":1,"version":1}' >"${validator_fixture}"
if "${PYTHON3_BIN}" -I "${VALIDATOR}" "${validator_fixture}"; then
  echo "Intent validator accepted duplicate JSON keys." >&2
  exit 1
fi
printf '\xff\xfe' >"${validator_fixture}"
if "${PYTHON3_BIN}" -I "${VALIDATOR}" "${validator_fixture}"; then
  echo "Intent validator accepted invalid UTF-8." >&2
  exit 1
fi

if [[ $(stat -c %a "${TEST_DIR}") != 700 || ! -x /usr/bin/flock ]]; then
  echo "SKIP runtime-state filesystem behavior (requires Unix modes and /usr/bin/flock)."
  exit 0
fi

export WARP_RUNTIME_STATE_TEST_MODE=1
export WARP_RUNTIME_STATE_TEST_DIR="${TEST_DIR}/run/warp-egress-gateway"
export WARP_GATEWAY_PYTHON3="${PYTHON3_BIN}"
# shellcheck source=../native/scripts/runtime-state.sh
source "${RUNTIME_LIB}"

runtime_state_prepare
[[ ! -L ${RUNTIME_STATE_DIR} && -d ${RUNTIME_STATE_DIR} ]]
[[ $(stat -c '%u:%g:%a' "${RUNTIME_STATE_DIR}") == "$(id -u):$(id -g):700" ]]
[[ ! -L ${MUTATION_LOCK_PATH} && -f ${MUTATION_LOCK_PATH} ]]
[[ $(stat -c '%u:%g:%a' "${MUTATION_LOCK_PATH}") == "$(id -u):$(id -g):600" ]]

lock_inode=$(stat -c %i "${MUTATION_LOCK_PATH}")
runtime_state_prepare
[[ $(stat -c %i "${MUTATION_LOCK_PATH}") == "${lock_inode}" ]]

[[ $(intentional_disconnect_state) == absent ]]

cat >"${INTENTIONAL_DISCONNECT_PATH}" <<'JSON'
{"version":1,"state":"intentionally_disconnected","created_at":"2026-01-02T03:04:05Z","request_id":"0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7","actor":"admin-example"}
JSON
chmod 600 "${INTENTIONAL_DISCONNECT_PATH}"
[[ $(intentional_disconnect_state) == valid ]]

printf '%s\n' '{"version":1,"version":1}' >"${INTENTIONAL_DISCONNECT_PATH}"
chmod 600 "${INTENTIONAL_DISCONNECT_PATH}"
[[ $(intentional_disconnect_state) == corrupt ]]

printf '%s\n' '{not-json}' >"${INTENTIONAL_DISCONNECT_PATH}"
chmod 600 "${INTENTIONAL_DISCONNECT_PATH}"
[[ $(intentional_disconnect_state) == corrupt ]]

chmod 644 "${INTENTIONAL_DISCONNECT_PATH}"
[[ $(intentional_disconnect_state) == unsafe ]]

rm -f "${INTENTIONAL_DISCONNECT_PATH}"
ln -s "${TEST_DIR}/target" "${INTENTIONAL_DISCONNECT_PATH}"
[[ $(intentional_disconnect_state) == unsafe ]]
rm -f "${INTENTIONAL_DISCONNECT_PATH}"

mutation_marker="${TEST_DIR}/mutated"
locked_mutation() {
  mutation_lock_require_held
  printf 'yes\n' >"${mutation_marker}"
}
with_mutation_lock locked_mutation
[[ -f ${mutation_marker} ]]

nested_marker="${TEST_DIR}/nested"
nested_mutation() {
  printf 'bad\n' >"${nested_marker}"
}
attempt_nested_lock() {
  mutation_lock_require_held
  if with_mutation_lock nested_mutation; then
    echo "Nested mutation lock acquisition unexpectedly succeeded." >&2
    return 1
  fi
}
with_mutation_lock attempt_nested_lock
[[ ! -e ${nested_marker} ]]

ready="${TEST_DIR}/ready"
holder_lifetime_seconds=$((MUTATION_LOCK_TIMEOUT_SECONDS + 20))
(
  exec 8<>"${MUTATION_LOCK_PATH}"
  /usr/bin/flock -x 8
  : >"${ready}"
  exec /usr/bin/sleep "${holder_lifetime_seconds}"
) &
holder_pid=$!
for _ in {1..50}; do
  [[ -e ${ready} ]] && break
  sleep 0.05
done
if [[ ! -e ${ready} ]]; then
  printf 'Mutation lock holder did not become ready: holder_pid=%s holder_alive=%s\n' \
    "${holder_pid}" "$(kill -0 "${holder_pid}" 2>/dev/null && printf yes || printf no)" >&2
  exit 1
fi

rm -f "${mutation_marker}"
monotonic_ns() {
  "${PYTHON3_BIN}" -I -c 'import time; print(time.monotonic_ns())'
}
start_ns=$(monotonic_ns)
if with_mutation_lock locked_mutation; then
  rc=0
else
  rc=$?
fi
end_ns=$(monotonic_ns)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
minimum_elapsed_ms=$(( (MUTATION_LOCK_TIMEOUT_SECONDS - 1) * 1000 ))
if kill -0 "${holder_pid}" 2>/dev/null; then
  holder_alive=yes
else
  holder_alive=no
fi
if [[ -e ${mutation_marker} ]]; then
  marker_present=yes
else
  marker_present=no
fi

if [[ ${rc} -ne 75 || ${MUTATION_RESULT} != mutation_busy || \
      ${elapsed_ms} -lt ${minimum_elapsed_ms} || ${holder_alive} != yes || \
      ${marker_present} != no ]]; then
  printf '%s\n' \
    "Mutation lock timeout assertion failed: rc=${rc} expected_rc=75 mutation_result=${MUTATION_RESULT} elapsed_ms=${elapsed_ms} configured_timeout_seconds=${MUTATION_LOCK_TIMEOUT_SECONDS} holder_alive=${holder_alive} marker_present=${marker_present}" >&2
  exit 1
fi
printf '%s\n' \
  "Mutation lock timeout check passed: rc=${rc} mutation_result=${MUTATION_RESULT} elapsed_ms=${elapsed_ms} configured_timeout_seconds=${MUTATION_LOCK_TIMEOUT_SECONDS} holder_alive=${holder_alive} marker_present=${marker_present}"

kill "${holder_pid}" 2>/dev/null || true
wait "${holder_pid}" 2>/dev/null || true
holder_pid=

rm -f "${INTENTIONAL_DISCONNECT_PATH}"
[[ $(intentional_disconnect_state) == absent ]]

echo "Runtime-state lock and intent validation checks passed."
