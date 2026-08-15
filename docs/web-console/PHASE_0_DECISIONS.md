# Web Console Phase 0 Decisions

## Purpose

This ledger separates requirements that implementation must not reinterpret
from capabilities intentionally left for later releases. A future change to a
FROZEN security or fail-closed decision requires an explicit architecture
review and documentation update before code changes.

## FROZEN

### Product boundary

- The Web Management Console is optional.
- The existing CLI/runtime remains authoritative and usable without the web
  component.
- Web failure, helper failure, authentication failure, and web uninstallation
  do not affect normal dataplane startup or operation.
- Phase 0 changes documentation only. `VERSION` remains `0.4.1` and no runtime,
  installer, upgrade, Docker, systemd, authentication, TLS, API, or dependency
  code is added.
- The initial implementation target is Native deployment. Docker web-console
  support is not implicitly covered by this design.

### Architecture and privilege

- `warp-web` runs as a dedicated unprivileged, no-login system account.
- One short-lived root-owned helper invoked through sudoers is the selected
  v0.5.0 privilege architecture.
- Sudoers authorizes only one fixed absolute helper entry point with zero
  command-line arguments and `NOSETENV`.
- Helper requests use one bounded versioned JSON object on stdin.
- `warp-web` never invokes project scripts, `systemctl`, `journalctl`, `ip`,
  `nft`, `wg`, shells, interpreters, or arbitrary executables through sudo.
- The helper provides only fixed verbs: `status`, `health-read`, `health-run`,
  `routing-status`, `routing-repair`, `warp-disconnect`, `logs-read`, and
  `version`.
- There is no arbitrary command, command-name, shell-fragment, interface-name,
  path, service-name, unit, environment, route, firewall, or URL parameter.
- The helper clears caller environment, uses fixed absolute executables/direct
  argv, never invokes a shell, and applies strict deadlines/output limits.
- Trusted gateway configuration is read from fixed root-owned project paths and
  parsed as data. The helper never sources it as shell code and never honors
  caller path/environment overrides.
- Raw child stdout/stderr is not the API contract. The helper and backend
  validate structured schemas.
- A compromised `warp-web` process must remain limited to the helper allowlist
  and cannot disable the kill switch or gain a general root primitive.

### State model and evidence

- API/UI top-level state distinguishes at least `ok`, `degraded`, `failed`, and
  `intentionally_disconnected`.
- Systemd `active` state alone is never evidence of a healthy dataplane.
- Healthy state requires actual interface, direct/WARP probe, routing,
  kill-switch, and required upstream evidence.
- A current `warp=on` probe outweighs stale/absent passive handshake telemetry;
  that condition may be degraded but is not alone a failure.
- Missing/unknown required evidence never defaults to healthy.
- WireGuard public keys may be returned as authenticated diagnostics.
- WireGuard private/preshared keys and WARP account material never enter the
  helper response, API, UI, logs, or audit events.

### Intentional disconnect

- `warp-disconnect` creates explicit root-owned runtime intent at the fixed
  `/run/warp-egress-gateway/intentional-disconnect.json` path.
- The intent directory is root-owned mode `0700`; the atomic record is
  root-owned mode `0600` and cannot be written/deleted by `warp-web`.
- Disconnect first acquires the fixed shared root mutation lock, then validates
  configuration and kill-switch state, creates or revalidates intent, performs
  every mutation, and verifies final postconditions before releasing the lock.
- Kill-switch validity is verified before the intent or dataplane is changed.
- Intentional disconnect removes only project-owned policy rules and the WARP
  table default, stops WARP as appropriate, and leaves the nftables kill switch
  active.
- Transit becomes intentionally blocked and never falls through to the main
  management uplink.
- The host main/default route is captured and verified unchanged.
- Health and monitor logic distinguish intentional disconnect from failure and
  never repair/restart WARP while valid or unsafe/corrupt intent exists.
- Health and monitor timers remain enabled and active. They report
  `intentionally_disconnected` as a successful observation, verify kill switch
  active, routing absent, WireGuard stopped, direct management alive, and
  transit blocked, and do not make their systemd units fail for this state.
- A partial disconnect failure leaves intent/recovery suppression active and
  remains fail closed.
- Reboot clears `/run` intent and permits the established fail-closed boot
  sequence to reconnect. A future explicit CLI start/reconnect operation may
  clear intent only as part of a safety-verified reconnect.
