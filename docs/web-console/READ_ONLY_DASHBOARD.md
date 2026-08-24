# v0.5.0 Read-Only Dashboard

## Product boundary

v0.5.0 is a monitoring dashboard. It displays a sanitized gateway snapshot and
has no network-control surface. The previously designed helper, mutation
adapters, sudoers policy, authentication model, and administration API remain in
the repository as deferred future work; none are imported, invoked, installed,
or required by this dashboard.

The dashboard does not change `native/` behavior and is not a dependency of the
gateway dataplane. Collector or web-service failure cannot change WireGuard,
routing, nftables, forwarding, services, or intentional state.

## Data flow

```text
fixed read-only observations
        |
        v
web/dashboard/collector.py
        |
        | validated atomic JSON publication
        v
/run/warp-egress-dashboard/status.json
        |
        | file read only; no command execution
        v
web/dashboard/server.py  (127.0.0.1:8787)
        |
        v
GET-only browser dashboard
```

The dashboard runtime directory is deliberately separate from
`/run/warp-egress-gateway`. Dashboard code does not read or require the gateway
mutation lock or intentional-disconnect record.

## Production ownership and permissions

An eventual installer or systemd unit must prepare the runtime directory as:

```text
/run/warp-egress-dashboard              root:warp-web 0750
/run/warp-egress-dashboard/status.json  root:warp-web 0640
```

The root-run collector resolves the `warp-web` group, creates a same-directory
temporary file with mode `0640`, writes and fsyncs the complete validated JSON,
atomically replaces `status.json`, and fsyncs the directory. The non-root web
service receives group read access only. This phase does not install the
directory, users, units, or timers on a host.

## Collector behavior

The collector uses fixed absolute executables, direct argument arrays,
`shell=False`, a minimal environment, bounded output, and command deadlines. It
observes:

- hostname, installed version, and uptime;
- `warp0` link/address state and public handshake timestamps;
- direct and WARP Cloudflare traces, including public WARP IP, POP, and location;
- rules 100/110, table 100, and the main default route;
- the semantic `WARP_KILL_SWITCH` rule and IPv4 forwarding;
- health/monitor records, both timers, and failed-unit count.

An individual observation failure becomes `unknown`, `warn`, or `failed` data;
it does not abort all snapshot construction. The collector never runs repair,
recovery, service lifecycle, route/nft/WireGuard mutation, sudo, or a privileged
helper. Browser polling never runs the collector. A future collector timer may
use a 10–15 second cadence.

## Status schema

The checked-in contract is `web/dashboard/status-schema.json` with
`schema_version: 1`. Objects reject additional fields and enforce explicit
types/enums. JSON duplicate keys, malformed Unicode, non-finite numbers,
oversized documents, and recursive secret-like fields are rejected.

The snapshot includes only overall, system, WARP public telemetry, path,
routing, safety, and monitoring state. It never includes private or preshared
keys, credentials, account material, tokens, cookies, TLS material, environment
dumps, arbitrary configuration, command stderr, SSH information, or sudoers.

## HTTP service

The dependency-free server accepts exactly the literal listener
`127.0.0.1` and defaults to port `8787`. It rejects wildcard, IPv6, hostname,
and non-loopback addresses before creating a socket. v0.5.0 deliberately has no
TLS or application authentication; it is not exposed to the LAN or Internet.

Supported routes are:

- `GET /`
- `GET /assets/styles.css`
- `GET /assets/app.js`
- `GET /api/status`
- `GET /healthz`

Unsafe HTTP methods have no application handlers. `/api/status` returns only a
bounded, re-parsed, schema-validated regular snapshot file; missing, symlinked,
malformed, or unsafe data produces a sanitized `503 status_unavailable` result.
`/healthz` reports only that the web process can answer HTTP.

## Access

From an administrative workstation, forward the gateway's loopback listener:

```bash
ssh -L 8787:127.0.0.1:8787 <gateway>
```

Then open:

```text
http://127.0.0.1:8787
```

## Refresh and staleness

The browser requests `/api/status` every five seconds without running host
observations. It marks data `STALE` when the validated `generated_at` timestamp
is more than 30 seconds old. Loading, API-unavailable, stale, healthy, degraded,
failed, and unknown states are visually distinct.

## Local fixture demo

From the repository root:

```bash
python3 -m web.dashboard.server --fixture healthy --listen 127.0.0.1 --port 8787
```

Replace `healthy` with `degraded` or `failed` to inspect the other safe synthetic
states. Fixture mode refreshes only `generated_at`; it does not execute any host
command. Stop the server with `Ctrl+C`.

Run focused validation with:

```bash
bash tests/dashboard.sh
```
