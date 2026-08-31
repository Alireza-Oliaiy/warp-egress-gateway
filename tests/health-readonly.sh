#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  echo "health-readonly: FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local label=$3
  grep -Fq -- "${needle}" <<<"${haystack}" ||
    fail "${label}: missing '${needle}' in '${haystack}'"
}

assert_unchanged() {
  local before=$1
  local path=$2
  local label=$3
  local after
  after=$(sha256sum -- "${path}")
  [[ ${after} == "${before}" ]] || fail "${label} changed"
}

BIN_DIR="${TEST_ROOT}/bin"
TEST_STATE_DIR="${TEST_ROOT}/state"
LOCK_PARENT="${TEST_ROOT}/run/warp-egress-gateway"
LOCK_PATH="${LOCK_PARENT}/admin-mutation.lock"
mkdir -p "${BIN_DIR}" "${TEST_STATE_DIR}"
mkdir -m 0700 "${TEST_ROOT}/run"

cat > "${TEST_STATE_DIR}/config" <<'EOF'
TRANSIT_IF=ens192
UPLINK_IF=ens160
WARP_IF=warp0
EOF
cat > "${TEST_STATE_DIR}/forwarding" <<'EOF'
net.ipv4.ip_forward = 1
EOF
cat > "${TEST_STATE_DIR}/wireguard" <<'EOF'
warp0:up:public-key-unchanged
EOF
cat > "${TEST_STATE_DIR}/nft" <<'EOF'
table inet warp_gateway
EOF
mkdir "${TEST_STATE_DIR}/intent-parent"

cat > "${BIN_DIR}/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ip %s\n' "$*" >> "${TEST_COMMAND_LOG}"
case " $* " in
  *' rule add '*|*' rule del '*|*' route add '*|*' route del '*|*' route replace '*|*' route flush '*|*' link set '*|*' address add '*|*' address del '*)
    printf 'MUTATION ip %s\n' "$*" >> "${TEST_MUTATION_LOG}"
    exit 97
    ;;
esac
if [[ $* == 'link show warp0' ]]; then
  [[ ${TEST_WG_STATE} == up ]]
elif [[ $* == '-4 -o address show dev warp0 scope global' ]]; then
  [[ ${TEST_WG_STATE} == up ]] && printf '7: warp0 inet 172.16.0.2/32 scope global warp0\n'
elif [[ $* == '-4 -o address show dev ens160 scope global' ]]; then
  printf '2: ens160 inet 172.21.31.5/24 scope global ens160\n'
elif [[ $* == '-4 rule show' ]]; then
  if [[ ${TEST_ROUTE_STATE} == ok ]]; then
    printf '100: from 172.16.0.2 lookup 100\n110: from all iif ens192 lookup 100\n'
  else
    printf '110: from all iif ens192 lookup 100\n'
  fi
elif [[ $* == '-4 route show table 100 default' ]]; then
  [[ ${TEST_ROUTE_STATE} == ok ]] && printf 'default dev warp0 scope link\n'
else
  printf 'unexpected ip query: %s\n' "$*" >&2
  exit 96
fi
EOF

cat > "${BIN_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "${TEST_COMMAND_LOG}"
case " $* " in
  *' start '*|*' stop '*|*' restart '*|*' reload '*|*' try-restart '*)
    printf 'MUTATION systemctl %s\n' "$*" >> "${TEST_MUTATION_LOG}"
    exit 97
    ;;
esac
if [[ $1 == is-active ]]; then
  if [[ " $* " == *'.timer '* ]]; then
    [[ ${TEST_TIMER_STATE} == ok ]]
  else
    [[ ${TEST_SERVICE_STATE} == ok ]]
  fi
else
  printf 'unexpected systemctl query: %s\n' "$*" >&2
  exit 96
fi
EOF

cat > "${BIN_DIR}/wg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'wg %s\n' "$*" >> "${TEST_COMMAND_LOG}"
if [[ $1 != show ]]; then
  printf 'MUTATION wg %s\n' "$*" >> "${TEST_MUTATION_LOG}"
  exit 97