- The initial web UI/API has no reconnect operation and no kill-switch-disable
  operation.

### Shared root mutation lock

- `/run/warp-egress-gateway/mutation.lock` is the single stable root-owned mode
  `0600` exclusive lock for the boot; its parent is root-owned mode `0700`.
- Periodic and manual health recovery, helper routing repair, disconnect,
  route-up/policy activation, and any future explicit reconnect/start use this
  same host lock. Application-process serialization is not sufficient.
- Lock acquisition is bounded to five seconds. Timeout returns structured
  `mutation_busy`, makes no mutation, and never falls back to unlocked work.
- Every recovery path acquires the lock and re-reads intent and safety evidence
  under it immediately before mutation. Valid, corrupt, unsafe, or inconsistent
  intent forbids recovery.
- Route-up and repeated project route service starts refuse to apply routing
  while intent exists. Reboot clears `/run`, allowing normal fail-closed boot.
- The firewall guard remains independent: it installs fail-closed nftables
  safety and never waits on this WARP/routing mutation lock.

### Routing repair and health

- Routing repair uses the existing v0.4.1 policy-only model.
- It requires valid trusted configuration, expected WARP interface/WireGuard
  state, WARP IPv4, active semantic kill switch, and no intentional-disconnect
  intent.
- Repair and recovery hold the shared root lock through exact postconditions;
  intent absence observed before locking is never sufficient.
- It may change only the configured source rule priority, transit-ingress rule
  priority, and default route in the configured WARP table.
- It never changes the main/default route, unrelated rule priorities/routes,
  WireGuard lifecycle, forwarding, nftables, or host network management.
- It verifies exact postconditions and refuses safely when prerequisites fail.
- `GET /health` is passive. `POST /health/run` is Admin-only because existing
  health semantics may repair policy routing or, when configured, restart the
  tunnel for tunnel-specific failure.

### Authentication and authorization

- Initial authentication is a local user database with Viewer and Admin roles.
- Viewer is read-only for status, passive health, routing, version, and approved
  project logs. Optional networkd logs require Admin.
- Admin receives only the explicit health-run, routing-repair, and disconnect
  controls.
- Passwords use Argon2id with unique salts and parameters no weaker than 64 MiB
  memory, three iterations, one lane, and 32-byte output.
- There is no default username/password and no browser first-user enrollment.
- First Admin bootstrap is an offline root-authorized local operation.
- Sessions use at least 256 bits of CSPRNG entropy and server-side one-way token
  storage; they rotate after login/privilege changes.
- Cookie name/attributes are `__Host-warp_session`, `Secure`, `HttpOnly`,
  `SameSite=Strict`, `Path=/`, and no `Domain`.
- Session idle timeout is 15 minutes; absolute timeout is eight hours.
- Logout revokes server-side state before expiring the cookie.
- Unsafe methods require a session-bound CSRF token, same-origin validation,
  and JSON content type. State-changing GET requests do not exist.
- Login rate limiting covers normalized account, source, and global pressure;
  errors do not reveal account existence.
- Mutations are serialized by the shared root lock, rate limited, audited, and
  protected by scoped UUID idempotency keys.

### TLS and exposure

- Safe default is direct HTTPS bound only to an explicit loopback address.
- SSH local port forwarding is the documented default remote-access method.
- There is no plaintext HTTP management listener, wildcard bind, automatic
  management bind, or transit-interface bind.
- Missing/unsafe TLS material causes startup failure, never HTTP fallback.
- Management-interface HTTPS and reverse-proxy-over-local-socket deployments
  are explicit opt-in modes and retain application authentication.
- Management binding requires one explicit management IP plus upstream/host
  source restrictions.
- Certificates and private keys are provisioned/generated on the host, never
  committed or returned by the API. Renewal failure never downgrades transport.
- Forwarded identity/source headers are ignored by default.

### API and logs

- API namespace is `/api/v1/` with JSON schemas and `Cache-Control: no-store`.
- Required endpoints are:
  - `GET /status`, `/health`, `/routing`, `/version`, `/logs`
  - `POST /health/run`, `/routing/repair`, `/warp/disconnect`
  - local-auth login, session, and logout endpoints
- Each endpoint has a fixed role, schema, timeout, helper mapping, audit event,
  HTTP status/failure semantics, and response size.
