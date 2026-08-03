#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="${ROOT_DIR}/install.sh"

UPLINK_IP=""
TRANSIT_CIDR=""
TRANSIT_IF=""
TRUSTED_SOURCE_CIDR=""
PROFILE=""
ACCEPT_TOS="false"
NON_INTERACTIVE="false"

usage() {
  cat <<'USAGE'
Interactive installer for WARP Egress Gateway.

Usage:
  sudo ./native/setup.sh

Unattended example:
  sudo ./native/setup.sh \
    --uplink-ip 172.20.31.5 \
    --transit-ip 10.1.1.230/30 \
    --accept-tos

Options:
  --uplink-ip IP           IPv4 address already configured on the Internet/uplink NIC.
  --transit-ip IP/CIDR     Server-side transit address. /30 is assumed when omitted.
  --transit-if NAME        Transit interface name; normally auto-detected.
  --trusted-source CIDR    Upstream firewall source; auto-derived for a /30.
  --profile PATH           Reuse an existing WireGuard WARP profile.
  --accept-tos             Confirm that Cloudflare terms were reviewed and accepted.
  --non-interactive        Fail instead of prompting for missing values.
  -h, --help               Show this help.
USAGE
}

log() { printf '[setup] %s\n' "$*"; }
die() { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uplink-ip) UPLINK_IP=${2:?Missing value after --uplink-ip}; shift 2 ;;
    --transit-ip) TRANSIT_CIDR=${2:?Missing value after --transit-ip}; shift 2 ;;
    --transit-if) TRANSIT_IF=${2:?Missing value after --transit-if}; shift 2 ;;
    --trusted-source) TRUSTED_SOURCE_CIDR=${2:?Missing value after --trusted-source}; shift 2 ;;
    --profile) PROFILE=${2:?Missing value after --profile}; shift 2 ;;
    --accept-tos) ACCEPT_TOS="true"; shift ;;
    --non-interactive) NON_INTERACTIVE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run with sudo or as root."
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'warp-egress-gateway'; then
  die "Docker edition is already running. Remove it before installing Native mode."
fi
[[ -x ${INSTALLER} ]] || die "Missing installer: ${INSTALLER}"
command -v ip >/dev/null || die "The ip command is required."

prompt() {
  local variable_name=$1 message=$2 current=${3:-}
  local answer
  if [[ ${NON_INTERACTIVE} == "true" ]]; then
    [[ -n ${current} ]] || die "Missing required value: ${variable_name}"
    printf -v "${variable_name}" '%s' "${current}"
    return
  fi
  if [[ -n ${current} ]]; then
    read -r -p "${message} [${current}]: " answer
    answer=${answer:-${current}}
  else
    read -r -p "${message}: " answer
  fi
  [[ -n ${answer} ]] || die "A value is required for ${variable_name}."
  printf -v "${variable_name}" '%s' "${answer}"
}

normalize_ipv4() {
  printf '%s\n' "${1%%/*}"
}

