#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MODE=auto
ASSUME_YES=false
DRY_RUN=false
SKIP_TESTS=false
BACKUP_ROOT=/var/backups/warp-egress-gateway
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/upgrade-${TIMESTAMP}"

usage() {
  cat <<'USAGE'
Safe in-place upgrader for WARP Egress Gateway.

Usage:
  sudo bash upgrade.sh [options]

Options:
  --mode MODE        auto, native, or docker. Default: auto.
  --yes              Do not prompt before the maintenance window.
  --dry-run          Detect mode, version, source, and prerequisites only.
  --skip-tests       Skip source-tree validation tests.
  -h, --help         Show this help.

The upgrader:
  * detects Native or Docker mode,
  * creates a root-only backup,
  * preserves the existing WARP identity and deployment settings,
  * keeps the fail-closed guard active during the maintenance window,
  * validates the upgraded path,
  * rolls back automatically when post-upgrade validation fails.
USAGE
}

log() { printf '[upgrade] %s\n' "$*"; }
warn() { printf '[upgrade] WARNING: %s\n' "$*" >&2; }
die() { printf '[upgrade] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE=${2:?Missing value after --mode}; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-tests) SKIP_TESTS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run as root."
[[ ${MODE} =~ ^(auto|native|docker)$ ]] || die "Invalid mode: ${MODE}"
[[ -r ${ROOT_DIR}/VERSION ]] || die "VERSION file is missing from the release source."
TARGET_VERSION=$(<"${ROOT_DIR}/VERSION")

native_detected=false
docker_detected=false
if [[ -r /etc/warp-egress-gateway/warp-gateway.env ]] && { [[ -x /usr/local/sbin/warp-gateway ]] || [[ -f /etc/systemd/system/warp-gateway.service ]]; }; then
  native_detected=true
fi
[[ -r /etc/warp-egress-gateway-docker/guard.env ]] && docker_detected=true
if command -v docker >/dev/null 2>&1 && docker inspect warp-egress-gateway >/dev/null 2>&1; then
  docker_detected=true
fi

if [[ ${MODE} == auto ]]; then
  if [[ ${native_detected} == true && ${docker_detected} == true ]]; then
    die "Both Native and Docker installations were detected. Select --mode explicitly after reviewing the host."
  elif [[ ${native_detected} == true ]]; then
    MODE=native
  elif [[ ${docker_detected} == true ]]; then
    MODE=docker
  else
    die "No supported existing installation was detected. Use setup.sh for a new installation."
  fi
fi

case ${MODE} in
  native) [[ ${native_detected} == true ]] || die "Native installation was not detected." ;;
  docker) [[ ${docker_detected} == true ]] || die "Docker installation was not detected." ;;
esac

run_source_tests() {
  [[ ${SKIP_TESTS} == true ]] && { warn "Source validation tests were skipped by request."; return; }
  local tests=(
    tests/syntax.sh
    tests/security-order.sh
    tests/monitoring.sh
    tests/profile-ipv4.sh
    tests/upgrade.sh
    tests/docs.sh
    tests/release-metadata.sh
  ) test
  for test in "${tests[@]}"; do
    [[ -r ${ROOT_DIR}/${test} ]] || die "Required validation test missing: ${test}"
    bash "${ROOT_DIR}/${test}"
  done
}

installed_version() {
  local file=$1
  if [[ -r ${file} ]]; then cat "${file}"; else printf 'legacy/unknown\n'; fi
}

copy_rootfs_path() {
  local path=$1
  [[ -e ${path} || -L ${path} ]] || return 0
  cp -a --parents "${path}" "${BACKUP_DIR}/rootfs"
}

write_manifest() {
  local current_version=$1
  cat >"${BACKUP_DIR}/manifest.env" <<MANIFEST
BACKUP_FORMAT="1"
MODE="${MODE}"
CURRENT_VERSION="${current_version}"
TARGET_VERSION="${TARGET_VERSION}"
CREATED_AT="$(date --iso-8601=seconds)"
HOSTNAME="$(hostname)"
MANIFEST
  chmod 600 "${BACKUP_DIR}/manifest.env"
}

