#!/usr/bin/env bash

INTENT_LIBRARY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Called only inside the existing native shared/exclusive lock callback.
# The descriptor is dynamically scoped by admin_lock_run_at, never from env.
intent_state_locked() {
  [[ -n ${ADMIN_LOCK_HELD_FD:-} && -n ${ADMIN_LOCK_HELD_PARENT:-} ]] || {
    printf 'unsafe\n'
    return 1
  }
  # No-intent fast path keeps existing health/monitor timing. Unsafe parent/lock
  # metadata is already rejected by the authoritative lock before the callback.
  if [[ ! -e ${ADMIN_LOCK_HELD_PARENT}/intentional-disconnect.json \
      && ! -L ${ADMIN_LOCK_HELD_PARENT}/intentional-disconnect.json ]]; then
    printf 'absent\n'
    return 0
  fi
  /usr/bin/python3 -I "${INTENT_LIBRARY_DIR}/intent-state.py" check "${ADMIN_LOCK_HELD_FD}"
}

intent_require_absent_locked() {
  local state
  state=$(intent_state_locked) || state=unsafe
  if [[ ${state} != absent ]]; then
    printf 'warp-egress-gateway: lifecycle suppressed intent=%s\n' "${state}" >&2
    return 1
  fi
}

intent_disconnected_locked() {
  [[ -n ${ADMIN_LOCK_HELD_FD:-} ]] || return 1
  /usr/bin/python3 -I "${INTENT_LIBRARY_DIR}/intent-state.py" inspect "${ADMIN_LOCK_HELD_FD}" >/dev/null
}
