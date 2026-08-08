# Changelog

## 0.4.0 - 2026-08-08

- Fixed qualification-discovered false monitor failures: a stale WireGuard
  handshake is now `STATUS=WARN` when the active WARP trace proves the
  dataplane is working; actual WARP or safety-check failures remain `FAIL`.
- Fixed qualification-discovered backup permissions: every timestamped upgrade
  backup and `rootfs` directory is now explicitly `root:root` mode `0700`,
  while manifests and Native upgrade configuration copies are mode `0600`.
- Sanitized public examples to use documentation-only network ranges and removed
  internal planning artifacts.
- Minimized release archives by excluding contributor, CI, internal planning,
  and generated runtime material while retaining runtime upgrade checks.
- Added managed upgrade, rollback, version reporting, release lifecycle documentation, and production-oriented operator workflows.
- Hardened Windows publishing so tracked files intentionally removed by a new release are staged before line-ending renormalization.
- Hardened release packaging to preserve tracked Docker placeholder directories while still excluding generated runtime state and secrets.
- Added publisher and release-package regression tests to the required release test suite.
- Added a repository whitespace/EOF regression gate so trailing whitespace and extra blank lines at EOF fail before publish.
- Hardened bootstrap upgrades: stable tags now resolve to an exact Git object and must match the downloaded semantic `VERSION`; missing, malformed, or mismatched versions fail before host changes.
- Added `bash tests/run-all.sh` as the canonical deterministic validation command, with clear mandatory-prerequisite failures and explicit PASS/FAIL/SKIP reporting.
- Made ZIP, TAR.GZ, and SHA256SUMS mandatory release artifacts; ZIP creation now uses Python 3 safely when `zip` is unavailable, and package regression coverage validates an extracted payload plus a clone-like Git overlay.

- Added a supported in-place upgrade framework for Native and Docker deployments with mode detection, root-only backups, maintenance-window validation, and automatic rollback on failed post-upgrade health checks.
- Added installed upgrade/rollback helpers and Native `warp-gateway version`, `upgrade`, and `rollback` commands.
- Added legacy 0.3.x upgrade instructions that preserve the existing WARP identity instead of registering a new account.
- Added dedicated upgrade, rollback, operations, documentation-index, and release-process runbooks.
- Added release governance: Semantic Versioning guidance, documentation definition-of-done, pull-request checklist, release metadata tests, and GitHub tag-driven release artifacts with SHA256 checksums.
- Updated the Windows publisher to run the complete regression suite and optionally create/push the `vX.Y.Z` release tag.
- Added managed upgrade/rollback regression checks and documentation completeness checks to CI.

## 0.3.3 - 2026-08-08

- Fixed startup failure on hosts with IPv6 disabled when `wgcf` profiles contain an IPv6 interface address.
- Native and Docker deployments now normalize WARP profiles to the project's IPv4-only data path before `wg-quick` starts.
- The normalizer preserves the WARP identity and IPv4 address while removing IPv6 from `Address` and forcing `AllowedIPs = 0.0.0.0/0`.
- Added a regression test covering generated/imported dual-stack WARP profiles so this failure cannot silently return.

## 0.3.2 - 2026-08-08

- Added persistent systemd journal retention for seven days with compression and bounded disk usage.
- Added passive one-minute WARP path monitoring for Native deployments with structured `warp-monitor` journal records.
- Added equivalent one-minute structured monitoring to the Docker runtime and routed Docker logs to journald.
- Monitoring records WireGuard state, handshake age, direct Internet, WARP Internet, upstream transit reachability, policy routing, and nftables state.
- Added `warp-gateway history` and `warp-gateway failures` commands for seven-day incident review.
- Changed new-install `AUTO_RECOVER` default to `false` so failures are preserved for root-cause analysis before optional automated recovery.
- Extended diagnostics, status output, CI/static tests, and documentation for the new observability layer.

## 0.3.1 - 2026-08-03

- Fixed native and Docker status output so all three interfaces are displayed.
- Added Windows-safe publishing automation with Git executable-mode handling.
- Added `.gitattributes` to enforce LF line endings for shell scripts.
- Made the top-level selector invoke child installers through Bash, reducing dependency on extracted filesystem permissions.
- Updated documentation to use `sudo bash setup.sh`, which is resilient even before executable modes are restored.

## 0.3.0 - 2026-08-03

- Split the repository into `native/` and `docker/` deployment editions.
- Added a top-level deployment selector that asks for Native or Docker mode.
- Added a Docker Compose runtime using Linux host networking and scoped `NET_ADMIN`/`NET_RAW` capabilities.
- Added automatic Docker host discovery from the main IP and transit IP/CIDR.
- Added a persistent host-level Docker kill switch independent of container health.
- Added Docker health checks, automatic WARP recovery, state persistence, status commands, and uninstaller.
- Documented the Linux-only transparent Docker gateway constraint.

## 0.2.0 - 2026-08-03

- Added a two-address interactive setup wizard.
- Added automatic interface and default-gateway discovery.
- Added `/30` peer derivation and optional Netplan transit configuration.
- Preserved the fail-closed kill-switch design.

## 0.1.0 - 2026-08-03

- Initial reusable native Ubuntu gateway implementation.
