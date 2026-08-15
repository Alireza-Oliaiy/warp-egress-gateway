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

Ordinary runtime recovery never removes or replaces the kill switch. Before a
policy-only repair, the gateway verifies the WARP interface, WireGuard state,
WARP IPv4 address, and the `WARP_KILL_SWITCH` nftables rule. A missing safety
rule blocks repair and leaves the path failed closed. Repair only replaces the
configured WARP-table default and the two project-owned rule priorities; it
does not create or change the host main-table default route.

At boot, IPv4 forwarding defaults to disabled. The Native firewall and Docker
host guard require and start after `systemd-sysctl.service`, then run as early
`sysinit.target` services ordered before
`network-pre.target`; each installs the nftables guard atomically before it
enables forwarding. WireGuard, policy routing, and Docker then start only in
the protected order. This prevents a transient transit-to-uplink forwarding
path during boot or a guard-install failure.

`AUTO_RECOVER=false` disables disruptive tunnel restart, but it does not
disable deterministic restoration of project-owned policy routing. This
exception is safe because routing is restored only behind the already-active
kill switch and is verified before a WARP dataplane probe is accepted.

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

## Upgrade and rollback safety

The supported upgrader treats the fail-closed control as independent from the runtime being replaced. Native upgrades pause health timers but keep `warp-gateway-firewall.service` loaded. Docker upgrades stop/rebuild the container while keeping `warp-egress-docker-guard.service` active.

`/var/backups/warp-egress-gateway`, each upgrade directory, and its `rootfs` are explicitly `root:root` mode `0700`. `manifest.env` and Native `upgrade-config.env` are mode `0600`. Backups can contain configuration and WARP profile material, so they must be handled as sensitive administrative data. Remote upgrades should be pinned to a reviewed immutable tag with `--ref vX.Y.Z`.
