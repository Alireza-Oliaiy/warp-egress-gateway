# Web Console API Contract

## Contract status

This is the Phase 0 contract for `/api/v1/`. It fixes security, roles,
semantics, states, bounds, and field meaning before implementation. Field
additions within an object may be backward-compatible; removing fields,
changing enum meaning, relaxing security, or accepting general command/path
input requires a new API version or an explicit Phase 0 amendment.

The API is available only over the configured HTTPS deployment. There is no
plaintext HTTP management listener.

## Common rules

- Media type is `application/json`; request and response encoding is UTF-8.
- Responses include `Cache-Control: no-store` and do not contain secret data.
- Request bodies are limited to 8 KiB. Unknown or duplicate JSON fields fail.
- Dates use UTC RFC 3339 with seconds, for example `2026-01-02T03:04:05Z`.
- Durations and ages use non-negative integer seconds.
- IPv4 addresses are strings or `null`; synthetic examples use documentation
  prefixes.
- Every request receives a server-generated UUID `request_id`. A valid inbound
  `X-Request-ID` may be retained as `client_request_id` for correlation but
  never controls authorization or privileged input.
- All authenticated endpoints require a valid server-side session.
- All `POST` endpoints require `Content-Type: application/json`, a valid
  session-bound `X-CSRF-Token`, and a matching same-origin `Origin`.
- Mutating controls require a UUID `Idempotency-Key`. Keys are scoped to user,
  operation, and canonical body for ten minutes. Reuse with a different body
  returns `409`.
- The API never returns raw shell, `systemctl`, `journalctl`, `ip`, `nft`, or
  `wg` output.

## Roles

| Role | Capabilities |
|---|---|
| Viewer | Read status, passive health, routing, version, and approved project logs. |
| Admin | Viewer capabilities plus health execution, routing repair, intentional disconnect, and optional networkd log access. |

Authorization is checked before a privileged helper call. A helper request is
still treated as hostile and independently constrained; role checks do not make
helper input trusted.

The internal helper protocol v1 envelope carries a bounded top-level audit
object:

```json
"audit_context": {
  "asserted_actor": "admin-example",
  "asserted_role": "Admin",
  "asserted_source_ip": "127.0.0.1"
}
```

These `asserted_*` values are untrusted audit context only. They never affect
authorization, the validated verb, command construction, paths, arguments,
interfaces, executables, environment, or safety decisions. Authoritative
helper identity comes from effective root, the verified sudo caller
`warp-web`, the fixed helper entry point, protocol, and validated verb.
`asserted_role` accepts only the literal enum `Viewer` or `Admin`.

## Response envelopes

Success:

```json
{
  "api_version": "v1",
  "request_id": "b3e29819-d970-4288-8d4f-c24d6638a42c",
  "observed_at": "2026-01-02T03:04:05Z",
  "data": {}
}
```

Error:

```json
{
  "api_version": "v1",
  "request_id": "b3e29819-d970-4288-8d4f-c24d6638a42c",
  "error": {
    "code": "unsafe_precondition",
    "message": "The operation was refused because a required safety condition was not met.",
    "details": {
      "condition": "kill_switch_active"
    }
  }
}
```

Messages are stable, non-secret summaries. `details` contains enumerated fields
only, never raw child output or stack traces.

A lock conflict uses the stable code `mutation_busy`, includes
`retry_after_seconds: 1`, and sets `Retry-After: 1`. It is never retried by
performing an unlocked mutation.

## Common HTTP status codes

| Status | Meaning |
|---:|---|
| 200 | Synchronous read or action completed and postconditions were evaluated. |
| 400 | Malformed JSON, duplicate/unknown field, invalid header, or invalid cursor. |
| 401 | Missing, expired, or invalid session. |
| 403 | Valid session lacks the role, CSRF failed, or origin is not allowed. |
| 404 | Fixed API resource does not exist; never used to expose host paths/units. |
| 409 | Conflicting action, reused idempotency key, or intentional state conflicts with the request. |
| 422 | Well-formed request violates a documented enum/range/schema. |
| 423 | The shared root mutation lock was not acquired within five seconds; no mutation occurred. |
| 429 | Authentication or request rate limit exceeded. |
| 502 | Helper failed, returned invalid schema, or an approved fixed dependency failed unexpectedly. |
| 503 | Gateway safety/configuration precondition failed or a partial action remained fail closed. |
| 504 | Endpoint/helper deadline expired. |

## Gateway-state vocabulary

Every top-level operational response uses one of:

```text
ok
degraded
failed
intentionally_disconnected
```

