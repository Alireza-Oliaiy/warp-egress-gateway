#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

JOURNAL_FILE="${ROOT}/shared/journald/10-warp-egress-gateway-retention.conf"
NATIVE_MONITOR="${ROOT}/native/scripts/monitor.sh"
DOCKER_MONITOR="${ROOT}/docker/bin/monitor.sh"
DOCKER_HEALTHCHECK="${ROOT}/docker/bin/healthcheck.sh"
MONITOR_LIB="${ROOT}/native/scripts/monitor-lib.sh"

[[ -r ${MONITOR_LIB} ]] || {
  echo "Monitor behavior library is missing: ${MONITOR_LIB}" >&2
  exit 1
}

for expected in \
  'Storage=persistent' \
  'Compress=yes' \
  'MaxRetentionSec=7day' \
  'SystemMaxUse=1G' \
  'SystemKeepFree=2G'; do
  grep -q "^${expected}$" "${JOURNAL_FILE}" || {
    echo "Missing journal setting: ${expected}" >&2
    exit 1
  }
done

grep -q 'OnUnitActiveSec=60s' "${ROOT}/native/systemd/warp-monitor.timer" || {
  echo "Native passive monitor must default to one-minute sampling" >&2
  exit 1
}

grep -q 'logger -t warp-monitor' "${NATIVE_MONITOR}" || {
  echo "Native monitor must write structured warp-monitor journal records" >&2
  exit 1
}

grep -q 'monitor_sample' "${NATIVE_MONITOR}" || {
  echo "Native monitor is not using the shared structured sample" >&2
  exit 1
}

grep -q 'driver: journald' "${ROOT}/docker/compose.yaml" || {
  echo "Docker logs must use journald for seven-day host retention" >&2
  exit 1
}

grep -q 'monitor_sample' "${DOCKER_MONITOR}" || {
  echo "Docker monitor is not using the shared structured sample" >&2
  exit 1
}

grep -q 'policy_routing_status' "${DOCKER_HEALTHCHECK}" || {
  echo "Docker healthcheck must use exact shared policy-routing validation" >&2
  exit 1
}

if grep -q '^AUTO_RECOVER="true"' "${ROOT}/native/config/warp-gateway.env.example"; then
  echo "AUTO_RECOVER must not default to true in the example config" >&2
  exit 1
fi

run_monitor_decision_cases() {
  local case_name expected actual
  # shellcheck source=../native/scripts/monitor-lib.sh
  source "${MONITOR_LIB}"
  for case_name in \
    'fresh:OK:up:ok:ok:on:ok:ok:ok' \
    'stale_dataplane_healthy:WARN:up:stale:ok:on:ok:ok:ok' \
    'stale_warp_failed:FAIL:up:stale:ok:fail:ok:ok:ok' \
    'none_warp_failed:FAIL:up:none:ok:fail:ok:ok:ok' \
    'route_failed:FAIL:up:ok:ok:on:fail:ok:ok' \
    'nft_failed:FAIL:up:ok:ok:on:ok:fail:ok' \
    'upstream_failed:FAIL:up:ok:ok:on:ok:ok:fail'; do
    # shellcheck disable=SC2034 # inputs consumed by the extracted monitor helper
    IFS=: read -r case_name expected WG_STATE HANDSHAKE_STATE DIRECT_STATE WARP_STATE ROUTE_STATE NFT_STATE UPSTREAM_STATE <<<"${case_name}"
    actual=$(monitor_status)
    [[ ${actual} == "${expected}" ]] || {
      echo "${case_name} expected ${expected}, got ${actual}." >&2
      exit 1
    }
  done

  # shellcheck disable=SC2034 # monitor_status consumes dynamically scoped inputs
  INTENT_STATE=valid WG_STATE=down HANDSHAKE_STATE=none DIRECT_STATE=ok \
    WARP_STATE=off ROUTE_STATE=absent NFT_STATE=ok UPSTREAM_STATE=skip
  actual=$(monitor_status)
  [[ ${actual} == OK ]] || {
    echo "Intentional disconnect expected OK observation, got ${actual}." >&2
    exit 1
  }
}

run_monitor_decision_cases

run_monitor_probe_cases() {
  local test_dir mock_bin sample now
  test_dir=$(mktemp -d)
  mock_bin=${test_dir}/bin
  mkdir -p "${mock_bin}"

  cat >"${mock_bin}/ip" <<'MOCK_IP'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  'link show warp0') [[ ${MOCK_WG_PRESENT:-true} == true ]] ;;
  '-4 -o address show dev eth0 scope global')
    echo '2: eth0    inet 203.0.113.10/24 scope global eth0' ;;
  '-4 -o address show dev warp0 scope global')
    [[ ${MOCK_WG_PRESENT:-true} == true ]] || exit 1
    echo '7: warp0    inet 192.0.2.2/32 scope global warp0' ;;
  '-4 rule show')
    if [[ ${MOCK_POLICY_PRESENT:-true} == true ]]; then
      printf '%s\n' \
        '100: from 192.0.2.2 lookup warp_gateway' \
        '110: from all iif eth1 lookup warp_gateway'
    fi ;;
  '-4 route show table 100 default'|'-4 route show table 100')
    if [[ ${MOCK_POLICY_PRESENT:-true} == true ]]; then
      echo 'default dev warp0'
    fi ;;
  *) echo "Unexpected fake ip invocation: $*" >&2; exit 64 ;;
