#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for doc in docs/README.md docs/upgrade.md docs/rollback.md docs/operations.md docs/release-process.md; do
  [[ -s ${ROOT}/${doc} ]] || { echo "Missing/empty documentation: ${doc}" >&2; exit 1; }
done

for readme in README.md README.fa.md; do
  grep -qi 'upgrade' "${ROOT}/${readme}" || { echo "${readme} must document upgrades" >&2; exit 1; }
  grep -q 'docs/upgrade.md' "${ROOT}/${readme}" || { echo "${readme} must link the upgrade guide" >&2; exit 1; }
done

grep -q 'release-process.md' "${ROOT}/docs/README.md" || { echo "Documentation index must link release process" >&2; exit 1; }
grep -q 'CHANGELOG.md' "${ROOT}/docs/release-process.md" || { echo "Release process must require changelog updates" >&2; exit 1; }
grep -q 'tests/run-all.sh' "${ROOT}/docs/release-process.md" || { echo "Release process must document the canonical test runner" >&2; exit 1; }
grep -qi 'requested tag' "${ROOT}/docs/upgrade.md" || { echo "Upgrade guide must document tag/VERSION mismatch rejection" >&2; exit 1; }
grep -q 'ZIP' "${ROOT}/docs/release-process.md" || { echo "Release process must document mandatory ZIP artifacts" >&2; exit 1; }

echo "Documentation completeness checks passed."