confirm_upgrade() {
  [[ ${ASSUME_YES} == true ]] && return
  echo
  echo "Upgrade plan"
  echo "------------"
  echo "Mode:            ${MODE}"
  echo "Target version:  ${TARGET_VERSION}"
  echo "Backup:          ${BACKUP_DIR}"
  echo "Expected impact: brief WARP-path interruption; management uplink remains direct."
  echo "Fail-closed firewall/host guard remains active during the maintenance window."
  echo
  read -r -p "Continue with the upgrade? [y/N] " answer
  [[ ${answer} =~ ^[Yy]$ ]] || die "Upgrade cancelled."
}

rollback_native() {
  warn "Post-upgrade validation failed. Restoring Native backup ${BACKUP_DIR}."
  systemctl stop warp-gateway-healthcheck.timer warp-monitor.timer 2>/dev/null || true
  systemctl stop warp-gateway.service 2>/dev/null || true
  if [[ -r /etc/warp-egress-gateway/warp-gateway.env ]]; then
    # shellcheck disable=SC1091
    source /etc/warp-egress-gateway/warp-gateway.env
    systemctl stop "wg-quick@${WARP_IF:-warp0}.service" 2>/dev/null || true
  fi
  [[ -d ${BACKUP_DIR}/rootfs ]] || die "Native rollback data is missing. Manual recovery required."
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
  warn "Rollback completed. Verify the gateway before restoring upstream traffic."
}

upgrade_native() {
  local config=/etc/warp-egress-gateway/warp-gateway.env current_version temp_config profile
  current_version=$(installed_version /etc/warp-egress-gateway/VERSION)
  # shellcheck disable=SC1090
  source "${config}"
  profile="/etc/wireguard/${WARP_IF:-warp0}.conf"
  [[ -r ${profile} ]] || die "Existing WARP profile not found: ${profile}"

  install -d -m 700 "${BACKUP_DIR}/rootfs"
  write_manifest "${current_version}"
  for path in \
    /etc/warp-egress-gateway \
    "${profile}" \
    /usr/local/lib/warp-egress-gateway \
    /usr/local/sbin/warp-gateway \
    /usr/local/sbin/warp-gateway-upgrade \
    /usr/local/sbin/warp-gateway-rollback \
    /etc/systemd/system/warp-gateway-firewall.service \
    /etc/systemd/system/warp-gateway.service \
    /etc/systemd/system/warp-gateway-healthcheck.service \
    /etc/systemd/system/warp-gateway-healthcheck.timer \
    /etc/systemd/system/warp-monitor.service \
    /etc/systemd/system/warp-monitor.timer \
    "/etc/systemd/system/wg-quick@${WARP_IF:-warp0}.service.d" \
    /etc/sysctl.d/99-warp-egress-gateway.conf \
    /etc/iproute2/rt_tables.d/warp-egress-gateway.conf \
    /etc/systemd/journald.conf.d/10-warp-egress-gateway-retention.conf; do
    copy_rootfs_path "${path}"
  done

  temp_config="${BACKUP_DIR}/upgrade-config.env"
  cp -a "${config}" "${temp_config}"
  if grep -q '^MANAGE_TRANSIT_ADDRESS=' "${temp_config}"; then
    sed -i 's/^MANAGE_TRANSIT_ADDRESS=.*/MANAGE_TRANSIT_ADDRESS="false"/' "${temp_config}"
  else
    printf '\nMANAGE_TRANSIT_ADDRESS="false"\n' >>"${temp_config}"
  fi
  chmod 600 "${temp_config}"

  log "Backup created: ${BACKUP_DIR}"
  log "Pausing periodic health actions; fail-closed firewall remains active."
  systemctl stop warp-gateway-healthcheck.timer warp-monitor.timer 2>/dev/null || true

  if ! bash "${ROOT_DIR}/native/install.sh" --config "${temp_config}" --profile "${profile}"; then
    rollback_native
    die "Native upgrade failed and was rolled back."
  fi

  if ! {
    printf '%s\n' "${TARGET_VERSION}" >/etc/warp-egress-gateway/VERSION &&
    chmod 644 /etc/warp-egress-gateway/VERSION &&
    /usr/local/sbin/warp-gateway health &&
    /usr/local/sbin/warp-gateway monitor;
  }; then
    rollback_native
    die "Native post-upgrade validation failed and was rolled back."
  fi

  log "Native upgrade succeeded: ${current_version} -> ${TARGET_VERSION}."
}

