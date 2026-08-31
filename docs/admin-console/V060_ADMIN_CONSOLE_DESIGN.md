# v0.6.0 Admin Console Design

**Status:** FROZEN for Phase 0

**Authoritative runtime base:** `main` at `2bc026680d32e350a1cf2521523e0e8cf3d8358c`

**Released VERSION at design time:** `0.5.1`

**Initial deployment target:** Native

**Phase 0 effect:** documentation only

This document is the authoritative architecture and security contract for the
v0.6.0 Admin Console. Phase 0 adds no runtime, helper, sudoers, systemd,
installer, dashboard, dataplane, or version change. A later change to a frozen
boundary requires an explicit architecture review before implementation.

## 1. Product boundary and invariants

The v0.5.x Dashboard and the v0.6.0 Admin Console are separate products with
separate identities, processes, listeners, files, and privileges.

The existing Dashboard remains unchanged:

```text
service/runtime: warp-dashboard.service / warp-web
listener:        172.21.31.5:8787
authority:       read-only sanitized monitoring
sudo/helper:     none
```

`warp-web` must never receive sudo access, helper access, mutation permissions,
membership in an administrative group, or write access to Admin Console files.
The Admin Console must not add an action route to the Dashboard, import the
Dashboard server as its control plane, or make either service depend on the
other.

The new administrative plane is:

```text
service:         warp-admin.service
runtime user:    warp-admin
listener:        127.0.0.1:8788 (IPv4 loopback only)
remote access:   SSH local port forwarding
root boundary:   one fixed, short-lived helper
```

The existing CLI, systemd units, and fail-closed dataplane remain authoritative.
Admin Console failure, helper failure, failed HTTP requests, or Admin Console
uninstallation must not remove the kill switch, change forwarding, alter
routing, stop WireGuard, or prevent normal gateway boot.

Frozen safety invariants are:

1. No administrative action may create a transit-to-management-uplink leak.
2. The main default route and management interface addressing are immutable to
   Admin Console actions.
3. The nftables kill switch is never disabled or removed by the Admin Console.
4. WireGuard private material, account material, and configuration contents
   never cross the helper/API/UI/audit boundary.
5. No action is successful until its exact postconditions are independently
   verified.
6. A systemd unit being `active` is supporting telemetry, never sufficient
   dataplane-health evidence.

## 2. Architecture and trust boundaries

```text
Operator browser
    |
    | HTTP to local 127.0.0.1:8788
    v
SSH client local forward
    |
    | encrypted and authenticated SSH transport
    v
sshd on the gateway -> remote 127.0.0.1:8788
    |
    v
warp-admin.service                         unprivileged: warp-admin
    - exact Host/Origin validation
    - CSRF/session binding
    - fixed HTTP routes and schemas
    - confirmation and response rendering
    - bounded application audit records
    |
    | sudo -n, one exact zero-argument executable
    | one bounded versioned JSON object on stdin
    v
/usr/local/libexec/warp-egress-gateway/warp-admin-helper
                                             short-lived: root
    - strict request/config/result schemas
    - root-owned shared mutation lock
    - fixed executable paths and argv
    - safety preconditions and postconditions
    - bounded sanitized journald audit records
    |
    v
Existing project lifecycle, WireGuard, policy routing, and fail-closed guard

Separate observer only:
warp-dashboard.service -> warp-web -> 172.21.31.5:8787 (no sudo/helper)
```

Trust assumptions and boundaries:

- The browser, all HTTP input, headers, cookies, helper stdin, child-process
  output, and journal text are hostile data.
- SSH authentication and host verification are the v0.6.0 MVP transport and
  operator-authentication boundary. Anyone authorized to create the server-side
  loopback forward can reach the Admin Console and must be treated as an
  administrator.
- The Admin Console does not claim to know the individual SSH identity because
  TCP forwarding does not convey it to the HTTP process. Per-user attribution
  requires a separately reviewed authentication design.
- `warp-admin` is assumed compromisable. Its maximum privilege remains the
  fixed helper allowlist; it receives no general root or host-inspection
  primitive.
