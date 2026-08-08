#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

mapfile -t files < <(find "${ROOT}" -type f -name '*.sh' -not -path '*/release/*' | sort)
for file in "${files[@]}"; do
  bash -n "${file}"
done

required=(
  README.md
  README.fa.md
  LICENSE
  setup.sh
  .gitattributes
  publish-to-github.ps1
  WINDOWS-PUBLISH.md
  native/setup.sh
  native/install.sh
  native/config/warp-gateway.env.example
  native/systemd/warp-gateway-firewall.service
  native/scripts/monitor.sh
  native/systemd/warp-monitor.service
  native/systemd/warp-monitor.timer
  docker/bin/monitor.sh
  shared/journald/10-warp-egress-gateway-retention.conf
  shared/profile/normalize-warp-profile-ipv4.sh
  tests/profile-ipv4.sh
  tests/run-all.sh
  tests/whitespace.sh
  docs/monitoring.md
  docker/setup.sh
  docker/Dockerfile
  docker/compose.yaml
  docker/generated/.gitkeep
  docker/state/.gitkeep
  docker/bin/entrypoint.sh
  docker/host/warp-egress-docker-guard.service
  docs/docker.md
)

for path in "${required[@]}"; do
  [[ -e ${ROOT}/${path} ]] || {
    echo "Missing required file: ${path}" >&2
    exit 1
  }
done


# Windows publishing and extracted-file resilience checks.
grep -q 'exec bash .*native/setup.sh' "${ROOT}/setup.sh" || {
  echo "Top-level native dispatch must invoke Bash explicitly." >&2
  exit 1
}
grep -q 'exec bash .*docker/setup.sh' "${ROOT}/setup.sh" || {
  echo "Top-level Docker dispatch must invoke Bash explicitly." >&2
  exit 1
}
grep -q '\*.sh text eol=lf' "${ROOT}/.gitattributes" || {
  echo "Shell scripts must be pinned to LF line endings." >&2
  exit 1
}
[[ -x ${ROOT}/tests/run-all.sh ]] || {
  echo "Canonical tests/run-all.sh runner is missing or not executable." >&2
  exit 1
}
grep -q 'tests/run-all.sh' "${ROOT}/Makefile" || {
  echo "make test must delegate to the canonical test runner." >&2
  exit 1
}
grep -q 'WARP_GATEWAY_PYTHON3' "${ROOT}/tests/whitespace.sh" || {
  echo "Whitespace validation must fail clearly when Python 3 is unavailable." >&2
  exit 1
}

echo "Syntax and repository structure checks passed."
