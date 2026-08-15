# Web Console Architecture

## Status and scope

This document freezes the Phase 0 architecture for the optional v0.5.0 Web
Management Console. It is a design contract, not an implementation. Version
`0.4.1` remains the released runtime baseline.

The initial console covers status, bounded project logs, health execution,
policy-only routing repair, and intentional WARP disconnect. It does not add a
general host-management plane. Installation, upgrade, Docker, TLS, web, API,
authentication, and helper code are outside Phase 0.

The existing CLI and systemd-managed dataplane remain authoritative. A host
without the web component must install, boot, route, monitor, recover, upgrade,
and roll back exactly as it does without the console.

## Goals

- Report actual dataplane and safety state rather than treating a systemd
  `active` state as health evidence.
- Preserve the management default route and fail-closed transit behavior for
  every web action and failure.
- Keep the network-facing process unprivileged.
- Reduce root operations to a fixed, reviewable interface with structured
  input and output.
- Keep all WARP private material, credentials, arbitrary files, and command
  execution outside the browser/backend boundary.
- Make intentional disconnect a first-class state that cannot be undone by
  automatic recovery.

## Non-goals for v0.5.0

- Replacing the CLI or making the web service a gateway startup dependency.
- Editing deployment configuration, routes, nftables policy, WireGuard
  profiles, users outside the console, or arbitrary systemd units.
- Disabling, removing, or bypassing the kill switch.
- Exposing a shell, file browser, terminal, raw command output, or arbitrary
  journal query.
- Managing Docker mode. The first web-console implementation targets the
  Native deployment only; Docker support requires a separate security review.
- LDAP, OIDC, high availability, multi-host control, or a public Internet
  management service.

## Component model

```text
Administrator browser
        |
        | HTTPS (loopback by default, normally through SSH forwarding)
        v
warp-web                         unprivileged account: warp-web
  - local authentication
  - Viewer/Admin authorization
  - CSRF and session controls
  - API schemas and output encoding
  - application audit events
        |
        | one fixed sudo entry point, zero command-line arguments
        | one bounded JSON request on stdin
        v
warp-web-helper                  root-owned, short-lived
  - fixed verbs and fixed trusted paths
  - strict config parser
  - safety precondition checks
  - bounded structured output
  - privileged audit events
        |
        +-- existing warp-gateway behavior
        +-- selected fixed systemd units
        +-- project-owned ip rules/table
        +-- inet warp_gateway nftables table
        +-- WireGuard public diagnostics
        +-- approved project journal sources
```

`warp-web` never runs as root. It cannot use sudo for `systemctl`,
`journalctl`, `ip`, `nft`, `wg`, a shell, a project script, or any other
executable. Sudo authorizes only the fixed helper entry point. The helper is
not a generic command wrapper and does not accept caller-selected executable
names, paths, interface names, environment settings, or shell fragments.

## Dataplane independence

The web components are downstream observers/controllers of an already
operating gateway. No existing firewall, WireGuard, routing, health, or monitor
unit may require or order itself after `warp-web` or the helper.

- If `warp-web` fails to start, the gateway operates normally.
- If the helper fails, the requested web operation fails without relaxing the
  dataplane.
- If authentication storage is unavailable, login fails closed while the
  dataplane remains unchanged.
- Stopping or uninstalling the web component does not stop WireGuard, remove
  policy routing, change forwarding, or alter nftables.

## State model

The API and UI expose exactly one top-level state from this minimum set:

| State | Meaning |
|---|---|
| `ok` | Required dataplane, safety, direct-management, routing, and configured upstream checks are healthy. |
| `degraded` | Service remains usable and safe, but non-fatal telemetry is abnormal, such as a stale handshake while a current trace proves `warp=on`. |
| `failed` | A required dataplane, management-path, routing, upstream, or safety check failed and no intentional-disconnect intent explains it. |
| `intentionally_disconnected` | A root-owned runtime intent exists, WARP transit is deliberately unavailable, and the kill switch continues to block fallback. |

Precedence is deterministic:

1. An intent record is never sufficient by itself. If it exists, the helper
   verifies the kill switch, absence of project-owned routing, and WARP stop
   state. Matching evidence produces `intentionally_disconnected`.
2. If intent exists but the safety evidence is inconsistent, state is
   `failed`; the response also reports `intentional_disconnect.active=true`
   and the inconsistency.
