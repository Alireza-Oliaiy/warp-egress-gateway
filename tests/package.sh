#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(<"${ROOT}/VERSION")
NAME="warp-egress-gateway-${VERSION}"
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
OUT=$(mktemp -d)
trap 'rm -rf "${OUT}"' EXIT

WARP_GATEWAY_PYTHON3="${PYTHON3_BIN}" bash "${ROOT}/scripts/package-release.sh" "${OUT}" >/dev/null

[[ -f ${OUT}/${NAME}.tar.gz ]] || { echo "Release TAR was not created." >&2; exit 1; }
[[ -f ${OUT}/${NAME}.zip ]] || { echo "Release ZIP was not created." >&2; exit 1; }
[[ -f ${OUT}/${NAME}-SHA256SUMS.txt ]] || { echo "Release checksum file was not created." >&2; exit 1; }
grep -q 'PACKAGE_PAYLOAD_TESTED' "${ROOT}/tests/package.sh" || {
  echo "Package validation must run the extracted payload suite exactly once." >&2; exit 1;
}
grep -q 'diff --cached --check' "${ROOT}/tests/package.sh" || {
  echo "Package validation must check a staged Git overlay for whitespace errors." >&2; exit 1;
}

tar_list="${OUT}/tar-list.txt"
tar -tzf "${OUT}/${NAME}.tar.gz" >"${tar_list}"
for required in \
  VERSION LICENSE README.md README.fa.md CHANGELOG.md setup.sh upgrade.sh rollback.sh \
  native/install.sh docker/setup.sh shared/upgrade/remote-upgrade.sh \
  native/scripts/admin-lock.sh native/scripts/health-readonly.sh \
  native/scripts/mutation-transactions.sh native/scripts/observation-entrypoints.sh \
  native/scripts/wg-quick-locked.sh native/systemd/warp-gateway.conf \
  web/__init__.py web/dashboard/README.md web/dashboard/__init__.py \
  web/dashboard/collector.py web/dashboard/schema.py web/dashboard/server.py \
  web/dashboard/status-schema.json \
  web/dashboard/fixtures/healthy.json web/dashboard/fixtures/degraded.json \
  web/dashboard/fixtures/failed.json \
  web/dashboard/static/index.html web/dashboard/static/styles.css \
  web/dashboard/static/app.js \
  web/dashboard/deploy/__init__.py web/dashboard/deploy/install.sh \
  web/dashboard/deploy/uninstall.sh \
  web/dashboard/deploy/dashboard.env.example web/dashboard/deploy/launcher.py \
  web/dashboard/deploy/systemd/warp-dashboard.service \
  web/dashboard/deploy/systemd/warp-dashboard-collector.service \
  web/dashboard/deploy/systemd/warp-dashboard-collector.timer \
  web/dashboard/deploy/tmpfiles/warp-egress-dashboard.conf \
  docs/upgrade.md docs/security.md docs/web-console/READ_ONLY_DASHBOARD.md \
  docs/admin-console/SLICE_1A_HEALTH_LOCK_FOUNDATION.md \
  tests/dashboard.sh tests/dashboard_test.py tests/dashboard_ui_test.js \
  tests/dashboard-deploy.sh tests/dashboard_deploy_test.py tests/syntax.sh \
  tests/health-lock.sh tests/health-readonly.sh tests/observation-locking.sh \
  tests/writer-locking.sh \
  docker/generated/.gitkeep docker/state/.gitkeep; do
  grep -qx "${NAME}/${required}" "${tar_list}" || {
    echo "Packaged TAR is missing required file: ${required}" >&2; exit 1;
  }
done
if grep -Eq "^${NAME}/(\\.git/|\\.github/|docs/superpowers/|release[^/]*/|CONTRIBUTING\\.md$|docker/\\.env$|wgcf-account\\.toml$|wgcf-profile\\.conf$)|(__pycache__/|\\.py[co]$)" "${tar_list}"; then
  echo "Packaged TAR contains forbidden development or runtime-private content." >&2
  exit 1
fi
for executable in \
  setup.sh upgrade.sh rollback.sh tests/run-all.sh \
  web/dashboard/deploy/install.sh web/dashboard/deploy/uninstall.sh; do
  tar -tvzf "${OUT}/${NAME}.tar.gz" | grep -E "^-rwxr-xr-x .*${NAME}/${executable}$" >/dev/null || {
    echo "Packaged TAR executable mode is missing: ${executable}" >&2; exit 1;
  }
