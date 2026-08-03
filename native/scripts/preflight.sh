#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
load_config

command -v ip >/dev/null || die "iproute2 is required."
command -v nft >/dev/null || die "nftables is required."
command -v wg >/dev/null || die "wireguard-tools is required."

ip link show "${UPLINK_IF}" >/dev/null 2>&1 || die "Uplink interface ${UPLINK_IF} does not exist."
ip link show "${TRANSIT_IF}" >/dev/null 2>&1 || die "Transit interface ${TRANSIT_IF} does not exist."

if [[ ${ENABLE_IPV6_TRANSIT:-false} == "true" ]]; then
  die "IPv6 transit is not implemented in this release. Keep ENABLE_IPV6_TRANSIT=false."
fi

python3 - "${TRUSTED_SOURCE_CIDR}" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError as exc:
    raise SystemExit(f"Invalid TRUSTED_SOURCE_CIDR: {exc}")
if net.version != 4:
    raise SystemExit("TRUSTED_SOURCE_CIDR must be IPv4")
PY

for value in "${ROUTING_TABLE_ID}" "${SOURCE_RULE_PRIORITY}" "${INGRESS_RULE_PRIORITY}"; do
  [[ ${value} =~ ^[0-9]+$ ]] || die "Routing table IDs and priorities must be numeric."
done

if [[ ${SOURCE_RULE_PRIORITY} == "${INGRESS_RULE_PRIORITY}" ]]; then
  die "SOURCE_RULE_PRIORITY and INGRESS_RULE_PRIORITY must differ."
fi

main_route=$(ip -4 route show default | head -n1 || true)
[[ ${main_route} == *" dev ${UPLINK_IF}"* ]] \
  || die "The main default route is not using UPLINK_IF=${UPLINK_IF}: ${main_route:-none}"

if [[ -n ${UPLINK_GATEWAY:-} && ${main_route} != *"via ${UPLINK_GATEWAY}"* ]]; then
  die "The main default route does not use UPLINK_GATEWAY=${UPLINK_GATEWAY}: ${main_route}"
fi

if [[ ${MANAGE_TRANSIT_ADDRESS:-false} != "true" ]]; then
  ip -4 -o address show dev "${TRANSIT_IF}" | grep -Fq " ${TRANSIT_CIDR}" \
    || die "${TRANSIT_IF} does not have ${TRANSIT_CIDR}; configure it first or set MANAGE_TRANSIT_ADDRESS=true."
fi

log "Preflight checks passed."