validate_ipv4() {
  local ip=$1 octet
  local IFS=.
  read -r -a parts <<<"${ip}"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for octet in "${parts[@]}"; do
    [[ ${octet} =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

ipv4_to_int() {
  local ip=$1 a b c d
  IFS=. read -r a b c d <<<"${ip}"
  printf '%u\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

int_to_ipv4() {
  local value=$1
  printf '%d.%d.%d.%d\n' \
    "$(( (value >> 24) & 255 ))" \
    "$(( (value >> 16) & 255 ))" \
    "$(( (value >> 8) & 255 ))" \
    "$(( value & 255 ))"
}

interface_for_ipv4() {
  local wanted=$1
  ip -4 -o address show | awk -v wanted="${wanted}" '
    {
      split($4, address, "/")
      if (address[1] == wanted) { print $2; exit }
    }'
}

cidr_for_ipv4() {
  local wanted=$1
  ip -4 -o address show | awk -v wanted="${wanted}" '
    {
      split($4, address, "/")
      if (address[1] == wanted) { print $4; exit }
    }'
}

derive_peer_from_30() {
  local cidr=$1 ip prefix ip_int network host1 host2
  ip=${cidr%%/*}
  prefix=${cidr##*/}
  [[ ${prefix} == "30" ]] || return 1
  validate_ipv4 "${ip}" || return 1
  ip_int=$(ipv4_to_int "${ip}")
  network=$(( ip_int & 0xFFFFFFFC ))
  host1=$(( network + 1 ))
  host2=$(( network + 2 ))
  if (( ip_int == host1 )); then
    int_to_ipv4 "${host2}"
  elif (( ip_int == host2 )); then
    int_to_ipv4 "${host1}"
  else
    return 1
  fi
}

select_transit_interface() {
  local uplink_if=$1 selected="" index choice
  mapfile -t candidates < <(
    for path in /sys/class/net/*; do
      name=${path##*/}
      [[ ${name} == "lo" || ${name} == "${uplink_if}" ]] && continue
      [[ ${name} =~ ^(docker|veth|br-|virbr|warp|wg) ]] && continue
      printf '%s\n' "${name}"
    done
  )

  if [[ ${#candidates[@]} -eq 1 ]]; then
    printf '%s\n' "${candidates[0]}"
    return
  fi

  if [[ ${NON_INTERACTIVE} == "true" ]]; then
    die "Could not uniquely detect the transit interface. Use --transit-if."
  fi

  [[ ${#candidates[@]} -gt 0 ]] || die "No candidate transit interface was found."
  echo "Available transit interfaces:" >&2
  for index in "${!candidates[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${candidates[index]}" >&2
  done
  read -r -p "Select the transit interface number: " choice
  [[ ${choice} =~ ^[0-9]+$ ]] || die "Invalid selection."
  (( choice >= 1 && choice <= ${#candidates[@]} )) || die "Selection out of range."
  selected=${candidates[choice-1]}
  printf '%s\n' "${selected}"
}

default_route=$(ip -4 route show default | head -n1 || true)
[[ -n ${default_route} ]] || die "No IPv4 default route was found."
DEFAULT_UPLINK_IF=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<<"${default_route}")
DEFAULT_GATEWAY=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<<"${default_route}")
[[ -n ${DEFAULT_UPLINK_IF} ]] || die "Could not determine the default-route interface."
[[ -n ${DEFAULT_GATEWAY} ]] || die "Could not determine the default gateway."

if [[ -z ${UPLINK_IP} ]]; then
  suggested_uplink=$(ip -4 -o address show dev "${DEFAULT_UPLINK_IF}" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')
  prompt UPLINK_IP "Main/uplink IPv4 address" "${suggested_uplink}"
fi
UPLINK_IP=$(normalize_ipv4 "${UPLINK_IP}")
validate_ipv4 "${UPLINK_IP}" || die "Invalid uplink IPv4 address: ${UPLINK_IP}"
UPLINK_IF=$(interface_for_ipv4 "${UPLINK_IP}")
[[ -n ${UPLINK_IF} ]] || die "The uplink IP ${UPLINK_IP} is not configured on this host."
[[ ${UPLINK_IF} == "${DEFAULT_UPLINK_IF}" ]] \
  || die "${UPLINK_IP} is on ${UPLINK_IF}, but the default route uses ${DEFAULT_UPLINK_IF}."

if [[ -z ${TRANSIT_CIDR} ]]; then
  prompt TRANSIT_CIDR "Server transit IPv4/CIDR, for example 10.1.1.230/30"
fi
if [[ ${TRANSIT_CIDR} != */* ]]; then
  log "No prefix supplied for the transit IP; assuming /30."
  TRANSIT_CIDR="${TRANSIT_CIDR}/30"
fi
TRANSIT_IP=${TRANSIT_CIDR%%/*}
TRANSIT_PREFIX=${TRANSIT_CIDR##*/}
validate_ipv4 "${TRANSIT_IP}" || die "Invalid transit IPv4 address: ${TRANSIT_IP}"
[[ ${TRANSIT_PREFIX} =~ ^[0-9]+$ ]] && (( TRANSIT_PREFIX >= 1 && TRANSIT_PREFIX <= 32 )) \
  || die "Invalid transit prefix: ${TRANSIT_PREFIX}"

ASSIGNED_TRANSIT_IF=$(interface_for_ipv4 "${TRANSIT_IP}")
if [[ -n ${ASSIGNED_TRANSIT_IF} ]]; then
  TRANSIT_IF=${TRANSIT_IF:-${ASSIGNED_TRANSIT_IF}}
  [[ ${TRANSIT_IF} == "${ASSIGNED_TRANSIT_IF}" ]] \
    || die "${TRANSIT_IP} is already assigned to ${ASSIGNED_TRANSIT_IF}, not ${TRANSIT_IF}."
  MANAGE_TRANSIT_ADDRESS="false"
else
  if [[ -z ${TRANSIT_IF} ]]; then
    TRANSIT_IF=$(select_transit_interface "${UPLINK_IF}")
  fi
  ip link show "${TRANSIT_IF}" >/dev/null 2>&1 || die "Transit interface ${TRANSIT_IF} does not exist."
  MANAGE_TRANSIT_ADDRESS="true"
fi
[[ ${TRANSIT_IF} != "${UPLINK_IF}" ]] || die "Uplink and transit interfaces must be different."

if [[ -z ${TRUSTED_SOURCE_CIDR} ]]; then
  if peer=$(derive_peer_from_30 "${TRANSIT_CIDR}"); then
    TRUSTED_SOURCE_CIDR="${peer}/32"
  else
    prompt TRUSTED_SOURCE_CIDR "Upstream firewall source CIDR"
  fi
fi

if [[ ${ACCEPT_TOS} != "true" ]]; then
  if [[ ${NON_INTERACTIVE} == "true" ]]; then
    die "Use --accept-tos after reviewing Cloudflare terms."
  fi
  echo
  echo "This project uses the unofficial wgcf utility to register a consumer WARP profile."
  echo "Review Cloudflare terms before continuing."
  read -r -p "Have you reviewed and accepted those terms? [y/N] " answer
  [[ ${answer} =~ ^[Yy]$ ]] || die "Terms were not accepted."
  ACCEPT_TOS="true"
fi

cat <<SUMMARY

Detected deployment
-------------------
Uplink IP:             ${UPLINK_IP}
Uplink interface:      ${UPLINK_IF}
Uplink gateway:        ${DEFAULT_GATEWAY}
Transit IP/CIDR:       ${TRANSIT_CIDR}
Transit interface:     ${TRANSIT_IF}
Configure transit IP:  ${MANAGE_TRANSIT_ADDRESS}
Trusted source:        ${TRUSTED_SOURCE_CIDR}
WARP interface:        warp0
SUMMARY

if [[ ${NON_INTERACTIVE} != "true" ]]; then
  read -r -p "Install with these values? [y/N] " answer
  [[ ${answer} =~ ^[Yy]$ ]] || die "Installation cancelled."
fi

CONFIG_FILE=$(mktemp)
trap 'rm -f "${CONFIG_FILE}"' EXIT
chmod 600 "${CONFIG_FILE}"
cat >"${CONFIG_FILE}" <<CONFIG
TRANSIT_IF="${TRANSIT_IF}"
MANAGE_TRANSIT_ADDRESS="${MANAGE_TRANSIT_ADDRESS}"
TRANSIT_CIDR="${TRANSIT_CIDR}"
TRUSTED_SOURCE_CIDR="${TRUSTED_SOURCE_CIDR}"
UPLINK_IF="${UPLINK_IF}"
UPLINK_GATEWAY="${DEFAULT_GATEWAY}"
WARP_IF="warp0"
WARP_MTU="1280"
PERSISTENT_KEEPALIVE="25"
TCP_MSS="1240"
ROUTING_TABLE_ID="100"
ROUTING_TABLE_NAME="warp_gateway"
SOURCE_RULE_PRIORITY="100"
INGRESS_RULE_PRIORITY="110"
WGCF_VERSION="2.2.31"
ACCEPT_CLOUDFLARE_TOS="yes"
EXISTING_WARP_PROFILE=""
HEALTHCHECK_URL="https://www.cloudflare.com/cdn-cgi/trace"
HEALTHCHECK_INTERVAL="60"
HEALTHCHECK_TIMEOUT="15"
AUTO_RECOVER="true"
ENABLE_IPV6_TRANSIT="false"
CONFIG

install_args=(--config "${CONFIG_FILE}")
if [[ -n ${PROFILE} ]]; then
  install_args+=(--profile "${PROFILE}")
fi

"${INSTALLER}" "${install_args[@]}"

cat <<DONE

Setup completed.

Upstream firewall next hop: ${TRANSIT_IP}
Expected firewall source:   ${TRUSTED_SOURCE_CIDR}

Check status with:
  sudo warp-gateway status
DONE