done
for regular in \
  web/__init__.py \
  web/dashboard/__init__.py \
  web/dashboard/collector.py \
  web/dashboard/schema.py \
  web/dashboard/server.py \
  web/dashboard/deploy/__init__.py \
  web/dashboard/deploy/dashboard.env.example \
  web/dashboard/deploy/launcher.py \
  web/dashboard/deploy/systemd/warp-dashboard.service \
  web/dashboard/deploy/systemd/warp-dashboard-collector.service \
  web/dashboard/deploy/systemd/warp-dashboard-collector.timer \
  web/dashboard/deploy/tmpfiles/warp-egress-dashboard.conf; do
  tar -tvzf "${OUT}/${NAME}.tar.gz" | grep -E "^-rw-r--r-- .*${NAME}/${regular}$" >/dev/null || {
    echo "Packaged TAR regular-file mode is not 0644: ${regular}" >&2; exit 1;
  }
done

"${PYTHON3_BIN}" - "${OUT}/${NAME}.zip" "${NAME}" <<'PY'
from pathlib import Path, PurePosixPath
import sys
import zipfile

archive_path, name = map(Path, sys.argv[1:])
required = {
    f'{name}/VERSION', f'{name}/LICENSE', f'{name}/README.md',
    f'{name}/README.fa.md', f'{name}/CHANGELOG.md', f'{name}/setup.sh',
    f'{name}/upgrade.sh', f'{name}/rollback.sh', f'{name}/native/install.sh',
    f'{name}/native/scripts/admin-lock.sh',
    f'{name}/native/scripts/health-readonly.sh',
    f'{name}/native/scripts/mutation-transactions.sh',
    f'{name}/native/scripts/observation-entrypoints.sh',
    f'{name}/native/scripts/wg-quick-locked.sh',
    f'{name}/native/systemd/warp-gateway.conf',
    f'{name}/web/__init__.py', f'{name}/web/dashboard/README.md',
    f'{name}/web/dashboard/__init__.py',
    f'{name}/web/dashboard/collector.py',
    f'{name}/web/dashboard/schema.py',
    f'{name}/web/dashboard/server.py',
    f'{name}/web/dashboard/status-schema.json',
    f'{name}/web/dashboard/fixtures/healthy.json',
    f'{name}/web/dashboard/fixtures/degraded.json',
    f'{name}/web/dashboard/fixtures/failed.json',
    f'{name}/web/dashboard/static/index.html',
    f'{name}/web/dashboard/static/styles.css',
    f'{name}/web/dashboard/static/app.js',
    f'{name}/web/dashboard/deploy/install.sh',
    f'{name}/web/dashboard/deploy/uninstall.sh',
    f'{name}/web/dashboard/deploy/__init__.py',
    f'{name}/web/dashboard/deploy/dashboard.env.example',
    f'{name}/web/dashboard/deploy/launcher.py',
    f'{name}/web/dashboard/deploy/systemd/warp-dashboard.service',
    f'{name}/web/dashboard/deploy/systemd/warp-dashboard-collector.service',
    f'{name}/web/dashboard/deploy/systemd/warp-dashboard-collector.timer',
    f'{name}/web/dashboard/deploy/tmpfiles/warp-egress-dashboard.conf',
    f'{name}/docker/setup.sh', f'{name}/shared/upgrade/remote-upgrade.sh',
    f'{name}/docs/upgrade.md', f'{name}/docs/security.md',
    f'{name}/docs/web-console/READ_ONLY_DASHBOARD.md',
    f'{name}/docs/admin-console/SLICE_1A_HEALTH_LOCK_FOUNDATION.md',
    f'{name}/tests/dashboard.sh', f'{name}/tests/dashboard_test.py',
    f'{name}/tests/dashboard_ui_test.js', f'{name}/tests/dashboard-deploy.sh',
    f'{name}/tests/dashboard_deploy_test.py', f'{name}/tests/syntax.sh',
    f'{name}/tests/health-lock.sh', f'{name}/tests/health-readonly.sh',
    f'{name}/tests/observation-locking.sh', f'{name}/tests/writer-locking.sh',
    f'{name}/docker/generated/.gitkeep',
    f'{name}/docker/state/.gitkeep',
}
with zipfile.ZipFile(archive_path) as archive:
    entries = set(archive.namelist())
    missing = required.difference(entries)
    forbidden_roots = ('.git/', '.github/', 'docs/superpowers/', 'release')
    forbidden_files = {
        'CONTRIBUTING.md', 'docker/.env',
        'wgcf-account.toml', 'wgcf-profile.conf',
    }
    forbidden = [entry for entry in entries if entry.removeprefix(f'{name}/') in forbidden_files
                 or entry.removeprefix(f'{name}/').startswith(forbidden_roots)
                 or '__pycache__' in PurePosixPath(entry).parts
                 or PurePosixPath(entry).suffix in {'.pyc', '.pyo'}]
