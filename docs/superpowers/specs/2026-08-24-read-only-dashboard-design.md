# v0.5.0 Read-Only Dashboard Design

## Scope

v0.5.0 adds a monitoring-only dashboard. It does not expose gateway controls,
invoke the privileged helper, depend on sudoers, or change the qualified Native
runtime. The existing helper, mutation adapters, sudoers policy, and Phase 0
control-plane documents remain in the repository as deferred future work.

## Architecture

The implementation has three independent layers:

1. A one-shot read-only collector executes a fixed set of bounded observations,
   converts failures into explicit `unknown`, `warn`, or `failed` fields, validates
   the complete schema, and atomically publishes a sanitized snapshot.
2. A non-root HTTP server bound strictly to `127.0.0.1` reads and revalidates only
   `/run/warp-egress-dashboard/status.json`. Request handlers never import the
   collector or execute commands.
3. A vanilla HTML/CSS/JavaScript frontend polls `GET /api/status` every five
   seconds and renders status cards, loading/error states, and a stale warning
   when `generated_at` is more than 30 seconds old.

The production snapshot directory is separate from the gateway runtime:

```text
/run/warp-egress-dashboard                  root:warp-web 0750
/run/warp-egress-dashboard/status.json      root:warp-web 0640
```

No dashboard component reads `/run/warp-egress-gateway`, its mutation lock, or
its intentional-disconnect state.

## Collector boundary

The collector uses Python's standard library and fixed absolute executable
paths. Every subprocess uses `shell=False`, a fixed argument vector, a deadline,
bounded stdout/stderr, a fixed working directory, and a minimal environment.
It observes hostname, version, uptime, interface and public WireGuard telemetry,
Cloudflare traces, policy routing, the semantic kill switch, forwarding,
health/monitor records, timer states, and failed-unit count. It never invokes a
mutation adapter or any command form that changes services, routing, nftables,
WireGuard, sysctl, or intentional state.

The collector is not run by browser requests. A future root-owned timer may run
it every 10–15 seconds; this phase does not install that timer.

## Snapshot contract

`schema_version` is exactly `1`. The top-level keys are exactly:
`schema_version`, `generated_at`, `overall`, `system`, `warp`, `paths`,
`routing`, `safety`, and `monitoring`. Nested objects also reject unknown keys
and enforce explicit enums and primitive types. Recursive key inspection rejects
secret-like names including private keys, preshared keys, passwords, tokens,
cookies, TLS private material, environment dumps, account material, and sudoers.

The collector writes compact JSON to a same-directory exclusive temporary file,
flushes and fsyncs it, applies mode `0640`, atomically replaces `status.json`, and
fsyncs the parent directory. The web server caps input size, refuses symlinks,
parses with duplicate-key rejection, and validates the schema before returning
the document.

## HTTP and access model

The service supports only:

- `GET /`
- `GET /assets/styles.css`
- `GET /assets/app.js`
- `GET /api/status`
- `GET /healthz`

The CLI accepts only the literal listener `127.0.0.1`; wildcard, IPv6, hostname,
and non-loopback binds fail before server creation. It defaults to port `8787`.
There is no TLS or application authentication in v0.5.0. Remote access is through
an SSH tunnel:

```bash
ssh -L 8787:127.0.0.1:8787 <gateway>
```

The browser then opens `http://127.0.0.1:8787`.

## Demo and presentation

Fixture mode reads one of three repository-owned, schema-valid documents:
`healthy`, `degraded`, or `failed`. Fixtures use only documentation addresses and
synthetic hostnames. The demo provider refreshes only `generated_at`; it never
executes host observations.

The UI uses semantic HTML, local CSS design tokens, accessible contrast and live
status announcements. Desktop uses grouped cards; mobile collapses to a single
column without horizontal scrolling. It has no buttons, forms, controls, or
disabled control placeholders.

## Failure behavior

Collector observation failures are isolated and represented in the snapshot.
Malformed or unsafe snapshots produce a bounded `503 status_unavailable` API
response without raw parser or command errors. A missing frontend asset returns
404. Unsupported HTTP methods are not implemented by the application. Web server
health reports only the web process and never infers gateway health.

## Frozen boundaries

- No changes under `native/`, `web/helper/`, or `web/sudoers/`.
- `VERSION` remains `0.4.1`.
- No host access, deployment, systemd installation, commit, push, or release.
- No TLS, authentication, database, sudo, privileged helper, or mutation route.
