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
web/dashboard/server.py  (one explicit IPv4:8787)
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

WireGuard and other tunnel links may be administratively up while Linux reports
`operstate=UNKNOWN`. The collector accepts a structurally valid `UP` link flag
as administrative-up evidence; WARP path, routing, safety, and monitoring
observations still independently determine dataplane health. `/proc/uptime` is
read through a separate fixed-path, bounded, no-follow virtual-file reader
because procfs reports a metadata size of zero even when content is available.
Normal installation files such as `VERSION` retain the stricter positive-size
regular-file checks.

A failed external Cloudflare trace remains `unknown`; it is never rewritten as
healthy. A deployment qualification should sample critical external-path
telemetry across multiple collector executions before classifying an isolated
UNKNOWN as a persistent path failure.

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

The dependency-free server defaults to `127.0.0.1` on port `8787`. An operator
may instead pass one concrete management IPv4 with `--listen`; the server binds
exactly that address. It does not discover interfaces or add secondary
listeners. Wildcard, IPv6, hostname, multicast, limited-broadcast, and invalid
listeners are rejected before creating a socket.

v0.5.0 deliberately has no TLS or application authentication. When the server
is bound to a management IPv4, anyone with TCP access to that address and port
can view the sanitized read-only dashboard. Restrict access with the host and
management-network firewall or ACL; do not expose the listener to an untrusted
network or the Internet.

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

For direct management-network access, bind the service to the gateway's one
explicit management IPv4. For example, using the documentation-only address:

```bash
python3 -m web.dashboard.server --listen 192.0.2.10 --port 8787
```

Then open `http://192.0.2.10:8787` from a workstation allowed by the management
network policy. Replace the documentation address with the gateway's actual
management IPv4. No real deployment address is stored in the repository.

Omitting `--listen` retains the safer loopback-only default. Direct management
binding does not add authentication or encryption.

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
