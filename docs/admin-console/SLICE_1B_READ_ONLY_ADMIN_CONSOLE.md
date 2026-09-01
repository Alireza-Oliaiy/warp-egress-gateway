# Slice 1B: read-only Admin Console

Slice 1B adds a separate, SSH-forwarded administrative observation plane to
the v0.5.1-derived Native gateway. It implements only Passive Status and Run
Health. It does not add routing repair, WARP lifecycle, intentional-disconnect,
configuration, upgrade, rollback, reboot, or another mutation authority.

## Installed boundary

The dedicated resources are:

```text
/opt/warp-egress-admin-console/app/admin/
/run/warp-egress-admin-console/
/usr/local/libexec/warp-egress-gateway/warp-admin-helper
/usr/local/libexec/warp-egress-gateway/warp_admin_protocol.py
/etc/systemd/system/warp-admin.service
/etc/sudoers.d/warp-egress-gateway-admin
```

`warp-admin.service` runs as the locked, no-login `warp-admin` system account.
The account has only its primary group and is not a member of `warp-web` or an
administrative group. Application, helper, unit, and sudoers files are
root-owned and not writable by either web identity. The existing Dashboard,
`warp-dashboard.service`, `warp-web`, and `172.21.31.5:8787` are not imported,
restarted, reconfigured, or granted privilege.

## Listener and operator access

The application has no listener configuration. Its only production socket is
IPv4 `AF_INET` at `127.0.0.1:8788`; arguments and environment variables cannot
replace the address or port. It does not bind wildcard, management, transit,
alternate-loopback, hostname, or IPv6 addresses and does not trust proxy
headers.

The supported remote-access path is an authenticated SSH local forward:

```bash
ssh -o ExitOnForwardFailure=yes -L 8788:127.0.0.1:8788 cc-warp
```

The operator then opens `http://127.0.0.1:8788`. Plain HTTP is limited to the
browser's local loopback plus the encrypted SSH tunnel. Slice 1B adds no TLS,
reverse proxy, management-interface listener, LDAP, OIDC, password database,
or direct-network fallback.

## HTTP and browser boundary

The only routes are:

| Method | Route | Result |
|---|---|---|
| `GET` | `/` | Issue a new memory-only browser binding and render the UI |
| `GET` | `/assets/admin.css` | Fixed local stylesheet |
| `GET` | `/assets/admin.js` | Fixed local application script |
| `GET` | `/api/status` | Coherent read-only status evaluation |
| `POST` | `/api/actions/health` | Fresh official no-recovery health evaluation |

Repair Routing, Connect, Disconnect, generic action/command routes, shell, and
execution routes are absent and return `404` without invoking the helper.
Unsupported methods do not trigger actions, and CORS/preflight access is not
enabled.

Every request requires the single exact `Host: 127.0.0.1:8788`. Missing,
duplicate, alternate, absolute-form, forwarded-host, and proxy-style requests
fail before helper invocation. Query strings are not accepted.

`GET /` creates independent 256-bit opaque binding and CSRF values. The
binding cookie is host-only, `HttpOnly`, `SameSite=Strict`, `Path=/`, has no
`Domain`, and deliberately has no misleading `Secure` attribute on the
HTTP-over-SSH URL. Records exist only in process memory, expire after 15
minutes of inactivity or eight hours absolute, are bounded to 1,024 entries,
and rotate on restart. POST requires the valid binding, a constant-time CSRF
match, and exact `Origin: http://127.0.0.1:8788`; Referer is not a fallback.

Run Health accepts exactly the empty JSON object. It requires one exact
`Content-Type: application/json`, one explicit decimal `Content-Length` no
larger than 1,024 bytes, and rejects transfer/content encoding, duplicate
lengths or JSON keys, unknown fields, non-objects, malformed UTF-8, non-finite
values, and trailing data.

All responses are `no-store`, deny framing and referrers, use `nosniff`, a
same-origin CSP without inline/eval script, and a restrictive permissions
policy. There are no external scripts, styles, fonts, analytics, or permissive
CORS headers. Dynamic UI values use `textContent`; Run Health is the only
active control and has idle, running, success, and failed presentation states.

## Rate limits

Sliding one-minute in-memory budgets are keyed by browser binding rather than
loopback source IP:

```text
status: 60 per binding, 120 global
health:  6 per binding,  12 global
```

An exhausted budget returns `429` before the helper is invoked. Restart clears
the in-memory windows.

## Helper protocol and read-only semantics

The web process executes only:

```text
sudo -n -- /usr/local/libexec/warp-egress-gateway/warp-admin-helper
```

There are zero helper arguments. The root helper requires effective UID zero,
uses a fixed clean environment and working directory, and accepts one strict
JSON object of at most 4,096 bytes:

```json
{"protocol":1,"operation":"status|health","request_id":"canonical UUIDv4"}
```

The shared `admin/protocol.py` source is the authoritative versioned contract
used by both installed sides. Duplicate, unknown, missing, malformed,
noncanonical, oversized, and trailing input is rejected. The allowlist does
not contain `repair-routing`, `connect`, or `disconnect`, and the schema has no
path, service, interface, executable, argv, environment, URL, timeout, or
configuration field.

