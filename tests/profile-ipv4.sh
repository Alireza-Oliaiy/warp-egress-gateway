#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NORMALIZER="${ROOT}/shared/profile/normalize-warp-profile-ipv4.sh"

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT
profile="${workdir}/warp.conf"

cat > "${profile}" <<'PROFILE'
[Interface]
PrivateKey = secret-placeholder
Address = 172.16.0.2/32, 2606:4700:110:8d10:aeae:ba80:8fb2:4aa0/128
DNS = 1.1.1.1

[Peer]
PublicKey = peer-placeholder
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
PROFILE

bash "${NORMALIZER}" "${profile}"

grep -qx 'Address = 172.16.0.2/32' "${profile}" || {
  echo "IPv4 Address normalization failed" >&2
  exit 1
}
grep -qx 'AllowedIPs = 0.0.0.0/0' "${profile}" || {
  echo "IPv4 AllowedIPs normalization failed" >&2
  exit 1
}
if grep -Eq '^(Address|AllowedIPs)[[:space:]]*=.*:' "${profile}"; then
  echo "IPv6 remained in normalized profile" >&2
  exit 1
fi
grep -q '^PrivateKey = secret-placeholder$' "${profile}" || {
  echo "Normalizer must preserve PrivateKey" >&2
  exit 1
}
grep -q '^PublicKey = peer-placeholder$' "${profile}" || {
  echo "Normalizer must preserve peer PublicKey" >&2
  exit 1
}

grep -q 'normalize-warp-profile-ipv4.sh' "${ROOT}/native/install.sh" || {
  echo "Native installer must normalize imported/generated WARP profiles" >&2
  exit 1
}
grep -q '/app/bin/normalize-warp-profile-ipv4.sh' "${ROOT}/docker/bin/entrypoint.sh" || {
  echo "Docker runtime must normalize imported/generated WARP profiles" >&2
  exit 1
}
grep -q 'shared/profile/normalize-warp-profile-ipv4.sh' "${ROOT}/docker/Dockerfile" || {
  echo "Docker image must include the IPv4 profile normalizer" >&2
  exit 1
}

echo "IPv4-only WARP profile normalization checks passed."