fi
[[ $* == 'show warp0' && ${TEST_WG_STATE} == up ]]
EOF

cat > "${BIN_DIR}/nft" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nft %s\n' "$*" >> "${TEST_COMMAND_LOG}"
if [[ $* != 'list table inet warp_gateway' ]]; then
  printf 'MUTATION nft %s\n' "$*" >> "${TEST_MUTATION_LOG}"
  exit 97
fi
[[ ${TEST_NFT_STATE} == ok ]] || exit 1
cat <<'RULES'
table inet warp_gateway {
  chain forward {
    iifname "ens192" oifname != "warp0" counter drop comment "WARP_KILL_SWITCH"
  }
}
RULES
EOF

cat > "${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${TEST_COMMAND_LOG}"
interface=
while (($#)); do
  if [[ $1 == --interface ]]; then
    interface=$2
    shift 2
  else
    shift
  fi
done
case "${interface}" in
  172.21.31.5) printf 'ip=198.51.100.10\nwarp=off\n' ;;
  172.16.0.2)
    [[ ${TEST_WARP_STATE} == on ]] || exit 28
    printf 'ip=203.0.113.10\nwarp=on\n'
    ;;
  *) exit 96 ;;
esac
EOF

cat > "${BIN_DIR}/ping" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ping %s\n' "$*" >> "${TEST_COMMAND_LOG}"
[[ ${TEST_UPSTREAM_STATE} == ok ]]
EOF

cat > "${BIN_DIR}/sysctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sysctl %s\n' "$*" >> "${TEST_COMMAND_LOG}"
if [[ " $* " == *' -w '* ]]; then
  printf 'MUTATION sysctl %s\n' "$*" >> "${TEST_MUTATION_LOG}"
  exit 97
fi
printf 'net.ipv4.ip_forward = 1\n'
EOF