esac
MOCK_IP

  cat >"${mock_bin}/wg" <<'MOCK_WG'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $* == 'show warp0 latest-handshakes' ]]; then
  printf 'test-peer\t%s\n' "${MOCK_HANDSHAKE_TS}"
elif [[ $* == 'show warp0' ]]; then
  exit 0
else
  exit 64
fi
MOCK_WG

  cat >"${mock_bin}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ " $* " == *' --interface 203.0.113.10 '* ]]; then
  printf 'ip=203.0.113.10\nwarp=off\n'
  exit 0
fi
if [[ " $* " == *' --interface 192.0.2.2 '* ]]; then
  if [[ ${MOCK_WARP_CURL_RC:-0} != 0 ]]; then
    exit "${MOCK_WARP_CURL_RC}"
  fi
  printf 'ip=198.51.100.20\nwarp=on\ncolo=TEST\nloc=ZZ\n'
  exit 0
fi
exit 64
MOCK_CURL

cat >"${mock_bin}/nft" <<'MOCK_NFT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${MOCK_NFT_ACTIVE:-true} == true ]] || exit 1
cat <<'NFT'
table inet warp_gateway {
  chain forward {
    iifname "eth1" oifname != "warp0" counter drop comment "WARP_KILL_SWITCH"
  }
}
NFT
MOCK_NFT

  cat >"${mock_bin}/ping" <<'MOCK_PING'
#!/usr/bin/env bash
exit 0
MOCK_PING

  chmod +x "${mock_bin}"/*
  PATH="${mock_bin}:${PATH}"
  export PATH

  WARP_IF=warp0
  UPLINK_IF=eth0
  TRANSIT_IF=eth1
  TRUSTED_SOURCE_CIDR=198.51.100.1/32
  ROUTING_TABLE_ID=100
  ROUTING_TABLE_NAME=warp_gateway
  SOURCE_RULE_PRIORITY=100
  INGRESS_RULE_PRIORITY=110
  NFT_TABLE=warp_gateway
  UPSTREAM_MONITOR_IP=off
  MONITOR_HANDSHAKE_WARN_SEC=120
  MONITOR_CURL_TIMEOUT=1
  HEALTHCHECK_URL=https://example.invalid/trace
  export WARP_IF UPLINK_IF TRANSIT_IF TRUSTED_SOURCE_CIDR
  export ROUTING_TABLE_ID ROUTING_TABLE_NAME SOURCE_RULE_PRIORITY
  export INGRESS_RULE_PRIORITY NFT_TABLE UPSTREAM_MONITOR_IP
  export MONITOR_HANDSHAKE_WARN_SEC MONITOR_CURL_TIMEOUT HEALTHCHECK_URL

  # common.sh deliberately enables errexit; monitor_sample must still turn
  # expected probe failures into telemetry rather than terminate the process.
  # shellcheck source=../native/scripts/common.sh
  source "${ROOT}/native/scripts/common.sh"
  # shellcheck source=../native/scripts/routing.sh
  source "${ROOT}/native/scripts/routing.sh"
  # shellcheck source=../native/scripts/monitor-lib.sh
  source "${MONITOR_LIB}"

  intentional_disconnect_state() {
    printf '%s\n' "${MOCK_INTENT_STATE:-absent}"
  }

  now=$(date +%s)
  MOCK_HANDSHAKE_TS=$((now - 10))
  MOCK_WARP_CURL_RC=0
  export MOCK_HANDSHAKE_TS MOCK_WARP_CURL_RC
  sample=$(monitor_sample)
  [[ ${sample} == STATUS=OK* && ${sample} == *'route=ok'* ]]

  MOCK_HANDSHAKE_TS=$((now - 180))
  export MOCK_HANDSHAKE_TS
  sample=$(monitor_sample)
  [[ ${sample} == STATUS=WARN* && ${sample} == *'handshake=stale'* && ${sample} == *'warp=on'* ]]

  MOCK_WARP_CURL_RC=28
  export MOCK_WARP_CURL_RC
  sample=$(monitor_sample)
  [[ ${sample} == STATUS=FAIL* ]]
  [[ ${sample} == *'warp=fail'* && ${sample} == *'warp_rc=28'* ]]

  MOCK_INTENT_STATE=valid
  MOCK_WG_PRESENT=false
  MOCK_POLICY_PRESENT=false
  MOCK_NFT_ACTIVE=true
  export MOCK_INTENT_STATE MOCK_WG_PRESENT MOCK_POLICY_PRESENT MOCK_NFT_ACTIVE
  sample=$(monitor_sample)
  [[ ${sample} == STATUS=OK* ]]
  [[ ${sample} == *'state=intentionally_disconnected'* ]]
  [[ ${sample} == *'intent=valid'* && ${sample} == *'wg=down'* ]]
  [[ ${sample} == *'route=absent'* && ${sample} == *'warp=off'* ]]

  MOCK_NFT_ACTIVE=false
  export MOCK_NFT_ACTIVE
  sample=$(monitor_sample)
  [[ ${sample} == STATUS=FAIL* && ${sample} == *'state=failed'* ]]

  MOCK_INTENT_STATE=corrupt
  MOCK_NFT_ACTIVE=true
  export MOCK_INTENT_STATE MOCK_NFT_ACTIVE
  sample=$(monitor_sample)
  [[ ${sample} == STATUS=FAIL* && ${sample} == *'intent=corrupt'* ]]

  rm -rf "${test_dir}"
}

run_monitor_probe_cases

echo "Seven-day journal retention and passive monitoring checks passed."
