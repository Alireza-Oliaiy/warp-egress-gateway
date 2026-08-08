# Release Lifecycle Integrity Design

## Goal

Make the v0.4.0 release payload safe to upgrade, validate, package, and publish without weakening its fail-closed WARP gateway protections.

## Decisions

- The fixed2 payload remains the sole working copy; no historical release directory is changed.
- `warp-gateway-upgrade --ref vX.Y.Z` accepts only a canonical semantic-version tag for release upgrades. After cloning, its `VERSION` must be a single valid semantic version and must exactly match the requested tag without the `v` prefix. `latest` resolves to a canonical tag and is verified the same way. An explicit `main` ref remains intentionally available only as an unreleased path and must still contain a valid `VERSION`.
- Upgrade source validation is performed before `upgrade.sh` can create a backup or alter host services. Native and Docker upgrade/rollback behavior remains unchanged after that boundary.
- `tests/run-all.sh` is the canonical deterministic runner. It runs every mandatory static, lifecycle, package, and overlay test, records explicit PASS/FAIL status, and stops with nonzero status on a failed test or missing mandatory prerequisite.
- Whitespace validation remains Python-based for robust Unicode-safe file inspection, but it declares Python 3 as a mandatory prerequisite and fails before running if absent.
- Release packaging requires `tar`, `sha256sum`, `zip`, and `unzip`; missing tooling is a hard error. The package test requires all three release artifacts and validates an extracted payload plus a Git overlay check.

## Safety Boundaries

- No command prints, copies to output, or regenerates a WARP private key or account identity.
- Upgrade backups stay root-only and automatic rollback continues to restore the independent native firewall or Docker host guard before restarting the restored deployment.
- No production host, Git tag, GitHub release, or remote repository is modified by this work.

## Verification

The suite will include regression cases for version/ref mismatch, missing or malformed downloaded version files, mandatory-tool failure, test-runner propagation, whitespace failure, package artifact completeness, placeholder preservation, and clean Git overlay staging.