- Unknown/duplicate fields are rejected. Mutating request bodies have no
  general arguments; disconnect requires a fixed confirmation literal.
- Logs are limited to approved project sources and optional networkd
  diagnostics.
- `logs-read` accepts only source/window enums, integer limit 1-500, and a
  helper-issued opaque cursor. It accepts no journal arguments, units, paths,
  regex, format, or arbitrary time expression.
- Maximum log window is seven days; maximum response is 500 records and
  256 KiB.
- Log content is bounded, redacted, control-character-normalized, JSON encoded,
  and rendered as text rather than HTML.
- Browser responses use restrictive CSP, HSTS, frame denial, no-sniff,
  no-referrer, no-store, and permissions policy. Inline/eval script is not
  required.

### Auditing

- Application and helper both emit structured events linked by request ID.
- Helper protocol v1 carries exactly one bounded top-level `audit_context` with
  `asserted_actor`, `asserted_role` (`Viewer` or `Admin`), and
  `asserted_source_ip`.
- These `asserted_*` values are untrusted audit-only data. They never affect
  authorization, verb selection, commands, files, arguments, interfaces,
  executables, environment, or safety decisions.
- Helper events use the `asserted_*` names and also record authoritative
  effective root identity, verified sudo caller `warp-web`, fixed helper and
  protocol, validated verb, result, stable failure reason, and duration.
- Mutations record bounded before/after safety state.
- Passwords/hashes, cookies, session/CSRF tokens, authorization headers,
  private/preshared keys, account secrets, and TLS private keys are never logged.
- User/log strings are escaped and length bounded; they never become log format.

### Fail-closed invariants

1. Web Console failure does not affect dataplane operation.
2. Web Console is never required for gateway startup.
3. Web crash cannot disable or remove the kill switch.
4. Authentication, authorization, CSRF, configuration, and parsing failures
   fail closed.
5. Helper failure/timeout/output overflow fails closed.
6. Disconnect blocks transit instead of leaking it through management.
7. Web actions never change unrelated host routes, rules, firewall state, or
   network services.
8. `PrivateKey` and account secrets never cross the API/log/UI boundary.
9. UI state is based on actual dataplane evidence, not only systemd activity.
10. Existing CLI remains available and authoritative without the console.
11. No WARP/routing mutation occurs without the shared root lock.
12. Intent is rechecked under lock immediately before any recovery mutation.

### Mandatory concurrency and intent tests

- healthcheck already running when disconnect begins;
- disconnect running when the health timer fires;
- routing repair racing health recovery;
- repeated route service start while intent exists;
- health timer stays active while intentionally disconnected;
- monitor stays active while intentionally disconnected;
- health returns `intentionally_disconnected` without a failed unit;
- lock timeout never permits unlocked mutation;
- intent is rechecked under lock immediately before recovery;
- route-up cannot reapply while intent exists;
- reboot-cleared `/run` restores normal boot;
- asserted audit metadata cannot affect authorization or command construction.

## DEFERRED

- Implementation language, web framework, UI framework, build tool, and exact
  packaging mechanism. Selection must satisfy the frozen security contract and
  dependency-review requirements.
- Runtime, installer, upgrade, rollback, systemd, sudoers, helper, API,
  authentication, TLS, UI, and test implementation. Phase 0 writes no code.
- Web-based reconnect/start. Initial recovery uses the existing/future explicit
  CLI path or reboot semantics.
- Persistent disconnect across reboot.
- Password-change and user/role administration UI. Initial management may use
  an offline root-authorized local CLI.
- LDAP and OIDC.
- Multi-factor authentication and hardware-backed credentials.
- Multiple gateway hosts, clustering, remote agents, or centralized control.
- Docker Web Console support.
- IPv6 management listener and IPv6 transit management.
- Automated certificate enrollment/renewal provider. The file/permission and
  no-fallback contract is frozen; provider integration is not.
- Trusted reverse-proxy identity, client certificates, and source-header
  contracts.
- Long-term audit export/SIEM integration beyond structured local events.
- Additional controls such as reconnect, restart, diagnostics bundle, upgrade,
  rollback, configuration editing, or user management. Each needs a separate
  allowlist/threat review.

## OPEN QUESTION

None for the Phase 0 security architecture or initial API semantics.

Implementation technology choices are deliberately DEFERRED, not open-ended
permission to alter the frozen privilege, authentication, TLS, state, API, or
fail-closed contracts.
