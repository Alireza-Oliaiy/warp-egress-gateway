#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}

if ! command -v "${PYTHON3_BIN}" >/dev/null 2>&1 && [[ ! -x ${PYTHON3_BIN} ]]; then
  echo "Python 3 is required for dashboard deployment tests: ${PYTHON3_BIN}" >&2
  exit 1
fi

(cd "${ROOT}" && "${PYTHON3_BIN}" tests/dashboard_deploy_test.py)

DEPLOY=${ROOT}/web/dashboard/deploy
TEST_AREA=$(mktemp -d)
trap 'rm -rf "${TEST_AREA}"' EXIT

write_config() {
  local path=$1 listen=$2 port=$3
  printf 'DASHBOARD_LISTEN=%s\nDASHBOARD_PORT=%s\n' "${listen}" "${port}" >"${path}"
}

run_install() {
  local rootfs=$1 account=${2:-absent}
  shift 2 || true
  WARP_DASHBOARD_TEST_MODE=1 \
    WARP_DASHBOARD_TEST_ROOT="${rootfs}" \
    WARP_DASHBOARD_TEST_ACCOUNT="${account}" \
    WARP_DASHBOARD_TEST_FAIL="${WARP_DASHBOARD_TEST_FAIL:-}" \
    WARP_GATEWAY_PYTHON3="${PYTHON3_BIN}" \
    bash "${DEPLOY}/install.sh" "$@"
}

run_uninstall() {
  local rootfs=$1 account=${2:-absent}
  WARP_DASHBOARD_TEST_MODE=1 \
    WARP_DASHBOARD_TEST_ROOT="${rootfs}" \
    WARP_DASHBOARD_TEST_ACCOUNT="${account}" \
    bash "${DEPLOY}/uninstall.sh"
}

version_before=$(sha256sum "${ROOT}/VERSION" | awk '{print $1}')
rootfs=${TEST_AREA}/rootfs
mkdir -p "${rootfs}"
config=${TEST_AREA}/dashboard.env
write_config "${config}" 192.0.2.10 8787
first_output=$(run_install "${rootfs}" absent --config "${config}")
grep -qx 'DASHBOARD_INSTALL_OK http://192.0.2.10:8787' <<<"${first_output}"

