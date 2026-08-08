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

# Evaluate the intended early-boot dependency graph rather than merely looking
# for ordering keywords. The firewall/guard must be started from sysinit and
# complete before network-pre, WireGuard/Docker, and policy routing can run.
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
"${PYTHON3_BIN}" - "${ROOT}" <<'PY'
from collections import defaultdict, deque
from pathlib import Path
import sys

root = Path(sys.argv[1])

def unit(path):
    section = None
    values = defaultdict(list)
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('[') and line.endswith(']'):
            section = line[1:-1]
            continue
        if section and '=' in line:
            key, value = line.split('=', 1)
            values[(section, key)].extend(value.split())
    return values

native = unit(root / 'native/systemd/warp-gateway-firewall.service')
gateway = unit(root / 'native/systemd/warp-gateway.service')
wg = unit(root / 'native/systemd/warp-gateway.conf')
docker = unit(root / 'docker/host/warp-egress-docker-guard.service')

def require(values, section, key, value, label):
    if value not in values[(section, key)]:
        raise SystemExit(f'{label} must include {key}={value}')

for values, label in ((native, 'Native firewall guard'), (docker, 'Docker host guard')):
    require(values, 'Unit', 'DefaultDependencies', 'no', label)
    require(values, 'Unit', 'After', 'local-fs.target', label)
    require(values, 'Unit', 'Requires', 'systemd-sysctl.service', label)
    require(values, 'Unit', 'After', 'systemd-sysctl.service', label)
    require(values, 'Unit', 'Before', 'network-pre.target', label)
    require(values, 'Unit', 'Wants', 'network-pre.target', label)
    require(values, 'Unit', 'Before', 'shutdown.target', label)
    require(values, 'Unit', 'Conflicts', 'shutdown.target', label)
    require(values, 'Install', 'WantedBy', 'sysinit.target', label)

require(native, 'Service', 'ExecStop', '/bin/true', 'Native firewall guard')
require(docker, 'Service', 'ExecStop', '/bin/true', 'Docker host guard')
require(wg, 'Unit', 'Requires', 'warp-gateway-firewall.service', 'WireGuard drop-in')
require(wg, 'Unit', 'After', 'warp-gateway-firewall.service', 'WireGuard drop-in')
require(gateway, 'Unit', 'Requires', 'warp-gateway-firewall.service', 'Policy-routing service')
require(gateway, 'Unit', 'Requires', 'wg-quick@warp0.service', 'Policy-routing service')

edges = {
    'local-fs.target': {'systemd-sysctl.service'},
    'systemd-sysctl.service': {'firewall', 'docker-guard'},
    'firewall': {'network-pre.target', 'wg-quick@warp0.service', 'warp-gateway.service'},
    'network-pre.target': {'wg-quick@warp0.service', 'docker.service'},
    'wg-quick@warp0.service': {'warp-gateway.service'},
    'docker-guard': {'network-pre.target', 'docker.service'},
}
incoming = defaultdict(int)
nodes = set(edges)
for source, targets in edges.items():
    for target in targets:
        nodes.add(target)
        incoming[target] += 1
queue = deque(node for node in nodes if not incoming[node])
seen = []
while queue:
    node = queue.popleft()
    seen.append(node)
    for target in edges.get(node, ()):
        incoming[target] -= 1
        if incoming[target] == 0:
            queue.append(target)
if len(seen) != len(nodes):
    raise SystemExit('Early-boot dependency graph contains an ordering cycle')

native_sysctl = (root / 'native/install.sh').read_text(encoding='utf-8')
docker_sysctl = (root / 'docker/setup.sh').read_text(encoding='utf-8')
for content, label in ((native_sysctl, 'Native'), (docker_sysctl, 'Docker')):
    if 'net.ipv4.ip_forward=0' not in content:
        raise SystemExit(f'{label} persistent sysctl must default ip_forward to 0')
for script, label in ((root / 'native/scripts/firewall-apply.sh', 'Native'),
                      (root / 'docker/host/guard-apply.sh', 'Docker')):
    content = script.read_text(encoding='utf-8')
    if 'destroy table inet' not in content or 'net.ipv4.ip_forward=1' not in content:
        raise SystemExit(f'{label} guard must atomically install rules before enabling forwarding')
PY

if command -v systemd-analyze >/dev/null 2>&1; then
  unit_test_dir=$(mktemp -d)
  trap 'rm -rf "${unit_test_dir}"' EXIT
  for unit in \
    native/systemd/warp-gateway-firewall.service \
    native/systemd/warp-gateway.service \
    docker/host/warp-egress-docker-guard.service; do
    sed -E 's#^Exec(Start|Stop|Reload)=.*#Exec\1=/bin/true#' "${ROOT}/${unit}" \
      >"${unit_test_dir}/$(basename "${unit}")"
  done
  {
    cat "${ROOT}/native/systemd/warp-gateway.conf"
    printf '\n[Service]\nType=oneshot\nExecStart=/bin/true\n'
  } >"${unit_test_dir}/wg-quick@warp0.service"
  systemd-analyze verify \
    "${unit_test_dir}/warp-gateway-firewall.service" \
    "${unit_test_dir}/wg-quick@warp0.service" \
    "${unit_test_dir}/warp-gateway.service" \
    "${unit_test_dir}/warp-egress-docker-guard.service"
  echo "PASS systemd unit verification"
else
  echo "SKIP systemd unit verification (systemd-analyze unavailable)"
fi

echo "Native and Docker kill-switch static safety checks passed."
