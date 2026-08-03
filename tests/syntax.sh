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
  native/setup.sh
  native/install.sh
  native/config/warp-gateway.env.example
  native/systemd/warp-gateway-firewall.service
  docker/setup.sh
  docker/Dockerfile
  docker/compose.yaml
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

echo "Syntax and repository structure checks passed."
