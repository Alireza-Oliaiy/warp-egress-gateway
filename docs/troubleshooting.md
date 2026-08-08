# Troubleshooting

## WARP interface is up but no handshake

```bash
sudo wg show warp0
sudo tcpdump -ni <uplink-interface> udp port 2408
```

Check UDP reachability, DNS resolution for the endpoint, and upstream firewall policy.

A stale or absent handshake timestamp is recorded as `STATUS=WARN`, rather
than a failure, only when the active WARP trace still returns `warp=on` and all
other monitor checks are healthy. A failed WARP trace remains `STATUS=FAIL`.

## Host Internet works but forwarded traffic does not

```bash
sudo ip -4 rule
sudo ip -4 route show table 100
sudo nft list table inet warp_gateway
sudo conntrack -L | head
```

Verify the actual source arriving from the firewall matches `TRUSTED_SOURCE_CIDR`.

## Kill-switch counter increases

Linux selected an egress other than WARP for transit traffic. Check:

```bash
sudo systemctl status wg-quick@warp0.service
sudo systemctl status warp-gateway.service
sudo ip route get 8.8.8.8 from <trusted-source-ip> iif <transit-interface>
```

## TCP works but some sites stall

Inspect MSS and MTU:

```bash
sudo nft list table inet warp_gateway
ip link show warp0
```

The default profile uses MTU 1280 and TCP MSS 1240. Adjust carefully if the underlay requires a different value.

## QUIC does not work

Ensure the upstream firewall passes UDP/443 and that its selected route applies to UDP as well as TCP.

## Health check fails but traffic appears active

Run:

```bash
sudo warp-gateway health
sudo journalctl -u warp-gateway-healthcheck.service -n 100 --no-pager
```

The configured trace URL must return a line exactly equal to `warp=on`.


## Review an intermittent outage from the last week

Native deployment:

```bash
sudo warp-gateway history
sudo warp-gateway failures
journalctl -t warp-monitor --since "7 days ago" --no-pager -o short-iso
```

The structured record separates direct Internet, WARP, handshake freshness, upstream transit, policy routing, and nftables state. System and kernel logs are retained persistently for the same seven-day window.

Docker deployment:

```bash
journalctl CONTAINER_TAG=warp-egress-gateway --since "7 days ago" --no-pager
```

## Collect diagnostics

```bash
sudo warp-gateway diagnostics
```

The output file is mode `0600`. Review it before sharing because it contains network addressing and operational metadata, though not the WireGuard private key.

## `wg-quick` fails because IPv6 is disabled

`wgcf` commonly generates a dual-stack profile. This project currently routes only IPv4 transit traffic. Since version `0.3.3`, both Native and Docker deployments normalize the runtime WARP profile to keep only the IPv4 interface address and `AllowedIPs = 0.0.0.0/0` before `wg-quick` starts. The WARP private/public identity is preserved.

For older installations, a failure containing `Error: ipv6: IPv6 is disabled on this device` means the installed `warp0.conf` still contains an IPv6 `Address`. Upgrade to `0.3.3` or newer rather than enabling IPv6 only to work around the profile mismatch.

## Upgrade or rollback failure

Do not remove the kill switch/host guard to make traffic pass. Keep the upstream firewall on fallback, preserve `/var/backups/warp-egress-gateway/upgrade-*`, and inspect the backup `manifest.env`.

Native evidence:

```bash
sudo warp-gateway failures
sudo journalctl -u wg-quick@warp0.service -u warp-gateway.service --since '1 hour ago' --no-pager
```

If an upgrade failed after the backup was created, follow [Rollback](rollback.md).
