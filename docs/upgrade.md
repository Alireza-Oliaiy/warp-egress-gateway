# Upgrade guide

WARP Egress Gateway includes a supported in-place upgrade path for both Native and Docker editions starting with release `0.4.0`.

The upgrade process is designed around four rules:

1. Preserve the existing WARP identity and deployment configuration.
2. Keep the fail-closed firewall/host guard active during the maintenance window.
3. Create a root-only backup before changing the runtime.
4. Validate the WARP path after the upgrade and automatically roll back if validation fails.

A brief WARP-path interruption is expected. The management/uplink default route is not intentionally changed by the upgrader.

## Before upgrading

- Schedule a maintenance window.
- Confirm upstream fallback behavior on the firewall/router if the path is business critical.
- Confirm the current gateway is healthy.
- Do not delete `/etc/wireguard/warp0.conf`, Docker `state/`, or the backup directory created by the upgrader.

Native health check:

```bash
sudo warp-gateway status
sudo warp-gateway health
```

## Native: normal upgrade from 0.4.0 or newer

The installed management command resolves the highest semantic-version `vX.Y.Z` tag by default, fetches that immutable release, and invokes the safe upgrader:

```bash
sudo warp-gateway upgrade
```

You can also pin a specific reviewed release tag:

```bash
sudo warp-gateway upgrade --ref vX.Y.Z
```

Preview without changing the host:

```bash
sudo warp-gateway upgrade --dry-run
```

Non-interactive maintenance window:

```bash
sudo warp-gateway upgrade --ref vX.Y.Z --yes
```

Before host changes, the bootstrap resolves the requested tag to its exact remote
Git object and fetches that pinned object. Release tags may be lightweight or
annotated. The bootstrap deterministically peels the pinned object to a commit,
checks out that exact commit detached, and verifies `HEAD` against the peeled
commit while retaining the original tag-object identity for audit. The downloaded
`VERSION` must still be the requested semantic tag without the `v` prefix. For
example, a requested tag `v1.2.3` must contain exactly `VERSION=1.2.3`. A missing,
malformed, or mismatched `VERSION`, an unresolvable ref, an object that cannot peel
to a commit, or a checkout that differs from the peeled commit stops the upgrade
before the backup or service-maintenance phase. There is no fallback to another
ref.

`--ref main` remains an explicit unreleased-code path. It is resolved to an exact branch object and still requires a valid semantic `VERSION`; use it only for intentional non-production testing.

## v0.5.0 annotated-tag compatibility bridge

The remote bootstrap installed by `v0.5.0` rejects normal annotated release tags
before any host mutation. It correctly pins the tag object and checks out the
tagged commit, but then incorrectly compares the checked-out commit OID with the
distinct annotated-tag object OID. `v0.5.1` fixes that comparison without changing
the project's annotated-tag release policy. Do not delete, recreate, or replace
an existing release tag to work around the issue.

For the first upgrade from a host running the affected bootstrap, download the
official `v0.5.1` release archive and checksum manifest, verify the archive, and
invoke its top-level upgrader directly:

```bash
mkdir warp-egress-gateway-0.5.1-bridge
cd warp-egress-gateway-0.5.1-bridge
curl -fLO https://github.com/Alireza-Oliaiy/warp-egress-gateway/releases/download/v0.5.1/warp-egress-gateway-0.5.1.tar.gz
curl -fLO https://github.com/Alireza-Oliaiy/warp-egress-gateway/releases/download/v0.5.1/warp-egress-gateway-0.5.1-SHA256SUMS.txt
grep ' warp-egress-gateway-0.5.1.tar.gz$' warp-egress-gateway-0.5.1-SHA256SUMS.txt | sha256sum -c -
tar -xzf warp-egress-gateway-0.5.1.tar.gz
cd warp-egress-gateway-0.5.1
sudo bash upgrade.sh --mode native --dry-run
sudo bash upgrade.sh --mode native --yes
```

Use `--mode docker` instead on an affected Docker host. After `v0.5.1` is
installed, subsequent upgrades can use the normal `warp-gateway upgrade --ref
vX.Y.Z` bootstrap path.

