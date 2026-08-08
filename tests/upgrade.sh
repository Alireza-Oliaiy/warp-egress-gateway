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
  /^resolve_requested_ref$/ { capture=0 }
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

echo "Managed upgrade and rollback safety checks passed."