3. Without intent, any required safety/dataplane failure produces `failed`.
4. A healthy dataplane with warning-only telemetry produces `degraded`.
5. Only complete healthy evidence produces `ok`.

Systemd unit activity is supporting telemetry only. `warp-gateway.service`
uses `RemainAfterExit`, so `active` proves that setup ran, not that rules still
exist. The helper must inspect the interface, WARP trace, direct trace,
project-owned rules, WARP table default, semantic kill-switch rule, and
configured upstream check.

## Read path

For a status request:

1. `warp-web` authenticates the session and verifies the Viewer role.
2. It sends a bounded helper request with the fixed `status` verb.
3. The helper loads only fixed project configuration paths with a strict data
   parser; it never sources the configuration as shell code.
4. The helper gathers live, structured evidence and the latest approved
   monitor/health evidence within fixed time and size bounds.
5. The helper redacts forbidden fields and returns versioned JSON.
6. `warp-web` validates that JSON against its internal schema before returning
   an API response.

Malformed or incomplete helper output is an upstream failure. The backend does
not pass raw stdout or stderr to the browser.

## Health semantics

`GET /api/v1/health` is passive. It returns the latest bounded health and
monitor evidence plus its age; it does not run a probe or recovery.

`POST /api/v1/health/run` is an Admin control. The existing v0.4.1 health path
may perform deterministic policy-only repair and, when `AUTO_RECOVER=true`, a
tunnel restart for tunnel-specific evidence. The response must state whether
recovery was `none`, `policy`, or `tunnel`.

When intentional-disconnect intent is active, both periodic health and an
explicit health run must return `intentionally_disconnected` without applying
routing or restarting WireGuard. The passive monitor may continue collecting
direct-path and kill-switch evidence, but it must not attempt recovery.

## Policy-routing repair

The `routing-repair` verb reuses the v0.4.1 policy-only model. Before any
mutation it verifies:

- the trusted configuration is syntactically and semantically valid;
- the configured WARP interface exists and is recognized by WireGuard;
- the interface has the expected IPv4 address used by the source rule;
- the semantic `WARP_KILL_SWITCH` drop rule is active;
- intentional-disconnect intent is absent.

It may replace only:

- `SOURCE_RULE_PRIORITY` for the current WARP IPv4 source;
- `INGRESS_RULE_PRIORITY` for `TRANSIT_IF`;
- the default route in `ROUTING_TABLE_ID` through `WARP_IF`.

It must not alter the main routing table, any unrelated rule priority, the
nftables table, WireGuard lifecycle, host network management, or forwarding.
It verifies the exact state after applying it. A missing safety prerequisite
causes refusal with no routing mutation.

## Intentional disconnect

### Runtime intent record

The helper owns an ephemeral record at the fixed path:

```text
/run/warp-egress-gateway/intentional-disconnect.json
```

The containing directory and record are root-owned. The record is mode `0600`
and is created atomically with a bounded schema containing only a format
version, state, creation time, request ID, and sanitized actor identifier.
`warp-web` cannot create, replace, truncate, or delete it. It learns intent
state only through helper responses.

The record is stored under `/run`, so reboot clears it. A future explicit CLI
`start`/`reconnect` path may clear it as part of a guarded reconnect sequence.
The initial UI has no reconnect operation.

### Disconnect transaction

`warp-disconnect` follows this order:

1. Validate configuration and capture the main default-route identity for
   postcondition comparison.
2. Verify the semantic kill switch is active. If it is absent or invalid,
   refuse without changing intent, routing, or WireGuard.
3. Atomically create the intentional-disconnect record.
4. Stop/suppress automatic health recovery before taking down the path.
5. Stop the project routing service so its existing stop behavior removes the
   two project-owned rules and flushes only the project WARP table.
6. Stop the configured `wg-quick` WARP unit. Do not stop or remove the firewall
   guard.
7. Verify that project-owned policy rules and the WARP-table default are
   absent, the WARP interface is stopped as intended, the kill switch remains
   active, and the main default route is byte-for-byte equivalent in semantic
   fields to the captured route.
8. Return structured state and record an audit event.

The monitor remains available to report direct management and safety state.
Transit traffic entering `TRANSIT_IF` has no WARP policy path and is blocked by
the retained kill switch rather than falling through to `UPLINK_IF`.

If a later step fails, the intent record remains. Automatic recovery remains
inhibited, the helper attempts the safe route-removal postcondition, and the
operation returns a partial-failure result. It never removes the kill switch to
make the action appear successful.

