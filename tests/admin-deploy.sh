#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
DEPLOY=${ROOT}/admin/deploy
TEST_AREA=$(mktemp -d)
trap 'rm -rf "${TEST_AREA}"' EXIT

(cd "${ROOT}" && "${PYTHON3_BIN}" tests/admin_deploy_test.py)
(cd "${ROOT}" && "${PYTHON3_BIN}" -B tests/admin_listener_test.py)
(cd "${ROOT}" && "${PYTHON3_BIN}" -B tests/admin_foundation_test.py)

run_install() {
  local rootfs=$1 account=${2:-absent}
  # Synthetic trusted configuration only; never inspect the test host network.
  "${PYTHON3_BIN}" "${ROOT}/tests/admin_network_fixture.py" "${rootfs}"
  WARP_ADMIN_TEST_MODE=1 \
    WARP_ADMIN_TEST_ROOT="${rootfs}" \
    WARP_ADMIN_TEST_ACCOUNT="${account}" \
    WARP_ADMIN_TEST_FAIL="${WARP_ADMIN_TEST_FAIL:-}" \
    WARP_ADMIN_TEST_LISTENER_SCENARIO="${WARP_ADMIN_TEST_LISTENER_SCENARIO:-immediate-exact}" \
    WARP_GATEWAY_PYTHON3="${PYTHON3_BIN}" \
    bash "${DEPLOY}/install.sh"
}

run_uninstall() {
  local rootfs=$1 account=${2:-absent}
  WARP_ADMIN_TEST_MODE=1 \
    WARP_ADMIN_TEST_ROOT="${rootfs}" \
    WARP_ADMIN_TEST_ACCOUNT="${account}" \
    bash "${DEPLOY}/uninstall.sh"
}