- The helper, root-owned installed files, sudo, systemd, kernel, and root-owned
  gateway configuration begin trusted. The helper still validates all trusted
  inputs before use and fails closed if ownership, type, mode, syntax, or
  semantics are unsafe.

## 3. Identities and ownership

| Identity | Purpose | Frozen permissions |
|---|---|---|
| SSH operator | Establish the encrypted local forward | Controlled solely by existing SSH policy; no identity is inferred from HTTP |
| `warp-web` | Existing v0.5.x read-only Dashboard | No sudo, no helper, no Admin Console groups or writable paths |
| `warp-admin` | Serve the loopback Admin Console | Locked/no-login service account; no supplementary groups; may execute only the exact helper through sudoers |
| `root` | Own helper, configuration, lock, lifecycle operations, and audit boundary | Never used as the web-service identity |

Admin application files and units are root-owned and not writable by
`warp-admin`. Runtime CSRF/session state is private to `warp-admin`; the root
mutation lock and intentional-disconnect state are not writable by either web
identity. `warp-admin` and `warp-web` must not share a Unix group merely for
convenience.

## 4. Listener and access model

`warp-admin.service` creates exactly one `AF_INET` listener at
`127.0.0.1:8788`. The address and port are fixed for the MVP. Startup rejects
or has no configuration path for:

- `0.0.0.0`, any wildcard, or any additional listener;
- the management IPv4 address, transit IPv4 address, or another loopback IPv4;
- IPv6, including `[::1]` and `[::]`;
- hostnames such as `localhost`;
- environment, command-line, proxy-header, or configuration overrides that
  could change the bind target.

Default remote access is:

```bash
ssh -o ExitOnForwardFailure=yes -L 8788:127.0.0.1:8788 cc-warp
```

The operator opens:

```text
http://127.0.0.1:8788
```

HTTP is acceptable only because the browser-to-server path is local loopback
plus the authenticated encrypted SSH tunnel. The MVP does not introduce TLS
PKI, a reverse proxy, LDAP, OIDC, a user database, an external authentication
service, management-interface binding, or a plaintext non-loopback listener.
There is no direct-network fallback if SSH forwarding is unavailable.

## 5. HTTP contract

### 5.1 Routes and methods

| Method | Route | Mutation | Purpose |
|---|---|---:|---|
| `GET` | `/` | No | Admin UI shell and CSRF bootstrap |
| `GET` | `/assets/admin.css` | No | Fixed local stylesheet |
| `GET` | `/assets/admin.js` | No | Fixed local application script |
| `GET` | `/api/status` | No | Bounded sanitized live status and action availability |
| `POST` | `/api/actions/health` | No | Run a fresh read-only health evaluation |
| `POST` | `/api/actions/repair-routing` | Yes | Repair only project policy-routing objects |
| `POST` | `/api/actions/connect` | Yes | Connect the existing configured WARP runtime |
| `POST` | `/api/actions/disconnect` | Yes | Intentionally disconnect while remaining fail closed |

There is no generic `/api/action`, `/api/command`, `/exec`, `/shell`, action
name parameter, dynamic route, configuration editor, file API, terminal, or
arbitrary command input.

All other routes return `404`; unsupported methods return `405`. `GET`, `HEAD`,
query strings, fragments, redirects, image requests, and asset requests never
cause actions. POST routes reject any query string and never redirect to
another action.

### 5.2 Request and response rules

- Mutations use POST only.
- POST requires an exact `Content-Type: application/json` media type, an
  explicit `Content-Length`, and a body no larger than 1,024 bytes. Transfer
  encoding, content encoding, multiple content lengths, malformed UTF-8,
  duplicate JSON keys, non-finite numbers, trailing data, arrays, and unknown
  fields are rejected.
- `/api/actions/health` accepts exactly `{}`.
- The three disruptive routes accept exactly one confirmation field:

  ```json
  {"confirmation":"repair-routing"}
  {"confirmation":"connect-warp"}
  {"confirmation":"disconnect-warp"}
  ```

  The route, not the confirmation value, selects the helper operation.
