# Seven-day observability

Version 0.3.2 adds a passive observability layer designed to preserve enough history for incident root-cause analysis without changing the normal routing path.

## Journal retention

Both deployment modes install:

```text
/etc/systemd/journald.conf.d/10-warp-egress-gateway-retention.conf
```

with:

```ini
[Journal]
Storage=persistent
Compress=yes
MaxRetentionSec=7day
SystemMaxUse=1G
SystemKeepFree=2G
```

This keeps systemd, kernel, networking, WireGuard, and gateway logs across reboots for up to seven days while bounding disk usage.

## Native monitor

The Native edition installs `warp-monitor.timer`. It runs once per minute and writes one structured record with the syslog identifier `warp-monitor`.

A healthy record resembles:

```text
STATUS=OK wg=up handshake=ok handshake_age=18s direct=ok direct_rc=0 direct_ip=203.0.113.10 warp=on warp_rc=0 warp_ip=198.51.100.20 colo=SOF loc=BG upstream=ok route=ok nft=ok
```

The upstream ping uses `UPSTREAM_MONITOR_IP="auto"` by default, which derives an exact `/32` trusted peer. Set it to `off` when the upstream device intentionally blocks ICMP.

The record distinguishes:

- WireGuard interface state.
- Handshake freshness.
- Direct/uplink Internet reachability.
- WARP egress reachability and `warp=on`.
- Upstream firewall/router reachability when an exact peer IP is available.
- Policy-routing table health.
- nftables gateway table health.

Review the last seven days:

```bash
sudo warp-gateway history
```

Show only detected failures:

```bash
sudo warp-gateway failures
```

Run one passive sample immediately:

```bash
sudo warp-gateway monitor
```

Direct journal queries:

```bash
journalctl -t warp-monitor --since "7 days ago" --no-pager -o short-iso
journalctl -t warp-monitor --since "7 days ago" --no-pager -o short-iso | grep 'STATUS=FAIL'
```

## Docker monitor

The Docker edition runs the same style of structured sample from the gateway container every `MONITOR_INTERVAL` seconds. The Compose service uses the `journald` logging driver, so the host seven-day journal retention applies to the container records as well.

Examples:

```bash
journalctl CONTAINER_TAG=warp-egress-gateway --since "7 days ago" --no-pager
cd docker && docker compose logs --since 168h gateway
```

## Recovery policy

`AUTO_RECOVER` defaults to `false` in version 0.3.2. This is intentional: a failure is recorded without immediately replacing the evidence by restarting the tunnel.

After the environment has been observed and the failure mode is understood, automated recovery can be enabled in the deployment configuration:

```bash
AUTO_RECOVER="true"
```

The fail-closed kill switch remains independent of this setting.
