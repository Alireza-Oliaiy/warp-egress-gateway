#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME_LIB_DIR=${WARP_GATEWAY_LIB_DIR:-/app/scripts}
export WARP_GATEWAY_CONFIG_FILE=${WARP_GATEWAY_CONFIG_FILE:-/etc/warp-egress-gateway/warp-gateway.env}
# shellcheck source=../../native/scripts/common.sh
source "${RUNTIME_LIB_DIR}/common.sh"
# shellcheck source=../../native/scripts/routing.sh
source "${RUNTIME_LIB_DIR}/routing.sh"
load_config

ip link show "${WARP_IF}" >/dev/null 2>&1 || exit 1
warp_ip=$(ip -4 -o address show dev "${WARP_IF}" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')
[[ -n ${warp_ip} ]] || exit 1
[[ $(policy_routing_status) == ok ]] || exit 1
kill_switch_active || exit 1

output=$(curl -4 --silent --show-error --fail \
  --interface "${warp_ip}" \
  --connect-timeout "${HEALTHCHECK_TIMEOUT:-15}" \
  --max-time "${HEALTHCHECK_TIMEOUT:-15}" \
  "${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}") || exit 1
grep -q '^warp=on$' <<<"${output}"