- API results use a versioned, bounded schema. Raw helper stdout, stderr,
  child exit codes, journal messages, or stack traces are never passed through.
- Dynamic values are rendered with text-only DOM APIs; untrusted values are
  never inserted as HTML. There are no third-party scripts, fonts, analytics,
  or network resources.
- All HTML/JSON responses use `Cache-Control: no-store`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, frame
  denial, a restrictive same-origin CSP with no inline/eval script, and a
  permissions policy denying unnecessary browser capabilities.
- CORS is not enabled. The service emits no permissive
  `Access-Control-Allow-Origin` or `Access-Control-Allow-Credentials` header and
  does not implement a cross-origin preflight success path.
- Requests are rate limited by the in-memory browser binding and by one global
  service budget, not by source IP because every SSH-forwarded connection
  appears to originate from loopback. The maximums are 60 status requests,
  six health requests, and three mutation requests per binding per minute,
  with global ceilings twice those values. Excess returns `429` and never
  invokes the helper.

The UI and API report at least these service states:

| State | Meaning |
|---|---|
| `ok` | Required dataplane, routing, direct path, WARP path, and safety evidence is healthy |
| `degraded` | Service is safe/usable but warning-only telemetry is abnormal |
| `failed` | A required dataplane or safety condition failed |
| `intentionally_disconnected` | Explicit root-owned intent is valid, WARP is stopped, project routing is absent, and the kill switch remains active |

`active` systemd state alone cannot produce `ok`.

## 6. CSRF and browser-request security

SSH access does not prevent a malicious web page from targeting a loopback
listener, so CSRF protections are mandatory.

1. Every request requires the exact `Host` value `127.0.0.1:8788`. Absolute-form
   targets, forwarded-host headers, `localhost`, alternate ports, duplicate
   Host headers, and missing/ambiguous Host values fail closed.
2. `GET /` creates or rotates an in-memory browser binding using at least 256
   bits of CSPRNG entropy. The opaque host-only cookie is `HttpOnly`,
   `SameSite=Strict`, `Path=/`, has no `Domain`, and contains no authentication
   claim. It is not an alternative to SSH authentication. Because the MVP is
   deliberately HTTP-over-SSH, it does not use a misleading `Secure` cookie
   contract that browsers cannot enforce on this URL.
3. The page receives a separate session-bound CSRF token with at least 256 bits
   of entropy. POST requires the binding cookie and the exact token in
   `X-CSRF-Token` using a constant-time comparison.
4. POST additionally requires the exact
   `Origin: http://127.0.0.1:8788`. Missing, `null`, multiple, malformed, or
   different Origin values are rejected; Referer is not an Origin fallback.
5. Session/CSRF records are memory-only, expire after bounded inactivity and an
   absolute lifetime, rotate on service restart, and are never logged.
6. The UI presents a specific confirmation dialog naming the disruptive action
   and its bounded effect. Buttons enter `confirming`, then `running`, and are
   disabled until a terminal `success` or `failed` result. Server-side checks
   remain authoritative if UI controls are bypassed.

## 7. Privileged helper contract

The future helper path is fixed:

```text
/usr/local/libexec/warp-egress-gateway/warp-admin-helper
```

It is a root-owned, non-writable, short-lived executable. It exits unless its
effective UID is root. Every parent directory is root-owned and not writable
by `warp-admin` or `warp-web`.

The web process invokes only:

```text
sudo -n -- /usr/local/libexec/warp-egress-gateway/warp-admin-helper
```

There are zero helper command-line arguments. One JSON request is read from
stdin with a hard maximum of 4,096 bytes:

```json
{
  "protocol": 1,
  "operation": "status|health|repair-routing|connect|disconnect",
  "request_id": "canonical UUIDv4"
}
```

The helper rejects missing, duplicate, unknown, malformed, non-canonical, or
oversized fields and any data after the object. It accepts no path, executable,
service, interface, rule, table, address, URL, timeout, environment, shell
fragment, command, configuration value, or caller-selected argument.
Confirmation is an HTTP-layer safety control and is not interpreted as root
authorization; the fixed operation allowlist remains authoritative.

The helper:

