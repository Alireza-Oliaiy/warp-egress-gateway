#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

ROUTING_LIB="${ROOT}/native/scripts/routing.sh"
HEALTHCHECK_LIB="${ROOT}/native/scripts/healthcheck-lib.sh"
ROUTE_UP="${ROOT}/native/scripts/route-up.sh"
ROUTE_DOWN="${ROOT}/native/scripts/route-down.sh"
[[ -r ${ROUTING_LIB} ]] || {
  echo "Routing validation library is missing: ${ROUTING_LIB}" >&2
  exit 1
}
[[ -r ${HEALTHCHECK_LIB} ]] || {
  echo "Healthcheck behavior library is missing: ${HEALTHCHECK_LIB}" >&2
  exit 1
}
grep -q 'policy_routing_activate' "${ROUTE_UP}" || {
  echo "Route activation must enter through the shared-lock wrapper." >&2
  exit 1
}
grep -q 'policy_routing_remove' "${ROUTE_DOWN}" || {
  echo "Route removal must enter through the shared-lock wrapper." >&2
  exit 1
}

TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT
MOCK_BIN="${TEST_DIR}/bin"
MOCK_RULES_FILE="${TEST_DIR}/rules"
MOCK_ROUTE_FILE="${TEST_DIR}/routes"
MOCK_IP_LOG="${TEST_DIR}/ip.log"
mkdir -p "${MOCK_BIN}"
: >"${MOCK_RULES_FILE}"
: >"${MOCK_ROUTE_FILE}"
: >"${MOCK_IP_LOG}"

cat >"${MOCK_BIN}/ip" <<'MOCK_IP'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${MOCK_IP_LOG}"

if [[ $* == '-4 rule show' ]]; then
  cat "${MOCK_RULES_FILE}"
elif [[ $* == '-4 rule del pref '* ]]; then
  priority=${5}
  awk -v prefix="${priority}:" '$1 != prefix' "${MOCK_RULES_FILE}" >"${MOCK_RULES_FILE}.next"
  mv "${MOCK_RULES_FILE}.next" "${MOCK_RULES_FILE}"
elif [[ $* == '-4 rule add pref '* ]]; then
  priority=${5}
  if [[ ${6} == from && ${8} == lookup ]]; then
    printf '%s: from %s lookup %s\n' "${priority}" "${7%/32}" "${9}" >>"${MOCK_RULES_FILE}"
  elif [[ ${6} == iif && ${8} == lookup ]]; then
    printf '%s: from all iif %s lookup %s\n' "${priority}" "${7}" "${9}" >>"${MOCK_RULES_FILE}"
  else
    exit 64
  fi
elif [[ $* == '-4 route show table '* ]]; then
  cat "${MOCK_ROUTE_FILE}"
elif [[ $* == '-4 route replace default dev '* ]]; then
  warp_if=${6}
  table_id=${8}
  [[ -n ${table_id} ]]
  printf 'default dev %s\n' "${warp_if}" >"${MOCK_ROUTE_FILE}"
elif [[ $* == '-4 route flush table '* ]]; then
  : >"${MOCK_ROUTE_FILE}"
elif [[ $* == '-4 route flush cache' ]]; then
  :
elif [[ $* == 'link show '* ]]; then
  [[ ${MOCK_WG_UP:-true} == true ]]
elif [[ $* == '-4 -o address show dev '* ]]; then
  if [[ ${6} == eth0 ]]; then
    printf '2: eth0    inet 203.0.113.10/24 scope global eth0\n'
  else
    [[ ${MOCK_WG_UP:-true} == true ]] || exit 1
    printf '7: %s    inet %s/32 scope global %s\n' "${6}" "${MOCK_WARP_IPV4}" "${6}"
  fi
else
  echo "Unexpected fake ip invocation: $*" >&2
  exit 64
fi
MOCK_IP

cat >"${MOCK_BIN}/wg" <<'MOCK_WG'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $* == "show ${WARP_IF}" && ${MOCK_WG_UP:-true} == true ]]
MOCK_WG

cat >"${MOCK_BIN}/nft" <<'MOCK_NFT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $* == "list table inet ${NFT_TABLE}" && ${MOCK_NFT_ACTIVE:-true} == true ]] || exit 1
if [[ ${MOCK_NFT_MODE:-drop} == comment_only ]]; then
  echo 'counter accept comment "WARP_KILL_SWITCH"'
  exit 0
fi
cat <<'NFT'
table inet warp_gateway {
  chain forward {
    iifname "eth1" oifname != "warp0" counter drop comment "WARP_KILL_SWITCH"
  }
}
NFT
MOCK_NFT