`intentionally_disconnected` requires both root-owned intent and matching live
safety evidence. An intent record with missing kill switch or unexpected
routing is `failed`, with the intent details still visible.

## `GET /api/v1/status`

- **Role:** Viewer
- **Request:** no body or query parameters
- **Backend timeout:** 17 seconds
- **Helper:** `status`
- **Audit:** `status.read`, success/failure and duration; sampling may be used
  to limit routine-read audit volume

Example response data:

```json
{
  "state": "degraded",
  "version": "0.4.1",
  "intentional_disconnect": {
    "active": false,
    "since": null,
    "evidence_consistent": true
  },
  "wireguard": {
    "interface": "warp0",
    "link_state": "up",
    "public_key": "PUBLIC_WIREGUARD_KEY_EXAMPLE",
    "handshake": {
      "state": "stale",
      "age_seconds": 180,
      "warning_after_seconds": 120
    }
  },
  "egress": {
    "warp": {
      "state": "on",
      "public_ipv4": "192.0.2.44",
      "cloudflare_colo": "TEST",
      "cloudflare_location": "ZZ",
      "probe_rc": 0
    },
    "direct_management": {
      "state": "ok",
      "public_ipv4": "198.51.100.25",
      "probe_rc": 0
    }
  },
  "routing": {
    "state": "ok",
    "source_rule": {
      "priority": 100,
      "source": "192.0.2.2/32",
      "table_id": 100,
      "state": "ok"
    },
    "transit_ingress_rule": {
      "priority": 110,
      "interface": "transit0",
      "table_id": 100,
      "state": "ok"
    },
    "warp_default": {
      "table_id": 100,
      "interface": "warp0",
      "state": "ok"
    },
    "main_default_preserved": true
  },
  "killswitch": {
    "state": "active",
    "table": "inet warp_gateway",
    "dropped_packets": 12
  },
  "transit": {
    "interface": "transit0",
    "link_state": "up",
    "trusted_source_cidr": "198.51.100.1/32"
  },
  "upstream": {
    "required": true,
    "state": "ok"
  },
  "evidence": {
    "systemd_active": true,
    "dataplane_verified": true,
    "sample_age_seconds": 4
  },
  "warnings": ["wireguard_handshake_stale"]
}
```

The public key is permitted diagnostic data. No private/preshared key or WARP
account field exists in the schema. `systemd_active` cannot set
`dataplane_verified` or determine top-level state.

Additional endpoint-specific failures include `503 unsafe_config`,
`502 evidence_collection_failed`, and `504 status_timeout`. A partial snapshot
may be returned only with `state=failed` and explicit per-field unknown states;
missing evidence is never assumed healthy.

## `GET /api/v1/health`

- **Role:** Viewer
- **Request:** no body or query parameters
- **Backend timeout:** 5 seconds
- **Helper:** `health-read`
- **Audit:** `health.read`
- **Mutation:** none

Response data:

```json
{
  "state": "ok",
  "reason": "none",
  "last_health": {
    "observed_at": "2026-01-02T03:03:45Z",
    "age_seconds": 20,
    "wireguard": "up",
    "direct": "ok",
    "warp": "on",
    "routing": "ok",
    "killswitch": "ok",
    "recovery": "none"
  },
  "last_monitor": {
    "state": "ok",
    "observed_at": "2026-01-02T03:03:30Z",
    "age_seconds": 35
  }
}
```

Stale evidence sets state to `degraded` or `failed` according to the configured
sampling interval and whether live safety evidence is available. Intentional
disconnect is reported without triggering recovery.

During intentional disconnect, health and monitor timers remain active. Their
evidence must show the kill switch active, project routing absent, WireGuard
stopped, direct management alive, and transit blocked. This is a successful
`intentionally_disconnected` observation, not a failed health unit.

## `GET /api/v1/routing`

- **Role:** Viewer
- **Request:** no body or query parameters
- **Backend timeout:** 5 seconds
- **Helper:** `routing-status`
- **Audit:** `routing.read`

Response data:

```json
{
  "state": "ok",
  "source_rule": {
    "priority": 100,
    "expected_source": "192.0.2.2/32",
    "expected_table_id": 100,
    "actual_count": 1,
    "state": "ok"
  },
  "transit_ingress_rule": {
    "priority": 110,
    "expected_interface": "transit0",
    "expected_table_id": 100,
    "actual_count": 1,
    "state": "ok"
  },
  "warp_default": {
    "table_id": 100,
    "expected_interface": "warp0",
    "actual_count": 1,
    "state": "ok"
  },
  "main_default": {
    "managed_by_project": false,
    "changed_by_last_action": false
  },
  "repair_allowed": true,
  "repair_block_reason": null
}
```

