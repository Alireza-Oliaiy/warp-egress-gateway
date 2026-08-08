#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_SOURCE="${REPO_DIR}/config/warp-gateway.env"

usage() {
  cat <<USAGE
Usage: sudo bash install.sh [--config PATH] [--profile PATH]

  --config PATH   Deployment configuration file.
  --profile PATH  Existing WireGuard WARP profile. Overrides EXISTING_WARP_PROFILE.
USAGE
}

PROFILE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_SOURCE=${2:?Missing path after --config}; shift 2 ;;
    --profile) PROFILE_OVERRIDE=${2:?Missing path after --profile}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -r ${CONFIG_SOURCE} ]] || {
  echo "Configuration not found: ${CONFIG_SOURCE}" >&2
  echo "Copy config/warp-gateway.env.example to config/warp-gateway.env and edit it." >&2
  exit 1
}

PROJECT_NAME="warp-egress-gateway"
CONFIG_DIR="/etc/${PROJECT_NAME}"
CONFIG_FILE="${CONFIG_DIR}/warp-gateway.env"
STATE_DIR="/var/lib/${PROJECT_NAME}"
LIB_DIR="/usr/local/lib/${PROJECT_NAME}"
BACKUP_DIR="/var/backups/${PROJECT_NAME}/$(date +%Y%m%d-%H%M%S)"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

install -d -m 700 "${CONFIG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
install -m 600 "${CONFIG_SOURCE}" "${CONFIG_FILE}"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

if [[ -n ${PROFILE_OVERRIDE} ]]; then
  EXISTING_WARP_PROFILE=${PROFILE_OVERRIDE}
fi

: "${TRANSIT_IF:?Required}"
: "${TRANSIT_CIDR:?Required}"
: "${TRUSTED_SOURCE_CIDR:?Required}"
: "${UPLINK_IF:?Required}"
: "${WARP_IF:?Required}"
: "${WGCF_VERSION:?Required}"

log "Installing operating-system dependencies."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates conntrack curl dnsutils git iproute2 jq nftables python3 \
  tcpdump wireguard-tools

if [[ ${MANAGE_TRANSIT_ADDRESS:-false} == "true" ]]; then
  command -v netplan >/dev/null || die "netplan is required when MANAGE_TRANSIT_ADDRESS=true."
  log "Configuring ${TRANSIT_CIDR} on ${TRANSIT_IF}."
  cp -a /etc/netplan "${BACKUP_DIR}/netplan"
  cat >"/etc/netplan/60-${PROJECT_NAME}-transit.yaml" <<NETPLAN
network:
  version: 2
  ethernets:
    ${TRANSIT_IF}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${TRANSIT_CIDR}
      optional: true
NETPLAN
  chmod 600 "/etc/netplan/60-${PROJECT_NAME}-transit.yaml"
  netplan generate
  netplan apply
fi

log "Configuring persistent seven-day system journal retention."
install -d -m 755 /etc/systemd/journald.conf.d
mkdir -p /var/log/journal
install -m 644 "${REPO_DIR}/../shared/journald/10-warp-egress-gateway-retention.conf" \
  /etc/systemd/journald.conf.d/10-warp-egress-gateway-retention.conf
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald

