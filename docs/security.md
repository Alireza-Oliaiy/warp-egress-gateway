# Security model

## Trust boundary

The transit interface is treated as a dedicated routed handoff. Only `TRUSTED_SOURCE_CIDR` may forward through WARP.

## Secret handling

The following must never be committed:

- `wgcf-account.toml`
- Generated WARP WireGuard profiles
- Private keys
- Operator-specific deployment configuration containing sensitive network data

The installer stores:

```text
/etc/wireguard/<interface>.conf       mode 0600
/var/lib/warp-egress-gateway/         mode 0700
/etc/warp-egress-gateway/             mode 0700
```

## Kill-switch independence

Firewall lifetime is intentionally separate from tunnel lifetime. The project does not remove the firewall during a normal service stop.

Only the explicit uninstall flow removes the nftables table.

## Dedicated host recommendation

Use a dedicated VM. Although the nftables rules are scoped to `TRANSIT_IF`, combining unrelated routing, container networking, or third-party VPN software on the same host increases operational risk.

## Upstream controls

Restrict management access to trusted administrative networks. Do not expose SSH or other management services through the transit handoff unless explicitly intended.

## Consumer service considerations

Treat consumer WARP as a non-dedicated, non-SLA egress path. Retain a fallback path for critical services and monitor application-level reachability, not only tunnel handshake.

## Docker security boundary

The Docker edition deliberately does not use `privileged: true`. It uses host networking plus `NET_ADMIN` and `NET_RAW`, which are powerful capabilities and should only be granted to trusted images built from this repository.

The independent `warp_docker_guard` nftables table is installed on the host. Container shutdown removes the runtime route and WireGuard interface but does not remove that host guard. Explicit uninstall is required to remove it.

Do not run the Docker edition on a shared, untrusted Docker host. The container can modify the host networking namespace by design.
