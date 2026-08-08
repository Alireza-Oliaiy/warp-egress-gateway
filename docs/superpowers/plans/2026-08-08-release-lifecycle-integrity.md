# Release Lifecycle Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the v0.4.0 payload deterministically upgradeable and releasable with verified source versioning and complete local validation.

**Architecture:** The installed bootstrap helper validates the selected Git release source before calling the existing host upgrader. A shell runner composes focused static tests. Packaging becomes dependency-strict and validates an extracted archive and a clean Git overlay.

**Tech Stack:** Bash, Python 3, Git, tar, zip/unzip, PowerShell publisher checks, GitHub Actions.

## Global Constraints

- Work only in this fixed2 payload.
- Preserve fail-closed firewall/host-guard ordering, IPv4 normalization, root-only backups, and WARP identity.
- Never push, tag, create a release, or contact production systems.
- Require all three v0.4.0 release artifacts.

---

### Task 1: Verify bootstrap source identity

**Files:**
- Modify: `shared/upgrade/remote-upgrade.sh`
- Modify: `tests/upgrade.sh`
- Modify: `docs/upgrade.md`

- [ ] Add test assertions for a `validate_checked_out_version` helper, canonical tag/version equivalence, malformed version rejection, and absent version rejection.
- [ ] Run `bash tests/upgrade.sh` and observe the new assertions fail before implementation.
- [ ] Add strict semantic-version parsing and call the helper after clone but before `upgrade.sh`.
- [ ] Re-run `bash tests/upgrade.sh` and confirm it passes.

### Task 2: Make validation deterministic

**Files:**
- Create: `tests/run-all.sh`
- Modify: `tests/whitespace.sh`
- Modify: `Makefile`
- Modify: `tests/syntax.sh`
- Modify: `tests/docs.sh`

- [ ] Add failing static checks that require the runner, explicit Python prerequisite handling, and `make test` delegation.
- [ ] Run the focused tests and observe failure.
- [ ] Implement the runner with mandatory-prerequisite checks and PASS/FAIL reporting; make the whitespace test fail clearly without Python 3.
- [ ] Re-run the focused tests and the runner.

### Task 3: Enforce complete release packaging

**Files:**
- Modify: `scripts/package-release.sh`
- Modify: `tests/package.sh`
- Modify: `tests/publisher.sh`
- Modify: `docs/release-process.md`

- [ ] Add failing package/publisher assertions for mandatory ZIP output, required tools, extraction validation, and clean overlay staging.
- [ ] Run package/publisher tests and observe failure.
- [ ] Implement strict packaging dependency checks and archive-payload/overlay verification.
- [ ] Re-run the focused tests.

### Task 4: Integrate lifecycle evidence

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `WINDOWS-PUBLISH.md`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- Test: `tests/run-all.sh`

- [ ] Add failing doc/metadata assertions for the canonical command and implemented integrity guarantees.
- [ ] Update user documentation and CI to use the runner; preserve tag/version validation.
- [ ] Run the full runner, package source and extracted payload, inspect files manually, and record unavailable checks honestly.
