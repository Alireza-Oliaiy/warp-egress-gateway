#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(<"${ROOT}/VERSION")

grep -qx "IMAGE_TAG=${VERSION}" "${ROOT}/docker/.env.example" || {
  echo "docker/.env.example IMAGE_TAG does not match VERSION=${VERSION}" >&2; exit 1;
}
grep -q "IMAGE_TAG:-${VERSION}" "${ROOT}/docker/compose.yaml" || {
  echo "docker/compose.yaml default image tag does not match VERSION=${VERSION}" >&2; exit 1;
}
grep -q "ARG WARP_GATEWAY_VERSION=${VERSION}" "${ROOT}/docker/Dockerfile" || {
  echo "docker/Dockerfile WARP_GATEWAY_VERSION does not match VERSION=${VERSION}" >&2; exit 1;
}
grep -q "## ${VERSION} -" "${ROOT}/CHANGELOG.md" || {
  echo "CHANGELOG.md does not contain release ${VERSION}" >&2; exit 1;
}
grep -q "Release v${VERSION}:" "${ROOT}/publish-to-github.ps1" || {
  echo "PowerShell publisher default message does not match VERSION=${VERSION}" >&2; exit 1;
}

echo "Release metadata checks passed for ${VERSION}."
