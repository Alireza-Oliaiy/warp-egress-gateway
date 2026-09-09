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

## Site-neutral runtime observations

The root collector reads only `UPLINK_IF`, `TRANSIT_IF`, `WARP_IF`, and
`ROUTING_TABLE_ID` from the fixed installed
`/etc/warp-egress-gateway/warp-gateway.env`. It never sources this file, uses an
environment/path override, or falls back to site-specific interface names.
Other configuration keys are ignored and are not copied into public telemetry.
The HTTP server still reads only the sanitized snapshot; it does not gain
configuration access, commands, or privileges.

Required declarations must occur exactly once. Bare, single-quoted and
double-quoted literal values are supported, matching the Native configuration
format; shell/export syntax and expansions are not supported. Interface names
match `[A-Za-z0-9][A-Za-z0-9_.-]{0,14}`, must be distinct, and cannot be `lo`.
The table ID is canonical decimal `1..4294967295`, without signs or leading
zeroes. The file must be regular, nonempty, at most 65,536 bytes, root-owned and
not group/other writable. Directory-descriptor traversal rejects symlink or
unsafe parent directories; no-follow/nonblocking opening and before/after
metadata checks reject unsafe files or a configuration changed during reading.

Direct trace uses the configured uplink. WARP link/address/handshake and table
checks use the configured WARP interface; the protected trace still binds its
observed IPv4 source for the existing source-policy path. Rule 110 and the
semantic kill-switch ingress use the configured transit interface. Kill-switch
egress must exclude the configured WARP interface and still include the drop,
family, table and comment checks. Exactly one unicast main default must use the
configured uplink, without requiring a site-specific gateway address.

Missing, malformed, duplicate, unsupported or unsafe role configuration skips
role-dependent commands and marks their observations `unknown`. Independent
system/health/monitoring evidence remains available: otherwise healthy evidence
produces `degraded`, no usable evidence produces `unknown`, and independent
genuine failures can still produce `offline`. No invented roles or healthy
fallback is used. The collector still publishes a valid schema-version-1
snapshot and does not crash the HTTP service.

API field names `rule_100`, `rule_110`, and `table_100` remain unchanged for
compatibility. The rule priorities remain 100/110; `table_100` observes the
configured table ID, not an assumed numeric 100. Numeric rule lookups accept
that configured ID or the canonical name `warp_gateway`. One unchanged package
supports CC (`ens160`/`ens192`), HQ (`ens33`/`ens35`) and other valid role names.
No deployment file, gateway configuration, route, firewall or WARP state is
modified by collection or by this telemetry correction.

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