- reads trusted configuration only from fixed project-owned paths;
- checks regular-file/no-symlink type, root ownership, restrictive mode, size,
  and a strict allowlisted data grammar before use;
- never sources configuration as shell code and ignores caller environment
  overrides such as the current shell library's `WARP_GATEWAY_CONFIG_*` values;
- clears the inherited environment and uses a fixed minimal environment,
  fixed working directory, closed unrelated descriptors, and fixed absolute
  executable paths with direct argv arrays;
- never invokes a shell, `eval`, a caller-selected interpreter, or a generic
  project CLI dispatcher with caller-controlled arguments;
- applies operation-specific timeouts, process-group termination, output
  limits, and exact child exit-code translation;
- parses live command output into its own strict schemas, including
  duplicate-key-rejecting JSON where structured command output is available;
- treats malformed/ambiguous output as failure and never forwards raw stderr;
- independently checks preconditions and postconditions rather than trusting
  the web process or a child process's exit code;
- writes bounded structured events to journald for every invocation.

The response is a single versioned JSON object no larger than 64 KiB. It
contains the request ID, fixed operation, `ok`, stable result code, `changed`,
sanitized state, and bounded evidence categories. It never contains private or
preshared keys, WARP account material, cookies, CSRF data, environment dumps,
arbitrary configuration, or raw command output.

## 8. Sudoers contract

Phase 0 installs no sudoers file. The future policy must authorize only
`warp-admin`, never `warp-web`, to execute the exact zero-argument helper as
root. The conceptual boundary is:

```sudoers
Defaults:warp-admin env_reset
Defaults:warp-admin secure_path="/usr/sbin:/usr/bin:/sbin:/bin"
Defaults:warp-admin umask=0077
Defaults:warp-admin umask_override
Defaults:warp-admin log_allowed,log_denied

warp-admin ALL=(root:root) NOPASSWD:NOSETENV: /usr/local/libexec/warp-egress-gateway/warp-admin-helper ""
```

The final packaged syntax must pass `visudo -cf` and negative execution tests.
There are no wildcard arguments and no authorization for `/bin/bash`, Python
interpreters, project scripts, `systemctl`, `journalctl`, `ip`, `nft`, `wg`,
editors, file utilities, environment preservation, or another executable.

## 9. Shared mutation lock

One root-owned lock coordinates every operation that may change the same
gateway state. Its fixed location is:

```text
/run/warp-egress-gateway/admin-mutation.lock
```

The parent is root-owned mode `0700`; the regular lock file is root-owned mode
`0600` and is not writable by either web identity. The helper opens it without
following symlinks and holds the descriptor for the complete transaction.

- `health` and `status` take a shared/read lock so they cannot report an
  internally inconsistent mid-mutation snapshot.
- `repair-routing`, `connect`, and `disconnect` take an exclusive lock before
  their first state snapshot and hold the same lock through all mutation,
  verification, intent transition, and audit completion.
- Lock acquisition has a short fixed bound. Contention returns
  `mutation_lock_busy`; operations are never queued indefinitely.
- Before Slice 1 can claim a coherent read-only health result, existing
  timer-based recovery and fixed CLI/systemd lifecycle paths that mutate the
  observed routing/WireGuard state must use this same exclusive lock. An
  Admin-only lock that permits automatic recovery to race an observation or a
  later disconnect is not acceptable.
- The web process never opens, owns, truncates, deletes, or substitutes the
  lock file.

## 10. Frozen action semantics

### 10.1 Run Health

Run Health is a fresh read-only operational evaluation. It checks the actual
WireGuard interface/address, direct path, WARP `warp=on` path, exact project
rules/table, semantic kill switch, required upstream evidence, and relevant
unit/timer telemetry. It may update only Admin Console in-memory/UI state and
write sanitized audit records.

The current v0.5.1 `warp-gateway health` command is **not** safe to invoke
unchanged for this action: its healthcheck can repair policy routing and, when
configured, restart WireGuard. Slice 1 must first expose/refactor an official
no-recovery health evaluation whose enforced mode cannot call policy repair,
restart a unit, write intent, or change host state. Merely setting an
environment variable from the caller is not an acceptable read-only boundary.