## Legacy Native upgrade from 0.3.x

Versions before `0.4.0` do not have the installed `upgrade` command. Fetch a current release checkout and run the universal upgrader:

```bash
cd /opt
git clone https://github.com/Alireza-Oliaiy/warp-egress-gateway.git warp-egress-gateway-upgrade
cd warp-egress-gateway-upgrade
sudo bash upgrade.sh --mode native
```

The upgrader reuses the existing `/etc/wireguard/<WARP_IF>.conf`; it does not register a new WARP identity.

## Docker upgrade

Prefer the installed remote bootstrap after `0.4.0` so the live Compose source tree is not modified before the backup is created:

```bash
sudo warp-gateway-upgrade --mode docker --ref vX.Y.Z
```

A separate, newly cloned release checkout can also run `sudo bash upgrade.sh --mode docker`. Do not `git pull` the live Docker project tree before the upgrader has captured its rollback copy.

The upgrader discovers the current Docker Compose working directory from the running `warp-egress-gateway` container, stages the new source beside the current project, copies `docker/state`, `docker/generated`, and `.env`, keeps the independent host kill switch active, rebuilds the image, and waits for a healthy container.

## What is backed up

Backups are stored under:

```text
/var/backups/warp-egress-gateway/upgrade-YYYYMMDD-HHMMSS/
```

`/var/backups/warp-egress-gateway`, each timestamped `upgrade-*` directory, and
its `rootfs` directory are explicitly created as `root:root` mode `0700`.
`manifest.env` and Native `upgrade-config.env` are mode `0600`. The backup
therefore contains sensitive configuration and WARP material without exposing
it to group or other users.

Native backups include the installed configuration, WARP profile, management scripts, systemd units, routing/sysctl metadata, and journald retention configuration.

Docker upgrades retain the previous project tree beside the live project and record its path in the backup manifest. Host guard files are also backed up.

## Configuration behavior

The upgrader preserves the existing deployment settings. During Native upgrade it forces `MANAGE_TRANSIT_ADDRESS=false` in the upgrade input because the transit address already exists; this prevents a software upgrade from unnecessarily reapplying Netplan.

New configuration keys may use release defaults until an operator explicitly sets them.

## v0.4.1 routing recovery behavior

The `0.4.1` runtime validates live policy rules instead of relying on the
oneshot routing service's active state. After upgrade, the periodic Native
healthcheck and Docker monitor loop can restore only the project-owned rules
and WARP-table default if host network reconciliation removes them. This
policy-only action is permitted with `AUTO_RECOVER=false`; it verifies the
WireGuard interface and kill switch first and never changes the main default
route. Full tunnel restart remains controlled by `AUTO_RECOVER=true`.

## Post-upgrade validation

Native:

```bash
sudo warp-gateway version
sudo warp-gateway health
sudo warp-gateway monitor
sudo systemctl is-active warp-gateway-firewall.service
sudo systemctl is-active wg-quick@warp0.service
sudo systemctl is-active warp-gateway.service
sudo systemctl is-active warp-gateway-healthcheck.timer
sudo systemctl is-active warp-monitor.timer
```

WARP trace:

```bash
warp_ip=$(ip -4 -o address show dev warp0 | awk 'NR==1 {split($4,a,"/"); print a[1]}')
curl -4 --interface "$warp_ip" -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|colo|loc|warp)='
```

Expected:

```text
warp=on
```

For a major operational change, reboot once during the maintenance window and repeat the checks.

## Automatic rollback

If the installer or post-upgrade health validation fails, `upgrade.sh` attempts to restore the pre-upgrade backup automatically while keeping the fail-closed control in place.

If automatic rollback cannot complete, do not disable the kill switch to restore traffic. Follow [Rollback](rollback.md) and inspect the backup manifest.

## Security note

`warp-gateway upgrade` fetches executable code from the configured Git repository. Its default is the highest `vX.Y.Z` tag; `--ref main` is intentionally opt-in for unreleased code. The bootstrap verifies the requested stable-tag identity and semantic `VERSION`, but operators should still independently review the release/tag before production rollout.
