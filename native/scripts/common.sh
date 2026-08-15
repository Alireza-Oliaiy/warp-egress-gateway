#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="warp-egress-gateway"
CONFIG_DIR=${WARP_GATEWAY_CONFIG_DIR:-/etc/${PROJECT_NAME}}
CONFIG_FILE=${WARP_GATEWAY_CONFIG_FILE:-${CONFIG_DIR}/warp-gateway.env}
# These values are consumed by the scripts that source this library.
# shellcheck disable=SC2034
STATE_DIR="/var/lib/${PROJECT_NAME}"
# shellcheck disable=SC2034
LIB_DIR="/usr/local/lib/${PROJECT_NAME}"
# shellcheck disable=SC2034
NFT_TABLE="warp_gateway"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this command as root."
}

load_config() {
  [[ -r ${CONFIG_FILE} ]] || die "Missing configuration: ${CONFIG_FILE}"
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"

  : "${TRANSIT_IF:?TRANSIT_IF is required}"
  : "${TRUSTED_SOURCE_CIDR:?TRUSTED_SOURCE_CIDR is required}"
  : "${UPLINK_IF:?UPLINK_IF is required}"
  : "${WARP_IF:?WARP_IF is required}"
  : "${ROUTING_TABLE_ID:?ROUTING_TABLE_ID is required}"
  : "${SOURCE_RULE_PRIORITY:?SOURCE_RULE_PRIORITY is required}"
  : "${INGRESS_RULE_PRIORITY:?INGRESS_RULE_PRIORITY is required}"
}

remove_rule_priority() {
  local priority=$1
  while ip -4 rule show | grep -qE "^${priority}:"; do
    ip -4 rule del pref "${priority}" || break
  done
}

warp_ipv4_cidr() {
  ip -4 -o address show dev "${WARP_IF}" scope global 2>/dev/null \
    | awk 'NR == 1 {print $4}'
}

warp_ipv4_address() {
  local cidr
  cidr=$(warp_ipv4_cidr)
  [[ -n ${cidr} ]] || return 1
  printf '%s\n' "${cidr%%/*}"
}