An unhealthy gateway is a successful health *evaluation* with state `failed`,
not a falsely successful gateway. Command/query failure is reported separately
from the evaluated health state.

### 10.2 Repair Routing

Repair Routing acquires the exclusive lock and verifies before mutation:

- trusted configuration and fixed identifiers are safe;
- the expected WARP interface exists, is a WireGuard interface, and has exactly
  one usable expected IPv4 source;
- the semantic `WARP_KILL_SWITCH` rule is active;
- intentional-disconnect intent is absent;
- the main default route is captured for immutable postcondition comparison.

It may restore only:

- the configured source rule at priority 100;
- the configured transit-ingress rule at priority 110;
- exactly one direct default through `warp0` in table 100.

Validation is semantic. Valid iproute2 metadata such as `scope link` is
accepted, while missing/duplicate routes, a gateway, `via`, `nexthops`, `nhid`,
a wrong device, or a non-unicast default fail closed. The action never changes
the main table/default, management addressing, WireGuard identity/lifecycle,
forwarding, nftables, or unrelated routes/rules. Exact postconditions,
unchanged main default, and active kill switch are verified before success.

If routing is already healthy, the result is `ok`, `changed=false`, only after
the same safety and postcondition checks.

### 10.3 Connect WARP

Connect uses only existing configured identity and project lifecycle
mechanisms. It never registers a new WARP identity, generates keys, replaces a
profile, edits configuration, changes the main default, or weakens the kill
switch.

Under the exclusive lock it verifies the root-owned configuration and
fail-closed guard, snapshots immutable identity/main-route/nftables evidence,
then starts only the fixed configured WARP and project-routing units in the
established fail-closed order. It verifies the interface, unchanged public-key
fingerprint, policy routing, main route, semantic kill switch, direct
`warp=off`, and protected `warp=on` path.

If valid intentional-disconnect state exists, that state is retained until all
connected postconditions pass. Only then may the helper atomically clear it.
Failure keeps intent/recovery suppression in place and reports failure. If WARP
is already fully connected with no intent, the action returns `ok`,
`changed=false` after verification.

### 10.4 Disconnect WARP

Disconnect is an intentional controlled outage, not uninstall or identity
deletion. It requires an active semantic kill switch before any change.

Under the exclusive lock it:

1. validates configuration and snapshots the main default, WARP public-key
   fingerprint, and kill-switch semantics;
2. atomically creates a fixed root-owned runtime intent record at
   `/run/warp-egress-gateway/intentional-disconnect.json`;
3. removes only project-owned rules 100/110 and the table-100 default;
4. stops only the fixed project routing/WARP lifecycle units while leaving the
   firewall guard and fail-closed policy active;
5. verifies project routing absent, WARP intentionally stopped, main default
   and identity/configuration unchanged, and the kill switch still active.

The intent file has a fixed bounded schema, root ownership, mode `0600`, and is
written by a no-symlink, same-directory temporary file followed by file fsync,
atomic rename, and parent-directory fsync. `warp-admin` cannot create, rewrite,
or remove it. Existing automatic recovery and monitor/health behavior must be
updated in Slice 3 to distinguish `intentionally_disconnected` and never
reconnect while valid or unsafe/corrupt intent exists.

If already intentionally disconnected with matching verified state, the action
is idempotent and returns `ok`, `changed=false` without rewriting intent. On a
partial failure, intent remains, recovery remains suppressed, the helper makes
only bounded fail-closed convergence attempts, and success is forbidden.
Configuration and identity are never deleted. Reboot clears runtime intent and
allows the established guarded boot sequence to reconnect; persistence across
reboot is a non-goal.

## 11. Audit model

Every action produces linked application-side and helper-side structured
journald records. The helper record is authoritative for privileged execution.
Each state transition records:

- UTC timestamp;
- protocol version and canonical request correlation ID;
- fixed action;
- event state: `requested`, `started`, `completed`, or `failed`;
- sudo caller (`warp-admin`) and service identity;
- start/end monotonic duration;
- stable sanitized result/reason code;
- `changed` and bounded before/after state categories for mutations.

