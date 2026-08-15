#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=web-operation-lib.sh
source "${SCRIPT_DIR}/web-operation-lib.sh"
# shellcheck source=healthcheck-lib.sh
source "${SCRIPT_DIR}/healthcheck-lib.sh"

web_operation_require_root
load_config
if ! web_require_empty_input; then
  web_emit_failure health-run unsafe_precondition
  exit 0
fi

if sample=$(healthcheck_run); then
  health_rc=0
else
  health_rc=$?
fi
[[ ${sample} == HEALTH=* && ${sample} != *$'\n'* ]] || {
  web_emit_failure health-run health_failed
  exit 0
}

declare -A fields=()
read -r -a tokens <<<"${sample}"
for token in "${tokens[@]}"; do
  [[ ${token} == *=* ]] || { web_emit_failure health-run health_failed; exit 0; }
  key=${token%%=*}
  value=${token#*=}
  [[ -z ${fields[${key}]+x} ]] || { web_emit_failure health-run health_failed; exit 0; }
  fields[${key}]=${value}
done
for key in HEALTH state reason intent wg direct direct_rc warp warp_rc route nft recovery; do
  [[ -n ${fields[${key}]+x} ]] || { web_emit_failure health-run health_failed; exit 0; }
done
[[ ${#fields[@]} -eq 12 ]] || { web_emit_failure health-run health_failed; exit 0; }

if [[ ${fields[recovery]} == mutation_busy ]]; then
  web_emit_failure health-run mutation_busy
  exit 0
fi
if [[ ${fields[HEALTH]} == OK && ${fields[state]} == intentionally_disconnected ]]; then
  state=intentionally_disconnected
elif [[ ${fields[HEALTH]} == OK && ${health_rc} -eq 0 ]]; then
  state=ok
else
  state=failed
fi
if [[ ${state} == failed ]]; then
  web_emit_failure health-run health_failed
  exit 0
fi
printf '{"protocol":1,"verb":"health-run","ok":true,"code":"ok","data":{"state":"%s","reason":"%s","recovery":"%s","checks":{"wireguard":"%s","direct":"%s","warp":"%s","routing":"%s","killswitch":"%s"}}}\n' \
  "${state}" "${fields[reason]}" "${fields[recovery]}" "${fields[wg]}" \
  "${fields[direct]}" "${fields[warp]}" "${fields[route]}" "${fields[nft]}"
