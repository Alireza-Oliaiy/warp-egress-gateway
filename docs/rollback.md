# Rollback guide

Every supported upgrade creates a backup before modifying the runtime. The backup directory is printed by `upgrade.sh` and stored under `/var/backups/warp-egress-gateway/`.

## List upgrade backups

```bash
sudo ls -1dt /var/backups/warp-egress-gateway/upgrade-* 2>/dev/null
```

Inspect a backup manifest:

```bash
sudo cat /var/backups/warp-egress-gateway/upgrade-YYYYMMDD-HHMMSS/manifest.env
```

The manifest records the mode, previous version, target version, host, and timestamp. Docker manifests also record the previous project tree. Backup directories are `root:root` mode `0700`; manifests and Native upgrade configuration copies are mode `0600`.

## Manual rollback command

From a release checkout:

```bash
sudo bash rollback.sh \
  --backup /var/backups/warp-egress-gateway/upgrade-YYYYMMDD-HHMMSS
```

After `0.4.0`, the helper is also installed on the host:

```bash
sudo warp-gateway rollback \
  --backup /var/backups/warp-egress-gateway/upgrade-YYYYMMDD-HHMMSS
```

Docker hosts can call:

```bash
sudo warp-gateway-rollback \
  --backup /var/backups/warp-egress-gateway/upgrade-YYYYMMDD-HHMMSS
```

## Native rollback behavior

Rollback stops periodic health actions and the WARP route/tunnel, restores the backed-up managed files, reloads systemd, then restarts firewall, WireGuard, policy routing, and available timers. The fail-closed firewall remains the safety boundary during the operation.

Validate immediately:

```bash
sudo warp-gateway status
sudo warp-gateway health
```

## Docker rollback behavior

The upgrader keeps the previous project tree as:

```text
<project>.preupgrade-YYYYMMDD-HHMMSS
```

Rollback stops the new Compose project, swaps the previous project tree back into the original path, restores the host guard backup, starts the host guard, and brings Compose up again.

Validate:

```bash
docker ps --filter name=warp-egress-gateway
docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' warp-egress-gateway
```

## If rollback fails

1. Keep the upstream firewall policy on fallback/disabled for this next hop.
2. Do not remove the kill switch just to make traffic pass.
3. Preserve the backup directory and journals.
4. Capture diagnostics and service/container logs.
5. Restore the previous WARP profile and runtime from the backup only after identifying which rollback step failed.
