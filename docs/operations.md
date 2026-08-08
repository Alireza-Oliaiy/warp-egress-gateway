# Operations runbook

This page is the short operator runbook for a deployed gateway.

## Native routine commands

```bash
sudo warp-gateway version
sudo warp-gateway status
sudo warp-gateway health
sudo warp-gateway monitor
sudo warp-gateway history
sudo warp-gateway failures
sudo warp-gateway logs
sudo warp-gateway diagnostics
```

## Native maintenance commands

Restart the managed path:

```bash
sudo warp-gateway restart
```

Fail closed intentionally while keeping the firewall loaded:

```bash
sudo warp-gateway lockdown
```

Start the path again:

```bash
sudo warp-gateway start
```

Upgrade:

```bash
sudo warp-gateway upgrade --ref vX.Y.Z
```

## Docker routine commands

```bash
cd /path/to/warp-egress-gateway/docker
docker compose ps
docker compose logs -f gateway
docker compose exec gateway /app/bin/status.sh
docker compose exec gateway /app/bin/healthcheck.sh
```

Upgrade:

```bash
sudo warp-gateway-upgrade --mode docker --ref vX.Y.Z
```

## Incident evidence

Do not restart repeatedly before collecting evidence when root-cause analysis is needed.

Native:

```bash
sudo warp-gateway failures
sudo warp-gateway diagnostics /root/warp-diagnostics.txt
sudo journalctl -t warp-monitor --since '2 hours ago' --no-pager -o short-iso
sudo journalctl -u wg-quick@warp0.service -u warp-gateway.service --since '2 hours ago' --no-pager
```

The default monitor is passive and `AUTO_RECOVER=false`, so failure evidence is not intentionally erased by an automatic restart loop.

## Backup retention

Upgrade backups contain sensitive network configuration and may contain the WARP WireGuard profile. Keep them root-only, copy them only to trusted administrative storage, and remove obsolete backups according to your operational retention policy.
