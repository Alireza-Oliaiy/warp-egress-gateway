#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }
skip() { printf 'SKIP %s\n' "$*"; }

for command in bash tar sha256sum git; do
  command -v "${command}" >/dev/null 2>&1 \
    || fail "mandatory prerequisite is unavailable: ${command}"
done
if ! command -v "${PYTHON3_BIN}" >/dev/null 2>&1 && [[ ! -x ${PYTHON3_BIN} ]]; then
  fail "mandatory prerequisite is unavailable: Python 3 (${PYTHON3_BIN})"
fi

tests=(
  syntax.sh
  whitespace.sh
  security-order.sh
  monitoring.sh
  profile-ipv4.sh
  upgrade.sh
  docs.sh
  release-metadata.sh
  publisher.sh
  package.sh
)

for test in "${tests[@]}"; do
  if WARP_GATEWAY_PYTHON3="${PYTHON3_BIN}" bash "${ROOT}/tests/${test}"; then
    pass "tests/${test}"
  else
    fail "tests/${test}"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  # Runtime profiles/configuration and literal static-test probes are resolved
  # outside ShellCheck's single-file analysis; retain all actionable warnings.
  find "${ROOT}" -type f -name '*.sh' -not -path '*/release/*' -print0 \
    | xargs -0 shellcheck -e SC1091,SC2015,SC2016,SC2153
  pass shellcheck
else
  skip 'shellcheck is unavailable locally; CI installs and runs it'
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  temporary_env=${ROOT}/docker/generated/warp-gateway.env
  trap 'rm -f "${temporary_env}"' EXIT
  cp "${ROOT}/native/config/warp-gateway.env.example" "${temporary_env}"
  (cd "${ROOT}/docker" && docker compose config >/dev/null)
  pass 'docker compose config'
else
  skip 'docker compose is unavailable locally; Docker configuration runtime validation was not run'
fi

pass 'full validation suite'