docker_workdir() {
  docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' warp-egress-gateway 2>/dev/null || true
}

wait_docker_healthy() {
  local state i
  for i in $(seq 1 45); do
    state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' warp-egress-gateway 2>/dev/null || true)
    [[ ${state} == healthy ]] && return 0
    [[ ${state} == exited || ${state} == dead ]] && return 1
    sleep 2
  done
  return 1
}

rollback_docker() {
  local project_root previous_root
  project_root=$(awk -F= '$1=="DOCKER_PROJECT_ROOT"{gsub(/^"|"$/, "", $2); print $2}' "${BACKUP_DIR}/manifest.env")
  previous_root=$(awk -F= '$1=="DOCKER_PREVIOUS_ROOT"{gsub(/^"|"$/, "", $2); print $2}' "${BACKUP_DIR}/manifest.env")
  warn "Post-upgrade validation failed. Restoring Docker project ${previous_root}."
  if [[ -d ${project_root}/docker ]]; then
    (cd "${project_root}/docker" && docker compose down) || true
  fi
  rm -rf "${project_root}.failed-${TIMESTAMP}"
  [[ -d ${project_root} ]] && mv "${project_root}" "${project_root}.failed-${TIMESTAMP}"
  [[ -d ${previous_root} ]] || die "Previous Docker project is missing. Manual recovery required."
  mv "${previous_root}" "${project_root}"
  cp -a "${BACKUP_DIR}/rootfs/." /
  [[ -e ${BACKUP_DIR}/rootfs/usr/local/sbin/warp-gateway-upgrade ]] || rm -f /usr/local/sbin/warp-gateway-upgrade
  [[ -e ${BACKUP_DIR}/rootfs/usr/local/sbin/warp-gateway-rollback ]] || rm -f /usr/local/sbin/warp-gateway-rollback
  [[ -e ${BACKUP_DIR}/rootfs/etc/warp-egress-gateway-docker/VERSION ]] || rm -f /etc/warp-egress-gateway-docker/VERSION
  systemctl daemon-reload
  systemctl restart warp-egress-docker-guard.service
  (cd "${project_root}/docker" && docker compose up -d)
  warn "Docker rollback completed. Verify the gateway before restoring upstream traffic."
}

upgrade_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is required for Docker-mode upgrade."
  local workdir project_root parent base stage previous current_version
  workdir=$(docker_workdir)
  [[ -n ${workdir} && -d ${workdir} ]] || die "Could not determine the current Docker Compose working directory."
  project_root=$(cd "${workdir}/.." && pwd)
  parent=$(dirname "${project_root}")
  base=$(basename "${project_root}")
  stage="${parent}/.${base}.upgrade-${TIMESTAMP}"
  previous="${parent}/${base}.preupgrade-${TIMESTAMP}"
  current_version=$(installed_version /etc/warp-egress-gateway-docker/VERSION)

  install -d -m 700 "${BACKUP_DIR}/rootfs"
  write_manifest "${current_version}"
  cat >>"${BACKUP_DIR}/manifest.env" <<MANIFEST
