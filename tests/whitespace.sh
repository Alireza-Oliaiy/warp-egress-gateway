#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}

if ! command -v "${PYTHON3_BIN}" >/dev/null 2>&1 && [[ ! -x ${PYTHON3_BIN} ]]; then
  echo "Python 3 is required for whitespace and EOF validation." >&2
  exit 1
fi

"${PYTHON3_BIN}" - "${ROOT}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
errors = []
skip_dirs = {'.git', 'release'}

for path in sorted(root.rglob('*')):
    if not path.is_file():
        continue
    if any(part in skip_dirs for part in path.relative_to(root).parts):
        continue
    data = path.read_bytes()
    if not data or b'\x00' in data:
        continue

    # Only lint UTF-8 text. Binary/non-UTF-8 payloads are ignored.
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        continue

    rel = path.relative_to(root)
    if '\r\n' in text or '\r' in text:
        errors.append(f'{rel}: CR/CRLF line ending detected; repository text must be LF-safe')

    lines = text.splitlines()
    for lineno, line in enumerate(lines, start=1):
        if line.endswith((' ', '\t')):
            errors.append(f'{rel}:{lineno}: trailing whitespace')

    # Non-empty text files must end with exactly one LF. This catches the
    # "new blank line at EOF" condition that git diff --check rejects.
    if not data.endswith(b'\n'):
        errors.append(f'{rel}: missing final LF')
    elif data.endswith(b'\n\n'):
        errors.append(f'{rel}: blank line at EOF')

if errors:
    print('Repository whitespace validation failed:', file=sys.stderr)
    for error in errors:
        print(f'  {error}', file=sys.stderr)
    sys.exit(1)

print('Repository whitespace and EOF checks passed.')
PY
