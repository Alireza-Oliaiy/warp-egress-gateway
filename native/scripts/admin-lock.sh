#!/usr/bin/env bash

if [[ ${ADMIN_LOCK_LIBRARY_LOADED:-false} == true ]]; then
  return 0
fi
readonly ADMIN_LOCK_LIBRARY_LOADED=true

# This library is sourced only by root-owned project entrypoints. Public
# functions deliberately expose no path, ownership, mode, or timeout override.
readonly ADMIN_LOCK_PARENT='/run/warp-egress-gateway'
readonly ADMIN_LOCK_PATH='/run/warp-egress-gateway/admin-mutation.lock'
readonly ADMIN_LOCK_TIMEOUT_SEC='3'
readonly ADMIN_LOCK_METADATA_RC='73'
readonly ADMIN_LOCK_BUSY_RC='75'

admin_lock_metadata_error() {
  echo "warp-egress-gateway: unsafe admin mutation lock metadata" >&2
  return "${ADMIN_LOCK_METADATA_RC}"
}

admin_lock_prepare_at() {
  local parent=$1
  local lock_path=$2
  local expected_uid=$3
  local expected_gid=$4
  local parent_metadata
  local lock_metadata

  [[ ${parent} == /* && ${parent} != / ]] || return "${ADMIN_LOCK_METADATA_RC}"
  [[ ${lock_path} == "${parent}/admin-mutation.lock" ]] ||
    return "${ADMIN_LOCK_METADATA_RC}"
  [[ ${expected_uid} =~ ^[0-9]+$ && ${expected_gid} =~ ^[0-9]+$ ]] ||
    return "${ADMIN_LOCK_METADATA_RC}"

  if [[ -L ${parent} ]]; then
    return "${ADMIN_LOCK_METADATA_RC}"
  fi
  if [[ ! -e ${parent} ]]; then
    # Another root boot-time creator (for example tmpfiles) may win after the
    # absence check. Creation status is not authority: always validate the
    # resulting object below, without repairing or following an unsafe winner.
    (umask 077; mkdir -m 0700 -- "${parent}") 2>/dev/null || true
  fi
  [[ -d ${parent} && ! -L ${parent} ]] || return "${ADMIN_LOCK_METADATA_RC}"

  parent_metadata=$(LC_ALL=C stat -c '%u:%g:%a:%F' -- "${parent}") ||
    return "${ADMIN_LOCK_METADATA_RC}"
  [[ ${parent_metadata} == "${expected_uid}:${expected_gid}:700:directory" ]] ||
    return "${ADMIN_LOCK_METADATA_RC}"

  if [[ -L ${lock_path} ]]; then
    return "${ADMIN_LOCK_METADATA_RC}"
  fi
  if [[ ! -e ${lock_path} ]]; then
    # noclobber maps creation to O_EXCL semantics and prevents following an
    # already-present symlink. A root-only parent closes the unprivileged race.
    (umask 077; set -o noclobber; : > "${lock_path}") 2>/dev/null || true
  fi
  [[ -f ${lock_path} && ! -L ${lock_path} ]] ||
    return "${ADMIN_LOCK_METADATA_RC}"

  lock_metadata=$(LC_ALL=C stat -c '%u:%g:%a' -- "${lock_path}") ||
    return "${ADMIN_LOCK_METADATA_RC}"
  [[ ${lock_metadata} == "${expected_uid}:${expected_gid}:600" ]] ||
    return "${ADMIN_LOCK_METADATA_RC}"
}

admin_lock_run_at() {
  local mode=$1
  local parent=$2
  local lock_path=$3
  local expected_uid=$4
  local expected_gid=$5
  local timeout_sec=$6
  shift 6

  local flock_mode
  local lock_fd
  local disk_identity
  local fd_identity
  local callback_rc=0
  local unlock_rc=0

  [[ $# -gt 0 ]] || return "${ADMIN_LOCK_METADATA_RC}"
  case "${mode}" in
    shared) flock_mode='-s' ;;
    exclusive) flock_mode='-x' ;;
    *) return "${ADMIN_LOCK_METADATA_RC}" ;;
  esac
  [[ ${timeout_sec} =~ ^([0-9]+)(\.[0-9]+)?$ ]] ||
    return "${ADMIN_LOCK_METADATA_RC}"

  admin_lock_prepare_at "${parent}" "${lock_path}" \
    "${expected_uid}" "${expected_gid}" || {
      admin_lock_metadata_error
      return "${ADMIN_LOCK_METADATA_RC}"
    }

  exec {lock_fd}<>"${lock_path}" || {
    admin_lock_metadata_error
    return "${ADMIN_LOCK_METADATA_RC}"
  }

  disk_identity=$(LC_ALL=C stat -c '%d:%i:%u:%g:%a:%F' -- "${lock_path}") || {
    exec {lock_fd}>&-
    admin_lock_metadata_error
    return "${ADMIN_LOCK_METADATA_RC}"
  }
  fd_identity=$(LC_ALL=C stat -Lc '%d:%i:%u:%g:%a:%F' \
    "/proc/${BASHPID}/fd/${lock_fd}") || {
    exec {lock_fd}>&-
    admin_lock_metadata_error
    return "${ADMIN_LOCK_METADATA_RC}"
  }
  [[ ${disk_identity} == "${fd_identity}" ]] || {
    exec {lock_fd}>&-
    admin_lock_metadata_error
    return "${ADMIN_LOCK_METADATA_RC}"
  }

  local flock_rc=0
  flock "${flock_mode}" -E "${ADMIN_LOCK_BUSY_RC}" \
    -w "${timeout_sec}" "${lock_fd}" || flock_rc=$?
  if (( flock_rc != 0 )); then
    exec {lock_fd}>&-
    return "${flock_rc}"
  fi

  # Internal dynamic scope, not exported or accepted from a caller environment.
  # Intent primitives reuse this exact open-file-description without re-locking.
  # shellcheck disable=SC2034 # consumed by the dynamically scoped intent callback
  local ADMIN_LOCK_HELD_FD=${lock_fd} ADMIN_LOCK_HELD_PARENT=${parent}
  "$@" || callback_rc=$?
  flock -u "${lock_fd}" || unlock_rc=$?
  exec {lock_fd}>&-

  if (( callback_rc != 0 )); then
    return "${callback_rc}"
  fi
  return "${unlock_rc}"
}

admin_lock_run_shared() {
  admin_lock_run_at shared "${ADMIN_LOCK_PARENT}" "${ADMIN_LOCK_PATH}" \
    0 0 "${ADMIN_LOCK_TIMEOUT_SEC}" "$@"
}

admin_lock_run_exclusive() {
  admin_lock_run_at exclusive "${ADMIN_LOCK_PARENT}" "${ADMIN_LOCK_PATH}" \
    0 0 "${ADMIN_LOCK_TIMEOUT_SEC}" "$@"
}
