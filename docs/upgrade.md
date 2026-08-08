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
sudo warp-gateway upgrade --ref v0.4.0
```

Preview without changing the host:

```bash
sudo warp-gateway upgrade --dry-run
```

Non-interactive maintenance window:

```bash
sudo warp-gateway upgrade --ref v0.4.0 --yes
```

Before host changes, the bootstrap resolves the requested tag to one exact Git object, checks out that object detached, and requires the downloaded `VERSION` to be the same value as the requested tag without the `v` prefix. For example, a requested tag `v0.4.0` must contain exactly `VERSION=0.4.0`. A missing, malformed, or mismatched `VERSION`, an unresolvable ref, or a checkout that does not match the resolved object stops the upgrade before the backup or service-maintenance phase. There is no fallback to another ref.

`--ref main` remains an explicit unreleased-code path. It is resolved to an exact branch object and still requires a valid semantic `VERSION`; use it only for intentional non-production testing.

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
sudo warp-gateway-upgrade --mode docker --ref v0.4.0
```

A separate, newly cloned release checkout can also run `sudo bash upgrade.sh --mode docker`. Do not `git pull` the live Docker project tree before the upgrader has captured its rollback copy.

The upgrader discovers the current Docker Compose working directory from the running `warp-egress-gateway` container, stages the new source beside the current project, copies `docker/state`, `docker/generated`, and `.env`, keeps the independent host kill switch active, rebuilds the image, and waits for a healthy container.

## What is backed up

Backups are stored under:

```text
/var/backups/warp-egress-gateway/upgrade-YYYYMMDD-HHMMSS/
```

The directory is root-only and contains `manifest.env` plus the deployment-specific rollback data.

Native backups include the installed configuration, WARP profile, management scripts, systemd units, routing/sysctl metadata, and journald retention configuration.

Docker upgrades retain the previous project tree beside the live project and record its path in the backup manifest. Host guard files are also backed up.

## Configuration behavior

The upgrader preserves the existing deployment settings. During Native upgrade it forces `MANAGE_TRANSIT_ADDRESS=false` in the upgrade input because the transit address already exists; this prevents a software upgrade from unnecessarily reapplying Netplan.

New configuration keys may use release defaults until an operator explicitly sets them.

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