DOCKER_PROJECT_ROOT="${project_root}"
DOCKER_PREVIOUS_ROOT="${previous}"
MANIFEST
  for path in \
    /etc/warp-egress-gateway-docker \
    /usr/local/sbin/warp-egress-docker-guard-apply \
    /usr/local/sbin/warp-egress-docker-guard-remove \
    /usr/local/sbin/warp-gateway-upgrade \
    /usr/local/sbin/warp-gateway-rollback \
    /etc/systemd/system/warp-egress-docker-guard.service \
    /etc/systemd/journald.conf.d/10-warp-egress-gateway-retention.conf; do
    copy_rootfs_path "${path}"
  done

  rm -rf "${stage}" "${previous}"
  mkdir -p "${stage}"
  cp -a "${ROOT_DIR}/." "${stage}/"
  install -d -m 700 "${stage}/docker/state" "${stage}/docker/generated"
  [[ -d ${workdir}/state ]] && cp -a "${workdir}/state/." "${stage}/docker/state/"
  [[ -d ${workdir}/generated ]] && cp -a "${workdir}/generated/." "${stage}/docker/generated/"
  [[ -f ${workdir}/.env ]] && cp -a "${workdir}/.env" "${stage}/docker/.env"
  if [[ -f ${stage}/docker/.env ]]; then
    if grep -q '^IMAGE_TAG=' "${stage}/docker/.env"; then
      sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TARGET_VERSION}/" "${stage}/docker/.env"
    else
      printf 'IMAGE_TAG=%s\n' "${TARGET_VERSION}" >>"${stage}/docker/.env"
    fi
  else
    cp "${stage}/docker/.env.example" "${stage}/docker/.env"
  fi

  log "Backup created: ${BACKUP_DIR}"
  log "Staging Docker release at ${stage}. Host kill switch remains active."

  docker_cutover() {
    (cd "${workdir}" && docker compose down) || return 1
    mv "${project_root}" "${previous}" || return 1
    mv "${stage}" "${project_root}" || return 1

    install -d -m 700 /etc/warp-egress-gateway-docker || return 1
    install -m 0755 "${project_root}/docker/host/guard-apply.sh" /usr/local/sbin/warp-egress-docker-guard-apply || return 1
    install -m 0755 "${project_root}/docker/host/guard-remove.sh" /usr/local/sbin/warp-egress-docker-guard-remove || return 1
    install -m 0644 "${project_root}/docker/host/warp-egress-docker-guard.service" /etc/systemd/system/ || return 1
    install -m 0755 "${project_root}/shared/upgrade/remote-upgrade.sh" /usr/local/sbin/warp-gateway-upgrade || return 1
    install -m 0755 "${project_root}/rollback.sh" /usr/local/sbin/warp-gateway-rollback || return 1
    printf '%s\n' "${TARGET_VERSION}" >/etc/warp-egress-gateway-docker/VERSION || return 1
    chmod 644 /etc/warp-egress-gateway-docker/VERSION || return 1
    systemctl daemon-reload || return 1
    systemctl restart warp-egress-docker-guard.service || return 1
    (cd "${project_root}/docker" && docker compose build && docker compose up -d) || return 1
    wait_docker_healthy || return 1
    (cd "${project_root}/docker" && docker compose exec -T gateway /app/bin/healthcheck.sh) || return 1
  }

  if ! docker_cutover; then
    rollback_docker
    die "Docker upgrade failed validation and was rolled back."
  fi
  log "Docker upgrade succeeded: ${current_version} -> ${TARGET_VERSION}."
  log "Previous project tree retained at ${previous} for manual rollback/audit."
}

log "Detected mode: ${MODE}. Target version: ${TARGET_VERSION}."
run_source_tests

if [[ ${DRY_RUN} == true ]]; then
  log "Dry run completed successfully. No host changes were made."
  exit 0
fi

install -d -m 700 "${BACKUP_ROOT}"
confirm_upgrade

case ${MODE} in
  native) upgrade_native ;;
  docker) upgrade_docker ;;
esac

log "Upgrade complete. Backup retained at ${BACKUP_DIR}."
