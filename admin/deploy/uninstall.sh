#!/usr/bin/env bash
set -Eeuo pipefail

TEST_MODE=false
ROOT_PREFIX=""

log() { printf 'ADMIN_UNINSTALL %s\n' "$*"; }
die() { printf 'ADMIN_UNINSTALL_ERROR %s\n' "$*" >&2; exit 1; }

[[ $# -eq 0 ]] || die 'GATE_ARGUMENT no arguments are accepted'

if [[ ${WARP_ADMIN_TEST_MODE:-0} == 1 ]]; then
  TEST_MODE=true
  ROOT_PREFIX=${WARP_ADMIN_TEST_ROOT:-}
  [[ ${ROOT_PREFIX} == /* && -d ${ROOT_PREFIX} && ! -L ${ROOT_PREFIX} ]] \
    || die 'GATE_TEST_ROOT invalid isolated root'
  ROOT_PREFIX=$(cd -- "${ROOT_PREFIX}" && pwd)
  [[ ${ROOT_PREFIX} != / ]] || die 'GATE_TEST_ROOT refused filesystem root'
elif [[ -n ${WARP_ADMIN_TEST_ROOT:-} ]]; then
  die 'GATE_TEST_ROOT test root requires explicit test mode'
else
  [[ ${EUID} -eq 0 ]] || die 'GATE_ROOT run as root'
fi

root_path() { printf '%s%s' "${ROOT_PREFIX}" "$1"; }

APP_BASE=$(root_path /opt/warp-egress-admin-console)
RUNTIME_DIR=$(root_path /run/warp-egress-admin-console)
CONFIG_DIR=$(root_path /etc/warp-egress-admin-console)
ACCOUNT_MARKER=${CONFIG_DIR}/.warp-admin-created
NETWORK_DEST=${CONFIG_DIR}/network.json
HELPER_DEST=$(root_path /usr/local/libexec/warp-egress-gateway/warp-admin-helper)
PROTOCOL_DEST=$(root_path /usr/local/libexec/warp-egress-gateway/warp_admin_protocol.py)
UNIT_DEST=$(root_path /etc/systemd/system/warp-admin.service)
SUDOERS_DEST=$(root_path /etc/sudoers.d/warp-egress-gateway-admin)
TEST_STATE_DIR=$(root_path /var/lib/warp-egress-admin-console)
TEST_ACTIONS=${TEST_STATE_DIR}/test-actions.log

for directory in "${APP_BASE}" "${RUNTIME_DIR}" "${CONFIG_DIR}"; do
  if [[ -e ${directory} || -L ${directory} ]]; then
    [[ -d ${directory} && ! -L ${directory} ]] \
      || die "GATE_DESTINATION unsafe Admin directory: ${directory}"
  fi
done
if [[ -d ${APP_BASE} && -n $(find "${APP_BASE}" -type l -print -quit) ]]; then
  die 'GATE_DESTINATION application tree contains a symlink'
fi
for file in "${HELPER_DEST}" "${PROTOCOL_DEST}" "${UNIT_DEST}" "${SUDOERS_DEST}" "${NETWORK_DEST}"; do
  if [[ -e ${file} || -L ${file} ]]; then
    [[ -f ${file} && ! -L ${file} ]] || die "GATE_DESTINATION unsafe Admin file: ${file}"
    if [[ ${TEST_MODE} == false ]]; then
      metadata=$(stat -c '%u:%g:%a' -- "${file}")
      mode=${metadata##*:}
      [[ ${metadata%:*} == 0:0 && $((8#${mode} & 8#22)) -eq 0 ]] \
        || die "GATE_DESTINATION unsafe Admin file metadata: ${file}"
    fi
  fi
done

account_safe() {
  if [[ ${TEST_MODE} == true ]]; then
    [[ ${WARP_ADMIN_TEST_ACCOUNT:-absent} != unsafe ]]
    return
  fi
  local passwd_entry group_entry uid gid group_gid group_members home shell groups lock
  /usr/bin/getent passwd warp-admin >/dev/null || return 1
  passwd_entry=$(/usr/bin/getent passwd warp-admin)
  group_entry=$(/usr/bin/getent group warp-admin || true)
  [[ -n ${group_entry} ]] || return 1
  IFS=: read -r _ _ uid gid _ home shell <<<"${passwd_entry}"
  IFS=: read -r _ _ group_gid group_members <<<"${group_entry}"
  groups=$(/usr/bin/id -Gn warp-admin 2>/dev/null || true)
  lock=$(/usr/bin/passwd -S warp-admin 2>/dev/null | /usr/bin/awk '{print $2}')
  [[ ${uid} =~ ^[0-9]+$ && ${uid} -gt 0 && ${uid} -lt 1000 \
      && ${gid} == "${group_gid}" && -z ${group_members} && ${home} == /nonexistent \
      && ${shell} == /usr/sbin/nologin && ${groups} == warp-admin && ${lock} == L ]]
}

REMOVE_ACCOUNT=false
if [[ -e ${ACCOUNT_MARKER} || -L ${ACCOUNT_MARKER} ]]; then
  [[ -f ${ACCOUNT_MARKER} && ! -L ${ACCOUNT_MARKER} && $(<"${ACCOUNT_MARKER}") == warp-admin ]] \
    || die 'GATE_IDENTITY account marker is unsafe'
  if [[ ${TEST_MODE} == false ]]; then
    [[ $(stat -c '%u:%g:%a' -- "${ACCOUNT_MARKER}") == 0:0:600 ]] \
      || die 'GATE_IDENTITY account marker metadata is unsafe'
  fi
  account_safe || die 'GATE_IDENTITY marked warp-admin identity is unsafe'
  REMOVE_ACCOUNT=true
fi

if [[ ${TEST_MODE} == true ]]; then
  mkdir -p "${TEST_STATE_DIR}"
  : >>"${TEST_ACTIONS}"
  printf 'systemctl disable --now warp-admin.service\n' >>"${TEST_ACTIONS}"
else
  /usr/bin/systemctl disable --now warp-admin.service >/dev/null 2>&1 || true
fi

rm -f -- "${SUDOERS_DEST}" "${HELPER_DEST}" "${PROTOCOL_DEST}" "${UNIT_DEST}" "${NETWORK_DEST}"
rm -rf -- "${APP_BASE}" "${RUNTIME_DIR}"

if [[ ${REMOVE_ACCOUNT} == true ]]; then
  rm -f -- "${ACCOUNT_MARKER}"
  if [[ ${TEST_MODE} == true ]]; then
    rm -f -- "${TEST_STATE_DIR}/test-account"
    printf 'userdel warp-admin\n' >>"${TEST_ACTIONS}"
  else
    /usr/sbin/userdel warp-admin || die 'GATE_IDENTITY failed to remove project-created warp-admin account'
    if /usr/bin/getent group warp-admin >/dev/null; then
      /usr/sbin/groupdel warp-admin || die 'GATE_IDENTITY failed to remove project-created warp-admin group'
    fi
  fi
elif account_safe; then
  printf 'ADMIN_ACCOUNT_PRESERVED warp-admin\n'
fi

if [[ -d ${CONFIG_DIR} ]]; then
  rmdir -- "${CONFIG_DIR}" 2>/dev/null || true
fi
if [[ ${TEST_MODE} == false ]]; then
  /usr/bin/systemctl daemon-reload
else
  printf 'systemctl daemon-reload\n' >>"${TEST_ACTIONS}"
fi

log 'removed only Admin Console resources'
printf 'ADMIN_UNINSTALL_OK\n'
