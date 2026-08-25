#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd)
TEST_MODE=false
TEST_FAIL=""
ROOT_PREFIX=""
PYTHON3_BIN=/usr/bin/python3

log() { printf 'DASHBOARD_INSTALL %s\n' "$*"; }
die() { printf 'DASHBOARD_INSTALL_ERROR %s\n' "$*" >&2; exit 1; }

if [[ ${WARP_DASHBOARD_TEST_MODE:-0} == 1 ]]; then
  TEST_MODE=true
  ROOT_PREFIX=${WARP_DASHBOARD_TEST_ROOT:-}
  [[ ${ROOT_PREFIX} == /* && -d ${ROOT_PREFIX} && ! -L ${ROOT_PREFIX} ]] \
    || die 'GATE_TEST_ROOT invalid isolated root'
  ROOT_PREFIX=$(cd -- "${ROOT_PREFIX}" && pwd)
  [[ ${ROOT_PREFIX} != / ]] || die 'GATE_TEST_ROOT refused filesystem root'
  PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
  TEST_FAIL=${WARP_DASHBOARD_TEST_FAIL:-}
  [[ -z ${TEST_FAIL} || ${TEST_FAIL} =~ ^(collector|snapshot|web|listener|http)$ ]] \
    || die 'GATE_TEST_FAILURE unknown injected failure'
elif [[ -n ${WARP_DASHBOARD_TEST_ROOT:-} ]]; then
  die 'GATE_TEST_ROOT test root requires explicit test mode'
else
  [[ ${EUID} -eq 0 ]] || die 'GATE_ROOT run as root'
fi

root_path() { printf '%s%s' "${ROOT_PREFIX}" "$1"; }

CONFIG_DIR=$(root_path /etc/warp-egress-dashboard)
CONFIG_FILE=${CONFIG_DIR}/dashboard.env
ACCOUNT_MARKER=${CONFIG_DIR}/.warp-web-created
APP_BASE=$(root_path /opt/warp-egress-dashboard)
APP_ROOT=${APP_BASE}/app
RUNTIME_DIR=$(root_path /run/warp-egress-dashboard)
STATUS_FILE=${RUNTIME_DIR}/status.json
TMPFILES_DEST=$(root_path /etc/tmpfiles.d/warp-egress-dashboard.conf)
UNIT_DIR=$(root_path /etc/systemd/system)
TEST_STATE_DIR=$(root_path /var/lib/warp-egress-dashboard)
TEST_ACTIONS=${TEST_STATE_DIR}/test-actions.log

usage() {
  cat <<'USAGE'
Usage: sudo ./install.sh [--config PATH]

  --config PATH  Validate and install this configuration. Without this option,
                 preserve an existing valid production config or install the
                 loopback-safe example on first installation.
USAGE
}

CONFIG_SOURCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 && -n $2 ]] || die 'GATE_ARGUMENT missing path after --config'
      CONFIG_SOURCE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "GATE_ARGUMENT unknown option: $1"
      ;;
  esac
done

runtime_files=(
  web/__init__.py
  web/dashboard/__init__.py
  web/dashboard/collector.py
  web/dashboard/schema.py
  web/dashboard/server.py
  web/dashboard/status-schema.json
  web/dashboard/static/index.html
  web/dashboard/static/styles.css
  web/dashboard/static/app.js
  web/dashboard/deploy/__init__.py
  web/dashboard/deploy/launcher.py
)
for relative in "${runtime_files[@]}"; do
  [[ -f ${SOURCE_ROOT}/${relative} && ! -L ${SOURCE_ROOT}/${relative} ]] \
    || die "GATE_SOURCE missing or unsafe runtime file: ${relative}"
done
for relative in \
  web/dashboard/deploy/dashboard.env.example \
  web/dashboard/deploy/tmpfiles/warp-egress-dashboard.conf \
  web/dashboard/deploy/systemd/warp-dashboard.service \
  web/dashboard/deploy/systemd/warp-dashboard-collector.service \
  web/dashboard/deploy/systemd/warp-dashboard-collector.timer; do
  [[ -f ${SOURCE_ROOT}/${relative} && ! -L ${SOURCE_ROOT}/${relative} ]] \
    || die "GATE_SOURCE missing or unsafe deployment file: ${relative}"
done
if ! command -v "${PYTHON3_BIN}" >/dev/null 2>&1 && [[ ! -x ${PYTHON3_BIN} ]]; then
  die "GATE_PYTHON Python 3 is unavailable: ${PYTHON3_BIN}"
fi

validate_config() {
  local path=$1 output
  [[ -f ${path} && ! -L ${path} ]] || die "GATE_CONFIG missing or unsafe file: ${path}"
  if ! output=$(PYTHONDONTWRITEBYTECODE=1 "${PYTHON3_BIN}" \
      "${SOURCE_ROOT}/web/dashboard/deploy/launcher.py" --check-config "${path}" 2>&1); then
    die "GATE_CONFIG ${output}"
  fi
  mapfile -t config_lines <<<"${output}"
  [[ ${#config_lines[@]} -eq 2 \
      && ${config_lines[0]} == DASHBOARD_LISTEN=* \
      && ${config_lines[1]} == DASHBOARD_PORT=* ]] \
    || die 'GATE_CONFIG validator output is malformed'
  DASHBOARD_LISTEN=${config_lines[0]#DASHBOARD_LISTEN=}
  DASHBOARD_PORT=${config_lines[1]#DASHBOARD_PORT=}
}

if [[ -n ${CONFIG_SOURCE} ]]; then
  CONFIG_CANDIDATE=${CONFIG_SOURCE}
  REPLACE_CONFIG=true
elif [[ -e ${CONFIG_FILE} ]]; then
  CONFIG_CANDIDATE=${CONFIG_FILE}
  REPLACE_CONFIG=false
else
  CONFIG_CANDIDATE=${SOURCE_ROOT}/web/dashboard/deploy/dashboard.env.example
  REPLACE_CONFIG=true
fi
validate_config "${CONFIG_CANDIDATE}"
if [[ ${REPLACE_CONFIG} == false ]]; then
  [[ -f ${CONFIG_FILE} && ! -L ${CONFIG_FILE} ]] || die 'GATE_CONFIG installed config is unsafe'
  if [[ ${TEST_MODE} == false ]]; then
    config_meta=$(stat -c '%u:%g:%a' "${CONFIG_FILE}")
    config_mode=${config_meta##*:}
    (( (8#${config_mode} & 8#22) == 0 )) || die 'GATE_CONFIG installed config is writable by group or others'
    [[ ${config_meta%:*} == 0:0 ]] || die 'GATE_CONFIG installed config is not root-owned'
  fi
fi

for destination_root in "${CONFIG_DIR}" "${APP_BASE}" "${RUNTIME_DIR}"; do
  if [[ -e ${destination_root} || -L ${destination_root} ]]; then
    [[ -d ${destination_root} && ! -L ${destination_root} ]] \
      || die "GATE_DESTINATION unsafe dashboard-owned path: ${destination_root}"
  fi
done
if [[ -d ${APP_BASE} && -n $(find "${APP_BASE}" -type l -print -quit) ]]; then
  die 'GATE_DESTINATION application tree contains a symlink'
fi

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
[[ ${identity} != unsafe ]] || die 'GATE_IDENTITY conflicting warp-web account or group'
if [[ -e ${ACCOUNT_MARKER} || -L ${ACCOUNT_MARKER} ]]; then
  [[ ${identity} == safe && -f ${ACCOUNT_MARKER} && ! -L ${ACCOUNT_MARKER} \
      && $(<"${ACCOUNT_MARKER}") == warp-web ]] \
    || die 'GATE_IDENTITY account ownership marker is unsafe or inconsistent'
  if [[ ${TEST_MODE} == false ]]; then
    [[ $(stat -c '%u:%g:%a' "${ACCOUNT_MARKER}") == 0:0:600 ]] \
      || die 'GATE_IDENTITY account ownership marker metadata is unsafe'
  fi
elif [[ ${identity} == absent ]]; then
  ACCOUNT_CREATE=true
else
  ACCOUNT_CREATE=false
fi

install_directory() {
  local mode=$1 path=$2
  if [[ ${TEST_MODE} == true ]]; then
    install -d -m "${mode}" "${path}"
  else
    install -d -o root -g root -m "${mode}" "${path}"
  fi
}

install_file() {
  local mode=$1 source=$2 destination=$3 temporary
  install_directory 0755 "$(dirname -- "${destination}")"
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
    printf 'useradd warp-web\n' >>"${TEST_ACTIONS}"
  else
    /usr/sbin/useradd --system --user-group --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin warp-web \
      || die 'GATE_IDENTITY failed to create warp-web account'
    [[ $(account_state) == safe ]] || die 'GATE_IDENTITY created warp-web account failed validation'
  fi
fi

install_directory 0755 "${CONFIG_DIR}"
if [[ ${ACCOUNT_CREATE:-false} == true ]]; then
  marker_temp=${ACCOUNT_MARKER}.tmp.$$
  printf 'warp-web\n' >"${marker_temp}"
  chmod 0600 "${marker_temp}"
  if [[ ${TEST_MODE} == false ]]; then chown root:root "${marker_temp}"; fi
  mv -f -- "${marker_temp}" "${ACCOUNT_MARKER}"
fi
if [[ ${REPLACE_CONFIG} == true ]]; then
  install_file 0644 "${CONFIG_CANDIDATE}" "${CONFIG_FILE}"
fi
validate_config "${CONFIG_FILE}"

install_directory 0755 "${APP_ROOT}"
for relative in "${runtime_files[@]}"; do
  install_file 0644 "${SOURCE_ROOT}/${relative}" "${APP_ROOT}/${relative}"
done
install_file 0644 "${SOURCE_ROOT}/web/dashboard/deploy/tmpfiles/warp-egress-dashboard.conf" "${TMPFILES_DEST}"
install_file 0644 "${SOURCE_ROOT}/web/dashboard/deploy/systemd/warp-dashboard.service" "${UNIT_DIR}/warp-dashboard.service"
install_file 0644 "${SOURCE_ROOT}/web/dashboard/deploy/systemd/warp-dashboard-collector.service" "${UNIT_DIR}/warp-dashboard-collector.service"
install_file 0644 "${SOURCE_ROOT}/web/dashboard/deploy/systemd/warp-dashboard-collector.timer" "${UNIT_DIR}/warp-dashboard-collector.timer"

if [[ ${TEST_MODE} == true ]]; then
  install_directory 0750 "${RUNTIME_DIR}"
  install -m 0640 "${SOURCE_ROOT}/web/dashboard/fixtures/healthy.json" "${STATUS_FILE}"
  printf 'systemd-tmpfiles --create %s\n' "${TMPFILES_DEST}" >>"${TEST_ACTIONS}"
  [[ ${TEST_FAIL} != collector ]] || die 'GATE_COLLECTOR injected test failure'
  if [[ ${TEST_FAIL} == snapshot ]]; then rm -f -- "${STATUS_FILE}"; fi
else
  /usr/bin/systemd-tmpfiles --create "${TMPFILES_DEST}"
  [[ -d ${RUNTIME_DIR} && ! -L ${RUNTIME_DIR} \
      && $(stat -c '%U:%G:%a' "${RUNTIME_DIR}") == root:warp-web:750 ]] \
    || die 'GATE_RUNTIME runtime directory metadata is unsafe'
  (
    cd -- "${APP_ROOT}"
    /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
      LANG=C LC_ALL=C PYTHONDONTWRITEBYTECODE=1 \
      /usr/bin/python3 -m web.dashboard.collector
  ) || die 'GATE_COLLECTOR manual collector execution failed'
fi

[[ -f ${STATUS_FILE} && ! -L ${STATUS_FILE} ]] || die 'GATE_SNAPSHOT status snapshot is missing or unsafe'
if [[ ${TEST_MODE} == false ]]; then
  [[ $(stat -c '%U:%G:%a' "${STATUS_FILE}") == root:warp-web:640 ]] \
    || die 'GATE_SNAPSHOT status snapshot metadata is unsafe'
fi
if [[ ${TEST_MODE} == true ]]; then
  PYTHON_ENV=(/usr/bin/env PYTHONDONTWRITEBYTECODE=1)
else
  PYTHON_ENV=(/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    LANG=C LC_ALL=C PYTHONDONTWRITEBYTECODE=1)
fi
"${PYTHON_ENV[@]}" "${PYTHON3_BIN}" - "${APP_ROOT}" "${STATUS_FILE}" <<'PY' \
  || die 'GATE_SNAPSHOT status snapshot validation failed'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from web.dashboard.schema import loads_status
loads_status(Path(sys.argv[2]).read_bytes())
PY

systemctl_command() {
  if [[ ${TEST_MODE} == true ]]; then
    {
      printf 'systemctl'
      printf ' %s' "$@"
      printf '\n'
    } >>"${TEST_ACTIONS}"
    case "$1" in
      is-active)
        if [[ ${TEST_FAIL} == web && ${2:-} == warp-dashboard.service ]]; then
          printf 'inactive\n'
        else
          printf 'active\n'
        fi
        ;;
      is-enabled) printf 'enabled\n' ;;
    esac
  else
    /usr/bin/systemctl "$@"
  fi
}

systemctl_command daemon-reload || die 'GATE_SYSTEMD daemon-reload failed'
systemctl_command enable warp-dashboard-collector.timer warp-dashboard.service \
  || die 'GATE_SYSTEMD unit enable failed'
systemctl_command restart warp-dashboard-collector.timer \
  || die 'GATE_SYSTEMD collector timer restart failed'
systemctl_command restart warp-dashboard.service \
  || die 'GATE_SYSTEMD web service restart failed'
[[ $(systemctl_command is-active warp-dashboard-collector.timer) == active \
    && $(systemctl_command is-enabled warp-dashboard-collector.timer) == enabled ]] \
  || die 'GATE_TIMER collector timer is not active and enabled'
[[ $(systemctl_command is-active warp-dashboard.service) == active \
    && $(systemctl_command is-enabled warp-dashboard.service) == enabled ]] \
  || die 'GATE_WEB dashboard service is not active and enabled'

[[ ${TEST_FAIL} != listener ]] || die 'GATE_LISTENER injected test failure'
[[ ${TEST_FAIL} != http ]] || die 'GATE_HTTP injected test failure'
if [[ ${TEST_MODE} == false ]]; then
  /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C LC_ALL=C \
    PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - \
    "${DASHBOARD_LISTEN}" "${DASHBOARD_PORT}" <<'PY' \
    || die 'GATE_LISTENER dashboard listener is not exact'
import subprocess, sys, time
listen, port = sys.argv[1:]
expected = f"{listen}:{port}"
for _ in range(20):
    result = subprocess.run(
        ["/usr/bin/ss", "-H", "-ltn", f"sport = :{port}"],
        check=True, capture_output=True, text=True,
    )
    addresses = [line.split()[3] for line in result.stdout.splitlines() if line.strip()]
    if addresses == [expected]:
        break
    time.sleep(0.25)
else:
    raise SystemExit(f"listener mismatch: {addresses!r}")
PY
  /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C LC_ALL=C \
    PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - \
    "${DASHBOARD_LISTEN}" "${DASHBOARD_PORT}" <<'PY' \
    || die 'GATE_HTTP dashboard health or status endpoint failed'
import json, sys, time, urllib.request
base = f"http://{sys.argv[1]}:{sys.argv[2]}"
last_error = None
for _ in range(20):
    try:
        with urllib.request.urlopen(base + "/healthz", timeout=2) as response:
            if response.status != 200 or json.load(response) != {"ok": True}:
                raise RuntimeError("health response is invalid")
        with urllib.request.urlopen(base + "/api/status", timeout=2) as response:
            status = json.load(response)
            if response.status != 200 or status.get("schema_version") != 1:
                raise RuntimeError("status response is invalid")
        break
    except Exception as exc:
        last_error = exc
        time.sleep(0.25)
else:
    raise SystemExit(f"HTTP validation failed: {last_error}")
PY
fi

log "CONFIG ${DASHBOARD_LISTEN}:${DASHBOARD_PORT}"
printf 'DASHBOARD_INSTALL_OK http://%s:%s\n' "${DASHBOARD_LISTEN}" "${DASHBOARD_PORT}"
