#!/usr/bin/env bash
set -Eeuo pipefail

TEST_MODE=false
ROOT_PREFIX=""

die() { printf 'DASHBOARD_UNINSTALL_ERROR %s\n' "$*" >&2; exit 1; }

if [[ ${WARP_DASHBOARD_TEST_MODE:-0} == 1 ]]; then
  TEST_MODE=true
  ROOT_PREFIX=${WARP_DASHBOARD_TEST_ROOT:-}
  [[ ${ROOT_PREFIX} == /* && -d ${ROOT_PREFIX} && ! -L ${ROOT_PREFIX} ]] \
    || die 'GATE_TEST_ROOT invalid isolated root'
  ROOT_PREFIX=$(cd -- "${ROOT_PREFIX}" && pwd)
  [[ ${ROOT_PREFIX} != / ]] || die 'GATE_TEST_ROOT refused filesystem root'
elif [[ -n ${WARP_DASHBOARD_TEST_ROOT:-} ]]; then
  die 'GATE_TEST_ROOT test root requires explicit test mode'
else
  [[ ${EUID} -eq 0 ]] || die 'GATE_ROOT run as root'
fi

root_path() { printf '%s%s' "${ROOT_PREFIX}" "$1"; }

CONFIG_DIR=$(root_path /etc/warp-egress-dashboard)
ACCOUNT_MARKER=${CONFIG_DIR}/.warp-web-created
APP_DIR=$(root_path /opt/warp-egress-dashboard)
RUNTIME_DIR=$(root_path /run/warp-egress-dashboard)
TMPFILES_DEST=$(root_path /etc/tmpfiles.d/warp-egress-dashboard.conf)
UNIT_DIR=$(root_path /etc/systemd/system)
TEST_STATE_DIR=$(root_path /var/lib/warp-egress-dashboard)
TEST_ACTIONS=${TEST_STATE_DIR}/test-actions.log

for destination_root in "${CONFIG_DIR}" "${APP_DIR}" "${RUNTIME_DIR}"; do
  if [[ -e ${destination_root} || -L ${destination_root} ]]; then
    [[ -d ${destination_root} && ! -L ${destination_root} ]] \
      || die "GATE_DESTINATION unsafe dashboard-owned path: ${destination_root}"
  fi
done

account_state() {
  if [[ ${TEST_MODE} == true ]]; then
    case "${WARP_DASHBOARD_TEST_ACCOUNT:-absent}" in
      unsafe) printf 'unsafe\n' ;;
      safe) printf 'safe\n' ;;
      absent)
        if [[ -f ${TEST_STATE_DIR}/test-account ]]; then printf 'safe\n'; else printf 'absent\n'; fi
        ;;
      *) printf 'unsafe\n' ;;
    esac
    return
  fi
  if /usr/bin/getent passwd warp-web >/dev/null; then
    local passwd_entry group_entry uid gid group_gid group_members home shell groups lock
    passwd_entry=$(/usr/bin/getent passwd warp-web)
    group_entry=$(/usr/bin/getent group warp-web || true)
    [[ -n ${group_entry} ]] || { printf 'unsafe\n'; return; }
    IFS=: read -r _ _ uid gid _ home shell <<<"${passwd_entry}"
    IFS=: read -r _ _ group_gid group_members <<<"${group_entry}"
    groups=$(/usr/bin/id -Gn warp-web 2>/dev/null || true)
    lock=$(/usr/bin/passwd -S warp-web 2>/dev/null | awk '{print $2}')
    if [[ ${uid} =~ ^[0-9]+$ && ${uid} -gt 0 && ${uid} -lt 1000 \
        && ${gid} == "${group_gid}" && -z ${group_members} && ${home} == /nonexistent \
        && ${shell} == /usr/sbin/nologin && ${groups} == warp-web && ${lock} == L ]]; then
      printf 'safe\n'
    else
      printf 'unsafe\n'
    fi
  elif /usr/bin/getent group warp-web >/dev/null; then
    printf 'unsafe\n'
  else
    printf 'absent\n'
  fi
}

identity=$(account_state)
owned_account=false
if [[ -e ${ACCOUNT_MARKER} || -L ${ACCOUNT_MARKER} ]]; then
  [[ ${identity} == safe && -f ${ACCOUNT_MARKER} && ! -L ${ACCOUNT_MARKER} \
      && $(<"${ACCOUNT_MARKER}") == warp-web ]] \
    || die 'GATE_IDENTITY account ownership marker is unsafe or inconsistent'
  if [[ ${TEST_MODE} == false ]]; then
    [[ $(stat -c '%u:%g:%a' "${ACCOUNT_MARKER}") == 0:0:600 ]] \
      || die 'GATE_IDENTITY account ownership marker metadata is unsafe'
  fi
  owned_account=true
elif [[ ${identity} == unsafe ]]; then
  die 'GATE_IDENTITY conflicting warp-web account or group'
fi

systemctl_command() {
  if [[ ${TEST_MODE} == true ]]; then
    mkdir -p "${TEST_STATE_DIR}"
    {
      printf 'systemctl'
      printf ' %s' "$@"
      printf '\n'
    } >>"${TEST_ACTIONS}"
  else
    /usr/bin/systemctl "$@"
  fi
}

if [[ -e ${UNIT_DIR}/warp-dashboard-collector.timer ]]; then
  systemctl_command disable --now warp-dashboard-collector.timer \
    || die 'GATE_SYSTEMD collector timer disable failed'
fi
if [[ -e ${UNIT_DIR}/warp-dashboard.service ]]; then
  systemctl_command disable --now warp-dashboard.service \
    || die 'GATE_SYSTEMD web service disable failed'
fi
if [[ -e ${UNIT_DIR}/warp-dashboard-collector.service ]]; then
  systemctl_command stop warp-dashboard-collector.service \
    || die 'GATE_SYSTEMD collector service stop failed'
fi
rm -f -- \
  "${UNIT_DIR}/warp-dashboard.service" \
  "${UNIT_DIR}/warp-dashboard-collector.service" \
  "${UNIT_DIR}/warp-dashboard-collector.timer" \
  "${TMPFILES_DEST}"
rm -rf -- "${CONFIG_DIR}" "${APP_DIR}" "${RUNTIME_DIR}"
systemctl_command daemon-reload || die 'GATE_SYSTEMD daemon-reload failed'

if [[ ${owned_account} == true ]]; then
  if [[ ${TEST_MODE} == true ]]; then
    rm -f -- "${TEST_STATE_DIR}/test-account"
    printf 'userdel warp-web\n' >>"${TEST_ACTIONS}"
    printf 'groupdel warp-web\n' >>"${TEST_ACTIONS}"
  else
    /usr/sbin/userdel warp-web || die 'GATE_IDENTITY failed to remove warp-web account'
    if /usr/bin/getent group warp-web >/dev/null; then
      [[ -z $(/usr/bin/getent group warp-web | cut -d: -f4) ]] \
        || die 'GATE_IDENTITY warp-web group has unexpected members'
      /usr/sbin/groupdel warp-web || die 'GATE_IDENTITY failed to remove warp-web group'
    fi
  fi
elif [[ ${identity} == safe ]]; then
  printf 'DASHBOARD_ACCOUNT_PRESERVED warp-web\n'
fi

printf 'DASHBOARD_UNINSTALL_OK\n'
