#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  echo "writer-locking: FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2 label=$3
  [[ ${actual} == "${expected}" ]] ||
    fail "${label}: expected '${expected}', got '${actual}'"
}

BIN_DIR="${TEST_ROOT}/bin"
TEST_STATE="${TEST_ROOT}/state"
LOCK_PARENT="${TEST_ROOT}/run/warp-egress-gateway"
LOCK_PATH="${LOCK_PARENT}/admin-mutation.lock"
mkdir -p "${BIN_DIR}" "${TEST_STATE}"
mkdir -m 0700 "${TEST_ROOT}/run"
export TEST_LOCK_PATH="${LOCK_PATH}"
export TEST_STATE
export TEST_LOG="${TEST_ROOT}/writer.log"
: > "${TEST_LOG}"

cat > "${BIN_DIR}/assert-exclusive" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if flock -s -n "${TEST_LOCK_PATH}" true; then
  printf 'UNLOCKED %s\n' "$*" >> "${TEST_LOG}"
  exit 98
fi
printf 'LOCKED %s\n' "$*" >> "${TEST_LOG}"
EOF

cat > "${BIN_DIR}/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' rule add '*|*' rule del '*|*' route replace '*|*' route flush '*)
    assert-exclusive "ip $*"
    ;;
esac
case "$*" in
  'link show warp0') exit 0 ;;
  '-4 -o address show dev warp0 scope global')
    printf '7: warp0 inet 172.16.0.2/32 scope global warp0\n'
    ;;
  '-4 -o address show dev ens160 scope global')
    printf '2: ens160 inet 172.21.31.5/24 scope global ens160\n'
    ;;
  '-4 rule show')
    [[ -e ${TEST_STATE}/source-rule ]] && printf '100: from 172.16.0.2 lookup 100\n'
    [[ -e ${TEST_STATE}/ingress-rule ]] && printf '110: from all iif ens192 lookup 100\n'
    ;;
  '-4 rule del pref 100') rm -f -- "${TEST_STATE}/source-rule" ;;
  '-4 rule del pref 110') rm -f -- "${TEST_STATE}/ingress-rule" ;;
  '-4 rule add pref 100 from 172.16.0.2/32 lookup 100') : > "${TEST_STATE}/source-rule" ;;
  '-4 rule add pref 110 iif ens192 lookup 100') : > "${TEST_STATE}/ingress-rule" ;;
  '-4 route replace default dev warp0 table 100') : > "${TEST_STATE}/default-route" ;;
  '-4 route show table 100 default')
    [[ -e ${TEST_STATE}/default-route ]] && printf 'default dev warp0 scope link\n'
    ;;
  '-4 route flush table 100') rm -f -- "${TEST_STATE}/default-route" ;;
  '-4 route flush cache') : ;;
  *) printf 'unexpected ip command: %s\n' "$*" >&2; exit 96 ;;
esac
EOF

cat > "${BIN_DIR}/wg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == 'show warp0' ]] || exit 96
EOF

cat > "${BIN_DIR}/nft" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == '-f -' ]]; then
  assert-exclusive "nft $*"
  cat >/dev/null
  : > "${TEST_STATE}/nft"
elif [[ $* == 'delete table inet warp_gateway' ]]; then
  assert-exclusive "nft $*"
  rm -f -- "${TEST_STATE}/nft"
elif [[ $* == 'list table inet warp_gateway' && -e ${TEST_STATE}/nft ]]; then
  printf 'iifname "ens192" oifname != "warp0" drop comment "WARP_KILL_SWITCH"\n'
else
  exit 1
fi
EOF

cat > "${BIN_DIR}/sysctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == '-w net.ipv4.ip_forward=1' ]] || exit 96
assert-exclusive "sysctl $*"
: > "${TEST_STATE}/forwarding"
EOF