Both operations execute only the fixed official
`/usr/local/lib/warp-egress-gateway/health-readonly.sh` Slice 1A entrypoint.
That entrypoint acquires the qualified shared side of
`/run/warp-egress-gateway/admin-mutation.lock`; the helper neither opens a
second lock nor changes lock metadata. The legacy recovering `warp-gateway
health` operation is never invoked.

The helper parses the bounded single-line no-recovery result into its own
strict allowlist. A completed unhealthy evaluation is returned as
`ok=true`, `state=failed`, and `result_code=evaluation_unhealthy`; observation
failure and lock contention remain operation failures. Status and Health
therefore represent actual dataplane/safety evidence, never systemd `active`
alone. Slice 1A currently provides WireGuard, direct path, WARP path, routing,
kill-switch, upstream, service, and timer categories. Handshake age,
forwarding, and an exact failed-unit count remain explicit `unknown`/`null`
rather than being invented from weaker evidence.

Helper output is one strict JSON object of at most 64 KiB containing only
protocol, request ID, operation, completion boolean, stable result code,
`changed=false`, one of `ok`, `degraded`, `failed`, or
`intentionally_disconnected`, and bounded evidence. Private/preshared keys,
profiles, account material, cookies, CSRF values, environment, raw output,
stderr, journal text, and stack traces are outside the schema.

The application independently bounds helper time/output and validates exact
response fields, request correlation, operation, enums, and `changed=false`.
Stable HTTP mappings include `503` for unavailable helper/privilege,
`409` for mutation-lock contention, `504` for timeout, and `502` for malformed
helper protocol.

## Sudoers and systemd hardening

The sudoers policy grants only `warp-admin` the exact zero-argument helper as
`root:root`, with `NOPASSWD:NOSETENV`. It grants nothing to `warp-web` and no
shell, interpreter, systemd/journal, network tool, project script, environment
preservation, or wildcard command. The packaged and installed policy is
validated with `visudo -cf`.

The service account starts with no effective or ambient capabilities, a
private temporary/device view, strict system/home/kernel/control-group
protection, memory-write/execute denial, personality/realtime restrictions,
and only `AF_INET`, `AF_UNIX`, and `AF_NETLINK`. `AF_NETLINK` is required by
the fixed root evaluator's WireGuard/nftables observations. The service is
ordered after the early firewall guard and exposes only the existing
root-owned `/run/warp-egress-gateway` directory as writable inside its strict
mount namespace; Unix ownership and mode still deny `warp-admin`, while the
root helper can open the established shared lock. An empty
`CapabilityBoundingSet`, `NoNewPrivileges=true`, and `PrivateUsers=true` are
intentionally omitted because they would also constrain or prevent the one
reviewed setuid sudo transition. The unprivileged service receives no ambient
capability, and these omissions do not broaden the exact sudoers authority.

## Audit model

The application and helper emit linked, bounded journald records for
`requested`, `started`, and `completed` or `failed`. Records include protocol,
canonical request ID, fixed action, monotonic duration, stable result code,
and `changed=false`. Helper-side records are authoritative for privileged
execution. No individual SSH identity is fabricated, and cookie/CSRF values,
secrets, raw HTTP bodies, raw child output, stderr, profiles, or environment
are never logged.

## Install, uninstall, and rollback scope

`admin/deploy/install.sh` creates or strictly validates the dedicated locked
identity, root-owned application/helper/protocol/unit/sudoers assets, private
runtime directory, sudoers syntax, service state, exact listener, and a
session-bound status smoke test. Conflicting identity, symlink, ownership, or
mode state fails closed. Reinstallation is deterministic and preserves a safe
pre-existing identity.

`admin/deploy/uninstall.sh` stops/disables only `warp-admin.service`, removes
only exact Admin files and directories, and removes the account only when the
root-owned project marker and strict identity both agree. Ambiguous identities
are preserved or rejected, never guessed. It does not delete the shared lock,
restart gateway/Dashboard services, or touch WireGuard, policy routing,
nftables, forwarding, configuration, or identity material.

Release packaging normalizes executable, regular, and sudoers modes for TAR
and ZIP payloads. Extracted-payload validation reruns the same test suite.

## Qualification coverage and remaining non-goals

Focused tests cover the fixed listener, Host/proxy boundary, sessions/CSRF and
expiry, strict body parser, CORS/security headers, per-binding/global limits,
helper input/output and future-operation rejection, no-recovery command,
lock-contention mapping, mutation tripwires, secret canaries, exact sudoers
allow/deny matrix, service identity/hardening, text-only UI, safe
install/reinstall/uninstall, archive modes, Dashboard separation, and full
repository regression.

Slice 1B intentionally does not implement Repair Routing, Connect,
Disconnect, intentional-disconnect state, logs browsing, configuration,
arbitrary commands, Docker Admin Console support, a non-loopback listener,
deployment to a host, a version bump, merge, tag, or release.
