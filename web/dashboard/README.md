# WARP Gateway Read-Only Dashboard

This package contains a standard-library-only collector, strict status schema,
explicit-IPv4 HTTP server, local fixtures, and vanilla frontend. It does not
import the privileged helper and exposes no control endpoints.

Launch the local healthy demo from the repository root:

```bash
python3 -m web.dashboard.server --fixture healthy --listen 127.0.0.1 --port 8787
```

Open `http://127.0.0.1:8787`. Other fixture names are `degraded` and `failed`.

The default listener is loopback only. An operator may explicitly bind one
concrete management IPv4 with `--listen 192.0.2.10`; wildcard, IPv6, hostname,
multicast, and limited-broadcast listeners are rejected. There is no TLS or
application authentication in this phase, so anyone with TCP access to a
management-bound address and port can view the sanitized read-only dashboard.
Protect direct access with host and management-network firewall or ACL policy.

The production snapshot path is fixed at:

```text
/run/warp-egress-dashboard/status.json
```

Production directory/file metadata is `root:warp-web 0750` and
`root:warp-web 0640`, respectively. This repository phase does not install or
deploy those objects.
