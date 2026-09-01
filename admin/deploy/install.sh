#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
TEST_MODE=false
ROOT_PREFIX=""
TEST_FAIL=""
PYTHON3_BIN=/usr/bin/python3

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
  PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
elif [[ -n ${WARP_ADMIN_TEST_ROOT:-} ]]; then
  die 'GATE_TEST_ROOT test root requires explicit test mode'
else
  [[ ${EUID} -eq 0 ]] || die 'GATE_ROOT run as root'
fi

root_path() { printf '%s%s' "${ROOT_PREFIX}" "$1"; }

APP_BASE=$(root_path /opt/warp-egress-admin-console)
APP_ROOT=${APP_BASE}/app
ADMIN_APP=${APP_ROOT}/admin
RUNTIME_DIR=$(root_path /run/warp-egress-admin-console)
CONFIG_DIR=$(root_path /etc/warp-egress-admin-console)
ACCOUNT_MARKER=${CONFIG_DIR}/.warp-admin-created
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
  "${SCRIPT_DIR}/sudoers/warp-egress-gateway-admin"; do
  [[ -f ${source} && ! -L ${source} ]] || die "GATE_SOURCE missing or unsafe file: ${source}"
done
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
for destination in "${HELPER_DEST}" "${PROTOCOL_DEST}" "${UNIT_DEST}" "${SUDOERS_DEST}"; do
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
if [[ ${ACCOUNT_CREATE:-false} == true ]]; then
  marker_temp=${ACCOUNT_MARKER}.tmp.$$
  printf 'warp-admin\n' >"${marker_temp}"
  chmod 0600 "${marker_temp}"
  if [[ ${TEST_MODE} == false ]]; then chown root:root "${marker_temp}"; fi
  mv -f -- "${marker_temp}" "${ACCOUNT_MARKER}"
fi

install_directory 0755 "${ADMIN_APP}"
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

if [[ ${TEST_FAIL} == metadata ]]; then
  die 'GATE_METADATA injected test failure'
fi
[[ $(stat -c '%a' -- "${HELPER_DEST}") == 755 \
    && $(stat -c '%a' -- "${PROTOCOL_DEST}") == 644 \
    && $(stat -c '%a' -- "${SUDOERS_DEST}") == 440 \
    && $(stat -c '%a' -- "${UNIT_DEST}") == 644 \
    && $(stat -c '%a' -- "${RUNTIME_DIR}") == 700 ]] \
  || die 'GATE_METADATA installed modes are unsafe'
if [[ ${TEST_MODE} == false ]]; then
  for relative in "${app_files[@]}"; do
    [[ $(stat -c '%u:%g:%a' -- "${ADMIN_APP}/${relative}") == 0:0:644 ]] \
      || die "GATE_METADATA application file metadata is unsafe: ${relative}"
  done
  for root_file in "${HELPER_DEST}" "${PROTOCOL_DEST}" "${SUDOERS_DEST}" "${UNIT_DEST}"; do
    [[ $(stat -c '%u:%g' -- "${root_file}") == 0:0 ]] \
      || die "GATE_METADATA installed file is not root-owned: ${root_file}"
  done
  [[ $(stat -c '%U:%G:%a' -- "${RUNTIME_DIR}") == warp-admin:warp-admin:700 ]] \
    || die 'GATE_METADATA runtime directory metadata is unsafe'
fi

if [[ ${TEST_MODE} == true ]]; then
  printf 'systemctl daemon-reload\nsystemctl enable --now warp-admin.service\n' >>"${TEST_ACTIONS}"
else
  /usr/bin/systemctl daemon-reload
  /usr/bin/systemctl enable --now warp-admin.service
  /usr/bin/systemctl is-active --quiet warp-admin.service \
    || die 'GATE_SERVICE warp-admin.service is not active'
  /usr/bin/systemctl is-enabled --quiet warp-admin.service \
    || die 'GATE_SERVICE warp-admin.service is not enabled'
fi

if [[ ${TEST_FAIL} == listener ]]; then
  die 'GATE_LISTENER injected test failure'
fi
if [[ ${TEST_MODE} == true ]]; then
  printf 'listener 127.0.0.1:8788 AF_INET only\n' >>"${TEST_ACTIONS}"
else
  mapfile -t listeners < <(/usr/bin/ss -H -ltn 'sport = :8788' | /usr/bin/awk '{print $4}')
  [[ ${#listeners[@]} -eq 1 && ${listeners[0]} == 127.0.0.1:8788 ]] \
    || die 'GATE_LISTENER expected exactly 127.0.0.1:8788'
fi

if [[ ${TEST_FAIL} == http ]]; then
  die 'GATE_HTTP injected test failure'
fi
if [[ ${TEST_MODE} == true ]]; then
  printf 'http GET / then GET /api/status\n' >>"${TEST_ACTIONS}"
else
  "${PYTHON3_BIN}" - <<'PY' || die 'GATE_HTTP Admin HTTP smoke test failed'
import http.client
import re

connection = http.client.HTTPConnection("127.0.0.1", 8788, timeout=60)
connection.request("GET", "/", headers={"Host": "127.0.0.1:8788"})
response = connection.getresponse()
body = response.read()
if response.status != 200:
    raise SystemExit(1)
cookie = response.getheader("Set-Cookie", "").split(";", 1)[0]
if not re.fullmatch(r"warp_admin_session=[A-Za-z0-9_-]{43}", cookie):
    raise SystemExit(1)
connection.request("GET", "/api/status", headers={"Host": "127.0.0.1:8788", "Cookie": cookie})
response = connection.getresponse()
body = response.read()
if response.status != 200 or b'"protocol":1' not in body or b'"changed":false' not in body:
    raise SystemExit(1)
connection.close()
PY
fi

log 'service_identity=warp-admin listener=127.0.0.1:8788 helper=read-only'
printf 'ADMIN_INSTALL_OK http://127.0.0.1:8788\n'
