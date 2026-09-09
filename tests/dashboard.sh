#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
NODE_BIN=${WARP_GATEWAY_NODE:-node}

if ! command -v "${PYTHON3_BIN}" >/dev/null 2>&1 && [[ ! -x ${PYTHON3_BIN} ]]; then
  echo "Python 3 is required for dashboard tests: ${PYTHON3_BIN}" >&2
  exit 1
fi
(cd "${ROOT}" && "${PYTHON3_BIN}" tests/dashboard_test.py)
(cd "${ROOT}" && "${PYTHON3_BIN}" -B tests/dashboard_roles_test.py)
if command -v "${NODE_BIN}" >/dev/null 2>&1 || [[ -x ${NODE_BIN} ]]; then
  (cd "${ROOT}" && "${NODE_BIN}" tests/dashboard_ui_test.js)
else
  echo "SKIP dashboard UI behavior tests: Node.js unavailable (${NODE_BIN})"
fi
echo "Read-only dashboard tests passed."
