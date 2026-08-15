#!/usr/bin/env bash

WEB_OPERATION_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ${WARP_WEB_OPERATION_TEST_MODE:-0} == 1 && ${EUID} -ne 0 ]]; then
  WEB_OPERATION_TEST_MODE=1
  WEB_INTENT_TOOL=${WEB_OPERATION_DIR}/runtime-state-intent.py
else
  WEB_OPERATION_TEST_MODE=0
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  export PATH
  # shellcheck disable=SC2034 # consumed by the sourcing disconnect adapter
  WEB_INTENT_TOOL=/usr/local/lib/warp-egress-gateway/runtime-state-intent.py
fi

# shellcheck source=common.sh
source "${WEB_OPERATION_DIR}/common.sh"
# shellcheck source=routing.sh
source "${WEB_OPERATION_DIR}/routing.sh"

web_operation_require_root() {
  if [[ ${WEB_OPERATION_TEST_MODE} != 1 ]]; then
    require_root
  fi
}

web_read_bounded_input() {
  local value
  value=$(head -c 4097)
  (( ${#value} <= 4096 )) || return 2
  printf '%s' "${value}"
}

web_require_empty_input() {
  local payload compact
  payload=$(web_read_bounded_input) || return
  compact=${payload//[[:space:]]/}
  [[ ${compact} == '{}' ]] || return 2
}

web_emit_failure() {
  local verb=$1 code=$2
  printf '{"protocol":1,"verb":"%s","ok":false,"code":"%s","data":{"state":"failed","reason":"%s"}}\n' "${verb}" "${code}" "${code}"
}

web_emit_disconnect_failure() {
  local code=$1 intent_active=$2
  printf '{"protocol":1,"verb":"warp-disconnect","ok":false,"code":"%s","data":{"state":"failed","reason":"%s","intent_active":%s,"automatic_recovery_suppressed":%s}}\n' \
    "${code}" "${code}" "${intent_active}" "${intent_active}"
}

web_fingerprint() {
  sha256sum | awk '{print $1}'
}

web_main_default_snapshot() {
  ip -4 route show table main default 2>/dev/null
}

web_nft_snapshot() {
  nft list table inet "${NFT_TABLE}" 2>/dev/null
}

web_wg_activation_snapshot() {
  systemctl show --property=ActiveEnterTimestampMonotonic --value "wg-quick@${WARP_IF}.service" 2>/dev/null
}
