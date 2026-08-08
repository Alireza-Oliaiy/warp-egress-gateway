#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

required=(
  upgrade.sh
  rollback.sh
  shared/upgrade/remote-upgrade.sh
  docs/upgrade.md
  docs/rollback.md
  docs/operations.md
  docs/release-process.md
)
for path in "${required[@]}"; do
  [[ -f ${ROOT}/${path} ]] || { echo "Missing upgrade/lifecycle file: ${path}" >&2; exit 1; }
done

for script in upgrade.sh rollback.sh shared/upgrade/remote-upgrade.sh; do
  bash -n "${ROOT}/${script}"
done

REMOTE_UPGRADE="${ROOT}/shared/upgrade/remote-upgrade.sh"
grep -q 'validate_checked_out_version' "${REMOTE_UPGRADE}" || {
  echo "Bootstrap upgrader must validate the checked-out VERSION before host changes" >&2; exit 1;
}
grep -q 'Requested tag' "${REMOTE_UPGRADE}" || {
  echo "Bootstrap upgrader must reject a tag whose VERSION does not match" >&2; exit 1;
}
grep -q 'missing VERSION' "${REMOTE_UPGRADE}" || {
  echo "Bootstrap upgrader must reject a missing downloaded VERSION" >&2; exit 1;
}
grep -q 'Malformed VERSION' "${REMOTE_UPGRADE}" || {
  echo "Bootstrap upgrader must reject a malformed downloaded VERSION" >&2; exit 1;
}

unit_dir=$(mktemp -d)
trap 'rm -rf "${unit_dir}"' EXIT
unit_runner="${unit_dir}/validate-version.sh"
cat >"${unit_runner}" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
RUNNER
awk '
  /^validate_checked_out_version\(\)/ { capture=1 }
  /^resolve_requested_ref / { capture=0 }
  capture { print }
' "${REMOTE_UPGRADE}" >>"${unit_runner}"
cat >>"${unit_runner}" <<'RUNNER'
REF=$1
validate_checked_out_version "$2"
RUNNER
chmod +x "${unit_runner}"

printf '0.4.0\n' >"${unit_dir}/valid"
printf 'not-a-version\n' >"${unit_dir}/invalid"
printf '0.4.1\n' >"${unit_dir}/mismatch"
"${unit_runner}" v0.4.0 "${unit_dir}/valid"
! "${unit_runner}" v0.4.0 "${unit_dir}/missing" >/dev/null 2>&1 || {
  echo "Bootstrap version validator accepted a missing VERSION." >&2; exit 1;
}
! "${unit_runner}" v0.4.0 "${unit_dir}/invalid" >/dev/null 2>&1 || {
  echo "Bootstrap version validator accepted a malformed VERSION." >&2; exit 1;
}
! "${unit_runner}" v0.4.0 "${unit_dir}/mismatch" >/dev/null 2>&1 || {
  echo "Bootstrap version validator accepted a mismatched tag/VERSION." >&2; exit 1;
}

grep -q 'warp-gateway-firewall.service' "${ROOT}/upgrade.sh" || {
  echo "Native upgrade must preserve/restart the independent firewall service" >&2; exit 1;
}
grep -q 'warp-egress-docker-guard.service' "${ROOT}/upgrade.sh" || {
  echo "Docker upgrade must preserve/restart the independent host guard" >&2; exit 1;
}
grep -Fq 'MANAGE_TRANSIT_ADDRESS="false"' "${ROOT}/upgrade.sh" || {
  echo "Native upgrade must avoid reapplying the transit address" >&2; exit 1;
}
grep -q -- '--profile "${profile}"' "${ROOT}/upgrade.sh" || {
  echo "Native upgrade must reuse the existing WARP profile" >&2; exit 1;
}
grep -q 'rollback_native' "${ROOT}/upgrade.sh" || {
  echo "Native upgrade must have automatic rollback" >&2; exit 1;
}
grep -q 'rollback_docker' "${ROOT}/upgrade.sh" || {
  echo "Docker upgrade must have automatic rollback" >&2; exit 1;
}
grep -q 'upgrade)' "${ROOT}/native/scripts/warp-gateway" || {
  echo "Native CLI must expose an upgrade command" >&2; exit 1;
}
grep -q 'warp-gateway-upgrade' "${ROOT}/native/install.sh" || {
  echo "Native installer must install the remote upgrade helper" >&2; exit 1;
}
grep -q 'warp-gateway-upgrade' "${ROOT}/docker/setup.sh" || {
  echo "Docker setup must install the remote upgrade helper" >&2; exit 1;
}

# Exercise the same backup-layout helper used by both Native and Docker upgrades.
# This reproduces the production failure where install created an implicit
# timestamped parent with the umask-derived mode instead of mode 0700.
grep -q '^create_backup_layout()' "${ROOT}/upgrade.sh" || {
  echo "Upgrade must explicitly create the timestamped backup directory." >&2; exit 1;
}
backup_test_dir=$(mktemp -d)
trap 'rm -rf "${unit_dir}" "${backup_test_dir}"' EXIT
backup_helper="${backup_test_dir}/backup-helper.sh"
awk '
  /^create_backup_layout\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "${ROOT}/upgrade.sh" >"${backup_helper}"
manifest_helper="${backup_test_dir}/manifest-helper.sh"
awk '
  /^write_manifest\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "${ROOT}/upgrade.sh" >"${manifest_helper}"

if install -d -m 700 "${backup_test_dir}/mode-probe" 2>/dev/null; then
  BACKUP_ROOT="${backup_test_dir}/backups"
  BACKUP_DIR="${BACKUP_ROOT}/upgrade-qualification"
  # shellcheck disable=SC1090
  source "${backup_helper}"
  create_backup_layout
  # shellcheck disable=SC2034 # consumed by the extracted write_manifest helper
  MODE=native
  # shellcheck disable=SC2034 # consumed by the extracted write_manifest helper
  TARGET_VERSION=0.4.0
  # shellcheck disable=SC1090
  source "${manifest_helper}"
  write_manifest 0.3.3
  printf 'MANAGE_TRANSIT_ADDRESS="false"\n' >"${backup_test_dir}/source-config.env"
  cp -a "${backup_test_dir}/source-config.env" "${BACKUP_DIR}/upgrade-config.env"
  chmod 600 "${BACKUP_DIR}/upgrade-config.env"
  for path_mode in \
    "${BACKUP_ROOT}:700" \
    "${BACKUP_DIR}:700" \
    "${BACKUP_DIR}/rootfs:700" \
    "${BACKUP_DIR}/manifest.env:600" \
    "${BACKUP_DIR}/upgrade-config.env:600"; do
    path=${path_mode%:*}
    expected_mode=${path_mode##*:}
    [[ $(stat -c '%a' "${path}") == "${expected_mode}" ]] || {
      echo "Backup permission regression: ${path} is not ${expected_mode}." >&2; exit 1;
    }
  done
  [[ $(stat -c '%u' "${BACKUP_ROOT}") == $(id -u) ]] || {
    echo "Backup root ownership does not match the effective upgrader user." >&2; exit 1;
  }
else
  echo "Backup permission filesystem behavior skipped: local filesystem cannot apply Unix modes."
fi

echo "Managed upgrade and rollback safety checks passed."