cat >"${MOCK_BIN}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ " $* " == *' --interface 203.0.113.10 '* ]]; then
  [[ ${MOCK_DIRECT_CURL_RC:-0} == 0 ]] || exit "${MOCK_DIRECT_CURL_RC}"
  printf 'ip=203.0.113.10\nwarp=off\n'
  exit 0
fi
if [[ " $* " == *' --interface 192.0.2.2 '* ]]; then
  if [[ ${MOCK_WARP_CURL_RC:-0} != 0 && ! -e ${MOCK_TUNNEL_RECOVERED_FILE} ]]; then
    exit "${MOCK_WARP_CURL_RC}"
  fi
  printf 'ip=198.51.100.20\nwarp=on\n'
  exit 0
fi
exit 64
MOCK_CURL

cat >"${MOCK_BIN}/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${MOCK_SYSTEMCTL_LOG}"
if [[ $* == 'is-active --quiet '* ]]; then
  [[ ${MOCK_WG_UP:-true} == true ]]
elif [[ $* == 'restart wg-quick@warp0.service' ]]; then
  touch "${MOCK_TUNNEL_RECOVERED_FILE}"
else
  exit 64
fi
MOCK_SYSTEMCTL

cat >"${MOCK_BIN}/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP

cat >"${MOCK_BIN}/flock" <<'MOCK_FLOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${MOCK_FLOCK_LOG}"
if [[ $* == '-x -w 5 '* ]]; then
  if [[ ${MOCK_FLOCK_CREATE_INTENT:-false} == true ]]; then
    printf 'valid\n' >"${MOCK_INTENT_STATE_FILE}"
  fi
  [[ ${MOCK_FLOCK_BUSY:-false} != true ]]
elif [[ $* == '-u '* ]]; then
  exit 0
else
  exit 64
fi
MOCK_FLOCK