The HTTP process cannot truthfully attribute the request to an individual SSH
user, so it must not fabricate one. Audit strings are length bounded, escaped,
and treated as data. Journald records never contain private/preshared keys,
WireGuard profiles, `wgcf` account material, cookies, CSRF/session secrets,
authorization headers, environment dumps, arbitrary configuration, raw child
stdout/stderr, or command lines assembled from user input.

## 12. Failure and postcondition behavior

| Condition | Required result |
|---|---|
| Helper unavailable | `503 helper_unavailable`; no mutation claimed |
| `sudo -n` denied | `503 privilege_denied`; no password prompt or fallback |
| Mutation lock busy | `409 mutation_lock_busy`; no mutation outside the lock |
| Safety/health precondition failed | `409 unsafe_precondition`; exact safe reason category, no mutation where preconditions precede writes |
| WARP already connected | `200`, `changed=false` only after full connected-state verification |
| WARP already intentionally disconnected | `200`, `changed=false` only when intent and all disconnected safety postconditions agree |
| Routing already healthy | `200`, `changed=false` only after exact semantic verification |
| Fixed command timeout | `504 operation_timeout`; terminate process group, verify safe state, never infer success |
| Partial mutation failure | `500 partial_mutation_failure`; retain fail-closed intent/safety, perform bounded verification, never report success |
| Post-action verification failure | `500 postcondition_failed`; result is failed even if every child exited zero |
| Malformed body/content type/size | `400`, `415`, or `413` before helper invocation |
| Host/Origin/CSRF failure | `403` before helper invocation and without revealing token details |

Mutations capture the immutable main-default, identity, and kill-switch evidence
needed by their contract before the first write and compare it afterward. If a
safe rollback/convergence step cannot be proven, the helper stops and reports
the exact bounded failure category. It never disables the guard, installs a
management-uplink fallback, or improvises host-network repair.

## 13. UI contract

The Admin UI is visually related to the existing Dashboard design language but
is a separate application clearly labeled **Admin Console**. It provides only:

- Run Health;
- Repair Routing;
- Connect WARP;
- Disconnect WARP.

Every control uses `idle`, `confirming`, `running`, `success`, and `failed`
states. Disruptive controls identify their exact bounded effect before POST.
The UI contains no fake terminal, shell input, configuration editor, arbitrary
command/action field, free-form service/interface/path field, or raw log/output
console. UI state never overrides helper evidence.

## 14. Implementation slices

Implementation is test-first and strictly sequential:

### Slice 1 — skeleton, CSRF, and read-only health

- Separate `warp-admin` application/service identity and fixed loopback
  listener.
- Exact HTTP/Host/Origin/CSRF/body contracts.
- Fixed UI shell, passive status, and Run Health only.
- Root helper supports only `status` and the enforced no-recovery `health`
  operation.
- Add the root-owned lock foundation and integrate every existing automatic or
  fixed lifecycle writer of observed routing/WireGuard state with its exclusive
  side; this coordinates existing behavior but adds no Admin mutation.
- No routing, WireGuard, intent, systemd lifecycle, or other mutation.
- Slice 1 must be independently reviewed, CI-qualified, and host-qualified
  before Slice 2 begins.

### Slice 2 — Repair Routing

- Reuse the already-qualified root-owned shared lock and writer integration.
- Add only the fixed `repair-routing` helper/API/UI operation.
- Prove kill-switch prerequisites, semantic routing, main-route immutability,
  lock exclusion, and exact postconditions.
- Qualify Slice 2 before adding WARP lifecycle controls.

### Slice 3 — Connect and Disconnect

- Add the fixed `connect` and `disconnect` operations.
- Add atomic intentional-disconnect state and recovery suppression.
- Integrate every overlapping CLI/timer/systemd mutator with the same lock.
- Prove identity/config preservation, guarded lifecycle ordering,
  fail-closed partial failure, reboot semantics, and postconditions.
- Connect and Disconnect may be delivered in Slice 3 only after Slices 1 and 2
  are qualified; they are not backported into earlier slices.

