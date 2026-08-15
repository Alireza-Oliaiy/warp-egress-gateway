#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
"${PYTHON3_BIN}" "${ROOT}/tests/helper_test.py"