cat > "${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
interface=
while (($#)); do
  if [[ $1 == --interface ]]; then interface=$2; shift 2; else shift; fi
done
if [[ ${interface} == 172.21.31.5 ]]; then
  printf 'ip=198.51.100.10\nwarp=off\n'
elif [[ ${interface} == 172.16.0.2 && ${TEST_WARP_FAIL:-false} != true ]]; then
  printf 'ip=203.0.113.10\nwarp=on\n'
else
  exit 28
fi
EOF

cat > "${BIN_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == is-active ]]; then
  exit 0
fi
if [[ $1 == restart && $2 == wg-quick@warp0.service ]]; then
  # health orchestration must not hold the project lock across systemctl: the
  # restarted wg-quick unit acquires it independently.
  if ! flock -x -n "${TEST_LOCK_PATH}" true; then
    printf 'NESTED_LOCK systemctl %s\n' "$*" >> "${TEST_LOG}"
    exit 99
  fi
  printf 'SYSTEMD_DELEGATED systemctl %s\n' "$*" >> "${TEST_LOG}"
  TEST_WARP_FAIL=false
  export TEST_WARP_FAIL
  exit 0
fi
exit 96
EOF

chmod 0755 "${BIN_DIR}"/*
export PATH="${BIN_DIR}:/usr/bin:/bin"

# shellcheck source=../native/scripts/common.sh
source "${ROOT}/native/scripts/common.sh"
# shellcheck source=../native/scripts/admin-lock.sh
source "${ROOT}/native/scripts/admin-lock.sh"
# shellcheck source=../native/scripts/routing.sh
source "${ROOT}/native/scripts/routing.sh"

MUTATION_LIB="${ROOT}/native/scripts/mutation-transactions.sh"
[[ -r ${MUTATION_LIB} ]] || fail "missing mutation transaction library"
# shellcheck source=../native/scripts/mutation-transactions.sh
source "${MUTATION_LIB}"

TRANSIT_IF=ens192
TRUSTED_SOURCE_CIDR=10.1.1.221/32
UPLINK_IF=ens160
WARP_IF=warp0
ROUTING_TABLE_ID=100
ROUTING_TABLE_NAME=warp_gateway
SOURCE_RULE_PRIORITY=100
INGRESS_RULE_PRIORITY=110
NFT_TABLE=warp_gateway
TCP_MSS=1240
export TRANSIT_IF TRUSTED_SOURCE_CIDR UPLINK_IF WARP_IF
export ROUTING_TABLE_ID ROUTING_TABLE_NAME SOURCE_RULE_PRIORITY
export INGRESS_RULE_PRIORITY NFT_TABLE TCP_MSS

admin_lock_run_shared() {
  admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
    "$(id -u)" "$(id -g)" 0.2 "$@"
}
admin_lock_run_exclusive() {
  admin_lock_run_at exclusive "${LOCK_PARENT}" "${LOCK_PATH}" \
    "$(id -u)" "$(id -g)" 0.2 "$@"
}

declare -F policy_routing_apply_locked >/dev/null || fail "missing locked routing primitive"
declare -F route_down_transaction_locked >/dev/null || fail "missing route-down transaction"
declare -F firewall_apply_transaction_locked >/dev/null || fail "missing firewall transaction"
declare -F wg_quick_transaction_locked >/dev/null || fail "missing WireGuard transaction"

# The public routing writer owns the exclusive lock through post-verification.
policy_routing_apply 172.16.0.2
assert_eq ok "$(policy_routing_status)" "policy routing after locked apply"

# Contention returns the deterministic busy status before any writer argv.
HOLDER_READY="${TEST_ROOT}/holder-ready"
hold_reader() { : > "${HOLDER_READY}"; sleep 1; }
admin_lock_run_shared hold_reader &
HOLDER_PID=$!
for _ in {1..100}; do [[ -e ${HOLDER_READY} ]] && break; sleep 0.01; done
LINES_BEFORE=$(wc -l < "${TEST_LOG}")
BUSY_RC=0
policy_routing_apply 172.16.0.2 || BUSY_RC=$?
assert_eq 75 "${BUSY_RC}" "writer contention status"
assert_eq "${LINES_BEFORE}" "$(wc -l < "${TEST_LOG}")" "no mutation before lock"
wait "${HOLDER_PID}"

# Route teardown, firewall install/removal, and forwarding transition are all
# performed while the same exclusive lock is held.
admin_lock_run_exclusive route_down_transaction_locked
[[ ! -e ${TEST_STATE}/default-route ]] || fail "route-down did not remove table state"
admin_lock_run_exclusive firewall_apply_transaction_locked
[[ -e ${TEST_STATE}/nft && -e ${TEST_STATE}/forwarding ]] ||
  fail "firewall transaction did not complete"
admin_lock_run_exclusive firewall_remove_transaction_locked
[[ ! -e ${TEST_STATE}/nft ]] || fail "firewall removal did not complete"

# The systemd WireGuard wrapper is a real exclusive writer. Its command can be
# replaced only inside this test process; production uses fixed /usr/bin/wg-quick.
wg_quick_command_locked() {
  assert-exclusive "wg-quick $*"
  printf 'WG_QUICK %s\n' "$*" >> "${TEST_LOG}"
}
wg_quick_reload_command_locked() {
  assert-exclusive "wg-quick reload $*"
  printf 'WG_QUICK reload %s\n' "$*" >> "${TEST_LOG}"
}
admin_lock_run_exclusive wg_quick_transaction_locked up warp0
admin_lock_run_exclusive wg_quick_transaction_locked down warp0
admin_lock_run_exclusive wg_quick_transaction_locked reload warp0

! grep -Fq UNLOCKED "${TEST_LOG}" || fail "a mutation ran without the exclusive lock"
! grep -Fq NESTED_LOCK "${TEST_LOG}" || fail "systemd restart inherited an outer lock"

echo "WRITER_LOCKING_TESTS_PASSED"