No slice is deployed by Phase 0.

## 15. Test strategy

Phase 0 validation proves the change is documentation-only. Future slices must
recreate tests against the current v0.5.1-derived implementation rather than
copy historical code blindly.

Required future coverage includes:

- exact listener family/address/port and rejection of wildcard, management,
  transit, hostname, alternate-loopback, and IPv6 binds;
- strict Host, Origin, CSRF, cookie binding, method, content-type, body-size,
  duplicate-key, unknown-field, query-string, and CORS rejection;
- `warp-web` has no sudo/helper permission and cannot read/write Admin paths;
- sudoers positive test for the zero-argument helper and negative tests for
  arguments, environment preservation, shells, interpreters, project scripts,
  `systemctl`, `journalctl`, `ip`, `nft`, `wg`, and other executables;
- helper root/metadata gates, exact stdin schema, hostile environment/cwd,
  fixed argv, timeouts, process-group termination, output bounds, schema
  validation, and seeded-secret non-disclosure;
- Run Health red/green proof that no policy route, unit, WireGuard, nftables,
  forwarding, intent, or file state changes even when recovery would otherwise
  be eligible;
- semantic rule/default-route fixtures, including valid `scope link` and
  rejection of duplicate/gateway/multipath/non-unicast defaults;
- semantic nftables fixtures that ignore runtime handles/counters but reject a
  changed or absent kill switch;
- exclusive mutation-lock contention with deterministic timing and coverage
  for automatic recovery/CLI overlap;
- routing repair changes only rules 100/110 and table 100, preserves the main
  default and unrelated objects, and verifies postconditions;
- atomic intent creation, ownership/mode, symlink refusal, corruption handling,
  idempotence, fsync/rename behavior, and recovery inhibition;
- Connect/Disconnect identity preservation, already-state behavior, timeout,
  partial failure, postcondition failure, and fail-closed convergence;
- structured audit event fields, request correlation, bounded sanitization,
  and secret/cookie/CSRF/environment exclusion;
- installer/package/rollback tests proving Dashboard files, identity, listener,
  and sudoers remain byte-for-byte untouched.

Host qualification is performed only after the exact slice commit passes CI
and only under a separate approved runbook. It records pre/post identity,
routing, nftables semantics, main route, listener, unit state, and backup or
rollback evidence.

## 16. Deployment strategy

Future deployment is optional and separate from the gateway and Dashboard:

```text
/opt/warp-egress-admin-console/             root-owned application
/run/warp-egress-admin-console/             private CSRF/session runtime
/etc/systemd/system/warp-admin.service      hardened unprivileged service
/usr/local/libexec/warp-egress-gateway/warp-admin-helper
/etc/sudoers.d/warp-egress-gateway-admin    exact helper rule
```

The installer must create or safely validate a locked `warp-admin` identity,
refuse conflicting ownership/group state, install root-owned files atomically,
validate sudoers with `visudo -cf`, verify the exact listener, and only then
enable the service. It must not restart/reinstall the Dashboard or modify
`warp-web`. Slice-specific native changes are installed only by the normal
versioned gateway upgrade/rollback mechanism after package tests.

Remote use is documented only through the SSH forward. There is no automatic
firewall opening, management-network listener, proxy, certificate, or external
identity integration.

## 17. Rollback strategy

Admin application rollback disables `warp-admin.service`, removes only its
exact sudoers file and helper after the service is stopped, removes its own
root-owned application/runtime files, and safely preserves ambiguous
pre-existing identities. It does not stop gateway units or touch Dashboard,
routing, WireGuard, nftables, forwarding, configuration, or identity.

For Slices 2 and 3, versioned rollback must restore the mutually compatible
helper and native coordination/intent code as one release unit. It must keep
the kill switch active throughout. A rollback encountering intentional intent
must preserve the safest understood state or refuse; it must never silently
reconnect or discard an unsafe/corrupt intent. Release backup, upgrade, and
rollback tests must cover these version boundaries before deployment.

An individual failed action follows the failure behavior in section 12 and is
not treated as permission to run an unreviewed repair command.

