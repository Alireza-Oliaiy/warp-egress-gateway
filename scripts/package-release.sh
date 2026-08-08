#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(<"${ROOT}/VERSION")
OUT=${1:-"${ROOT}/release"}
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
for command in tar sha256sum; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Required packaging tool is unavailable: ${command}" >&2
    exit 1
  }
done
if ! command -v "${PYTHON3_BIN}" >/dev/null 2>&1 && [[ ! -x ${PYTHON3_BIN} ]]; then
  echo "Python 3 is required to create a ZIP with portable Unix executable metadata." >&2
  exit 1
fi
mkdir -p "${OUT}"
OUT=$(cd "${OUT}" && pwd)
NAME="warp-egress-gateway-${VERSION}"
STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${STAGE}/${NAME}"

( cd "${ROOT}" && tar \
  --exclude='./.git' \
  --exclude='./release' \
  --exclude='./docker/state/*' \
  --exclude='./docker/generated/*' \
  --exclude='./docker/.env' \
  -cf - . ) | ( cd "${STAGE}/${NAME}" && tar -xf - )

# Runtime state/generated content is intentionally excluded, but the tracked
# placeholders must remain in release archives so a release payload can replace
# an older Git checkout without deleting repository structure unexpectedly.
mkdir -p "${STAGE}/${NAME}/docker/state" "${STAGE}/${NAME}/docker/generated"
: > "${STAGE}/${NAME}/docker/state/.gitkeep"
: > "${STAGE}/${NAME}/docker/generated/.gitkeep"

rm -f "${OUT}/${NAME}.tar.gz" "${OUT}/${NAME}.zip" "${OUT}/${NAME}-SHA256SUMS.txt"
tar -C "${STAGE}" -czf "${OUT}/${NAME}.tar.gz" "${NAME}"

tar_list=$(mktemp)
tar -tzf "${OUT}/${NAME}.tar.gz" >"${tar_list}"
grep -qx "${NAME}/docker/generated/.gitkeep" "${tar_list}" || {
  echo "Release TAR is missing docker/generated/.gitkeep" >&2
  exit 1
}
grep -qx "${NAME}/docker/state/.gitkeep" "${tar_list}" || {
  echo "Release TAR is missing docker/state/.gitkeep" >&2
  exit 1
}
rm -f "${tar_list}"

"${PYTHON3_BIN}" - "${STAGE}" "${OUT}/${NAME}.zip" "${NAME}" <<'PY'
from pathlib import Path
import stat
import sys
import time
import zipfile

stage, destination, top_level = map(Path, sys.argv[1:])
with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted((stage / top_level).rglob('*')):
        if path.is_file():
            relative = path.relative_to(stage).as_posix()
            info = zipfile.ZipInfo(relative, time.localtime(path.stat().st_mtime)[:6])
            info.create_system = 3
            is_executable = path.suffix == '.sh' or path.name == 'warp-gateway'
            permissions = 0o755 if is_executable else 0o644
            info.external_attr = (stat.S_IFREG | permissions) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
PY

[[ -f ${OUT}/${NAME}.zip ]] || { echo "Release ZIP was not created." >&2; exit 1; }
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
    raise SystemExit(f'Release ZIP is missing: {", ".join(sorted(missing))}')
PY
(
  cd "${OUT}"
  files=("${NAME}.tar.gz")
  [[ -f ${NAME}.zip ]] && files+=("${NAME}.zip")
  sha256sum "${files[@]}" >"${NAME}-SHA256SUMS.txt"
)
printf '%s\n' "${OUT}/${NAME}.tar.gz"
[[ -f ${OUT}/${NAME}.zip ]] && printf '%s\n' "${OUT}/${NAME}.zip"
printf '%s\n' "${OUT}/${NAME}-SHA256SUMS.txt"