chmod +x "${MOCK_BIN}"/*
PATH="${MOCK_BIN}:${PATH}"
export PATH MOCK_RULES_FILE MOCK_ROUTE_FILE MOCK_IP_LOG
export MOCK_WG_UP=true MOCK_NFT_ACTIVE=true MOCK_WARP_IPV4=192.0.2.2
export MOCK_NFT_MODE=drop
MOCK_SYSTEMCTL_LOG="${TEST_DIR}/systemctl.log"
MOCK_TUNNEL_RECOVERED_FILE="${TEST_DIR}/tunnel-recovered"
MOCK_FLOCK_LOG="${TEST_DIR}/flock.log"
MOCK_INTENT_STATE_FILE="${TEST_DIR}/intent-state"
export MOCK_SYSTEMCTL_LOG MOCK_TUNNEL_RECOVERED_FILE MOCK_FLOCK_LOG
export MOCK_INTENT_STATE_FILE
: >"${MOCK_SYSTEMCTL_LOG}"
: >"${MOCK_FLOCK_LOG}"

export WARP_RUNTIME_STATE_TEST_MODE=1
export WARP_RUNTIME_STATE_TEST_DIR="${TEST_DIR}/runtime"
export WARP_RUNTIME_STATE_TEST_ASSUME_SAFE=1
export WARP_RUNTIME_STATE_TEST_FLOCK_BIN="${MOCK_BIN}/flock"
export WARP_GATEWAY_PYTHON3=${WARP_GATEWAY_PYTHON3:-python3}

WARP_IF=warp0
TRANSIT_IF=eth1
ROUTING_TABLE_ID=100
ROUTING_TABLE_NAME=warp_gateway
SOURCE_RULE_PRIORITY=100
INGRESS_RULE_PRIORITY=110
NFT_TABLE=warp_gateway
export WARP_IF TRANSIT_IF ROUTING_TABLE_ID ROUTING_TABLE_NAME
export SOURCE_RULE_PRIORITY INGRESS_RULE_PRIORITY NFT_TABLE

# shellcheck source=../native/scripts/routing.sh
source "${ROUTING_LIB}"
# shellcheck source=../native/scripts/healthcheck-lib.sh
source "${HEALTHCHECK_LIB}"

intentional_disconnect_state() {
  if [[ -r ${MOCK_INTENT_STATE_FILE} ]]; then
    cat "${MOCK_INTENT_STATE_FILE}"
  else
    printf 'absent\n'
  fi
}

set_rules() {
  printf '%s\n' "$@" >"${MOCK_RULES_FILE}"
}

set_routes() {
  printf '%s\n' "$@" >"${MOCK_ROUTE_FILE}"
}

assert_status() {
  local expected=$1 actual
  actual=$(policy_routing_status)
  [[ ${actual} == "${expected}" ]] || {
    echo "Expected routing status ${expected}, got ${actual}" >&2
    exit 1
  }
}

set_healthy() {
  set_rules \
    '100: from 192.0.2.2 lookup warp_gateway' \
    '110: from all iif eth1 lookup warp_gateway'
  set_routes 'default dev warp0'
  : >"${MOCK_IP_LOG}"
}

set_healthy
assert_status ok

set_rules '110: from all iif eth1 lookup warp_gateway'
assert_status source_rule_missing

set_rules '100: from 192.0.2.2 lookup warp_gateway'
assert_status ingress_rule_missing

set_rules \
  '100: from 192.0.2.2 lookup main' \
  '110: from all iif eth1 lookup warp_gateway'
assert_status source_rule_mismatch

set_rules \
  '100: from 198.51.100.50 lookup warp_gateway' \
  '110: from all iif eth1 lookup warp_gateway'
assert_status source_rule_mismatch

set_rules \
  '100: from 192.0.2.2 to 198.51.100.0/24 lookup warp_gateway' \
  '110: from all iif eth1 lookup warp_gateway'
assert_status source_rule_mismatch

set_rules \
  '100: from 192.0.2.2 lookup warp_gateway' \
  '110: from all iif eth9 lookup warp_gateway'
assert_status ingress_rule_mismatch

set_rules \
  '100: from 192.0.2.2 lookup warp_gateway' \
  '110: from all to 203.0.113.0/24 iif eth1 lookup warp_gateway'
assert_status ingress_rule_mismatch

set_rules \
  '100: from 192.0.2.2 lookup warp_gateway' \
  '110: from all iif eth1 lookup main'
assert_status ingress_rule_mismatch

set_rules \
  '100: from 192.0.2.2 lookup 100' \
  '110: from all iif eth1 lookup 100'
assert_status ok

set_healthy
set_routes
assert_status default_route_missing

set_routes 'default dev eth0 via 203.0.113.1'
assert_status default_route_mismatch

# Simulate networkd reconciliation deleting only the runtime policy rules.
set_rules
set_routes 'default dev warp0'
assert_status source_rule_missing
policy_routing_repair
assert_status ok

# A second repair is a no-op and cannot create duplicate rules.
policy_routing_repair
[[ $(grep -c '^100:' "${MOCK_RULES_FILE}") -eq 1 ]]
[[ $(grep -c '^110:' "${MOCK_RULES_FILE}") -eq 1 ]]

# Policy repair never mutates nftables and never creates a main-table default.
nft list table inet "${NFT_TABLE}" | grep -q 'WARP_KILL_SWITCH'
grep -q '^-4 route replace default dev warp0 table 100$' "${MOCK_IP_LOG}"
if grep -qE '^-4 route (replace|add) default dev warp0$' "${MOCK_IP_LOG}"; then
  echo "Policy repair attempted an unscoped main-table default route" >&2
  exit 1
fi

# A marker on the wrong rule is not an active fail-closed kill switch.
MOCK_NFT_MODE=comment_only
export MOCK_NFT_MODE
if kill_switch_active; then
  echo "Kill-switch validation accepted a comment without the drop rule" >&2
  exit 1
fi
MOCK_NFT_MODE=drop
export MOCK_NFT_MODE

# Without the kill switch, drift remains fail closed and no route mutation occurs.
set_rules
: >"${MOCK_IP_LOG}"
MOCK_NFT_ACTIVE=false
export MOCK_NFT_ACTIVE
if policy_routing_repair; then
  echo "Policy repair must fail when the kill switch is absent" >&2
  exit 1
fi
[[ ! -s ${MOCK_IP_LOG} || $(grep -c 'route replace' "${MOCK_IP_LOG}" || true) -eq 0 ]]

run_health_success() {
  local sample
  sample=$(healthcheck_run)
  [[ ${sample} == HEALTH=OK* ]] || {
    echo "Expected healthy sample, got: ${sample}" >&2
    exit 1
  }
  printf '%s\n' "${sample}"
}

run_health_failure() {
  local expected_reason=$1 sample
  if sample=$(healthcheck_run); then
    echo "Expected health failure (${expected_reason}), got success: ${sample}" >&2
    exit 1
  fi
  [[ ${sample} == HEALTH=FAIL* && ${sample} == *"reason=${expected_reason}"* ]] || {
    echo "Expected failure reason ${expected_reason}, got: ${sample}" >&2
    exit 1
  }
  printf '%s\n' "${sample}"
}

assert_no_wg_restart() {
  if grep -q '^restart wg-quick@warp0.service$' "${MOCK_SYSTEMCTL_LOG}"; then
    echo "Healthcheck restarted WireGuard for a non-tunnel failure" >&2
    exit 1
  fi
}

UPLINK_IF=eth0
HEALTHCHECK_TIMEOUT=1
HEALTHCHECK_URL=https://example.invalid/trace
AUTO_RECOVER=false
export UPLINK_IF HEALTHCHECK_TIMEOUT HEALTHCHECK_URL AUTO_RECOVER

MOCK_NFT_ACTIVE=true
MOCK_DIRECT_CURL_RC=0
MOCK_WARP_CURL_RC=0
export MOCK_NFT_ACTIVE MOCK_DIRECT_CURL_RC MOCK_WARP_CURL_RC
rm -f "${MOCK_TUNNEL_RECOVERED_FILE}"
set_healthy
sample=$(run_health_success)
[[ ${sample} == *'recovery=none'* ]]

# Safe deterministic policy restoration is allowed even with AUTO_RECOVER=false.
set_rules
: >"${MOCK_SYSTEMCTL_LOG}"
sample=$(run_health_success)
[[ ${sample} == *'recovery=policy'* && ${sample} == *'route=ok'* ]]
assert_no_wg_restart
assert_status ok

# Missing safety state blocks policy repair and never restarts WireGuard.
set_rules
: >"${MOCK_IP_LOG}"
: >"${MOCK_SYSTEMCTL_LOG}"
MOCK_NFT_ACTIVE=false
export MOCK_NFT_ACTIVE
sample=$(run_health_failure kill_switch)
[[ ${sample} == *'nft=fail'* ]]
[[ $(grep -c 'route replace' "${MOCK_IP_LOG}" || true) -eq 0 ]]
assert_no_wg_restart

# Direct-uplink failure is classified separately and cannot trigger a tunnel restart.
set_healthy
MOCK_NFT_ACTIVE=true
MOCK_DIRECT_CURL_RC=7
AUTO_RECOVER=true
export MOCK_NFT_ACTIVE MOCK_DIRECT_CURL_RC AUTO_RECOVER
: >"${MOCK_SYSTEMCTL_LOG}"
sample=$(run_health_failure direct_uplink)
[[ ${sample} == *'direct=fail'* ]]
assert_no_wg_restart

# A WARP failure remains failed without automatic tunnel recovery.
MOCK_DIRECT_CURL_RC=0
MOCK_WARP_CURL_RC=28
AUTO_RECOVER=false
export MOCK_DIRECT_CURL_RC MOCK_WARP_CURL_RC AUTO_RECOVER
: >"${MOCK_SYSTEMCTL_LOG}"
rm -f "${MOCK_TUNNEL_RECOVERED_FILE}"
sample=$(run_health_failure warp_dataplane)
[[ ${sample} == *'warp=fail'* ]]
assert_no_wg_restart

# With AUTO_RECOVER=true, tunnel-specific evidence permits one WireGuard restart.
AUTO_RECOVER=true
export AUTO_RECOVER
: >"${MOCK_SYSTEMCTL_LOG}"
rm -f "${MOCK_TUNNEL_RECOVERED_FILE}"
sample=$(run_health_success)
[[ ${sample} == *'recovery=tunnel'* && ${sample} == *'warp=on'* ]]
[[ $(grep -c '^restart wg-quick@warp0.service$' "${MOCK_SYSTEMCTL_LOG}") -eq 1 ]]

# All route removal uses the same lock and remains project-scoped.
set_healthy
: >"${MOCK_IP_LOG}"
: >"${MOCK_FLOCK_LOG}"
policy_routing_remove
assert_status source_rule_missing
grep -q '^-4 route flush table 100$' "${MOCK_IP_LOG}"
grep -q '^-4 rule del pref 100$' "${MOCK_IP_LOG}"
grep -q '^-4 rule del pref 110$' "${MOCK_IP_LOG}"
if grep -qE 'route (del|flush) (default|table main)|nft' "${MOCK_IP_LOG}"; then
  echo "Route removal escaped project-owned routing scope." >&2
  exit 1
fi
grep -q '^-x -w 5 ' "${MOCK_FLOCK_LOG}"

# The systemd indirect-stop exception is a zero-mutation no-op only when a
# valid intent agrees with already-absent project routing.
printf 'valid\n' >"${MOCK_INTENT_STATE_FILE}"
set_rules
set_routes
: >"${MOCK_IP_LOG}"
: >"${MOCK_FLOCK_LOG}"
policy_routing_remove_for_shutdown
[[ ! -s ${MOCK_FLOCK_LOG} ]]
[[ $(grep -c 'rule del\|route flush' "${MOCK_IP_LOG}" || true) -eq 0 ]]

# Residual project routing forbids the no-lock shortcut. Busy means no cleanup.
set_healthy
: >"${MOCK_IP_LOG}"
: >"${MOCK_FLOCK_LOG}"
MOCK_FLOCK_BUSY=true
export MOCK_FLOCK_BUSY
if policy_routing_remove_for_shutdown; then
  echo "Route-down must not succeed unlocked while project routing remains." >&2
  exit 1
else
  [[ $? -eq 75 ]]
fi
[[ $(grep -c 'rule del\|route flush' "${MOCK_IP_LOG}" || true) -eq 0 ]]
MOCK_FLOCK_BUSY=false
export MOCK_FLOCK_BUSY

# Intent is re-read under the lock and blocks route activation and repair.
printf 'valid\n' >"${MOCK_INTENT_STATE_FILE}"
set_rules
set_routes
: >"${MOCK_IP_LOG}"
: >"${MOCK_FLOCK_LOG}"
if policy_routing_activate; then
  [[ ${POLICY_ROUTING_OUTCOME} == intentionally_disconnected ]]
else
  echo "Valid intent should make route activation an intentional no-op." >&2
  exit 1
fi
[[ $(grep -c 'route replace\|rule add' "${MOCK_IP_LOG}" || true) -eq 0 ]]
if policy_routing_repair; then
  echo "Policy repair must refuse intentional-disconnect intent." >&2
  exit 1
fi
[[ $(grep -c 'route replace\|rule add' "${MOCK_IP_LOG}" || true) -eq 0 ]]

# Intentional disconnect is a successful health observation only when live
# fail-closed evidence agrees. Timers can therefore keep running successfully.
MOCK_WG_UP=false
MOCK_NFT_ACTIVE=true
MOCK_DIRECT_CURL_RC=0
export MOCK_WG_UP MOCK_NFT_ACTIVE MOCK_DIRECT_CURL_RC
set_rules
set_routes
sample=$(healthcheck_run)
[[ ${sample} == HEALTH=OK* ]]
[[ ${sample} == *'state=intentionally_disconnected'* ]]
[[ ${sample} == *'route=absent'* && ${sample} == *'nft=ok'* ]]
[[ ${sample} == *'recovery=none'* ]]

# Corrupt/unsafe intent never becomes absent and never permits recovery.
for unsafe_state in corrupt unsafe; do
  printf '%s\n' "${unsafe_state}" >"${MOCK_INTENT_STATE_FILE}"
  set_rules
  set_routes
  : >"${MOCK_IP_LOG}"
  if sample=$(healthcheck_run); then
    echo "${unsafe_state} intent unexpectedly produced healthy state." >&2
    exit 1
  fi
  [[ ${sample} == *'state=failed'* && ${sample} == *"intent=${unsafe_state}"* ]]
  [[ $(grep -c 'route replace\|rule add' "${MOCK_IP_LOG}" || true) -eq 0 ]]
done

# Recovery that observed absent intent must check again after locking. Simulate
# intent appearing exactly as the health process acquires the shared lock.
rm -f "${MOCK_INTENT_STATE_FILE}"
MOCK_WG_UP=true
MOCK_FLOCK_CREATE_INTENT=true
export MOCK_WG_UP MOCK_FLOCK_CREATE_INTENT
set_rules
set_routes
: >"${MOCK_IP_LOG}"
if sample=$(healthcheck_run); then
  echo "Inconsistent newly-created intent should fail health observation." >&2
  exit 1
fi
[[ ${sample} == *'state=failed'* && ${sample} == *'intent=valid'* ]]
[[ $(grep -c 'route replace\|rule add' "${MOCK_IP_LOG}" || true) -eq 0 ]]
MOCK_FLOCK_CREATE_INTENT=false
export MOCK_FLOCK_CREATE_INTENT

# A contended lock produces stable mutation_busy evidence and no unlocked
# retry or routing mutation.
rm -f "${MOCK_INTENT_STATE_FILE}"
MOCK_FLOCK_BUSY=true
export MOCK_FLOCK_BUSY
set_rules
set_routes
: >"${MOCK_IP_LOG}"
if sample=$(healthcheck_run); then
  echo "Health recovery unexpectedly succeeded without the shared lock." >&2
  exit 1
fi
[[ ${sample} == *'recovery=mutation_busy'* ]]
[[ $(grep -c 'route replace\|rule add' "${MOCK_IP_LOG}" || true) -eq 0 ]]
MOCK_FLOCK_BUSY=false
export MOCK_FLOCK_BUSY

echo "Policy-routing drift detection and repair checks passed."
