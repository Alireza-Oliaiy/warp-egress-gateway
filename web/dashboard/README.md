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
`root:warp-web 0640`, respectively.

## Production installation

The committed production assets are under `web/dashboard/deploy`. From an
extracted release or repository checkout:

```bash
cd web/dashboard/deploy
cp dashboard.env.example dashboard.env
```

Edit `dashboard.env` to contain one explicit listener and TCP port:

```text
DASHBOARD_LISTEN=192.0.2.10
DASHBOARD_PORT=8787
```

Then install:

```bash
sudo ./install.sh --config ./dashboard.env
```

Replace the documentation address with the gateway's management IPv4. The
installer validates the two-key configuration, creates or safely reuses the
locked `warp-web` system identity, installs only runtime files, runs the
collector once, starts the timer and web service, and verifies the exact
listener plus `/healthz` and `/api/status`.

An existing valid `/etc/warp-egress-dashboard/dashboard.env` is preserved when
the installer is rerun without `--config`. Passing `--config` explicitly is the
operator's request to replace it. The loopback-only example is installed on a
first run that omits `--config`.

Uninstall only the dashboard-owned components with:

```bash
sudo ./uninstall.sh
```

The product has no TLS or application authentication in v0.5.0. Restrict a
management-bound TCP/8787 listener with host and management-network ACL or
firewall policy. An SSH tunnel is not required when the browser has authorized
management-network access to the configured IPv4.