chmod 0755 "${BIN_DIR}"/*

export PATH="${BIN_DIR}:/usr/bin:/bin"
export TEST_COMMAND_LOG="${TEST_STATE_DIR}/commands"
export TEST_MUTATION_LOG="${TEST_STATE_DIR}/mutations"
: > "${TEST_COMMAND_LOG}"
: > "${TEST_MUTATION_LOG}"

# shellcheck source=../native/scripts/common.sh
source "${ROOT}/native/scripts/common.sh"
# shellcheck source=../native/scripts/routing.sh
source "${ROOT}/native/scripts/routing.sh"
# shellcheck source=../native/scripts/admin-lock.sh
source "${ROOT}/native/scripts/admin-lock.sh"
# shellcheck source=../native/scripts/healthcheck-lib.sh
source "${ROOT}/native/scripts/healthcheck-lib.sh"

declare -F healthcheck_readonly_evaluate_locked >/dev/null ||
  fail "missing structural read-only health evaluator"

TRANSIT_IF=ens192
TRUSTED_SOURCE_CIDR=10.1.1.221/32
UPLINK_IF=ens160
WARP_IF=warp0
ROUTING_TABLE_ID=100
ROUTING_TABLE_NAME=warp_gateway
SOURCE_RULE_PRIORITY=100
INGRESS_RULE_PRIORITY=110
NFT_TABLE=warp_gateway
HEALTHCHECK_TIMEOUT=1
HEALTHCHECK_URL=https://example.invalid/cdn-cgi/trace
UPSTREAM_MONITOR_IP=10.1.1.221
AUTO_RECOVER=true
export TRANSIT_IF TRUSTED_SOURCE_CIDR UPLINK_IF WARP_IF
export ROUTING_TABLE_ID ROUTING_TABLE_NAME SOURCE_RULE_PRIORITY
export INGRESS_RULE_PRIORITY NFT_TABLE HEALTHCHECK_TIMEOUT HEALTHCHECK_URL
export UPSTREAM_MONITOR_IP AUTO_RECOVER

policy_routing_apply() {
  printf 'MUTATION function policy_routing_apply\n' >> "${TEST_MUTATION_LOG}"
  return 97
}
policy_routing_repair() {
  printf 'MUTATION function policy_routing_repair\n' >> "${TEST_MUTATION_LOG}"
  return 97
}
remove_rule_priority() {
  printf 'MUTATION function remove_rule_priority\n' >> "${TEST_MUTATION_LOG}"
  return 97
}

CONFIG_HASH=$(sha256sum -- "${TEST_STATE_DIR}/config")
FORWARD_HASH=$(sha256sum -- "${TEST_STATE_DIR}/forwarding")
WG_HASH=$(sha256sum -- "${TEST_STATE_DIR}/wireguard")
NFT_HASH=$(sha256sum -- "${TEST_STATE_DIR}/nft")

run_readonly_case() {
  local route_state=$1
  local warp_state=$2
  local expected_route=$3
  local expected_health=$4
  local output

  export TEST_ROUTE_STATE=${route_state}
  export TEST_WARP_STATE=${warp_state}
  export TEST_WG_STATE=up
  export TEST_NFT_STATE=ok
  export TEST_UPSTREAM_STATE=ok
  export TEST_SERVICE_STATE=ok
  export TEST_TIMER_STATE=ok

  output=$(admin_lock_run_at shared "${LOCK_PARENT}" "${LOCK_PATH}" \
    "$(id -u)" "$(id -g)" 1 healthcheck_readonly_evaluate_locked)
  assert_contains "${output}" 'EVALUATION=completed' "evaluation completion"
  assert_contains "${output}" "HEALTH=${expected_health}" "gateway health"
  assert_contains "${output}" "route=${expected_route}" "routing evidence"
  printf '%s\n' "${output}"
}

HEALTHY_OUTPUT=$(run_readonly_case ok on ok OK)
assert_contains "${HEALTHY_OUTPUT}" 'wg=up' "healthy WireGuard evidence"
assert_contains "${HEALTHY_OUTPUT}" 'direct=ok' "healthy direct evidence"
assert_contains "${HEALTHY_OUTPUT}" 'warp=on' "healthy WARP evidence"
assert_contains "${HEALTHY_OUTPUT}" 'nft=ok' "healthy nftables evidence"
assert_contains "${HEALTHY_OUTPUT}" 'upstream=ok' "healthy upstream evidence"
assert_contains "${HEALTHY_OUTPUT}" 'services=ok' "healthy service evidence"
assert_contains "${HEALTHY_OUTPUT}" 'timers=ok' "healthy timer evidence"

ROUTE_OUTPUT=$(run_readonly_case drift on source_rule_missing FAIL)
assert_contains "${ROUTE_OUTPUT}" 'reason=policy_routing' "unhealthy route reason"

WARP_OUTPUT=$(run_readonly_case ok fail ok FAIL)
assert_contains "${WARP_OUTPUT}" 'reason=warp_dataplane' "unhealthy WARP reason"
assert_contains "${WARP_OUTPUT}" 'recovery=none' "recovery-eligible read-only result"

[[ ! -s ${TEST_MUTATION_LOG} ]] ||
  fail "read-only evaluator reached mutation tripwire: $(cat "${TEST_MUTATION_LOG}")"
assert_unchanged "${CONFIG_HASH}" "${TEST_STATE_DIR}/config" configuration
assert_unchanged "${FORWARD_HASH}" "${TEST_STATE_DIR}/forwarding" forwarding
assert_unchanged "${WG_HASH}" "${TEST_STATE_DIR}/wireguard" WireGuard
assert_unchanged "${NFT_HASH}" "${TEST_STATE_DIR}/nft" nftables
[[ -z $(find "${TEST_STATE_DIR}/intent-parent" -mindepth 1 -print -quit) ]] ||
  fail "intent state was created"

grep -Fq 'systemctl is-active' "${TEST_COMMAND_LOG}" ||
  fail "service evidence was not queried"
! grep -Eq '(^| )(add|del|replace|flush|start|stop|restart|reload|set|-w)( |$)' \
  "${TEST_MUTATION_LOG}" || fail "mutation argv was recorded"

echo "HEALTH_READONLY_TESTS_PASSED"