version_before=$(sha256sum "${ROOT}/VERSION" | awk '{print $1}')
dashboard_before=$(find "${ROOT}/web/dashboard" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
native_before=$(find "${ROOT}/native" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')

rootfs=${TEST_AREA}/rootfs
mkdir -p "${rootfs}"
output=$(run_install "${rootfs}" absent)
grep -qx 'ADMIN_INSTALL_OK http://192.0.2.10:8788' <<<"${output}"

required_app=(
  __init__.py
  application.py
  network.py
  protocol.py
  static/index.html
  static/admin.css
  static/admin.js
)
for relative in "${required_app[@]}"; do
  cmp "${ROOT}/admin/${relative}" "${rootfs}/opt/warp-egress-admin-console/app/admin/${relative}"
  [[ $(stat -c '%a' "${rootfs}/opt/warp-egress-admin-console/app/admin/${relative}") == 644 ]]
done
cmp "${ROOT}/admin/helper.py" "${rootfs}/usr/local/libexec/warp-egress-gateway/warp-admin-helper"
cmp "${ROOT}/admin/protocol.py" "${rootfs}/usr/local/libexec/warp-egress-gateway/warp_admin_protocol.py"
[[ $(stat -c '%a' "${rootfs}/usr/local/libexec/warp-egress-gateway/warp-admin-helper") == 755 ]]
[[ $(stat -c '%a' "${rootfs}/usr/local/libexec/warp-egress-gateway/warp_admin_protocol.py") == 644 ]]
[[ $(stat -c '%a' "${rootfs}/etc/sudoers.d/warp-egress-gateway-admin") == 440 ]]
[[ $(stat -c '%a' "${rootfs}/etc/systemd/system/warp-admin.service") == 644 ]]
cmp "${DEPLOY}/systemd/warp-admin.service" "${rootfs}/etc/systemd/system/warp-admin.service"
[[ $(stat -c '%a' "${rootfs}/run/warp-egress-admin-console") == 700 ]]
[[ -f ${rootfs}/etc/warp-egress-admin-console/.warp-admin-created ]]
[[ -f ${rootfs}/var/lib/warp-egress-admin-console/test-account ]]

[[ $(stat -c '%a' "${rootfs}/etc/warp-egress-admin-console/network.json") == 644 ]]
"${PYTHON3_BIN}" - "${rootfs}/etc/warp-egress-admin-console/network.json" <<'PY'
import json, sys
from pathlib import Path
assert json.loads(Path(sys.argv[1]).read_text()) == {
    "address": "192.0.2.10", "uplink_if": "ens160", "transit_if": "ens192",
}
PY

# Invalid management configuration must fail before account or resource creation.
for invalid in 0.0.0.0 127.0.0.1 127.0.0.2 ::1 bad 10.1.1.222; do
  invalid_root=$(mktemp -d "${TEST_AREA}/network-invalid.XXXXXX")
  "${PYTHON3_BIN}" "${ROOT}/tests/admin_network_fixture.py" "${invalid_root}"
  printf 'DASHBOARD_LISTEN=%s\nDASHBOARD_PORT=8787\n' "${invalid}" \
    >"${invalid_root}/etc/warp-egress-dashboard/dashboard.env"
  if run_install "${invalid_root}" >"${TEST_AREA}/network-invalid.out" 2>&1; then
    echo "Admin accepted invalid management configuration: ${invalid}" >&2
    exit 1
  fi
  grep -q GATE_NETWORK "${TEST_AREA}/network-invalid.out"
  [[ ! -e ${invalid_root}/opt/warp-egress-admin-console ]]
  [[ ! -e ${invalid_root}/var/lib/warp-egress-admin-console/test-actions.log ]]
done

# A safe reinstall is idempotent and creates the project identity once.
run_install "${rootfs}" absent >/dev/null
cmp "${DEPLOY}/systemd/warp-admin.service" "${rootfs}/etc/systemd/system/warp-admin.service"
[[ $(grep -c '^useradd warp-admin$' "${rootfs}/var/lib/warp-egress-admin-console/test-actions.log") == 1 ]]

# Unsafe identity and unsafe existing destination metadata fail before replacement.
unsafe=${TEST_AREA}/unsafe
mkdir -p "${unsafe}"
if run_install "${unsafe}" unsafe >"${TEST_AREA}/unsafe.out" 2>&1; then
  echo 'Admin installer accepted an unsafe identity.' >&2
  exit 1
fi
grep -q 'GATE_IDENTITY' "${TEST_AREA}/unsafe.out"
[[ ! -e ${unsafe}/opt/warp-egress-admin-console ]]

metadata=${TEST_AREA}/metadata
mkdir -p "${metadata}/etc/systemd/system"
: >"${metadata}/etc/systemd/system/warp-admin.service"
chmod 0666 "${metadata}/etc/systemd/system/warp-admin.service"
if run_install "${metadata}" absent >"${TEST_AREA}/metadata.out" 2>&1; then
  echo 'Admin installer replaced unsafe existing metadata.' >&2
  exit 1
fi
grep -q 'GATE_DESTINATION' "${TEST_AREA}/metadata.out"

# Admin-owned destination roots are never followed through symlinks.
symlink_root=${TEST_AREA}/symlink-root
outside=${TEST_AREA}/outside
mkdir -p "${symlink_root}/opt" "${outside}"
ln -s "${outside}" "${symlink_root}/opt/warp-egress-admin-console"
if run_install "${symlink_root}" absent >"${TEST_AREA}/symlink.out" 2>&1; then
  echo 'Admin installer followed a destination symlink.' >&2
  exit 1
fi
grep -q 'GATE_DESTINATION' "${TEST_AREA}/symlink.out"
[[ -z $(find "${outside}" -mindepth 1 -print -quit) ]]

# Listener readiness fixtures are accepted only inside the explicit isolated
# test mode and cannot become production listener/timeout controls.
fixture_gate=${TEST_AREA}/listener-fixture-gate
mkdir -p "${fixture_gate}"
if WARP_ADMIN_TEST_ROOT="${fixture_gate}" WARP_ADMIN_TEST_LISTENER_SCENARIO=never \
  bash "${DEPLOY}/install.sh" >"${TEST_AREA}/listener-fixture-gate.out" 2>&1; then
  echo 'Admin installer accepted a readiness fixture outside test mode.' >&2
  exit 1
fi
grep -q 'GATE_TEST_ROOT test fixtures require explicit test mode' \
  "${TEST_AREA}/listener-fixture-gate.out"
[[ -z $(find "${fixture_gate}" -mindepth 1 -print -quit) ]]

# Listener readiness is bounded, retries absence only, and fails closed on
# service failure or any unsafe listener state.
listener_never=${TEST_AREA}/listener-never
mkdir -p "${listener_never}"
if WARP_ADMIN_TEST_LISTENER_SCENARIO=never \
  run_install "${listener_never}" absent >"${TEST_AREA}/listener-never.out" 2>&1; then
  echo 'Admin installer accepted a listener that never became ready.' >&2
  exit 1
fi
grep -q 'GATE_LISTENER readiness timeout waiting for exactly 192.0.2.10:8788' \
  "${TEST_AREA}/listener-never.out"

# A scheduler/probe delay crossing the deadline cannot turn a late exact bind
# into success. The synthetic clock jumps from 9750ms to 10250ms during sleep.
listener_after_deadline=${TEST_AREA}/listener-after-deadline
mkdir -p "${listener_after_deadline}"
if WARP_ADMIN_TEST_LISTENER_SCENARIO=after-deadline-exact \
  run_install "${listener_after_deadline}" absent \
    >"${TEST_AREA}/listener-after-deadline.out" 2>&1; then
  echo 'Admin installer accepted an exact listener after the readiness deadline.' >&2
  exit 1
fi
grep -q 'GATE_LISTENER readiness timeout waiting for exactly 192.0.2.10:8788' \
  "${TEST_AREA}/listener-after-deadline.out"
if grep -q 'addresses=192.0.2.10:8788' \
  "${listener_after_deadline}/var/lib/warp-egress-admin-console/test-actions.log"; then
  echo 'Admin installer probed and accepted readiness after the deadline.' >&2
  exit 1
fi

listener_immediate=${TEST_AREA}/listener-immediate
mkdir -p "${listener_immediate}"
WARP_ADMIN_TEST_LISTENER_SCENARIO=immediate-exact \
  run_install "${listener_immediate}" absent >/dev/null
grep -qx 'listener poll=1 service=active count=1 addresses=192.0.2.10:8788' \
  "${listener_immediate}/var/lib/warp-egress-admin-console/test-actions.log"

listener_delayed=${TEST_AREA}/listener-delayed
mkdir -p "${listener_delayed}"
WARP_ADMIN_TEST_LISTENER_SCENARIO=delayed-exact \
  run_install "${listener_delayed}" absent >/dev/null
grep -qx 'listener poll=1 service=active count=0 addresses=none' \
  "${listener_delayed}/var/lib/warp-egress-admin-console/test-actions.log"
grep -qx 'listener poll=3 service=active count=1 addresses=192.0.2.10:8788' \
  "${listener_delayed}/var/lib/warp-egress-admin-console/test-actions.log"

for state in failed inactive deactivating; do
  listener_service_failed=${TEST_AREA}/listener-service-${state}
  mkdir -p "${listener_service_failed}"
  if WARP_ADMIN_TEST_LISTENER_SCENARIO=service-${state} \
    run_install "${listener_service_failed}" absent >"${TEST_AREA}/listener-service-${state}.out" 2>&1; then
    echo "Admin installer waited through a ${state} service." >&2
    exit 1
  fi
  grep -q "GATE_SERVICE readiness failed: warp-admin.service is ${state}" \
    "${TEST_AREA}/listener-service-${state}.out"
  [[ $(grep -c '^listener poll=' \
    "${listener_service_failed}/var/lib/warp-egress-admin-console/test-actions.log") -eq 2 ]]
done

for scenario in \
  forbidden-wildcard \
  forbidden-management \
  forbidden-transit \
  forbidden-loopback \
  forbidden-loopback-alt \
  forbidden-ipv6-loopback \
  forbidden-ipv6-any; do
  listener_forbidden=${TEST_AREA}/listener-${scenario}
  mkdir -p "${listener_forbidden}"
  if WARP_ADMIN_TEST_LISTENER_SCENARIO=${scenario} \
    run_install "${listener_forbidden}" absent >"${TEST_AREA}/listener-${scenario}.out" 2>&1; then
    echo "Admin installer accepted forbidden listener scenario: ${scenario}." >&2
    exit 1
  fi
  grep -q 'GATE_LISTENER unsafe listener state while waiting for exactly 192.0.2.10:8788' \
    "${TEST_AREA}/listener-${scenario}.out"
  [[ $(grep -c '^listener poll=' \
    "${listener_forbidden}/var/lib/warp-egress-admin-console/test-actions.log") -eq 1 ]]
done

listener_multiple=${TEST_AREA}/listener-multiple
mkdir -p "${listener_multiple}"
if WARP_ADMIN_TEST_LISTENER_SCENARIO=multiple \
  run_install "${listener_multiple}" absent >"${TEST_AREA}/listener-multiple.out" 2>&1; then
  echo 'Admin installer accepted multiple listeners on port 8788.' >&2
  exit 1
fi
grep -q 'GATE_LISTENER unsafe listener state while waiting for exactly 192.0.2.10:8788' \
  "${TEST_AREA}/listener-multiple.out"
[[ $(grep -c '^listener poll=' \
  "${listener_multiple}/var/lib/warp-egress-admin-console/test-actions.log") -eq 1 ]]

# A failed readiness gate remains safely removable using the dedicated Admin
# uninstaller and does not leave any Admin-owned resource behind.
run_uninstall "${listener_never}" absent >/dev/null
for removed in \
  "${listener_never}/opt/warp-egress-admin-console" \
  "${listener_never}/run/warp-egress-admin-console" \
  "${listener_never}/etc/warp-egress-admin-console" \
  "${listener_never}/etc/systemd/system/warp-admin.service" \
  "${listener_never}/etc/sudoers.d/warp-egress-gateway-admin" \
  "${listener_never}/usr/local/libexec/warp-egress-gateway/warp-admin-helper" \
  "${listener_never}/usr/local/libexec/warp-egress-gateway/warp_admin_protocol.py"; do
  [[ ! -e ${removed} ]]
done

# Every post-install gate is fail closed and never emits success.
for failure in sudoers metadata listener http; do
  failure_root=${TEST_AREA}/failure-${failure}
  mkdir -p "${failure_root}"
  if WARP_ADMIN_TEST_FAIL=${failure} run_install "${failure_root}" absent >"${TEST_AREA}/${failure}.out" 2>&1; then
    echo "Admin installer claimed success after ${failure} failure." >&2
    exit 1
  fi
  grep -q "GATE_${failure^^}" "${TEST_AREA}/${failure}.out"
  if grep -q '^ADMIN_INSTALL_OK ' "${TEST_AREA}/${failure}.out"; then
    echo "Admin installer emitted success after ${failure} failure." >&2
    exit 1
  fi
done

# Product-created identity and only Admin resources are removed.
uninstall_output=$(run_uninstall "${rootfs}" absent)
grep -qx 'ADMIN_UNINSTALL_OK' <<<"${uninstall_output}"
for removed in \
  "${rootfs}/opt/warp-egress-admin-console" \
  "${rootfs}/run/warp-egress-admin-console" \
  "${rootfs}/etc/warp-egress-admin-console" \
  "${rootfs}/etc/systemd/system/warp-admin.service" \
  "${rootfs}/etc/sudoers.d/warp-egress-gateway-admin" \
  "${rootfs}/usr/local/libexec/warp-egress-gateway/warp-admin-helper" \
  "${rootfs}/usr/local/libexec/warp-egress-gateway/warp_admin_protocol.py" \
  "${rootfs}/var/lib/warp-egress-admin-console/test-account"; do
  [[ ! -e ${removed} ]]
done

# A safe pre-existing identity is preserved because no project marker exists.
preexisting=${TEST_AREA}/preexisting
mkdir -p "${preexisting}"
run_install "${preexisting}" safe >/dev/null
[[ ! -e ${preexisting}/etc/warp-egress-admin-console/.warp-admin-created ]]
preserve=$(run_uninstall "${preexisting}" safe)
grep -q '^ADMIN_ACCOUNT_PRESERVED warp-admin$' <<<"${preserve}"
grep -qx 'ADMIN_UNINSTALL_OK' <<<"$(tail -n 1 <<<"${preserve}")"

actions=$(find "${TEST_AREA}" -name test-actions.log -type f -exec cat {} + 2>/dev/null || true)
if grep -Eq 'warp-dashboard|warp-web|ip rule|ip route|nft |wg-quick|sysctl|health-run|routing-repair' <<<"${actions}"; then
  echo 'Admin deployment touched a forbidden Dashboard or dataplane surface.' >&2
  exit 1
fi

[[ $(sha256sum "${ROOT}/VERSION" | awk '{print $1}') == "${version_before}" ]]
[[ $(find "${ROOT}/web/dashboard" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}') == "${dashboard_before}" ]]
[[ $(find "${ROOT}/native" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}') == "${native_before}" ]]

echo 'Admin Console deployment tests passed.'
