# Security policy

## Supported versions

Only the latest tagged release is supported.

## Reporting a vulnerability

Do not publish private keys, WARP account files, internal addressing, or diagnostic bundles in a public issue.

Open a private security advisory in the GitHub repository and include:

- Affected version
- Reproduction steps
- Expected and actual behavior
- Whether the issue can cause direct-uplink traffic leakage
- Sanitized logs or packet-flow details

## High-impact areas

Changes affecting these areas require explicit failure-path testing:

- nftables kill-switch ordering
- systemd stop/restart behavior
- policy-rule removal or fallback behavior
- WARP profile/secret permissions
- uninstall and upgrade flows
- Docker host-network capability scope and image provenance
- independent `warp_docker_guard` persistence when the container stops
- accidental inclusion of `docker/state` or generated WARP identities in build context or Git
