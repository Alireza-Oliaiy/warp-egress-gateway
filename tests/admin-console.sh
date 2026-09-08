#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}

if ! command -v "${PYTHON3_BIN}" >/dev/null 2>&1 && [[ ! -x ${PYTHON3_BIN} ]]; then
  echo "Python 3 is required for Admin Console tests: ${PYTHON3_BIN}" >&2
  exit 1
fi

(cd "${ROOT}" && "${PYTHON3_BIN}" -B tests/admin_network_test.py && "${PYTHON3_BIN}" -B tests/admin_console_test.py)
echo "Admin Console tests passed."