State reasons reuse the v0.4.1 vocabulary, including
`source_rule_missing`, `source_rule_mismatch`, `ingress_rule_missing`,
`ingress_rule_mismatch`, `default_route_missing`, and
`default_route_mismatch`. Query failure is distinct from absence.

## `GET /api/v1/version`

- **Role:** Viewer
- **Request:** no body or query parameters
- **Backend timeout:** 3 seconds
- **Helper:** `version`
- **Audit:** `version.read` may be sampled

```json
{
  "installed": "0.4.1",
  "api": "v1",
  "web_component": "0.5.0-development"
}
```

The implementation must define the web component's development/build version
without changing the gateway `VERSION` during Phase 0.

## `GET /api/v1/logs`

- **Role:** Viewer; `source=networkd` requires Admin
- **Helper:** `logs-read`
- **Backend timeout:** 7 seconds
- **Audit:** `logs.read`, including source/window/limit/result count

Allowed query parameters:

| Parameter | Values | Default |
|---|---|---|
| `source` | `gateway`, `firewall`, `healthcheck`, `monitor`, `wireguard`, `networkd` | required |
| `window` | `15m`, `1h`, `6h`, `24h`, `7d` | `1h` |
| `limit` | integer 1-500 | 100 |
| `cursor` | absent or helper-issued opaque cursor, max 256 characters | absent |

No other query parameter is accepted. Values are enums/ranges, not
`journalctl` fragments.

```json
{
  "source": "monitor",
  "window": "1h",
  "records": [
    {
      "timestamp": "2026-01-02T03:03:30Z",
      "priority": "info",
      "source": "warp-monitor",
      "message": "STATUS=OK wg=up handshake=ok ..."
    }
  ],
  "next_cursor": null,
  "truncated": false,
  "returned_records": 1,
  "returned_bytes": 92,
  "limits": {
    "max_records": 500,
    "max_bytes": 262144,
    "max_window": "7d"
  }
}
```

Messages are control-character-normalized, length-bounded, redacted, JSON
encoded, and rendered in the UI as text, never HTML. Redaction removes known
private-key/account/token/password/cookie patterns and defensively suppresses
entire records whose structure cannot be made safe. Truncation is explicit.

## `POST /api/v1/health/run`

- **Role:** Admin
- **Request body:** exactly `{}`
- **Backend timeout:** 47 seconds
- **Helper:** `health-run`
- **Audit:** `health.run`, result, reason, and recovery class
- **Mutation:** may repair policy state; may restart WireGuard only under the
  existing `AUTO_RECOVER=true` tunnel-specific rules

```json
{
  "state": "ok",
  "reason": "none",
  "recovery": "policy",
  "checks": {
    "wireguard": "up",
    "direct": "ok",
    "warp": "on",
    "routing": "ok",
    "killswitch": "ok"
  }
}
```

When root-owned intentional-disconnect intent is active, the operation returns
200 with `state=intentionally_disconnected`, `recovery=none`, and performs no
repair/restart. A malformed intent or missing kill switch returns 503 and
remains fail closed.

If recovery is indicated, health acquires the shared root mutation lock and
then re-reads intent and safety evidence immediately before mutation. Any
valid, corrupt, unsafe, or inconsistent intent refuses recovery. Lock timeout
returns 423 `mutation_busy` and performs no mutation.

## `POST /api/v1/routing/repair`

- **Role:** Admin
- **Request body:** exactly `{}`
- **Backend timeout:** 17 seconds
- **Helper:** `routing-repair`
- **Audit:** `routing.repair` with before/after state and stable reason

```json
{
  "state": "ok",
  "changed": true,
  "before": "source_rule_missing",
  "after": "ok",
  "wireguard_restarted": false,
  "killswitch_changed": false,
  "main_default_changed": false
}
```

The helper refuses with 409 when intentionally disconnected and with 503 when
configuration, WARP interface, WARP IPv4, WireGuard, or kill-switch
prerequisites fail. It cannot restart WireGuard, change the main default,
disable the kill switch, or touch unrelated rules/routes.

Repair holds the shared root mutation lock through its postcondition checks.
It re-reads intent after acquiring the lock. A lock timeout returns 423
`mutation_busy`; it never proceeds unlocked.

## `POST /api/v1/warp/disconnect`

- **Role:** Admin
- **Request body:** exactly
  `{"confirmation":"disconnect-and-block-transit"}`
