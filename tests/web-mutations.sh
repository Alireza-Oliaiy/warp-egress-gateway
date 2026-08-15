#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}

"${PYTHON3_BIN}" "${ROOT}/tests/intent_writer_test.py"

for adapter in web-routing-repair.sh web-health-run.sh web-warp-disconnect.sh; do
  [[ -x ${ROOT}/native/scripts/${adapter} ]] || {
    printf 'Missing executable fixed operation adapter: %s\n' "${adapter}" >&2
    exit 1
  }
done

if [[ $(uname -s) != Linux || ! -x /usr/bin/flock ]]; then
  printf 'SKIP web mutation adapter filesystem/lock behavior (requires Linux).\n'
  printf 'Web mutation primitive checks passed.\n'
  exit 0
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT
MOCK_BIN=${TEST_DIR}/bin
mkdir -p "${MOCK_BIN}"
export MOCK_RULES=${TEST_DIR}/rules MOCK_ROUTES=${TEST_DIR}/routes
export MOCK_MAIN=${TEST_DIR}/main MOCK_WG_STATE=${TEST_DIR}/wg-state
export MOCK_SYSTEMCTL_LOG=${TEST_DIR}/systemctl.log
printf 'default via 203.0.113.1 dev eth0\n' >"${MOCK_MAIN}"
printf 'up\n' >"${MOCK_WG_STATE}"
: >"${MOCK_SYSTEMCTL_LOG}"

cat >"${MOCK_BIN}/ip" <<'MOCK_IP'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $* == '-4 rule show' ]]; then cat "${MOCK_RULES}"
elif [[ $* == '-4 rule del pref '* ]]; then p=${5}; awk -v p="${p}:" '$1 != p' "${MOCK_RULES}" >"${MOCK_RULES}.n"; mv "${MOCK_RULES}.n" "${MOCK_RULES}"
elif [[ $* == '-4 rule add pref '* ]]; then
  if [[ ${6} == from ]]; then printf '%s: from %s lookup %s\n' "${5}" "${7%/32}" "${9}" >>"${MOCK_RULES}"
  else printf '%s: from all iif %s lookup %s\n' "${5}" "${7}" "${9}" >>"${MOCK_RULES}"; fi
elif [[ $* == '-4 route show table main default' ]]; then cat "${MOCK_MAIN}"
elif [[ $* == '-4 route show table 100 default' || $* == '-4 route show table 100' ]]; then cat "${MOCK_ROUTES}"
elif [[ $* == '-4 route replace default dev warp0 table 100' ]]; then printf 'default dev warp0\n' >"${MOCK_ROUTES}"
elif [[ $* == '-4 route flush table 100' ]]; then : >"${MOCK_ROUTES}"
elif [[ $* == '-4 route flush cache' ]]; then :
elif [[ $* == '-4 -o address show dev warp0 scope global' ]]; then [[ $(cat "${MOCK_WG_STATE}") == up ]] && printf '7: warp0 inet 192.0.2.2/32 scope global warp0\n'
elif [[ $* == '-4 -o address show dev eth0 scope global' ]]; then printf '2: eth0 inet 203.0.113.10/24 scope global eth0\n'
elif [[ $* == 'link show warp0' ]]; then [[ $(cat "${MOCK_WG_STATE}") == up ]]
else printf 'unexpected ip: %s\n' "$*" >&2; exit 64; fi
MOCK_IP
cat >"${MOCK_BIN}/wg" <<'MOCK_WG'
#!/usr/bin/env bash
[[ $* == 'show warp0' && $(cat "${MOCK_WG_STATE}") == up ]]
MOCK_WG
cat >"${MOCK_BIN}/nft" <<'MOCK_NFT'
#!/usr/bin/env bash
[[ ${MOCK_NFT_ACTIVE:-true} == true ]] || exit 1
cat <<'NFT'
table inet warp_gateway { chain forward { iifname "eth1" oifname != "warp0" counter drop comment "WARP_KILL_SWITCH" } }
NFT
MOCK_NFT
cat >"${MOCK_BIN}/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${MOCK_SYSTEMCTL_LOG}"
case "$*" in
  'show --property=ActiveEnterTimestampMonotonic --value wg-quick@warp0.service') printf '123456\n' ;;
  'is-active --quiet wg-quick@warp0.service') [[ $(cat "${MOCK_WG_STATE}") == up ]] ;;
  'is-active --quiet warp-gateway-healthcheck.timer'|'is-active --quiet warp-monitor.timer') exit 0 ;;
  'stop wg-quick@warp0.service')
    [[ ${MOCK_STOP_FAIL:-false} != true ]] || exit 1
    printf 'down\n' >"${MOCK_WG_STATE}"
    ;;
  'restart wg-quick@warp0.service') printf 'up\n' >"${MOCK_WG_STATE}" ;;
  *) exit 64 ;;
