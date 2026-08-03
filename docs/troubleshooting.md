# Troubleshooting

## WARP interface is up but no handshake

```bash
sudo wg show warp0
sudo tcpdump -ni <uplink-interface> udp port 2408
```

Check UDP reachability, DNS resolution for the endpoint, and upstream firewall policy.

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

## Collect diagnostics

```bash
sudo warp-gateway diagnostics
```

The output file is mode `0600`. Review it before sharing because it contains network addressing and operational metadata, though not the WireGuard private key.