- **Backend timeout:** 32 seconds
- **Helper:** `warp-disconnect`
- **Audit:** `warp.disconnect`, before/after state, intent creation, and every
  verified postcondition

```json
{
  "state": "intentionally_disconnected",
  "intent": {
    "active": true,
    "since": "2026-01-02T03:04:05Z"
  },
  "routing_removed": true,
  "wireguard_stopped": true,
  "killswitch": "active",
  "transit_behavior": "blocked",
  "main_default_changed": false,
  "automatic_recovery_suppressed": true,
  "health_timer_active": true,
  "monitor_timer_active": true,
  "reconnect": {
    "available_in_web": false,
    "cleared_by_reboot": true,
    "cli_path_required": true
  }
}
```

If the kill switch is not proven active before mutation, the helper refuses
with 503 and changes nothing. If a later postcondition fails, it returns 503
with `state=failed`, leaves intent active, leaves recovery suppressed, and
reports only structured postcondition codes. It never deletes/replaces the
kill switch or enables transit fallback.

Disconnect first acquires the shared root mutation lock, then validates trusted
configuration and kill-switch state, creates or revalidates intent, performs
the routing/WireGuard changes, and verifies final postconditions before
releasing the lock. A five-second acquisition timeout returns 423
`mutation_busy` with no mutation. Health and monitor timers remain enabled;
their recovery branches acquire the same lock and re-read intent.

There is no kill-switch-disable endpoint and no equivalent hidden action.

## Authentication endpoints

### `POST /api/v1/auth/login`

- **Role:** unauthenticated
- **Body:** `{"username":"viewer-example","password":"<submitted>"}`
- **Timeout:** 5 seconds plus bounded rate-limit delay
- **Audit:** `auth.login` success/failure without password or account-existence
  disclosure

On success, rotate to a new server-side session, set
`__Host-warp_session`, and return:

```json
{
  "user": {"username": "viewer-example", "role": "Viewer"},
  "idle_expires_at": "2026-01-02T03:19:05Z",
  "absolute_expires_at": "2026-01-02T11:04:05Z",
  "csrf_token": "returned-to-client-memory-only"
}
```

The CSRF token is intentionally returned to the authenticated application but
is never logged. Login errors use one generic message. Rate-limited responses
use 429 and `Retry-After`.

### `GET /api/v1/auth/session`

- **Role:** Viewer
- **Mutation:** none

Returns username, role, session expiry times, and a refreshed CSRF token when
rotation policy requires it. It never returns the session token.

### `POST /api/v1/auth/logout`

- **Role:** Viewer
- **Body:** exactly `{}`
- **CSRF:** required
- **Audit:** `auth.logout`

The server revokes the session before expiring the cookie. Repeating logout is
safe and does not reveal whether an old token was valid.

## Rate and concurrency limits

- Login: five failed attempts per normalized username and per source IP in five
  minutes, followed by exponential delay capped at 15 minutes. Distributed
  source attempts also have a global bounded limiter.
- Authenticated reads: default 60 requests/minute/session, with a stricter 10
  requests/minute limit for logs.
- Mutating controls: one running operation globally and no more than five
  attempts per Admin per minute.
- Rate-limit state is bounded and expired; attacker-selected keys cannot cause
  unbounded memory growth.

## Audit event schema

Security-sensitive requests produce structured events:

```json
{
  "timestamp": "2026-01-02T03:04:05Z",
  "request_id": "b3e29819-d970-4288-8d4f-c24d6638a42c",
  "user": "admin-example",
  "role": "Admin",
  "source_ip": "127.0.0.1",
  "operation": "warp.disconnect",
  "target": "warp-dataplane",
  "result": "success",
  "failure_reason": null,
  "duration_ms": 841
}
```

Audit serialization treats all strings as data. Passwords, hashes, cookies,
session/CSRF tokens, authorization headers, WireGuard private/preshared keys,
WARP account data, and TLS private keys are forbidden fields.

This application event uses the human-facing names above. The corresponding
root helper event names all web-supplied identity fields `asserted_actor`,
`asserted_role`, and `asserted_source_ip`; they remain untrusted audit-only
data and are recorded alongside authoritative effective UID, sudo caller,
fixed helper/protocol, and validated verb.

## Browser security response headers

Every UI/API response uses a restrictive header baseline:

```text
Strict-Transport-Security: max-age=31536000
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Permissions-Policy: camera=(), microphone=(), geolocation=(), usb=()
Cache-Control: no-store
```

The implementation must not require inline scripts or `unsafe-eval`. Dynamic
log/status text is inserted using text-safe DOM APIs.
