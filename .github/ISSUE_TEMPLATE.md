## Environment

- Project version:
- Distribution/version:
- Kernel:
- Hypervisor/cloud:

## Topology

Sanitize all real public IPs and secrets.

## Expected behavior

## Actual behavior

## Diagnostics

Attach sanitized output from:

```bash
sudo warp-gateway diagnostics
```

Never attach a WireGuard private key or `wgcf-account.toml`.