### Reconnect and reboot

Reconnection is not an initial web control. A future explicit CLI operation
must verify/install the firewall guard, start WireGuard, apply and verify
policy routing, prove `warp=on`, and only then clear or transition the intent
record. Clearing the record before safety and dataplane verification is
forbidden.

Normal reboot clears `/run`; existing enabled units then follow the established
fail-closed boot order. A persistent disconnect-across-reboot feature is
deferred and would require a new design review.

## Network and TLS deployment

### Default

The safe default is a direct HTTPS listener bound only to
`127.0.0.1:<configured-high-port>`. There is no plaintext HTTP listener, no
automatic management-interface bind, and no `0.0.0.0` or wildcard bind.
Startup fails closed if the certificate or private key is missing, unsafe, or
unreadable by the dedicated service account.

Default remote access uses SSH local port forwarding, for example with
synthetic host data:

```bash
ssh -L 8443:127.0.0.1:8443 admin@gateway.example.invalid
```

The browser then connects to the certificate-valid local URL selected by the
operator. SSH authentication and host verification are outside the web
session and provide an additional access boundary.

### Opt-in modes

- **Management-interface HTTPS:** bind one explicit management IPv4 address,
  never a wildcard or transit address. Host/upstream policy must restrict it to
  approved administrative source networks.
- **Reverse proxy:** terminate HTTPS in an operator-managed proxy and connect
  to `warp-web` through a local Unix socket. The backend socket is never a
  network listener and has restrictive ownership/mode.

Neither opt-in mode weakens application authentication. Proxy identity headers
are ignored unless a future trusted-proxy contract explicitly defines them.

Certificates and private keys are generated or provisioned on the host. They
are never committed, embedded in release artifacts, returned by the API, or
written to audit logs. Renewal failure must not cause fallback to HTTP.

## Authentication and sessions

The initial model is a local user database with `Viewer` and `Admin` roles.
Passwords use Argon2id with a unique random salt and parameters no weaker than
64 MiB memory, three iterations, one lane, and a 32-byte output. Parameters are
stored with each hash for controlled future upgrades.

There is no default user or password. The first Admin is created through an
offline, root-authorized local bootstrap command; the network listener does not
offer first-user enrollment. Bootstrap refuses to print or log a password.

Sessions use at least 256 bits of CSPRNG entropy, are stored server-side by a
one-way token digest, rotate after login and privilege changes, expire after 15
minutes idle and eight hours absolute, and are revoked on logout. The cookie is
named `__Host-warp_session` and always has `Secure`, `HttpOnly`,
`SameSite=Strict`, `Path=/`, and no `Domain` attribute.

Unsafe methods require a session-bound synchronizer token in
`X-CSRF-Token`, a same-origin `Origin` check, and JSON content type. Login uses
same-origin checks and rate limits by normalized account and source. Error
messages do not disclose whether an account exists.

## Availability and resource bounds

- Web requests have endpoint-specific deadlines; helper processes have a hard
  wall-clock timeout and are killed as a process group on expiry.
- Helper input is at most 8 KiB. Structured output is at most 256 KiB.
- Log responses contain at most 500 records, cover at most seven days, and are
  truncated explicitly rather than silently.
- Concurrent mutating operations are serialized. A second conflicting action
  receives `409 Conflict`.
- Browser/API request bodies and headers have fixed limits. Slow headers,
  bodies, and idle connections time out.
- Status failure never blocks the dataplane and never triggers recovery.

## Alternatives considered

### Persistent root-owned Unix-domain service

This offers a natural message protocol and avoids sudoers, but it leaves a
long-running root parser exposed to every request from a compromised web
process. Lifecycle, socket authentication, concurrency, and daemon hardening
increase the privileged attack surface. It is not selected for v0.5.0.

### systemd/polkit-controlled actions

Predefined units and policy can constrain actions, but fine-grained argument
validation, structured synchronous results, read-only status, and bounded log
access become distributed across units, D-Bus policy, and polkit rules. This is
harder to audit and package consistently for the initial release. It is not
selected for v0.5.0.

### Selected: short-lived helper through one sudoers entry

The selected design has one root-owned executable, one input schema, a small
allowlist, no persistent privileged parser, and clear per-operation audit and
timeout boundaries. Sudoers limits execution to that entry point with no
command-line arguments and without caller environment preservation. The helper
still treats all input as hostile and independently enforces the fail-closed
invariants.