esac
MOCK_SYSTEMCTL
cat >"${MOCK_BIN}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
if [[ " $* " == *' --interface 203.0.113.10 '* ]]; then printf 'ip=203.0.113.10\nwarp=off\n'
elif [[ " $* " == *' --interface 192.0.2.2 '* ]]; then printf 'ip=198.51.100.20\nwarp=on\n'
else exit 64; fi
MOCK_CURL
chmod +x "${MOCK_BIN}"/*

CONFIG=${TEST_DIR}/warp-gateway.env
cat >"${CONFIG}" <<'CONFIG'
TRANSIT_IF="eth1"
TRUSTED_SOURCE_CIDR="198.51.100.1/32"
UPLINK_IF="eth0"
WARP_IF="warp0"
ROUTING_TABLE_ID="100"
ROUTING_TABLE_NAME="warp_gateway"
SOURCE_RULE_PRIORITY="100"
INGRESS_RULE_PRIORITY="110"
HEALTHCHECK_URL="https://example.invalid/trace"
HEALTHCHECK_TIMEOUT="1"
AUTO_RECOVER="false"
CONFIG
export PATH="${MOCK_BIN}:/usr/bin:/bin"
export WARP_GATEWAY_CONFIG_FILE=${CONFIG}
export WARP_WEB_OPERATION_TEST_MODE=1 WARP_RUNTIME_STATE_TEST_MODE=1
export WARP_RUNTIME_STATE_TEST_DIR=${TEST_DIR}/runtime
export WARP_RUNTIME_STATE_TEST_ASSUME_SAFE=0
export WARP_GATEWAY_PYTHON3=${PYTHON3_BIN}
export WARP_RUNTIME_STATE_TEST_FLOCK_BIN=/usr/bin/flock

connected_state() {
  printf '%s\n' '100: from 192.0.2.2 lookup warp_gateway' '110: from all iif eth1 lookup warp_gateway' >"${MOCK_RULES}"
  printf 'default dev warp0\n' >"${MOCK_ROUTES}"
  printf 'up\n' >"${MOCK_WG_STATE}"
}

connected_state
sed -i '/^100:/d' "${MOCK_RULES}"
main_before=$(cat "${MOCK_MAIN}")
nft_before=$(nft list table inet warp_gateway)
repair=$(printf '{}\n' | "${ROOT}/native/scripts/web-routing-repair.sh")
[[ ${repair} == *'"ok":true'* && ${repair} == *'"changed":true'* && ${repair} == *'"before":"source_rule_missing"'* ]]
[[ $(cat "${MOCK_MAIN}") == "${main_before}" ]]
[[ $(nft list table inet warp_gateway) == "${nft_before}" ]]
[[ $(grep -c '^restart ' "${MOCK_SYSTEMCTL_LOG}" || true) -eq 0 ]]
repair=$(printf '{}\n' | "${ROOT}/native/scripts/web-routing-repair.sh")
[[ ${repair} == *'"changed":false'* ]]

request='{"request_id":"0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7","asserted_actor":"admin-example"}'
disconnect=$(printf '%s\n' "${request}" | "${ROOT}/native/scripts/web-warp-disconnect.sh")
[[ ${disconnect} == *'"state":"intentionally_disconnected"'* && ${disconnect} == *'"already_disconnected":false'* ]]
[[ -f ${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json ]]
[[ $(stat -c %a "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json") == 600 ]]
[[ ! -s ${MOCK_RULES} && ! -s ${MOCK_ROUTES} && $(cat "${MOCK_WG_STATE}") == down ]]
[[ $(cat "${MOCK_MAIN}") == "${main_before}" ]]
inode_before=$(stat -c %i "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json")
record_before=$(cat "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json")
disconnect=$(printf '%s\n' "${request}" | "${ROOT}/native/scripts/web-warp-disconnect.sh")
[[ ${disconnect} == *'"already_disconnected":true'* ]]
[[ $(stat -c %i "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json") == "${inode_before}" ]]
[[ $(cat "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json") == "${record_before}" ]]

repair=$(printf '{}\n' | "${ROOT}/native/scripts/web-routing-repair.sh")
[[ ${repair} == *'"ok":false'* && ${repair} == *'"code":"intent_conflict"'* ]]
health=$(printf '{}\n' | "${ROOT}/native/scripts/web-health-run.sh")
[[ ${health} == *'"state":"intentionally_disconnected"'* && ${health} == *'"recovery":"none"'* ]]

# A post-intent failure remains fail closed and never removes the record.
rm -rf "${WARP_RUNTIME_STATE_TEST_DIR}"
connected_state
MOCK_STOP_FAIL=true
export MOCK_STOP_FAIL
failed=$(printf '%s\n' "${request}" | "${ROOT}/native/scripts/web-warp-disconnect.sh")
[[ ${failed} == *'"ok":false'* && ${failed} == *'"code":"postcondition_failed"'* ]]
[[ -f ${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json ]]
[[ ! -s ${MOCK_RULES} && ! -s ${MOCK_ROUTES} ]]
[[ $(grep -c '^restart ' "${MOCK_SYSTEMCTL_LOG}" || true) -eq 0 ]]
MOCK_STOP_FAIL=false
export MOCK_STOP_FAIL

# Missing kill switch refuses before intent, routing, or WireGuard mutation.
rm -rf "${WARP_RUNTIME_STATE_TEST_DIR}"
connected_state
MOCK_NFT_ACTIVE=false
export MOCK_NFT_ACTIVE
rules_before=$(cat "${MOCK_RULES}")
failed=$(printf '%s\n' "${request}" | "${ROOT}/native/scripts/web-warp-disconnect.sh")
[[ ${failed} == *'"code":"unsafe_precondition"'* ]]
[[ ! -e ${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json ]]
[[ $(cat "${MOCK_RULES}") == "${rules_before}" && $(cat "${MOCK_WG_STATE}") == up ]]
MOCK_NFT_ACTIVE=true
export MOCK_NFT_ACTIVE

# Corrupt and unsafe existing intent are never overwritten.
rm -rf "${WARP_RUNTIME_STATE_TEST_DIR}"
mkdir -m 700 "${WARP_RUNTIME_STATE_TEST_DIR}"
printf 'not-json\n' >"${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json"
chmod 600 "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json"
corrupt_before=$(cat "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json")
failed=$(printf '%s\n' "${request}" | "${ROOT}/native/scripts/web-warp-disconnect.sh")
[[ ${failed} == *'"code":"intent_conflict"'* ]]
[[ $(cat "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json") == "${corrupt_before}" ]]
rm "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json"
printf 'target\n' >"${TEST_DIR}/intent-target"
ln -s "${TEST_DIR}/intent-target" "${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json"
failed=$(printf '%s\n' "${request}" | "${ROOT}/native/scripts/web-warp-disconnect.sh")
[[ ${failed} == *'"code":"intent_conflict"'* ]]
[[ -L ${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json ]]

# Lock contention produces mutation_busy with no routing or WireGuard mutation.
rm -rf "${WARP_RUNTIME_STATE_TEST_DIR}"
connected_state
mkdir -m 700 "${WARP_RUNTIME_STATE_TEST_DIR}"
: >"${WARP_RUNTIME_STATE_TEST_DIR}/mutation.lock"
chmod 600 "${WARP_RUNTIME_STATE_TEST_DIR}/mutation.lock"
exec {busy_fd}<>"${WARP_RUNTIME_STATE_TEST_DIR}/mutation.lock"
/usr/bin/flock -x "${busy_fd}"
failed=$(printf '%s\n' "${request}" | "${ROOT}/native/scripts/web-warp-disconnect.sh")
[[ ${failed} == *'"code":"mutation_busy"'* ]]
[[ ! -e ${WARP_RUNTIME_STATE_TEST_DIR}/intentional-disconnect.json ]]
[[ -s ${MOCK_RULES} && $(cat "${MOCK_WG_STATE}") == up ]]
/usr/bin/flock -u "${busy_fd}"
exec {busy_fd}>&-

printf 'Web mutation primitive checks passed.\n'