log "Installing project scripts."
install -d -m 755 "${LIB_DIR}"
install -m 755 "${REPO_DIR}"/scripts/*.sh "${LIB_DIR}/"
install -m 755 "${REPO_DIR}/scripts/warp-gateway" /usr/local/sbin/warp-gateway
install -m 755 "${REPO_DIR}/../shared/upgrade/remote-upgrade.sh" /usr/local/sbin/warp-gateway-upgrade
install -m 755 "${REPO_DIR}/../rollback.sh" /usr/local/sbin/warp-gateway-rollback

bash "${LIB_DIR}/preflight.sh"

install_wgcf() {
  local version=${WGCF_VERSION}
  local asset="wgcf_${version}_linux_amd64"
  local workdir
  workdir=$(mktemp -d)

  case "$(dpkg --print-architecture)" in
    amd64) asset="wgcf_${version}_linux_amd64" ;;
    arm64) asset="wgcf_${version}_linux_arm64" ;;
    *) die "Unsupported architecture for automatic wgcf installation: $(dpkg --print-architecture)" ;;
  esac

  log "Downloading wgcf ${version}."
  curl -fL "https://github.com/ViRb3/wgcf/releases/download/v${version}/${asset}" -o "${workdir}/${asset}"
  curl -fL "https://github.com/ViRb3/wgcf/releases/download/v${version}/checksums.txt" -o "${workdir}/checksums.txt"
  (
    cd "${workdir}"
    grep -F "  ${asset}" checksums.txt > selected-checksum.txt \
      || die "Checksum for ${asset} not found."
    sha256sum -c selected-checksum.txt
  )
  install -m 0755 "${workdir}/${asset}" /usr/local/bin/wgcf
  rm -rf "${workdir}"
}

PROFILE_SOURCE=${EXISTING_WARP_PROFILE:-}
if [[ -z ${PROFILE_SOURCE} ]]; then
  install_wgcf
  pushd "${STATE_DIR}" >/dev/null
  if [[ ! -f wgcf-account.toml ]]; then
    if [[ ${ACCEPT_CLOUDFLARE_TOS:-no} != "yes" ]]; then
      if [[ -t 0 ]]; then
        echo "wgcf is unofficial and registration requires acceptance of Cloudflare terms."
        read -r -p "Have you reviewed and accepted those terms? [y/N] " answer
        [[ ${answer} =~ ^[Yy]$ ]] || die "Terms were not accepted."
      else
        die "Set ACCEPT_CLOUDFLARE_TOS=yes for unattended registration."
      fi
    fi
    printf 'y\n' | wgcf register
  else
    log "Reusing existing WARP account in ${STATE_DIR}."
  fi
  wgcf generate
  PROFILE_SOURCE="${STATE_DIR}/wgcf-profile.conf"
  popd >/dev/null
fi

[[ -r ${PROFILE_SOURCE} ]] || die "WARP profile not readable: ${PROFILE_SOURCE}"

grep -q '^\[Interface\]' "${PROFILE_SOURCE}" || die "Invalid profile: missing [Interface]."
grep -q '^\[Peer\]' "${PROFILE_SOURCE}" || die "Invalid profile: missing [Peer]."
grep -q '^Address[[:space:]]*=.*[0-9]' "${PROFILE_SOURCE}" || die "Invalid profile: missing address."
grep -q '^Endpoint[[:space:]]*=' "${PROFILE_SOURCE}" || die "Invalid profile: missing endpoint."

install -d -m 700 /etc/wireguard
if [[ -f /etc/wireguard/${WARP_IF}.conf ]]; then
  cp -a "/etc/wireguard/${WARP_IF}.conf" "${BACKUP_DIR}/${WARP_IF}.conf"
fi

tmp_profile=$(mktemp)
trap 'rm -f "${tmp_profile}"' EXIT
cp "${PROFILE_SOURCE}" "${tmp_profile}"
log "Normalizing WARP profile for the IPv4-only gateway path."
bash "${REPO_DIR}/../shared/profile/normalize-warp-profile-ipv4.sh" "${tmp_profile}"
sed -i -E \
  -e '/^(DNS|MTU|Table|PersistentKeepalive)[[:space:]]*=/d' \
  "${tmp_profile}"
sed -i "/^\[Peer\]/i MTU = ${WARP_MTU:-1280}\nTable = off" "${tmp_profile}"
sed -i "/^Endpoint[[:space:]]*=/a PersistentKeepalive = ${PERSISTENT_KEEPALIVE:-25}" "${tmp_profile}"
install -m 600 "${tmp_profile}" "/etc/wireguard/${WARP_IF}.conf"

log "Installing persistent kernel settings."
cat > /etc/sysctl.d/99-warp-egress-gateway.conf <<SYSCTL
net.ipv4.ip_forward=0
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL
sysctl --system >/dev/null

log "Registering policy-routing table name."
install -d -m 755 /etc/iproute2/rt_tables.d
cat > /etc/iproute2/rt_tables.d/warp-egress-gateway.conf <<RTTABLE
${ROUTING_TABLE_ID} ${ROUTING_TABLE_NAME:-warp_gateway}
RTTABLE

log "Installing systemd units."
install -m 644 "${REPO_DIR}/systemd/warp-gateway-firewall.service" /etc/systemd/system/
sed "s/wg-quick@warp0.service/wg-quick@${WARP_IF}.service/g" \
  "${REPO_DIR}/systemd/warp-gateway.service" \
  > /etc/systemd/system/warp-gateway.service
install -m 644 "${REPO_DIR}/systemd/warp-gateway-healthcheck.service" /etc/systemd/system/
sed "s/OnUnitActiveSec=60s/OnUnitActiveSec=${HEALTHCHECK_INTERVAL:-60}s/" \
  "${REPO_DIR}/systemd/warp-gateway-healthcheck.timer" \
  > /etc/systemd/system/warp-gateway-healthcheck.timer
install -m 644 "${REPO_DIR}/systemd/warp-monitor.service" /etc/systemd/system/
sed "s/OnUnitActiveSec=60s/OnUnitActiveSec=${MONITOR_INTERVAL:-60}s/" \
  "${REPO_DIR}/systemd/warp-monitor.timer" \
  > /etc/systemd/system/warp-monitor.timer
install -d -m 755 "/etc/systemd/system/wg-quick@${WARP_IF}.service.d"
install -m 644 "${REPO_DIR}/systemd/warp-gateway.conf" \
  "/etc/systemd/system/wg-quick@${WARP_IF}.service.d/10-network-online.conf"

systemctl daemon-reload
systemctl enable warp-gateway-firewall.service
systemctl enable "wg-quick@${WARP_IF}.service"
systemctl enable warp-gateway.service
systemctl enable warp-gateway-healthcheck.timer
systemctl enable warp-monitor.timer

log "Starting firewall first, then WARP and policy routing."
systemctl restart warp-gateway-firewall.service
systemctl restart "wg-quick@${WARP_IF}.service"
systemctl restart warp-gateway.service
systemctl restart warp-gateway-healthcheck.timer
systemctl restart warp-monitor.timer
systemctl start warp-monitor.service
printf '%s\n' "$(<"${REPO_DIR}/../VERSION")" >"${CONFIG_DIR}/VERSION"
chmod 644 "${CONFIG_DIR}/VERSION"

log "Installation complete."
/usr/local/sbin/warp-gateway status
