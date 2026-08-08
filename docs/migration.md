# Migrate an existing gateway

> This page is for bringing a manual or non-repository-managed gateway under project management. If the host already runs a repository release and only needs a newer version, use [Upgrade](upgrade.md) instead.

This procedure upgrades a manually configured host to the repository-managed layout without creating a new WARP identity.

## Reference existing configuration

Example:

```text
ens33 = 172.20.31.5/24, default gateway 172.20.31.254
ens35 = 10.1.1.230/30
FortiGate source = 10.1.1.229
warp0 = existing WARP interface
```

## Steps

1. Schedule a brief maintenance window.
2. Clone the repository on the gateway.
3. Create `native/config/warp-gateway.env` using the existing interface/IP values.
4. Keep `MANAGE_TRANSIT_ADDRESS=false`.
5. Reuse the existing profile:

```bash
sudo ./native/install.sh \
  --config native/config/warp-gateway.env \
  --profile /etc/wireguard/warp0.conf
```

The installer backs up the existing WARP configuration before writing the normalized profile.
From version `0.3.3`, normalization also removes the unused WARP IPv6 interface address and IPv6 AllowedIPs because the gateway data path is IPv4-only. This prevents `wg-quick` startup failures on hosts where IPv6 is disabled while preserving the existing WARP identity.

## Important safety improvement

The repository uses two independent services:

- `warp-gateway-firewall.service`
- `warp-gateway.service`

The firewall service remains loaded when the route/tunnel stops. This replaces older single-service layouts where an `ExecStop` action removed the firewall and could permit transit traffic to fall back through the management uplink.

## Post-migration checks

```bash
sudo systemctl status warp-gateway-firewall.service
sudo systemctl status wg-quick@warp0.service
sudo systemctl status warp-gateway.service
sudo warp-gateway status
```

Then reboot and repeat the checks before returning the full FortiGate policy to production.
