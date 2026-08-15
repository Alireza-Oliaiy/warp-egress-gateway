#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PUBLISHER="${ROOT}/publish-to-github.ps1"

first_stage=$(grep -nF 'Invoke-Git -GitArguments @("add", "-A")' "${PUBLISHER}" | head -1 | cut -d: -f1)
renormalize=$(grep -nF 'Invoke-Git -GitArguments @("add", "--renormalize", ".")' "${PUBLISHER}" | head -1 | cut -d: -f1)
[[ -n ${first_stage} && -n ${renormalize} && ${first_stage} -lt ${renormalize} ]] || {
  echo "Publisher must stage additions/deletions before git add --renormalize." >&2
  exit 1
}

for test in syntax.sh whitespace.sh security-order.sh policy-recovery.sh monitoring.sh profile-ipv4.sh upgrade.sh docs.sh release-metadata.sh publisher.sh package.sh; do
  grep -q "tests/${test}" "${PUBLISHER}" || {
    echo "Windows publisher must run tests/${test}" >&2
    exit 1
  }
done

echo "Windows publisher replacement/staging regression checks passed."
