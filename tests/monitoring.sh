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

echo "Seven-day journal retention and passive monitoring checks passed."
