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
- Exact source/ingress policy-rule and WARP-table health.
- nftables gateway table health.

`STATUS=FAIL` means a required dataplane or safety check failed: interface,
direct path, WARP `warp=on` probe, route, nftables table, or required upstream
reachability. `STATUS=WARN` means the active WARP probe is healthy but the
latest WireGuard handshake is stale or absent. Handshake age remains useful
telemetry, but it is not stronger evidence than a successful current WARP
trace. `warp-gateway failures` intentionally shows only `STATUS=FAIL` records.

The `route` field is `ok` only when both configured priorities select the
expected WARP source/transit interface and table, and that table has
`default dev WARP_IF`. Failure values identify the drift layer, for example
`source_rule_missing`, `ingress_rule_mismatch`, or
`default_route_missing`.

Probe failures are health data, not monitor process errors. A curl timeout is
recorded as `STATUS=FAIL`, `warp=fail`, and `warp_rc=28`; the sample process
still exits normally after emitting/logging the complete record. Nonzero
monitor process exit is reserved for configuration or internal errors.

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

The Docker edition runs the same shared structured sample from the gateway
container every `MONITOR_INTERVAL` seconds. The Compose service uses the
`journald` logging driver, so the host seven-day journal retention applies to
the container records as well. The container loop parses `STATUS`; it does not
depend on a health-failure exit code from the passive monitor.

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

Starting in `0.4.1`, exact policy-routing drift is the deliberately narrow
exception to `AUTO_RECOVER=false`. Native health checks and the Docker loop may
reapply only project-owned routing after verifying WireGuard and the kill
switch. A full WireGuard restart still requires `AUTO_RECOVER=true`, healthy
direct/safety/routing state, and evidence that the WARP tunnel/dataplane itself
failed.