## 18. Historical control-plane assessment

The historical `feature/v0.5.0-web-console` branch is reference material only.
It must not be merged, rebased onto this branch, or cherry-picked wholesale.

### Concepts that remain valid

- A short-lived root helper behind one exact zero-argument sudoers entry.
- Strict bounded JSON with duplicate/unknown-field rejection and canonical
  request IDs.
- Fixed absolute commands/argv, clean environment, trusted fixed-path config,
  no shell, deadlines, output bounds, and validated structured responses.
- A single lock held through pre-snapshot, mutation, intent handling, and final
  verification.
- Atomic root-owned intentional-disconnect state that suppresses recovery.
- Semantic route validation that accepts `scope link`, and semantic nftables
  snapshots that ignore runtime handles/counters.
- Exact postcondition/main-route/identity checks, secret canaries, negative
  sudoers tests, timeout tests, and fail-closed partial-failure fixtures.

### Incompatible with current v0.5.1 and this design

- The historical helper/sudoers authority was assigned to `warp-web`; the
  released Dashboard is now permanently read-only and must receive none.
- Historical native runtime-state, routing, health, monitor, and intent changes
  were built on an older runtime and are absent from authoritative v0.5.1.
  Importing them would overwrite current boot ordering, recovery, upgrade, and
  dashboard-qualified behavior.
- The old application-authentication, user database, TLS, management-interface
  bind, log APIs, Viewer/Admin role model, and broader verb set conflict with
  the SSH-authenticated, fixed-loopback, four-action MVP.
- Historical `health-run` allowed recovery/mutation; v0.6.0 Run Health is
  explicitly read-only.
- The old initial design omitted the new Connect action and used different API
  routes, state ownership, and deployment assumptions.

### Material that must not be reused

- Old helper, sudoers, adapters, installers, or privileged `warp-web` wiring.
- Historical native/runtime-state scripts or changes as a bulk patch.
- Old authentication/session database, TLS/reverse-proxy, management-binding,
  logs, arbitrary historical API, or role implementation.
- Any caller-controlled path/unit/interface/command/environment pattern, raw
  stdout/stderr response, or exact human-readable route-string assertion.

### Tests worth recreating cleanly

- Helper schema, duplicate-key, hostile-input/environment, output/timeout, and
  secret-redaction tests.
- Exact sudoers allow/deny matrix.
- Lock ownership/contention and same-lock transaction tests.
- Atomic intent writer and corrupt/unsafe intent tests.
- Semantic route/nftables fixtures and unrelated-state preservation checks.
- Idempotence, partial failure, postcondition, and recovery-suppression tests.

These are test *ideas and invariants*, not permission to import their old
implementation or fixtures without re-deriving them against the current base.

## 19. Explicit non-goals

The v0.6.0 MVP does not provide:

- any change to the v0.5.x Dashboard, `warp-web`, or `172.21.31.5:8787`;
- a wildcard, management, transit, hostname, IPv6, public, or direct-network
  Admin listener;
- TLS PKI, reverse proxy, LDAP, OIDC, external authentication, local user
  database, role administration, or password management;
- Docker Admin Console support without a separate architecture review;
- WARP registration, key generation, identity/profile replacement, or config
  editing;
- kill-switch disable/removal, main-route/default management, interface
  addressing, forwarding control, arbitrary nftables/routing/WireGuard control,
  reboot, upgrade, rollback, diagnostics bundle, or host administration;
- logs browsing, shell/terminal input, arbitrary commands/actions, file access,
  service selection, or free-form parameters;
- persistent intentional disconnect across reboot;
- multiple simultaneous mutations or optimistic success based only on exit 0;
- deployment or production implementation in Phase 0.

## 20. Phase 0 acceptance gates

Phase 0 is acceptable only when this is the sole repository content change,
`VERSION` remains `0.5.1`, and diffs under `native/` and `web/dashboard/` are
zero. Documentation/link validation, whitespace validation, and a secret audit
must pass. The single commit is documentation-only and does not authorize CC,
HQ, deployment, tagging, releasing, or production implementation.
