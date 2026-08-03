# Deployment guide

## 1. Prepare the host

Use a dedicated Ubuntu or Debian VM. Two interfaces are recommended:

- Uplink/management interface with the host default gateway
- Transit interface connected to the upstream firewall/router

Confirm:

```bash
ip -br address
ip -4 route
```

## 2. Configure the project

```bash
cp native/config/warp-gateway.env.example native/config/warp-gateway.env
editor native/config/warp-gateway.env
```

Keep `MANAGE_TRANSIT_ADDRESS=false` when Netplan or another system already manages the transit IP.

## 3. Install

Fresh WARP identity:

```bash
sudo ./native/install.sh --config native/config/warp-gateway.env
```

Existing identity:

```bash
sudo ./native/install.sh \
  --config native/config/warp-gateway.env \
  --profile /etc/wireguard/warp0.conf
```

## 4. Validate the host

```bash
sudo warp-gateway status
sudo systemctl --failed
```

Confirm:

- Main default route still uses the uplink interface.
- WARP table has `default dev warp0`.
- `warp=on` appears in the trace.
- Firewall counters exist.

## 5. Test one upstream source

Route a single client or test destination through the gateway before moving a production service group.

```bash
sudo watch -n1 'nft list table inet warp_gateway; wg show warp0'
```

## 6. Test failure behavior

Use:

```bash
sudo warp-gateway lockdown
```

Traffic from the transit interface must stop. The host management path must remain available. Restore with:

```bash
sudo warp-gateway start
```

## 7. Enable production policy

Move only the intended destination group on the upstream firewall. Keep a fallback path available.
