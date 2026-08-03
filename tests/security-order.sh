#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FILE="${ROOT}/native/scripts/firewall-apply.sh"

kill_line=$(grep -n 'WARP_KILL_SWITCH' "${FILE}" | head -n1 | cut -d: -f1)
return_line=$(grep -n 'WARP_RETURN_ACCEPT' "${FILE}" | head -n1 | cut -d: -f1)

[[ -n ${kill_line} && -n ${return_line} ]] || {
  echo "Missing kill-switch or return rule" >&2
  exit 1
}
(( kill_line < return_line )) || {
  echo "Kill switch must be evaluated before return acceptance" >&2
  exit 1
}

grep -q 'ExecStop=/bin/true' "${ROOT}/native/systemd/warp-gateway-firewall.service" || {
  echo "Native firewall service must not remove the kill switch on stop" >&2
  exit 1
}
grep -q 'WARP_DOCKER_HOST_KILL_SWITCH' "${ROOT}/docker/host/guard-apply.sh" || {
  echo "Docker host guard is missing" >&2
  exit 1
}
grep -q 'network_mode: host' "${ROOT}/docker/compose.yaml" || {
  echo "Docker runtime must share the Linux host network namespace" >&2
  exit 1
}
grep -q 'NET_ADMIN' "${ROOT}/docker/compose.yaml" || {
  echo "Docker runtime requires scoped NET_ADMIN" >&2
  exit 1
}
if grep -qE '^\s*privileged:' "${ROOT}/docker/compose.yaml"; then
  echo "Docker runtime must not use privileged mode" >&2
  exit 1
fi
grep -q 'host kill switch remains loaded' "${ROOT}/docker/bin/entrypoint.sh" || {
  echo "Docker cleanup safety behavior is undocumented" >&2
  exit 1
}

echo "Native and Docker kill-switch static safety checks passed."
