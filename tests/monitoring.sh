#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

JOURNAL_FILE="${ROOT}/shared/journald/10-warp-egress-gateway-retention.conf"
NATIVE_MONITOR="${ROOT}/native/scripts/monitor.sh"
DOCKER_MONITOR="${ROOT}/docker/bin/monitor.sh"

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

grep -q 'STATUS=${STATUS}' "${NATIVE_MONITOR}" || {
  echo "Native monitor is missing STATUS output" >&2
  exit 1
}

grep -q 'driver: journald' "${ROOT}/docker/compose.yaml" || {
  echo "Docker logs must use journald for seven-day host retention" >&2
  exit 1
}

grep -q 'STATUS=${STATUS}' "${DOCKER_MONITOR}" || {
  echo "Docker monitor is missing STATUS output" >&2
  exit 1
}

if grep -q '^AUTO_RECOVER="true"' "${ROOT}/native/config/warp-gateway.env.example"; then
  echo "AUTO_RECOVER must not default to true in the example config" >&2
  exit 1
fi

run_monitor_decision_cases() {
  local monitor=$1 helper case_name expected actual
  helper=$(mktemp)
  awk '
    /^monitor_status\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${monitor}" >"${helper}"
  [[ -s ${helper} ]] || { echo "Monitor decision helper is missing: ${monitor}" >&2; rm -f "${helper}"; exit 1; }
  # shellcheck disable=SC1090
  source "${helper}"
  rm -f "${helper}"

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
      echo "${monitor}: ${case_name} expected ${expected}, got ${actual}." >&2
      exit 1
    }
  done
}

run_monitor_decision_cases "${NATIVE_MONITOR}"
run_monitor_decision_cases "${DOCKER_MONITOR}"

echo "Seven-day journal retention and passive monitoring checks passed."
