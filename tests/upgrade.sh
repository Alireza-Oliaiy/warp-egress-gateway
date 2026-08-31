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
  capture { print }
  capture && /^}$/ { exit }
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

# Exercise the production ref-resolution and checkout functions against a real
# local bare remote. The annotated-tag case catches the v0.5.0 defect: the
# remote ref object is a tag object, while detached HEAD is its peeled commit.
ref_test_dir=$(mktemp -d)
trap 'rm -rf "${unit_dir}" "${ref_test_dir}"' EXIT
source_repo="${ref_test_dir}/source"
bare_remote="${ref_test_dir}/remote.git"
git init -q "${source_repo}"
git -C "${source_repo}" config user.name 'Upgrade Regression'
git -C "${source_repo}" config user.email 'upgrade-regression@example.invalid'
git -C "${source_repo}" checkout -q -b candidate

printf '0.5.1\n' >"${source_repo}/VERSION"
git -C "${source_repo}" add VERSION
git -C "${source_repo}" commit -q -m 'annotated release fixture'
annotated_commit=$(git -C "${source_repo}" rev-parse HEAD)
git -C "${source_repo}" tag -a v0.5.1 -m 'Release v0.5.1'
annotated_ref_oid=$(git -C "${source_repo}" rev-parse v0.5.1)
annotated_peeled_oid=$(git -C "${source_repo}" rev-parse 'v0.5.1^{commit}')
[[ ${annotated_ref_oid} != "${annotated_peeled_oid}" && ${annotated_peeled_oid} == "${annotated_commit}" ]] || {
  echo 'Annotated-tag fixture did not create distinct ref-object and commit OIDs.' >&2; exit 1;
}

printf '0.5.2\n' >"${source_repo}/VERSION"
git -C "${source_repo}" add VERSION
git -C "${source_repo}" commit -q -m 'lightweight release fixture'
lightweight_commit=$(git -C "${source_repo}" rev-parse HEAD)
git -C "${source_repo}" tag v0.5.2
lightweight_ref_oid=$(git -C "${source_repo}" rev-parse v0.5.2)
[[ ${lightweight_ref_oid} == "${lightweight_commit}" ]] || {
  echo 'Lightweight-tag fixture unexpectedly created a distinct object.' >&2; exit 1;
}

printf '0.5.3\n' >"${source_repo}/VERSION"
git -C "${source_repo}" add VERSION
git -C "${source_repo}" commit -q -m 'latest annotated release fixture'
latest_commit=$(git -C "${source_repo}" rev-parse HEAD)
git -C "${source_repo}" tag -a v0.5.3 -m 'Release v0.5.3'
latest_ref_oid=$(git -C "${source_repo}" rev-parse v0.5.3)

blob_oid=$(printf 'not a commit\n' | git -C "${source_repo}" hash-object -w --stdin)
git -C "${source_repo}" update-ref refs/tags/v0.4.9 "${blob_oid}"
git init -q --bare "${bare_remote}"
git -C "${source_repo}" push -q "${bare_remote}" candidate --tags
git -C "${bare_remote}" symbolic-ref HEAD refs/heads/candidate
repository_url="file://${bare_remote}"

# Narrow proof of the old v0.5.0 comparison against the same real fixture.
old_checkout="${ref_test_dir}/old-logic-checkout"
git clone -q --no-checkout --depth 1 "${repository_url}" "${old_checkout}"
git -C "${old_checkout}" fetch -q --depth 1 origin "${annotated_ref_oid}"
git -C "${old_checkout}" checkout -q --detach "${annotated_ref_oid}"
old_logic_head=$(git -C "${old_checkout}" rev-parse HEAD)
[[ ${old_logic_head} == "${annotated_peeled_oid}" && ${old_logic_head} != "${annotated_ref_oid}" ]] || {
  echo 'Old-logic fixture did not reproduce the annotated-tag object/commit distinction.' >&2; exit 1;
}
echo 'OLD_LOGIC_ANNOTATED_TAG=rejects-peeled-commit-as-expected'

extract_bootstrap_function() {
  local function_name=$1
  awk -v function_name="${function_name}" '
    $0 ~ ("^" function_name "\\(\\)") { capture=1 }
    capture { print }
    capture && /^}$/ { found=1; exit }
    END { if (!found) exit 1 }
  ' "${REMOTE_UPGRADE}"
}

