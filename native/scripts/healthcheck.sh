#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
load_config

TIMEOUT=${HEALTHCHECK_TIMEOUT:-15}
URL=${HEALTHCHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}
AUTO_RECOVER=${AUTO_RECOVER:-false}

check_warp() {
  local warp_ip output
  systemctl is-active --quiet "wg-quick@${WARP_IF}.service" || return 1
  systemctl is-active --quiet warp-gateway.service || return 1
  warp_ip=$(warp_ipv4_address) || return 1
  output=$(curl -4 --silent --show-error --fail \
    --interface "${warp_ip}" --connect-timeout "${TIMEOUT}" \
    --max-time "${TIMEOUT}" "${URL}") || return 1
  grep -q '^warp=on$' <<<"${output}"
}

if check_warp; then
  log "Health check passed."
  exit 0
fi

warn "WARP health check failed. Kill switch remains active."

if [[ ${AUTO_RECOVER} == "true" ]]; then
  warn "Attempting recovery."
  systemctl restart "wg-quick@${WARP_IF}.service"
  systemctl restart warp-gateway.service
  sleep 3
  if check_warp; then
    log "Recovery succeeded."
    exit 0
  fi
fi

if [[ ${AUTO_RECOVER} == "true" ]]; then
  die "WARP health check failed after recovery attempt."
fi
die "WARP health check failed; AUTO_RECOVER is disabled."
