#!/usr/bin/env bash

# Top-level mutators call with_mutation_lock exactly once. Functions whose
# names end in _locked require that lock and must never acquire it again.

RUNTIME_STATE_FIXED_DIR=/run/warp-egress-gateway
RUNTIME_STATE_FIXED_LOCK=${RUNTIME_STATE_FIXED_DIR}/mutation.lock
RUNTIME_STATE_FIXED_INTENT=${RUNTIME_STATE_FIXED_DIR}/intentional-disconnect.json
MUTATION_LOCK_TIMEOUT_SECONDS=5
MUTATION_LOCK_HELD=false
MUTATION_RESULT=none

if [[ ${WARP_RUNTIME_STATE_TEST_MODE:-0} == 1 && ${EUID} -ne 0 ]]; then
  : "${WARP_RUNTIME_STATE_TEST_DIR:?test runtime directory is required}"
  RUNTIME_STATE_DIR=${WARP_RUNTIME_STATE_TEST_DIR}
  MUTATION_LOCK_PATH=${RUNTIME_STATE_DIR}/mutation.lock
  INTENTIONAL_DISCONNECT_PATH=${RUNTIME_STATE_DIR}/intentional-disconnect.json
  RUNTIME_STATE_EXPECTED_UID=$(id -u)
  RUNTIME_STATE_EXPECTED_GID=$(id -g)
  RUNTIME_STATE_PYTHON=${WARP_GATEWAY_PYTHON3:-python3}
  RUNTIME_STATE_FLOCK=${WARP_RUNTIME_STATE_TEST_FLOCK_BIN:-/usr/bin/flock}
  RUNTIME_STATE_TEST_ASSUME_SAFE=${WARP_RUNTIME_STATE_TEST_ASSUME_SAFE:-0}
else
  RUNTIME_STATE_DIR=${RUNTIME_STATE_FIXED_DIR}
  MUTATION_LOCK_PATH=${RUNTIME_STATE_FIXED_LOCK}
  INTENTIONAL_DISCONNECT_PATH=${RUNTIME_STATE_FIXED_INTENT}
  RUNTIME_STATE_EXPECTED_UID=0
  RUNTIME_STATE_EXPECTED_GID=0
  RUNTIME_STATE_PYTHON=/usr/bin/python3
  RUNTIME_STATE_FLOCK=/usr/bin/flock
  RUNTIME_STATE_TEST_ASSUME_SAFE=0
fi

RUNTIME_STATE_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUNTIME_STATE_VALIDATOR=${RUNTIME_STATE_SCRIPT_DIR}/runtime-state-validate.py

runtime_state_diagnostic() {
  printf 'runtime_state: %s\n' "$*" >&2
}

runtime_state_path_metadata() {
  stat -c '%u:%g:%a' -- "$1" 2>/dev/null
}

runtime_state_directory_safe() {
  local metadata expected
  [[ ! -L ${RUNTIME_STATE_DIR} && -d ${RUNTIME_STATE_DIR} ]] || return 1
  [[ ${RUNTIME_STATE_TEST_ASSUME_SAFE} == 1 ]] && return 0
  metadata=$(runtime_state_path_metadata "${RUNTIME_STATE_DIR}") || return 1
  expected="${RUNTIME_STATE_EXPECTED_UID}:${RUNTIME_STATE_EXPECTED_GID}:700"
  [[ ${metadata} == "${expected}" ]]
}

runtime_state_lock_safe() {
  local metadata expected
  [[ ! -L ${MUTATION_LOCK_PATH} && -f ${MUTATION_LOCK_PATH} ]] || return 1
  [[ ${RUNTIME_STATE_TEST_ASSUME_SAFE} == 1 ]] && return 0
  metadata=$(runtime_state_path_metadata "${MUTATION_LOCK_PATH}") || return 1
  expected="${RUNTIME_STATE_EXPECTED_UID}:${RUNTIME_STATE_EXPECTED_GID}:600"
  [[ ${metadata} == "${expected}" ]]
}