ref_runner="${ref_test_dir}/ref-runner.sh"
cat >"${ref_runner}" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
RUNNER
for function_name in \
  select_latest_ref \
  resolve_requested_ref \
  peel_resolved_commit \
  verify_checked_out_commit \
  checkout_resolved_ref \
  validate_checked_out_version; do
  extract_bootstrap_function "${function_name}" >>"${ref_runner}" || {
    echo "Bootstrap is missing testable production function: ${function_name}." >&2; exit 1;
  }
done
cat >>"${ref_runner}" <<'RUNNER'
case $1 in
  run)
    REPOSITORY_URL=$2
    REF=$3
    checkout_dir=$4
    [[ ${REF} == latest ]] && select_latest_ref
    resolve_requested_ref "${REF}"
    checkout_resolved_ref "${checkout_dir}"
    validate_checked_out_version "${checkout_dir}/VERSION"
    printf 'SELECTED_REF=%s\n' "${REF}"
    printf 'RESOLVED_REF=%s\n' "${RESOLVED_REF}"
    printf 'RESOLVED_REF_OID=%s\n' "${RESOLVED_REF_OID}"
    printf 'RESOLVED_COMMIT_OID=%s\n' "${RESOLVED_COMMIT_OID}"
    printf 'HEAD=%s\n' "$(git -C "${checkout_dir}" rev-parse HEAD)"
    printf 'VERSION=%s\n' "$(<"${checkout_dir}/VERSION")"
    ;;
  verify)
    RESOLVED_COMMIT_OID=$3
    verify_checked_out_commit "$2"
    ;;
  *)
    exit 2
    ;;
esac
RUNNER
chmod +x "${ref_runner}"

assert_ref_case() {
  local name=$1 ref=$2 expected_remote_ref=$3 expected_ref_oid=$4 expected_commit_oid=$5 expected_version=$6
  local checkout_dir="${ref_test_dir}/checkout-${name}" output
  output=$("${ref_runner}" run "${repository_url}" "${ref}" "${checkout_dir}")
  grep -Fqx "RESOLVED_REF=${expected_remote_ref}" <<<"${output}"
  grep -Fqx "RESOLVED_REF_OID=${expected_ref_oid}" <<<"${output}"
  grep -Fqx "RESOLVED_COMMIT_OID=${expected_commit_oid}" <<<"${output}"
  grep -Fqx "HEAD=${expected_commit_oid}" <<<"${output}"
  grep -Fqx "VERSION=${expected_version}" <<<"${output}"
  printf 'REF_CASE[%s]=PASS\n' "${name}"
}

assert_ref_case annotated v0.5.1 refs/tags/v0.5.1 "${annotated_ref_oid}" "${annotated_peeled_oid}" 0.5.1
assert_ref_case lightweight v0.5.2 refs/tags/v0.5.2 "${lightweight_ref_oid}" "${lightweight_commit}" 0.5.2
branch_oid=$(git -C "${source_repo}" rev-parse candidate)
assert_ref_case branch candidate refs/heads/candidate "${branch_oid}" "${branch_oid}" 0.5.3
assert_ref_case latest latest refs/tags/v0.5.3 "${latest_ref_oid}" "${latest_commit}" 0.5.3

! "${ref_runner}" run "${repository_url}" v0.4.9 "${ref_test_dir}/checkout-noncommit" >/dev/null 2>&1 || {
  echo 'Bootstrap accepted a ref object that cannot peel to a commit.' >&2; exit 1;
}
echo 'REF_CASE[noncommit]=REJECTED'
! "${ref_runner}" run "${repository_url}" v9.9.9 "${ref_test_dir}/checkout-unresolved" >/dev/null 2>&1 || {
  echo 'Bootstrap accepted an unresolved exact ref.' >&2; exit 1;
}
echo 'REF_CASE[unresolved]=REJECTED'
! "${ref_runner}" verify "${ref_test_dir}/checkout-annotated" "${lightweight_commit}" >/dev/null 2>&1 || {
  echo 'Bootstrap accepted a checkout whose HEAD differs from the expected peeled commit.' >&2; exit 1;
}
echo 'REF_CASE[wrong-head]=REJECTED'
! "${ref_runner}" verify "${ref_test_dir}/checkout-annotated" not-an-oid >/dev/null 2>&1 || {
  echo 'Bootstrap accepted a malformed commit OID.' >&2; exit 1;
}
echo 'REF_CASE[malformed-oid]=REJECTED'

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
trap 'rm -rf "${unit_dir}" "${ref_test_dir}" "${backup_test_dir}"' EXIT
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
