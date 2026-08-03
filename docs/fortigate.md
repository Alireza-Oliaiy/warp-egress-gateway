# FortiGate integration

This project treats FortiGate as the policy engine and Ubuntu as a transparent next hop.

## Recommended transit design

```text
FortiGate: 10.1.1.229/30
Ubuntu:    10.1.1.230/30
```

## FortiGate responsibilities

- Match selected services using ISDB, address objects, policy routes, or SD-WAN policy.
- Set Ubuntu transit IP as the next hop.
- SNAT traffic to the FortiGate transit IP for the simplest return path.
- Ensure Ubuntu's uplink/management source is excluded from redirection.
- Allow TCP and UDP, including UDP/443 for Google QUIC.
- Keep existing proxy/SD-WAN paths as fallback where required.

## Source expected by Ubuntu

With FortiGate SNAT enabled:

```bash
TRUSTED_SOURCE_CIDR="10.1.1.229/32"
```

Without FortiGate SNAT, configure a CIDR covering actual client sources and ensure the Ubuntu return path reaches those client networks through FortiGate. The SNAT design is recommended for the initial deployment.

## Monitoring

Do not monitor only the Ubuntu transit IP. The host can remain reachable while WARP is unavailable.

Use the gateway health command or export diagnostics:

```bash
sudo warp-gateway health
sudo warp-gateway diagnostics
```

For automated failover, integrate an external monitor with a dedicated health endpoint or command execution mechanism appropriate to the environment.
