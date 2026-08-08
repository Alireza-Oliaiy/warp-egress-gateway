#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR=""
ASSUME_YES=false

usage() {
  cat <<'USAGE'
Rollback a WARP Egress Gateway upgrade from a backup created by upgrade.sh.

Usage:
  sudo bash rollback.sh --backup /var/backups/warp-egress-gateway/upgrade-YYYYMMDD-HHMMSS [--yes]

Options:
  --backup PATH   Required upgrade backup directory.
  --yes           Do not prompt for confirmation.
  -h, --help      Show this help.
USAGE
}

die() { printf '[rollback] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[rollback] %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) BACKUP_DIR=${2:?Missing value after --backup}; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run as root."
[[ -n ${BACKUP_DIR} && -d ${BACKUP_DIR} ]] || die "A valid --backup directory is required."
[[ -r ${BACKUP_DIR}/manifest.env ]] || die "Backup manifest is missing."
# shellcheck disable=SC1090
source "${BACKUP_DIR}/manifest.env"
[[ ${BACKUP_FORMAT:-} == "1" ]] || die "Unsupported backup format."

if [[ ${ASSUME_YES} != true ]]; then
  echo "Rollback ${MODE} gateway from target ${TARGET_VERSION} to ${CURRENT_VERSION}."
  read -r -p "Continue? [y/N] " answer
  [[ ${answer} =~ ^[Yy]$ ]] || die "Rollback cancelled."
fi

case ${MODE} in
  native)
    [[ -d ${BACKUP_DIR}/rootfs ]] || die "Native rootfs backup is missing."
    systemctl stop warp-gateway-healthcheck.timer warp-monitor.timer 2>/dev/null || true
    systemctl stop warp-gateway.service 2>/dev/null || true
    if [[ -r /etc/warp-egress-gateway/warp-gateway.env ]]; then
      # shellcheck disable=SC1091
      source /etc/warp-egress-gateway/warp-gateway.env
      systemctl stop "wg-quick@${WARP_IF:-warp0}.service" 2>/dev/null || true
    fi
    cp -a "${BACKUP_DIR}/rootfs/." /
    [[ -e ${BACKUP_DIR}/rootfs/usr/local/sbin/warp-gateway-upgrade ]] || rm -f /usr/local/sbin/warp-gateway-upgrade
    [[ -e ${BACKUP_DIR}/rootfs/usr/local/sbin/warp-gateway-rollback ]] || rm -f /usr/local/sbin/warp-gateway-rollback
    [[ -e ${BACKUP_DIR}/rootfs/etc/warp-egress-gateway/VERSION ]] || rm -f /etc/warp-egress-gateway/VERSION
    systemctl daemon-reload
    # shellcheck disable=SC1091
    source /etc/warp-egress-gateway/warp-gateway.env
    systemctl restart warp-gateway-firewall.service
    systemctl restart "wg-quick@${WARP_IF:-warp0}.service"
    systemctl restart warp-gateway.service
    systemctl restart warp-gateway-healthcheck.timer 2>/dev/null || true
    systemctl restart warp-monitor.timer 2>/dev/null || true
    ;;
  docker)
    [[ -n ${DOCKER_PROJECT_ROOT:-} && -n ${DOCKER_PREVIOUS_ROOT:-} ]] || die "Docker paths are missing from the manifest."
    [[ -d ${DOCKER_PREVIOUS_ROOT} ]] || die "Previous Docker project not found: ${DOCKER_PREVIOUS_ROOT}"
    if [[ -d ${DOCKER_PROJECT_ROOT}/docker ]]; then
      (cd "${DOCKER_PROJECT_ROOT}/docker" && docker compose down) || true
    fi
    failed="${DOCKER_PROJECT_ROOT}.rollback-replaced-$(date +%Y%m%d-%H%M%S)"
    [[ -d ${DOCKER_PROJECT_ROOT} ]] && mv "${DOCKER_PROJECT_ROOT}" "${failed}"
    mv "${DOCKER_PREVIOUS_ROOT}" "${DOCKER_PROJECT_ROOT}"
    [[ -d ${BACKUP_DIR}/rootfs ]] && cp -a "${BACKUP_DIR}/rootfs/." /
    [[ -e ${BACKUP_DIR}/rootfs/usr/local/sbin/warp-gateway-upgrade ]] || rm -f /usr/local/sbin/warp-gateway-upgrade
    [[ -e ${BACKUP_DIR}/rootfs/usr/local/sbin/warp-gateway-rollback ]] || rm -f /usr/local/sbin/warp-gateway-rollback
    [[ -e ${BACKUP_DIR}/rootfs/etc/warp-egress-gateway-docker/VERSION ]] || rm -f /etc/warp-egress-gateway-docker/VERSION
    systemctl daemon-reload
    systemctl restart warp-egress-docker-guard.service
    (cd "${DOCKER_PROJECT_ROOT}/docker" && docker compose up -d)
    ;;
  *) die "Unsupported backup mode: ${MODE}" ;;
esac

log "Rollback completed. Validate the gateway before restoring full upstream traffic."
