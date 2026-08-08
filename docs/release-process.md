# Release process

The project follows Semantic Versioning while it is in the `0.x` series:

- Patch (`0.4.1`): backward-compatible bug/security/documentation fix.
- Minor (`0.5.0`): new backward-compatible operator/deployment capability or significant lifecycle feature.
- `1.0.0`: declared stable interface/operations contract.

## Definition of done for every change

A change is not complete until all applicable items are updated in the same pull request/commit:

1. Code or configuration.
2. Automated regression/static tests for the changed behavior.
3. Operator documentation for any command, lifecycle, security, networking, or failure-mode change.
4. `CHANGELOG.md` for user-visible behavior.
5. `VERSION` and matching Docker image metadata for a release.
6. English and Persian README when top-level usage changes.
7. Security/troubleshooting docs when the safety model or failure behavior changes.

## Required validation

Run:

```bash
bash tests/run-all.sh
```

This is the canonical full validation command and does not require GNU Make. It runs all mandatory repository tests, reports explicit `PASS`/`FAIL`/`SKIP` states, and exits nonzero for any failing test or missing mandatory prerequisite. Python 3 is mandatory for whitespace/EOF and ZIP fallback validation. `shellcheck` and Docker Compose validation are reported as `SKIP` only when unavailable locally; CI installs ShellCheck, while Docker runtime validation remains host-dependent.

`make test` remains a convenience wrapper for the same command. The release metadata test verifies that `VERSION`, Docker image tags, changelog, and publishing metadata agree.

For Docker-capable development hosts also validate Compose:

```bash
make compose
```

## Release checklist

1. Create a focused branch.
2. Implement code + tests + docs.
3. Run `bash tests/run-all.sh` and review any local `SKIP` status. Do not release until mandatory tests pass; CI runs ShellCheck.
4. Perform a real Native/Docker maintenance-window validation when the change affects runtime networking.
5. Update `CHANGELOG.md` and `VERSION`.
6. Merge/publish to `main`.
7. Create an annotated `vX.Y.Z` tag.
8. Allow GitHub Actions to validate the tag and create release archives/checksums.
9. Verify the GitHub Release artifacts and SHA256 file.
10. Upgrade a non-critical gateway first, reboot-test when relevant, then promote to production.

## Windows publisher

The included PowerShell publisher validates the release and can create/push the release tag:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\publish-to-github.ps1 `
  -RepositoryUrl "https://github.com/Alireza-Oliaiy/warp-egress-gateway.git" `
  -CommitMessage "Release v0.4.0: add managed upgrade and release lifecycle" `
  -CreateReleaseTag
```

`-CreateReleaseTag` reads `VERSION`, creates `v<VERSION>`, and pushes it after `main`. The tag triggers the release workflow.

## Hotfix policy

For an urgent production bug:

- preserve incident evidence first;
- reproduce the failure with a regression test;
- make the smallest safe fix;
- update troubleshooting/changelog;
- publish a patch version;
- validate on a non-critical gateway before broad rollout.
## Artifact and publisher integrity

Before a release is tagged, the test suite validates the Windows replacement-publish path and builds disposable release artifacts. All three artifacts are mandatory: `warp-egress-gateway-<VERSION>.zip`, `warp-egress-gateway-<VERSION>.tar.gz`, and `warp-egress-gateway-<VERSION>-SHA256SUMS.txt`. Packaging requires Python 3 and uses its standard ZIP support to write explicit Unix `0755` metadata for every shell script and the `warp-gateway` CLI, so ZIP artifacts built on Windows extract executable on Linux. The TAR/ZIP structure must preserve tracked placeholder files such as `docker/generated/.gitkeep` and `docker/state/.gitkeep`, while generated runtime state and secrets remain excluded. Artifact SHA256 verification, extracted-payload validation, executable-mode validation, and a clone-like `git diff --cached --check` overlay gate are mandatory.

## Whitespace and repository hygiene gate

The release test suite validates UTF-8 text files before publishing. It rejects trailing spaces or tabs, CRLF/CR line endings in repository text, missing final newlines, and extra blank lines at EOF. The Windows publisher still runs `git diff --cached --check` as a second independent gate after staging the release payload.
