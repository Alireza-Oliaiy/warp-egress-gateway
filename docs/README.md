# Documentation index

This directory is the operational documentation for WARP Egress Gateway. Changes that alter installation, upgrade, rollback, security, networking, monitoring, or operator commands must update the matching document in the same release.

## Start here

- [Architecture](architecture.md) — packet flow, routing model, and component boundaries.
- [Native deployment](deployment.md) — Ubuntu/systemd installation.
- [Docker deployment](docker.md) — Linux Docker Engine installation and host guard.
- [FortiGate integration](fortigate.md) — upstream next-hop and policy guidance.

## Lifecycle and operations

- [Upgrade](upgrade.md) — supported upgrade paths, one-command upgrade, dry-run, and validation.
- [Rollback](rollback.md) — automatic and manual rollback procedures.
- [Migration](migration.md) — bringing a manual/legacy gateway under repository management.
- [Operations](operations.md) — routine status, health, logs, maintenance, and incident commands.
- [Monitoring](monitoring.md) — seven-day journald retention and passive path monitoring.
- [Troubleshooting](troubleshooting.md) — common failures and evidence collection.

## Project governance

- [Security model](security.md) — fail-closed behavior and trust boundaries.
- [Release process](release-process.md) — versioning, required tests/docs, tags, release artifacts, and publishing checklist.
- [Contributing](../CONTRIBUTING.md) — contribution requirements.
- [Security policy](../SECURITY.md) — supported versions and vulnerability reporting.
