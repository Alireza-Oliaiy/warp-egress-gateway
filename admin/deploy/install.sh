#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
TEST_MODE=false
ROOT_PREFIX=""
TEST_FAIL=""
TEST_LISTENER_SCENARIO=immediate-exact
TEST_READINESS_NOW_MS=0
READINESS_POLL=0
ADMIN_PROCESS_IDENTITY=""
PYTHON3_BIN=/usr/bin/python3
readonly LISTENER_READINESS_TIMEOUT_MS=10000
readonly LISTENER_READINESS_POLL_SECONDS=0.2

log() { printf 'ADMIN_INSTALL %s\n' "$*"; }
die() { printf 'ADMIN_INSTALL_ERROR %s\n' "$*" >&2; exit 1; }

[[ $# -eq 0 ]] || die 'GATE_ARGUMENT no arguments are accepted'

if [[ ${WARP_ADMIN_TEST_MODE:-0} == 1 ]]; then
  TEST_MODE=true
  ROOT_PREFIX=${WARP_ADMIN_TEST_ROOT:-}
  [[ ${ROOT_PREFIX} == /* && -d ${ROOT_PREFIX} && ! -L ${ROOT_PREFIX} ]] \
    || die 'GATE_TEST_ROOT invalid isolated root'
  ROOT_PREFIX=$(cd -- "${ROOT_PREFIX}" && pwd)
  [[ ${ROOT_PREFIX} != / ]] || die 'GATE_TEST_ROOT refused filesystem root'
  TEST_FAIL=${WARP_ADMIN_TEST_FAIL:-}
  [[ -z ${TEST_FAIL} || ${TEST_FAIL} =~ ^(sudoers|metadata|listener|http)$ ]] \
    || die 'GATE_TEST_FAILURE unknown injected failure'
  TEST_LISTENER_SCENARIO=${WARP_ADMIN_TEST_LISTENER_SCENARIO:-immediate-exact}
  [[ ${TEST_LISTENER_SCENARIO} =~ ^(immediate-exact|delayed-exact|after-deadline-exact|never|service-failed|service-inactive|service-deactivating|forbidden-wildcard|forbidden-management|forbidden-transit|forbidden-loopback|forbidden-loopback-alt|forbidden-ipv6-loopback|forbidden-ipv6-any|multiple)$ ]] \
    || die 'GATE_TEST_LISTENER unknown readiness scenario'
  PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
elif [[ -n ${WARP_ADMIN_TEST_ROOT:-} || -n ${WARP_ADMIN_TEST_LISTENER_SCENARIO:-} ]]; then
  die 'GATE_TEST_ROOT test fixtures require explicit test mode'
else
  [[ ${EUID} -eq 0 ]] || die 'GATE_ROOT run as root'
fi

root_path() { printf '%s%s' "${ROOT_PREFIX}" "$1"; }

APP_BASE=$(root_path /opt/warp-egress-admin-console)
APP_ROOT=${APP_BASE}/app
ADMIN_APP=${APP_ROOT}/admin
READONLY_PARENT=${APP_BASE}/readonly
READONLY_BUNDLE=${READONLY_PARENT}/v2
readonly_files=(evaluate.py health-readonly.sh common.sh routing.sh admin-lock.sh healthcheck-lib.sh observation-entrypoints.sh intent-state.sh intent-state.py)
RUNTIME_DIR=$(root_path /run/warp-egress-admin-console)
SHARED_RUNTIME_DIR=$(root_path /run/warp-egress-gateway)
TMPFILES_SOURCE=${SCRIPT_DIR}/tmpfiles/warp-egress-admin-console.conf
TMPFILES_DEST=$(root_path /etc/tmpfiles.d/warp-egress-admin-console.conf)
RUNTIME_OWNER=0:0
if [[ ${TEST_MODE} == true ]]; then RUNTIME_OWNER=$(id -u):$(id -g); fi
readonly RUNTIME_OWNER
CONFIG_DIR=$(root_path /etc/warp-egress-admin-console)
ACCOUNT_MARKER=${CONFIG_DIR}/.warp-admin-created
NETWORK_DEST=${CONFIG_DIR}/network.json
LIBEXEC_DIR=$(root_path /usr/local/libexec/warp-egress-gateway)
HELPER_DEST=${LIBEXEC_DIR}/warp-admin-helper
PROTOCOL_DEST=${LIBEXEC_DIR}/warp_admin_protocol.py
UNIT_DEST=$(root_path /etc/systemd/system/warp-admin.service)
SUDOERS_DEST=$(root_path /etc/sudoers.d/warp-egress-gateway-admin)
TEST_STATE_DIR=$(root_path /var/lib/warp-egress-admin-console)
TEST_ACTIONS=${TEST_STATE_DIR}/test-actions.log

app_files=(
  __init__.py
  application.py
  network.py
  protocol.py
  static/index.html
  static/admin.css
  static/admin.js
)
for relative in "${app_files[@]}"; do
  [[ -f ${SOURCE_ROOT}/admin/${relative} && ! -L ${SOURCE_ROOT}/admin/${relative} ]] \
    || die "GATE_SOURCE missing or unsafe Admin application file: ${relative}"
done
for source in \
  "${SOURCE_ROOT}/admin/helper.py" \
  "${SCRIPT_DIR}/systemd/warp-admin.service" \
  "${TMPFILES_SOURCE}" \
  "${SCRIPT_DIR}/sudoers/warp-egress-gateway-admin"; do
  [[ -f ${source} && ! -L ${source} ]] || die "GATE_SOURCE missing or unsafe file: ${source}"
done
[[ $(<"${TMPFILES_SOURCE}") == 'd /run/warp-egress-gateway 0700 root root -' ]] \
  || die 'GATE_SOURCE unexpected shared runtime tmpfiles rule'
for source in "${SOURCE_ROOT}" "${SOURCE_ROOT}/admin" "${SCRIPT_DIR}" "${SCRIPT_DIR}/tmpfiles" "${TMPFILES_SOURCE}"; do
  [[ ! -L ${source} ]] || die 'GATE_SOURCE unsafe tmpfiles source path'
  metadata=$(stat -c '%u:%g:%a' -- "${source}")
  mode=${metadata##*:}
  [[ ${metadata%:*} == "${RUNTIME_OWNER}" && $((8#${mode} & 8#22)) -eq 0 ]] \
    || die 'GATE_SOURCE tmpfiles source is not root-controlled'
done
[[ -x /usr/bin/systemd-tmpfiles ]] || die 'GATE_SHARED_RUNTIME systemd-tmpfiles is unavailable'

validate_shared_runtime() {
  [[ -d ${SHARED_RUNTIME_DIR} && ! -L ${SHARED_RUNTIME_DIR} \
      && $(stat -c '%u:%g:%a' -- "${SHARED_RUNTIME_DIR}") == "${RUNTIME_OWNER}:700" ]] \
    || die 'GATE_SHARED_RUNTIME shared runtime parent must be a root-owned 0700 directory'
}
# tmpfiles may adjust existing metadata: reject unsafe state BEFORE invoking it.
if [[ -e ${SHARED_RUNTIME_DIR} || -L ${SHARED_RUNTIME_DIR} ]]; then
  validate_shared_runtime
fi
if ! command -v "${PYTHON3_BIN}" >/dev/null 2>&1 && [[ ! -x ${PYTHON3_BIN} ]]; then
  die "GATE_PYTHON Python 3 is unavailable: ${PYTHON3_BIN}"
fi
VISUDO_BIN=$(command -v visudo || true)
[[ -n ${VISUDO_BIN} ]] || die 'GATE_SUDOERS visudo is unavailable'

for directory in "${APP_BASE}" "${CONFIG_DIR}" "${LIBEXEC_DIR}"; do
  if [[ -e ${directory} || -L ${directory} ]]; then
    [[ -d ${directory} && ! -L ${directory} ]] \
      || die "GATE_DESTINATION unsafe Admin destination directory: ${directory}"
    if [[ ${TEST_MODE} == false ]]; then
      metadata=$(stat -c '%u:%g:%a' -- "${directory}")
      mode=${metadata##*:}
      [[ ${metadata%:*} == 0:0 && $((8#${mode} & 8#22)) -eq 0 ]] \
        || die "GATE_DESTINATION unsafe ownership or mode: ${directory}"
    fi
  fi
done
if [[ -e ${RUNTIME_DIR} || -L ${RUNTIME_DIR} ]]; then
  [[ -d ${RUNTIME_DIR} && ! -L ${RUNTIME_DIR} ]] \
    || die "GATE_DESTINATION unsafe Admin runtime directory: ${RUNTIME_DIR}"
fi
for shared_parent in \
  "$(root_path /run)" \
  "$(root_path /etc/tmpfiles.d)" \
  "$(root_path /etc/systemd/system)" \
  "$(root_path /etc/sudoers.d)"; do
  if [[ -e ${shared_parent} || -L ${shared_parent} ]]; then
    [[ -d ${shared_parent} && ! -L ${shared_parent} ]] \
      || die "GATE_DESTINATION unsafe shared parent: ${shared_parent}"
    if [[ ${TEST_MODE} == false ]]; then
      metadata=$(stat -c '%u:%g:%a' -- "${shared_parent}")
      mode=${metadata##*:}
      [[ ${metadata%:*} == 0:0 && $((8#${mode} & 8#22)) -eq 0 ]] \
        || die "GATE_DESTINATION unsafe shared-parent ownership or mode: ${shared_parent}"
    fi
  fi
done
if [[ -d ${APP_BASE} && -n $(find "${APP_BASE}" -type l -print -quit) ]]; then
  die 'GATE_DESTINATION application tree contains a symlink'
fi
if [[ -d ${APP_BASE} ]]; then
  while IFS= read -r -d '' entry; do
    metadata=$(stat -c '%u:%g:%a' -- "${entry}")
    mode=${metadata##*:}
    [[ $((8#${mode} & 8#22)) -eq 0 ]] \
      || die "GATE_DESTINATION application tree is group/other writable: ${entry}"
    if [[ ${TEST_MODE} == false ]]; then
      [[ ${metadata%:*} == 0:0 ]] \
        || die "GATE_DESTINATION application tree is not root-owned: ${entry}"
    fi
  done < <(find "${APP_BASE}" -mindepth 1 -print0)
fi
for destination in "${HELPER_DEST}" "${PROTOCOL_DEST}" "${UNIT_DEST}" "${SUDOERS_DEST}" "${NETWORK_DEST}" "${TMPFILES_DEST}"; do
  if [[ -e ${destination} || -L ${destination} ]]; then
    [[ -f ${destination} && ! -L ${destination} ]] \
      || die "GATE_DESTINATION unsafe existing file: ${destination}"
    metadata=$(stat -c '%u:%g:%a' -- "${destination}")
    mode=${metadata##*:}
    [[ $((8#${mode} & 8#22)) -eq 0 ]] \
      || die "GATE_DESTINATION existing file is group/other writable: ${destination}"
    if [[ ${TEST_MODE} == false ]]; then
      [[ ${metadata%:*} == 0:0 ]] \
        || die "GATE_DESTINATION existing file is not root-owned: ${destination}"
    fi
  fi
done

readonly_source() {
  if [[ $1 == evaluate.py ]]; then printf '%s/readonly/evaluate.py' "${SCRIPT_DIR}"
  else printf '%s/native/scripts/%s' "${SOURCE_ROOT}" "$1"; fi
}

validate_foundation_directory() {
  [[ -d $1 && ! -L $1 ]] || die 'GATE_FOUNDATION unsafe foundation directory'
  local metadata mode
  metadata=$(stat -c '%u:%g:%a' -- "$1")
  mode=${metadata##*:}
  [[ ${metadata%:*} == "${RUNTIME_OWNER}" && $((8#${mode} & 8#22)) -eq 0 ]] \
    || die 'GATE_FOUNDATION foundation directory is not root-controlled'
}

# Validate source closure and installed ancestors before any account/file/service
# mutation. Never obtain dependencies from the host's older native Core tree.
for directory in "${SOURCE_ROOT}/native" "${SOURCE_ROOT}/native/scripts" "${SCRIPT_DIR}/readonly"; do
  validate_foundation_directory "${directory}"
done
for name in "${readonly_files[@]}"; do
  source=$(readonly_source "${name}")
  [[ -f ${source} && ! -L ${source} ]] || die 'GATE_FOUNDATION missing or unsafe bundle source'
  metadata=$(stat -c '%u:%g:%a' -- "${source}")
  mode=${metadata##*:}
  [[ ${metadata%:*} == "${RUNTIME_OWNER}" && $((8#${mode} & 8#22)) -eq 0 ]] \
    || die 'GATE_FOUNDATION bundle source is not root-controlled'
done
directory=${READONLY_PARENT}
while [[ ${directory} != "${ROOT_PREFIX:-/}" ]]; do
  if [[ -e ${directory} || -L ${directory} ]]; then validate_foundation_directory "${directory}"; fi
  directory=$(dirname -- "${directory}")
done
validate_foundation_directory "${ROOT_PREFIX:-/}"

validate_foundation_bundle() {
  local bundle=$1 name mode
  validate_foundation_directory "${bundle}"
  [[ $(find "${bundle}" -mindepth 1 -maxdepth 1 -printf '. ' | wc -w) -eq ${#readonly_files[@]} ]] \
    || die 'GATE_FOUNDATION unexpected bundle contents'
  for name in "${readonly_files[@]}"; do
    mode=644
    if [[ ${name} == evaluate.py ]]; then mode=755; fi
    [[ -f ${bundle}/${name} && ! -L ${bundle}/${name} \
        && $(stat -c '%u:%g:%a' -- "${bundle}/${name}") == "${RUNTIME_OWNER}:${mode}" ]] \
      || die 'GATE_FOUNDATION unsafe installed bundle file'
    cmp -s -- "$(readonly_source "${name}")" "${bundle}/${name}" \
      || die 'GATE_FOUNDATION existing bundle version differs; refusing a mixed or rewritten foundation'
  done
}
if [[ -e ${READONLY_BUNDLE} || -L ${READONLY_BUNDLE} ]]; then
  validate_foundation_bundle "${READONLY_BUNDLE}"
fi

account_state() {
  if [[ ${TEST_MODE} == true ]]; then
    case "${WARP_ADMIN_TEST_ACCOUNT:-absent}" in
      unsafe) printf 'unsafe\n' ;;
      safe) printf 'safe\n' ;;
      absent)
        if [[ -f ${TEST_STATE_DIR}/test-account ]]; then printf 'safe\n'; else printf 'absent\n'; fi
        ;;
      *) printf 'unsafe\n' ;;
    esac
    return
  fi
  if /usr/bin/getent passwd warp-admin >/dev/null; then
    local passwd_entry group_entry uid gid group_gid group_members home shell groups lock
    passwd_entry=$(/usr/bin/getent passwd warp-admin)
    group_entry=$(/usr/bin/getent group warp-admin || true)
    [[ -n ${group_entry} ]] || { printf 'unsafe\n'; return; }
    IFS=: read -r _ _ uid gid _ home shell <<<"${passwd_entry}"
    IFS=: read -r _ _ group_gid group_members <<<"${group_entry}"
    groups=$(/usr/bin/id -Gn warp-admin 2>/dev/null || true)
    lock=$(/usr/bin/passwd -S warp-admin 2>/dev/null | /usr/bin/awk '{print $2}')
    if [[ ${uid} =~ ^[0-9]+$ && ${uid} -gt 0 && ${uid} -lt 1000 \
        && ${gid} == "${group_gid}" && -z ${group_members} && ${home} == /nonexistent \
        && ${shell} == /usr/sbin/nologin && ${groups} == warp-admin && ${lock} == L ]]; then
      printf 'safe\n'
    else
      printf 'unsafe\n'
    fi
  elif /usr/bin/getent group warp-admin >/dev/null; then
    printf 'unsafe\n'
  else
    printf 'absent\n'
  fi
}

identity=$(account_state)
[[ ${identity} != unsafe ]] || die 'GATE_IDENTITY conflicting warp-admin account or group'
if [[ -d ${RUNTIME_DIR} ]]; then
  [[ ${identity} == safe && $(stat -c '%a' -- "${RUNTIME_DIR}") == 700 ]] \
    || die 'GATE_IDENTITY existing runtime directory is inconsistent with warp-admin'
  if [[ ${TEST_MODE} == false ]]; then
    [[ $(stat -c '%U:%G' -- "${RUNTIME_DIR}") == warp-admin:warp-admin ]] \
      || die 'GATE_IDENTITY existing runtime directory has unsafe ownership'
  fi
fi
if [[ -e ${ACCOUNT_MARKER} || -L ${ACCOUNT_MARKER} ]]; then
  [[ ${identity} == safe && -f ${ACCOUNT_MARKER} && ! -L ${ACCOUNT_MARKER} \
      && $(<"${ACCOUNT_MARKER}") == warp-admin ]] \
    || die 'GATE_IDENTITY account ownership marker is unsafe or inconsistent'
  if [[ ${TEST_MODE} == false ]]; then
    [[ $(stat -c '%u:%g:%a' -- "${ACCOUNT_MARKER}") == 0:0:600 ]] \
      || die 'GATE_IDENTITY account marker metadata is unsafe'
  fi
elif [[ ${identity} == absent ]]; then
  ACCOUNT_CREATE=true
else
  ACCOUNT_CREATE=false
fi

install_directory() {
  local mode=$1 path=$2 owner=${3:-root} group=${4:-root}
  if [[ ${TEST_MODE} == true ]]; then
    install -d -m "${mode}" "${path}"
  else
    install -d -o "${owner}" -g "${group}" -m "${mode}" "${path}"
  fi
}

install_file() {
  local mode=$1 source=$2 destination=$3 temporary parent
  parent=$(dirname -- "${destination}")
  if [[ ! -e ${parent} ]]; then
    install_directory 0755 "${parent}"
  else
    [[ -d ${parent} && ! -L ${parent} ]] \
      || die "GATE_DESTINATION unsafe install parent: ${parent}"
  fi
  temporary=${destination}.tmp.$$
  if [[ ${TEST_MODE} == true ]]; then
    install -m "${mode}" "${source}" "${temporary}"
  else
    install -o root -g root -m "${mode}" "${source}" "${temporary}"
  fi
  mv -f -- "${temporary}" "${destination}"
}

readiness_set_now() {
  local uptime whole fraction
  if [[ ${TEST_MODE} == true ]]; then
    READINESS_NOW_MS=${TEST_READINESS_NOW_MS}
    return
  fi
  read -r uptime _ </proc/uptime || die 'GATE_LISTENER monotonic clock unavailable'
  [[ ${uptime} =~ ^[0-9]+\.[0-9]+$ ]] || die 'GATE_LISTENER monotonic clock is malformed'
  whole=${uptime%%.*}
  fraction=${uptime#*.}000
  fraction=${fraction:0:3}
  READINESS_NOW_MS=$((10#${whole} * 1000 + 10#${fraction}))
}

readiness_sleep() {
  if [[ ${TEST_MODE} == true ]]; then
    if [[ ${TEST_LISTENER_SCENARIO} == after-deadline-exact && ${TEST_READINESS_NOW_MS} -eq 9750 ]]; then
      TEST_READINESS_NOW_MS=10250
    else
      TEST_READINESS_NOW_MS=$((TEST_READINESS_NOW_MS + 250))
    fi
  else
    /usr/bin/sleep "${LISTENER_READINESS_POLL_SECONDS}"
  fi
}

admin_service_state() {
  if [[ ${TEST_MODE} == true ]]; then
    if [[ ${TEST_LISTENER_SCENARIO} == service-* && ${READINESS_POLL} -ge 2 ]]; then
      printf '%s\n' "${TEST_LISTENER_SCENARIO#service-}"
    else
      printf 'active\n'
    fi
    return
  fi
  /usr/bin/systemctl is-active warp-admin.service 2>/dev/null || true
}

admin_listener_snapshot() {
  if [[ ${TEST_MODE} == true ]]; then
    case "${TEST_LISTENER_SCENARIO}" in
      immediate-exact) printf '%s\n' "${ADMIN_LISTENER}" ;;
      delayed-exact)
        if [[ ${READINESS_POLL} -ge 3 ]]; then printf '%s\n' "${ADMIN_LISTENER}"; fi
        ;;
      after-deadline-exact)
        if [[ ${READINESS_NOW_MS} -ge 10250 ]]; then printf '%s\n' "${ADMIN_LISTENER}"; fi
        ;;
      never|service-*) ;;
      forbidden-wildcard) printf '0.0.0.0:8788\n' ;;
      forbidden-management) printf '172.21.31.5:8788\n' ;;
      forbidden-transit) printf '10.1.1.222:8788\n' ;;
      forbidden-loopback) printf '127.0.0.1:8788\n' ;;
      forbidden-loopback-alt) printf '127.0.0.2:8788\n' ;;
      forbidden-ipv6-loopback) printf '[::1]:8788\n' ;;
      forbidden-ipv6-any) printf '[::]:8788\n' ;;
      multiple) printf '%s\n0.0.0.0:8788\n' "${ADMIN_LISTENER}" ;;
    esac
    return
  fi
  /usr/bin/ss -H -ltn 'sport = :8788' | /usr/bin/awk '{print $4}'
}

wait_for_admin_listener() {
  local deadline service_state listener_output addresses
  local -a listeners=()

  if [[ ${TEST_FAIL} == listener ]]; then
    die 'GATE_LISTENER injected test failure'
  fi
  readiness_set_now
  deadline=$((READINESS_NOW_MS + LISTENER_READINESS_TIMEOUT_MS))

  while true; do
    if (( READINESS_POLL > 0 )); then
      readiness_set_now
      if (( READINESS_NOW_MS >= deadline )); then
        die "GATE_LISTENER readiness timeout waiting for exactly ${ADMIN_LISTENER}"
      fi
    fi
    READINESS_POLL=$((READINESS_POLL + 1))
    service_state=$(admin_service_state)
    case "${service_state}" in
      active|activating) ;;
      failed|inactive|deactivating)
        if [[ ${TEST_MODE} == true ]]; then
          printf 'listener poll=%s service=%s count=not_checked addresses=not_checked\n' \
            "${READINESS_POLL}" "${service_state}" >>"${TEST_ACTIONS}"
        fi
        die "GATE_SERVICE readiness failed: warp-admin.service is ${service_state}"
        ;;
      *) die "GATE_SERVICE readiness failed: warp-admin.service state is ${service_state:-unknown}" ;;
    esac

    listeners=()
    if ! listener_output=$(admin_listener_snapshot); then
      die 'GATE_LISTENER listener inspection failed'
    fi
    if [[ -n ${listener_output} ]]; then
      mapfile -t listeners <<<"${listener_output}"
    fi
    if [[ ${#listeners[@]} -eq 0 ]]; then
      addresses=none
    else
      addresses=$(IFS=,; printf '%s' "${listeners[*]}")
    fi
    if [[ ${TEST_MODE} == true ]]; then
      printf 'listener poll=%s service=%s count=%s addresses=%s\n' \
        "${READINESS_POLL}" "${service_state}" "${#listeners[@]}" "${addresses}" \
        >>"${TEST_ACTIONS}"
    fi

    if [[ ${#listeners[@]} -gt 0 ]]; then
      if [[ ${#listeners[@]} -ne 1 || ${listeners[0]} != "${ADMIN_LISTENER}" ]]; then
        die "GATE_LISTENER unsafe listener state while waiting for exactly ${ADMIN_LISTENER}"
      fi
    fi

    readiness_set_now
    if (( READINESS_NOW_MS >= deadline )); then
      die "GATE_LISTENER readiness timeout waiting for exactly ${ADMIN_LISTENER}"
    fi
    if [[ ${#listeners[@]} -eq 1 ]]; then
      return 0
    fi
    readiness_sleep
  done
}

verify_admin_process() {
  [[ ${TEST_MODE} == false ]] || return 0
  local snapshot key value identity
  local -A properties=()
  if ! snapshot=$(/usr/bin/timeout --kill-after=5s 10s /usr/bin/systemctl show \
      --property=ActiveState,SubState,MainPID,ExecMainStartTimestampMonotonic,NRestarts \
      warp-admin.service); then
    die 'GATE_SERVICE cannot inspect the new Admin process'
  fi
  while IFS='=' read -r key value; do
    case "${key}" in
      ActiveState|SubState|MainPID|ExecMainStartTimestampMonotonic|NRestarts) ;;
      *) die 'GATE_SERVICE unexpected process metadata' ;;
    esac
    [[ ! -v properties[${key}] ]] || die 'GATE_SERVICE duplicate process metadata'
    properties[${key}]=${value}
  done <<<"${snapshot}"
  [[ ${#properties[@]} -eq 5 && ${properties[ActiveState]} == active \
      && ${properties[SubState]} == running && ${properties[NRestarts]} == 0 \
      && ${properties[MainPID]} =~ ^[1-9][0-9]{0,9}$ \
      && ${properties[ExecMainStartTimestampMonotonic]} =~ ^[1-9][0-9]{0,17}$ ]] \
    || die 'GATE_SERVICE Admin process is missing, not running, or automatically restarting'
  (( properties[ExecMainStartTimestampMonotonic] >= ADMIN_ACTIVATION_FLOOR_US )) \
    || die 'GATE_SERVICE Admin process predates the installed application/configuration'
  identity=${properties[MainPID]}:${properties[ExecMainStartTimestampMonotonic]}
  [[ -z ${ADMIN_PROCESS_IDENTITY:-} || ${ADMIN_PROCESS_IDENTITY} == "${identity}" ]] \
    || die 'GATE_SERVICE Admin process changed during readiness validation'
  ADMIN_PROCESS_IDENTITY=${identity}
}

# Resolve from existing trusted settings before account creation or installation.
# Only the explicit isolated test mode substitutes synthetic address evidence.
if [[ ${TEST_MODE} == true ]]; then
  if ! NETWORK_JSON=$("${PYTHON3_BIN}" -B - "${SOURCE_ROOT}" "${ROOT_PREFIX}" <<'PY'
from pathlib import Path
import json, os, sys
sys.path.insert(0, sys.argv[1])
from admin.network import resolve_install, NetworkConfigError
root = Path(sys.argv[2])
try:
    observed = json.loads((root / "network-addresses.json").read_text())
    config = resolve_install(root=root, observe=lambda name: observed[name],
                             required_uid=os.getuid(), required_gid=os.getgid())
    print(config.serialize(), end="")
except (OSError, ValueError, KeyError, NetworkConfigError):
    raise SystemExit(78)
PY
  ); then
    die 'GATE_NETWORK trusted management configuration is invalid'
  fi
else
  if ! NETWORK_JSON=$("${PYTHON3_BIN}" -I "${SOURCE_ROOT}/admin/network.py" --resolve); then
    die 'GATE_NETWORK trusted management configuration is invalid'
  fi
fi
ADMIN_ADDRESS=$(printf '%s' "${NETWORK_JSON}" | "${PYTHON3_BIN}" -c \
  'import json,sys; print(json.load(sys.stdin)["address"])')
readonly ADMIN_ADDRESS
readonly ADMIN_LISTENER="${ADMIN_ADDRESS}:8788"

if [[ ${TEST_MODE} == true ]]; then
  install_directory 0755 "${TEST_STATE_DIR}"
  : >>"${TEST_ACTIONS}"
fi

if [[ ${ACCOUNT_CREATE:-false} == true ]]; then
  if [[ ${TEST_MODE} == true ]]; then
    : >"${TEST_STATE_DIR}/test-account"
    printf 'useradd warp-admin\n' >>"${TEST_ACTIONS}"
  else
    /usr/sbin/useradd --system --user-group --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin warp-admin \
      || die 'GATE_IDENTITY failed to create warp-admin account'
    [[ $(account_state) == safe ]] \
      || die 'GATE_IDENTITY created warp-admin account failed validation'
  fi
fi

install_directory 0755 "${CONFIG_DIR}"
# Non-secret projection: root-owned, service-readable, atomic fixed-directory replacement.
network_temp=$(mktemp "${CONFIG_DIR}/.network.XXXXXXXX")
trap 'rm -f -- "${network_temp}"' EXIT
printf '%s\n' "${NETWORK_JSON}" >"${network_temp}"
chmod 0644 "${network_temp}"
if [[ ${TEST_MODE} == false ]]; then chown root:root "${network_temp}"; fi
mv -f -- "${network_temp}" "${NETWORK_DEST}"
if [[ ${ACCOUNT_CREATE:-false} == true ]]; then
  marker_temp=${ACCOUNT_MARKER}.tmp.$$
  printf 'warp-admin\n' >"${marker_temp}"
  chmod 0600 "${marker_temp}"
  if [[ ${TEST_MODE} == false ]]; then chown root:root "${marker_temp}"; fi
  mv -f -- "${marker_temp}" "${ACCOUNT_MARKER}"
fi

install_directory 0755 "${ADMIN_APP}"
# Publish one complete immutable version before installing the helper that uses
# it. Reinstall reuses an identical safe bundle; changed versions need a new ID.
install_directory 0755 "${READONLY_PARENT}"
if [[ ! -e ${READONLY_BUNDLE} ]]; then
  foundation_temporary=$(mktemp -d "${READONLY_PARENT}/.v2.XXXXXXXX")
  for name in "${readonly_files[@]}"; do
    mode=0644
    if [[ ${name} == evaluate.py ]]; then mode=0755; fi
    install_file "${mode}" "$(readonly_source "${name}")" "${foundation_temporary}/${name}"
  done
  chmod 0755 "${foundation_temporary}"
  validate_foundation_bundle "${foundation_temporary}"
  # -T forbids accidentally nesting a bundle if another installer won the race;
  # an existing nonempty version cannot be replaced by this directory rename.
  mv -T -- "${foundation_temporary}" "${READONLY_BUNDLE}"
fi
validate_foundation_bundle "${READONLY_BUNDLE}"
for relative in "${app_files[@]}"; do
  install_file 0644 "${SOURCE_ROOT}/admin/${relative}" "${ADMIN_APP}/${relative}"
done
install_file 0755 "${SOURCE_ROOT}/admin/helper.py" "${HELPER_DEST}"
install_file 0644 "${SOURCE_ROOT}/admin/protocol.py" "${PROTOCOL_DEST}"

if [[ ${TEST_FAIL} == sudoers ]]; then
  die 'GATE_SUDOERS injected test failure'
fi
"${VISUDO_BIN}" -cf "${SCRIPT_DIR}/sudoers/warp-egress-gateway-admin" >/dev/null \
  || die 'GATE_SUDOERS packaged policy is invalid'
install_file 0440 "${SCRIPT_DIR}/sudoers/warp-egress-gateway-admin" "${SUDOERS_DEST}"
"${VISUDO_BIN}" -cf "${SUDOERS_DEST}" >/dev/null \
  || die 'GATE_SUDOERS installed policy is invalid'
install_file 0644 "${SCRIPT_DIR}/systemd/warp-admin.service" "${UNIT_DEST}"
install_directory 0700 "${RUNTIME_DIR}" warp-admin warp-admin

install_file 0644 "${TMPFILES_SOURCE}" "${TMPFILES_DEST}"
[[ -f ${TMPFILES_DEST} && ! -L ${TMPFILES_DEST} \
    && $(stat -c '%u:%g:%a' -- "${TMPFILES_DEST}") == "${RUNTIME_OWNER}:644" ]] \
  || die 'GATE_SHARED_RUNTIME installed tmpfiles metadata is unsafe'
if [[ -e ${SHARED_RUNTIME_DIR} || -L ${SHARED_RUNTIME_DIR} ]]; then
  validate_shared_runtime
fi
if [[ ${TEST_MODE} == true ]]; then
  # Real tmpfiles, isolated filesystem only. Map root to the fixture owner for
  # unprivileged CI; neither installed rule nor production command is changed.
  sed "s/ root root / ${RUNTIME_OWNER/:/ } /" "${TMPFILES_DEST}" \
    | /usr/bin/systemd-tmpfiles --root="${ROOT_PREFIX}" --create - \
    || die 'GATE_SHARED_RUNTIME tmpfiles creation failed'
else
  /usr/bin/systemd-tmpfiles --create "${TMPFILES_DEST}" \
    || die 'GATE_SHARED_RUNTIME tmpfiles creation failed'
fi
validate_shared_runtime
# The rule creates only the parent. Never create, unlink or replace its shared
# admin-mutation.lock; the authoritative lock implementation owns that lifecycle.

if [[ ${TEST_FAIL} == metadata ]]; then
  die 'GATE_METADATA injected test failure'
fi
[[ $(stat -c '%a' -- "${HELPER_DEST}") == 755 \
    && $(stat -c '%a' -- "${PROTOCOL_DEST}") == 644 \
    && $(stat -c '%a' -- "${NETWORK_DEST}") == 644 \
    && $(stat -c '%a' -- "${SUDOERS_DEST}") == 440 \
    && $(stat -c '%a' -- "${UNIT_DEST}") == 644 \
    && $(stat -c '%a' -- "${RUNTIME_DIR}") == 700 ]] \
  || die 'GATE_METADATA installed modes are unsafe'
if [[ ${TEST_MODE} == false ]]; then
  for relative in "${app_files[@]}"; do
    [[ $(stat -c '%u:%g:%a' -- "${ADMIN_APP}/${relative}") == 0:0:644 ]] \
      || die "GATE_METADATA application file metadata is unsafe: ${relative}"
  done
  for root_file in "${HELPER_DEST}" "${PROTOCOL_DEST}" "${SUDOERS_DEST}" "${UNIT_DEST}" "${NETWORK_DEST}"; do
    [[ $(stat -c '%u:%g' -- "${root_file}") == 0:0 ]] \
      || die "GATE_METADATA installed file is not root-owned: ${root_file}"
  done
  [[ $(stat -c '%U:%G:%a' -- "${RUNTIME_DIR}") == warp-admin:warp-admin:700 ]] \
    || die 'GATE_METADATA runtime directory metadata is unsafe'
fi

if [[ ${TEST_MODE} == true ]]; then
  printf 'systemctl daemon-reload\nsystemctl enable warp-admin.service\nsystemctl restart warp-admin.service\n' >>"${TEST_ACTIONS}"
else
  # CLOCK_MONOTONIC matches systemd's ExecMainStartTimestampMonotonic. Capture
  # only after all installed files/configuration and metadata checks complete.
  ADMIN_ACTIVATION_FLOOR_US=$("${PYTHON3_BIN}" -I -c 'import time; print(time.monotonic_ns() // 1000)')
  [[ ${ADMIN_ACTIVATION_FLOOR_US} =~ ^[1-9][0-9]{0,17}$ ]] \
    || die 'GATE_SERVICE activation clock unavailable'
  readonly ADMIN_ACTIVATION_FLOOR_US
  /usr/bin/timeout --kill-after=5s 30s /usr/bin/systemctl daemon-reload \
    || die 'GATE_SERVICE daemon-reload failed or timed out'
  /usr/bin/timeout --kill-after=5s 30s /usr/bin/systemctl enable warp-admin.service \
    || die 'GATE_SERVICE Admin enable failed or timed out'
  # restart also starts an inactive/never-started unit; enable --now would
  # leave an already-active process using its old application/configuration.
  /usr/bin/timeout --kill-after=5s 30s /usr/bin/systemctl restart warp-admin.service \
    || die 'GATE_SERVICE Admin restart failed or timed out'
  /usr/bin/timeout --kill-after=5s 10s /usr/bin/systemctl is-enabled --quiet warp-admin.service \
    || die 'GATE_SERVICE warp-admin.service is not enabled'
fi

verify_admin_process
wait_for_admin_listener
verify_admin_process
if [[ ${TEST_MODE} == true ]]; then
  printf 'listener %s AF_INET only\n' "${ADMIN_LISTENER}" >>"${TEST_ACTIONS}"
fi

if [[ ${TEST_FAIL} == http ]]; then
  die 'GATE_HTTP injected test failure'
fi
if [[ ${TEST_MODE} == true ]]; then
  printf 'http GET / then GET /api/status\n' >>"${TEST_ACTIONS}"
else
  "${PYTHON3_BIN}" - "${ADMIN_ADDRESS}" <<'PY' || die 'GATE_HTTP Admin HTTP smoke test failed'
import http.client
import re
import sys

address = sys.argv[1]
host = f"{address}:8788"
connection = http.client.HTTPConnection(address, 8788, timeout=60)
connection.request("GET", "/", headers={"Host": host})
response = connection.getresponse()
body = response.read()
if response.status != 200:
    raise SystemExit(1)
cookie = response.getheader("Set-Cookie", "").split(";", 1)[0]
if not re.fullmatch(r"warp_admin_session=[A-Za-z0-9_-]{43}", cookie):
    raise SystemExit(1)
connection.request("GET", "/api/status", headers={"Host": host, "Cookie": cookie})
response = connection.getresponse()
body = response.read()
if response.status != 200 or b'"protocol":1' not in body or b'"changed":false' not in body:
    raise SystemExit(1)
connection.close()
PY
fi

verify_admin_process
log "service_identity=warp-admin listener=${ADMIN_LISTENER} helper=read-only"
printf 'ADMIN_INSTALL_OK http://%s\n' "${ADMIN_LISTENER}"