required_runtime=(
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
for relative in "${required_runtime[@]}"; do
  cmp "${ROOT}/${relative}" "${rootfs}/opt/warp-egress-dashboard/app/${relative}"
done
[[ ! -e ${rootfs}/opt/warp-egress-dashboard/app/web/dashboard/fixtures ]]
[[ $(stat -c '%a' "${rootfs}/opt/warp-egress-dashboard/app/web/dashboard/server.py") == 644 ]]
[[ $(stat -c '%a' "${rootfs}/run/warp-egress-dashboard") == 750 ]]
[[ -f ${rootfs}/run/warp-egress-dashboard/status.json ]]
[[ $(stat -c '%a' "${rootfs}/run/warp-egress-dashboard/status.json") == 640 ]]
[[ -f ${rootfs}/etc/warp-egress-dashboard/.warp-web-created ]]
[[ -f ${rootfs}/var/lib/warp-egress-dashboard/test-account ]]
[[ -f ${rootfs}/etc/systemd/system/warp-dashboard.service ]]
[[ -f ${rootfs}/etc/systemd/system/warp-dashboard-collector.service ]]
[[ -f ${rootfs}/etc/systemd/system/warp-dashboard-collector.timer ]]
[[ -f ${rootfs}/etc/tmpfiles.d/warp-egress-dashboard.conf ]]

# A reinstall without --config preserves the already-installed validated config.
write_config "${rootfs}/etc/warp-egress-dashboard/dashboard.env" 192.0.2.20 8787
second_output=$(run_install "${rootfs}" absent)
grep -qx 'DASHBOARD_INSTALL_OK http://192.0.2.20:8787' <<<"${second_output}"
[[ $(grep -c '^useradd warp-web$' "${rootfs}/var/lib/warp-egress-dashboard/test-actions.log") == 1 ]]

# Supplying --config is an intentional deterministic replacement.
replacement=${TEST_AREA}/replacement.env
write_config "${replacement}" 192.0.2.30 9443
third_output=$(run_install "${rootfs}" absent --config "${replacement}")
grep -qx 'DASHBOARD_INSTALL_OK http://192.0.2.30:9443' <<<"${third_output}"
cmp "${replacement}" "${rootfs}/etc/warp-egress-dashboard/dashboard.env"

# Invalid configuration fails before any installation mutation.
for case_name in wildcard invalid_port; do
  bad_root=${TEST_AREA}/${case_name}-root
  mkdir -p "${bad_root}"
  bad_config=${TEST_AREA}/${case_name}.env
  if [[ ${case_name} == wildcard ]]; then
    write_config "${bad_config}" 0.0.0.0 8787
  else
    write_config "${bad_config}" 127.0.0.1 0
  fi
  if run_install "${bad_root}" absent --config "${bad_config}" >"${TEST_AREA}/${case_name}.out" 2>&1; then
    echo "Installer accepted ${case_name}." >&2
    exit 1
  fi
  grep -q 'GATE_CONFIG' "${TEST_AREA}/${case_name}.out"
  [[ ! -e ${bad_root}/opt/warp-egress-dashboard ]]
  [[ ! -e ${bad_root}/etc/systemd/system/warp-dashboard.service ]]
done

# Every post-mutation success gate must remain fail closed and omit success.
for failure in collector snapshot web listener http; do
  failure_root=${TEST_AREA}/failure-${failure}-root
  mkdir -p "${failure_root}"
  if WARP_DASHBOARD_TEST_FAIL=${failure} run_install \
      "${failure_root}" absent --config "${config}" >"${TEST_AREA}/failure-${failure}.out" 2>&1; then
    echo "Installer claimed success after injected ${failure} failure." >&2
    exit 1
  fi
  grep -q "GATE_${failure^^}" "${TEST_AREA}/failure-${failure}.out"
  if grep -q '^DASHBOARD_INSTALL_OK ' "${TEST_AREA}/failure-${failure}.out"; then
    echo "Installer emitted success after injected ${failure} failure." >&2
    exit 1
  fi
done

# Dashboard-owned destination roots must never be followed through symlinks.
symlink_root=${TEST_AREA}/symlink-root
symlink_outside=${TEST_AREA}/symlink-outside
mkdir -p "${symlink_root}/opt" "${symlink_outside}"
ln -s "${symlink_outside}" "${symlink_root}/opt/warp-egress-dashboard"
if run_install "${symlink_root}" absent --config "${config}" >"${TEST_AREA}/symlink.out" 2>&1; then
  echo "Installer followed a symlinked dashboard destination." >&2
  exit 1
fi
grep -q 'GATE_DESTINATION' "${TEST_AREA}/symlink.out"
[[ -z $(find "${symlink_outside}" -mindepth 1 -print -quit) ]]

# An ambiguous or unsafe pre-existing identity fails before application mutation.
unsafe_root=${TEST_AREA}/unsafe-root
mkdir -p "${unsafe_root}"
if run_install "${unsafe_root}" unsafe --config "${config}" >"${TEST_AREA}/unsafe.out" 2>&1; then
  echo "Installer accepted an unsafe pre-existing warp-web identity." >&2
  exit 1
fi
grep -q 'GATE_IDENTITY' "${TEST_AREA}/unsafe.out"
[[ ! -e ${unsafe_root}/opt/warp-egress-dashboard ]]

# Product-created identity is removed; every removal remains dashboard-scoped.
uninstall_output=$(run_uninstall "${rootfs}" absent)
grep -qx 'DASHBOARD_UNINSTALL_OK' <<<"${uninstall_output}"
for removed in \
  "${rootfs}/opt/warp-egress-dashboard" \
  "${rootfs}/etc/warp-egress-dashboard" \
  "${rootfs}/run/warp-egress-dashboard" \
  "${rootfs}/etc/tmpfiles.d/warp-egress-dashboard.conf" \
  "${rootfs}/etc/systemd/system/warp-dashboard.service" \
  "${rootfs}/etc/systemd/system/warp-dashboard-collector.service" \
  "${rootfs}/etc/systemd/system/warp-dashboard-collector.timer" \
  "${rootfs}/var/lib/warp-egress-dashboard/test-account"; do
  [[ ! -e ${removed} ]]
done

# A safe pre-existing identity is reused and deliberately preserved on uninstall.
preexisting_root=${TEST_AREA}/preexisting-root
mkdir -p "${preexisting_root}"
run_install "${preexisting_root}" safe --config "${config}" >/dev/null
[[ ! -e ${preexisting_root}/etc/warp-egress-dashboard/.warp-web-created ]]
preserve_output=$(run_uninstall "${preexisting_root}" safe)
grep -q '^DASHBOARD_ACCOUNT_PRESERVED warp-web$' <<<"${preserve_output}"
grep -qx 'DASHBOARD_UNINSTALL_OK' <<<"${preserve_output}"

actions=$(find "${TEST_AREA}" -name test-actions.log -type f -exec cat {} + 2>/dev/null || true)
if grep -Eq '(^| )(ip rule|ip route|nft|wg|wg-quick|warp-gateway|sudoers)( |$)' <<<"${actions}"; then
  echo "Dashboard deployment attempted a forbidden gateway or sudoers action." >&2
  exit 1
fi
version_after=$(sha256sum "${ROOT}/VERSION" | awk '{print $1}')
[[ ${version_after} == "${version_before}" ]]

echo "Read-only dashboard deployment tests passed."