runtime_state_prepare() {
  local parent created=false
  parent=$(dirname -- "${RUNTIME_STATE_DIR}")

  if [[ -L ${RUNTIME_STATE_DIR} ]]; then
    runtime_state_diagnostic "unsafe runtime directory symlink"
    return 1
  fi
  if [[ ! -e ${RUNTIME_STATE_DIR} ]]; then
    umask 077
    mkdir -p -- "${parent}"
    mkdir -- "${RUNTIME_STATE_DIR}"
    chmod 700 -- "${RUNTIME_STATE_DIR}"
    created=true
  fi
  if ! runtime_state_directory_safe; then
    runtime_state_diagnostic "unsafe runtime directory ownership, mode, or type"
    return 1
  fi

  if [[ -L ${MUTATION_LOCK_PATH} ]]; then
    runtime_state_diagnostic "unsafe mutation lock symlink"
    return 1
  fi
  if [[ ! -e ${MUTATION_LOCK_PATH} ]]; then
    umask 077
    ( set -o noclobber; : >"${MUTATION_LOCK_PATH}" ) || {
      runtime_state_diagnostic "unable to create mutation lock"
      return 1
    }
    chmod 600 -- "${MUTATION_LOCK_PATH}"
  fi
  if ! runtime_state_lock_safe; then
    runtime_state_diagnostic "unsafe mutation lock ownership, mode, or type"
    return 1
  fi

  # Keep the stable lock inode for the entire boot. Preparation never replaces
  # an existing safe lock file.
  [[ ${created} == true || -f ${MUTATION_LOCK_PATH} ]]
}

mutation_lock_require_held() {
  if [[ ${MUTATION_LOCK_HELD} != true ]]; then
    runtime_state_diagnostic "locked mutation primitive called without the shared lock"
    return 70
  fi
}

with_mutation_lock() {
  local callback_rc lock_fd
  if [[ ${MUTATION_LOCK_HELD} == true ]]; then
    runtime_state_diagnostic "nested mutation lock acquisition refused"
    return 70
  fi
  runtime_state_prepare || return 1
  [[ -x ${RUNTIME_STATE_FLOCK} ]] || {
    runtime_state_diagnostic "flock executable is unavailable"
    return 1
  }

  exec {lock_fd}<>"${MUTATION_LOCK_PATH}"
  if ! "${RUNTIME_STATE_FLOCK}" -x -w "${MUTATION_LOCK_TIMEOUT_SECONDS}" "${lock_fd}"; then
    exec {lock_fd}>&-
    MUTATION_RESULT=mutation_busy
    runtime_state_diagnostic "mutation_busy: lock unavailable after ${MUTATION_LOCK_TIMEOUT_SECONDS} seconds"
    return 75
  fi

  MUTATION_LOCK_HELD=true
  # shellcheck disable=SC2034 # structured result consumed by sourcing callers
  MUTATION_RESULT=locked
  if "$@"; then
    callback_rc=0
  else
    callback_rc=$?
  fi
  MUTATION_LOCK_HELD=false
  "${RUNTIME_STATE_FLOCK}" -u "${lock_fd}" || true
  exec {lock_fd}>&-
  return "${callback_rc}"
}

intentional_disconnect_state() {
  local metadata expected size
  if [[ ! -e ${RUNTIME_STATE_DIR} && ! -L ${RUNTIME_STATE_DIR} ]]; then
    printf 'absent\n'
    return 0
  fi
  if ! runtime_state_directory_safe; then
    printf 'unsafe\n'
    return 0
  fi
  if [[ ! -e ${INTENTIONAL_DISCONNECT_PATH} && ! -L ${INTENTIONAL_DISCONNECT_PATH} ]]; then
    printf 'absent\n'
    return 0
  fi
  if [[ -L ${INTENTIONAL_DISCONNECT_PATH} || ! -f ${INTENTIONAL_DISCONNECT_PATH} ]]; then
    printf 'unsafe\n'
    return 0
  fi

  metadata=$(runtime_state_path_metadata "${INTENTIONAL_DISCONNECT_PATH}") || {
    printf 'unsafe\n'
    return 0
  }
  expected="${RUNTIME_STATE_EXPECTED_UID}:${RUNTIME_STATE_EXPECTED_GID}:600"
  if [[ ${metadata} != "${expected}" ]]; then
    printf 'unsafe\n'
    return 0
  fi
  size=$(stat -c %s -- "${INTENTIONAL_DISCONNECT_PATH}" 2>/dev/null) || {
    printf 'unsafe\n'
    return 0
  }
  if (( size < 1 || size > 4096 )); then
    printf 'corrupt\n'
    return 0
  fi
  if [[ ! -x ${RUNTIME_STATE_PYTHON} && ${RUNTIME_STATE_PYTHON} == */* ]]; then
    printf 'corrupt\n'
    return 0
  fi
  if "${RUNTIME_STATE_PYTHON}" -I "${RUNTIME_STATE_VALIDATOR}" \
    "${INTENTIONAL_DISCONNECT_PATH}" >/dev/null 2>&1; then
    printf 'valid\n'
  else
    printf 'corrupt\n'
  fi
}
