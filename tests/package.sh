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
grep -qx "${NAME}/docker/generated/.gitkeep" "${tar_list}" || {
  echo "Packaged TAR must preserve docker/generated/.gitkeep." >&2; exit 1;
}
grep -qx "${NAME}/docker/state/.gitkeep" "${tar_list}" || {
  echo "Packaged TAR must preserve docker/state/.gitkeep." >&2; exit 1;
}

"${PYTHON3_BIN}" - "${OUT}/${NAME}.zip" "${NAME}" <<'PY'
from pathlib import Path
import sys
import zipfile

archive_path, name = map(Path, sys.argv[1:])
required = {
    f'{name}/docker/generated/.gitkeep',
    f'{name}/docker/state/.gitkeep',
}
with zipfile.ZipFile(archive_path) as archive:
    missing = required.difference(archive.namelist())
if missing:
    raise SystemExit(f'Packaged ZIP is missing: {", ".join(sorted(missing))}')
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