if missing:
    raise SystemExit(f'Packaged ZIP is missing: {", ".join(sorted(missing))}')
if forbidden:
    raise SystemExit('Packaged ZIP contains forbidden content: ' + ', '.join(sorted(forbidden)))
PY

"${PYTHON3_BIN}" - "${OUT}/${NAME}.zip" <<'PY'
from pathlib import PurePosixPath
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    invalid = []
    for entry in archive.infolist():
        path = PurePosixPath(entry.filename)
        is_shell = path.suffix == '.sh' or path.name == 'warp-gateway'
        if is_shell and ((entry.external_attr >> 16) & 0o111) != 0o111:
            invalid.append(entry.filename)
if invalid:
    raise SystemExit('ZIP shell/CLI entries are not executable: ' + ', '.join(invalid))
PY

"${PYTHON3_BIN}" - "${OUT}/${NAME}.zip" "${NAME}" <<'PY'
import sys
import zipfile

archive_path, name = sys.argv[1:]
expected = {
    f'{name}/web/dashboard/deploy/install.sh': 0o755,
    f'{name}/web/dashboard/deploy/uninstall.sh': 0o755,
    f'{name}/web/__init__.py': 0o644,
    f'{name}/web/dashboard/__init__.py': 0o644,
    f'{name}/web/dashboard/collector.py': 0o644,
    f'{name}/web/dashboard/schema.py': 0o644,
    f'{name}/web/dashboard/server.py': 0o644,
    f'{name}/web/dashboard/deploy/__init__.py': 0o644,
    f'{name}/web/dashboard/deploy/dashboard.env.example': 0o644,
    f'{name}/web/dashboard/deploy/launcher.py': 0o644,
    f'{name}/web/dashboard/deploy/systemd/warp-dashboard.service': 0o644,
    f'{name}/web/dashboard/deploy/systemd/warp-dashboard-collector.service': 0o644,
    f'{name}/web/dashboard/deploy/systemd/warp-dashboard-collector.timer': 0o644,
    f'{name}/web/dashboard/deploy/tmpfiles/warp-egress-dashboard.conf': 0o644,
}
with zipfile.ZipFile(archive_path) as archive:
    entries = {entry.filename: entry for entry in archive.infolist()}
for path, mode in expected.items():
    actual = (entries[path].external_attr >> 16) & 0o777
    if actual != mode:
        raise SystemExit(f'Packaged ZIP mode mismatch for {path}: {actual:o}, expected {mode:o}.')
PY

(
  cd "${OUT}"
  sha256sum -c "${NAME}-SHA256SUMS.txt" >/dev/null
)

if [[ ${WARP_GATEWAY_PACKAGE_PAYLOAD_TESTED:-false} != true ]]; then
  extracted="${OUT}/extracted"
  overlay="${OUT}/overlay"
  "${PYTHON3_BIN}" - "${OUT}/${NAME}.zip" "${extracted}" <<'PY'
from pathlib import Path
import os
import sys
import zipfile

archive_path, destination = map(Path, sys.argv[1:])
with zipfile.ZipFile(archive_path) as archive:
    for member in archive.infolist():
        extracted = Path(archive.extract(member, destination))
        mode = (member.external_attr >> 16) & 0o777
        if mode and extracted.is_file():
            os.chmod(extracted, mode)
PY
  [[ -d ${extracted}/${NAME} ]] || { echo "Release ZIP extraction failed." >&2; exit 1; }
  WARP_GATEWAY_PYTHON3="${PYTHON3_BIN}" WARP_GATEWAY_PACKAGE_PAYLOAD_TESTED=true \
    bash "${extracted}/${NAME}/tests/run-all.sh"

  mkdir -p "${overlay}/docker/generated" "${overlay}/docker/state"
  : >"${overlay}/docker/generated/.gitkeep"
  : >"${overlay}/docker/state/.gitkeep"
  git -C "${overlay}" init --quiet
  git -C "${overlay}" add -A
  git -C "${overlay}" -c user.name='Release validation' -c user.email='release-validation@example.invalid' \
    commit --quiet -m 'Baseline clone-like layout'
  find "${overlay}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
  "${PYTHON3_BIN}" - "${OUT}/${NAME}.zip" "${overlay}" <<'PY'
from pathlib import Path
import sys
import zipfile

archive_path, destination = map(Path, sys.argv[1:])
with zipfile.ZipFile(archive_path) as archive:
    archive.extractall(destination)
payload = destination / archive_path.stem
for item in payload.iterdir():
    item.replace(destination / item.name)
payload.rmdir()
PY
  git -C "${overlay}" add -A
  git -C "${overlay}" add --renormalize .
  git -C "${overlay}" diff --cached --check
fi

echo "Release package structure and checksum checks passed."
