# Web Console Threat Model

## Scope

This threat model covers the optional v0.5.0 Native Web Management Console,
its browser/API surface, local authentication/session state, the single
privileged helper boundary, approved host observations/actions, and its
interaction with the v0.4.1 fail-closed dataplane.

It assumes the operating system, kernel, systemd, sudo, and root-owned project
files begin trusted. It does not assume the browser, request data, journal
messages, the `warp-web` process, helper input, or a local unprivileged user are
trusted.

## Security objectives

1. Never disclose WireGuard private keys, WARP account material, credentials,
   session secrets, arbitrary files, or TLS private keys.
2. Never allow web control to route transit traffic through the management
   uplink or disable/bypass the kill switch.
3. Limit a compromised web process to a small set of fail-closed verbs.
4. Preserve CLI/dataplane availability independently of the console.
5. Authenticate users, enforce Viewer/Admin roles, resist session/CSRF abuse,
   and audit security-sensitive operations.
6. Bound CPU, memory, processes, output, journal access, and request time.

## Assets

- WARP/WireGuard identity and private material.
- Integrity of the nftables kill switch and project policy routing.
- Integrity of the host main/default management route.
- Availability of management access and selected transit service.
- Local user password hashes, sessions, CSRF tokens, and TLS private key.
- Project configuration, operational logs, audit records, and release version.
- Root authority exposed through the helper.

## Trust boundaries

```text
Untrusted network/browser
        | HTTPS + authentication + CSRF
        v
Unprivileged warp-web
        | sudo: one fixed zero-argument helper
        v
Root helper
        | fixed paths, fixed argv, project-only mutations
        v
Host control plane and dataplane
```

## Threat analysis

| Threat | Impact | Existing protection | Required v0.5.0 mitigation | Residual risk |
|---|---|---|---|---|
| Remote unauthenticated attacker | Account compromise, information disclosure, action abuse, or denial of service. | Gateway management is already expected on a trusted management path. | Loopback-only HTTPS by default; SSH forwarding for remote access; no HTTP/wildcard bind; local authentication; generic errors; rate and size limits. | Attackers with SSH/network reach can still consume bounded login resources or exploit an unknown web/TLS defect. |
| Authenticated Viewer | Attempts Admin actions or extracts sensitive host data through read APIs. | Existing CLI requires root and has no Viewer surface. | Deny-by-default route authorization; per-endpoint role checks; no control endpoint for Viewer; bounded approved logs; helper remains safe if role checks fail. | Viewer can see operational metadata, public IPs, configured project CIDR, and public WireGuard key. |
| Compromised Admin browser/session | Executes all allowed Admin controls, repeatedly disconnects or repairs routing. | Kill switch and routing scope already constrain runtime behavior. | SameSite/CSRF/origin controls; short idle/absolute sessions; recent session rotation; idempotency; rate limits; helper postconditions; no kill-switch disable or generic action. | A valid Admin session can intentionally cause bounded service disruption, including transit disconnect. |
| CSRF | Tricks an authenticated browser into a privileged action. | None for the current CLI-only runtime. | `SameSite=Strict`, session-bound synchronizer token, same-origin `Origin` validation, JSON-only unsafe methods, no state-changing GET. | Browser/plugin defects or same-origin compromise can bypass browser-layer protections. |
| XSS | Steals CSRF data, performs actions in an authenticated session, or falsifies UI state. | No current browser UI. | Context-safe encoding; render logs as text; strict CSP without inline/eval; no third-party scripts; security headers; dependency review. | Same-origin framework/browser vulnerability can act with the current user's role; HttpOnly still protects direct cookie reads. |
| Command injection | Converts API/helper input into root shell execution. | Existing scripts use fixed project commands but were not designed as a web RPC layer. | One non-shell helper; fixed verbs; direct absolute argv; zero helper CLI args; strict JSON; no shell/eval/interpreters selected by input. | Vulnerabilities inside the helper or a fixed child executable remain privileged risk. |
| Argument injection | Adds flags, units, interfaces, routes, or journal expressions to fixed commands. | Existing CLI loads root-controlled configuration. | Caller cannot supply command arguments except strict `logs-read` enums/ranges; use `--` where supported; construct argv from trusted parsed config; reject leading-hyphen identifiers. | A bug in strict parsing or argv construction could widen a fixed operation. |
| Path traversal/arbitrary file access | Reads secrets or overwrites root files. | Sensitive WARP material is root-only. | No path fields in helper protocol; fixed configuration, version, state, and executable paths; safe open/type/owner/mode checks; no file-download endpoint. | Root helper implementation bugs involving symlinks or temporary files remain possible. |
| SSRF | Uses the host to scan internal services or exfiltrate data. | Health URL is root-controlled configuration. | No caller-provided URL/host/port; status probes use only the validated fixed project health URL; no generic fetch/proxy endpoint; redirect policy is fixed and restrictive. | A compromised root-owned configuration can redirect probes; that is outside the web trust boundary. |
| Authentication brute force | Recovers weak passwords or exhausts authentication resources. | No existing web authentication. | Argon2id; strong-password policy; per-account/source/global rate limits; exponential delays; generic failure messages; structured audit/alerting. | Distributed low-rate attacks remain; password strength and operational alert response matter. |
| Username enumeration | Discovers valid operator accounts. | No current web users. | Identical login response/status/timing envelope for unknown user and wrong password; bounded dummy Argon2id verification. | Statistical timing differences may remain and require testing. |
| Session theft | Attacker reuses a cookie to impersonate a user. | No current web session. | CSPRNG tokens; server-side digest; Secure/HttpOnly/`__Host-` cookie; TLS only; idle and absolute expiry; logout revocation; no token logging. | Malware, browser compromise, or TLS endpoint compromise can use an active session until revocation/expiry. |
| Session fixation | Attacker chooses or preserves a token through login/role change. | No current web session. | Ignore caller session IDs; rotate after login and privilege changes; invalidate pre-auth state; bind CSRF to the new session. | Same-origin compromise can still operate the newly rotated session. |
| Replayed privileged action | Repeats disconnect/repair/health actions after a network retry or captured request. | Existing CLI is interactive/local. | TLS; session+CSRF; UUID idempotency key bound to user/verb/body; short retention; serialized actions; audit duplicate results. | An active compromised Admin session can intentionally submit new keys. |
| Malicious log contents | Injects HTML, terminal controls, fake audit lines, huge messages, or secret-looking data. | Journald stores structured metadata and seven-day bounded history. | Fixed sources; JSON serialization; control-character normalization; message length/byte/line limits; redaction; UI text rendering; never trust log severity/source text. | Sensitive content produced by another root service may evade pattern redaction, so log scope must stay narrow. |
| Privilege escalation from `warp-web` | Gains root or arbitrary host control. | Root-owned project files and sudo boundaries. | Dedicated no-login user; no network capabilities; single zero-argument helper sudo rule with `NOSETENV`; fixed verbs/paths/argv; short-lived helper; OS sandboxing in implementation. | Any memory-safety/parser/logic defect in helper or sudo itself can be a root escalation path. |
| Malicious local user | Reads sessions/TLS keys, calls helper, tampers with runtime intent, or binds the service port. | Unix ownership/modes, sudo policy, root configuration. | `0700` web state; root-owned sudoers/helper/intent; helper verifies sudo caller; protected service identity; fail on unsafe file ownership/type/mode. | Root or equivalent host compromise is out of scope; local denial of service may still be possible through shared resources. |
| Denial of service | Exhausts worker threads, helper processes, Argon2 memory, journal reads, disk, or action locks. | Journald usage is bounded; current monitors use timeouts. | Connection/body/header deadlines; bounded workers/queues; Argon2 concurrency cap; global helper/action concurrency; rate limits; 8 KiB input; 256 KiB output; fixed action deadlines. | A local or management-network attacker can still cause bounded service unavailability; dataplane must remain independent. |
| Oversized responses | Consumes memory/bandwidth or crashes browser/backend. | Monitor lines are small but journal records are not guaranteed small. | Maximum 500 log records/256 KiB; per-field lengths; status 64 KiB; helper kills/refuses over-limit children; explicit truncation metadata. | Required evidence may be omitted during an output-limit failure; state must then be failed/unknown, never healthy. |
| Slow requests/slow clients | Occupies sockets/workers and blocks management. | No current web listener. | TLS handshake, header, body, response-write, and idle deadlines; minimum transfer rates; bounded keep-alive; reverse-proxy equivalents required. | Enough distributed clients can exhaust the configured connection limit. |
| Secret leakage in API/UI | Exposes private keys, accounts, passwords, tokens, or arbitrary files. | WARP profiles/account files are root-only and excluded from Git. | Explicit denylist; schema allowlist; no raw command/file responses; secret-marker tests; redaction; no debug traces; `Cache-Control: no-store`. | New fixed command output may introduce an unrecognized secret and requires review before allowlisting. |
| WireGuard `PrivateKey` exposure | Full WARP identity compromise. | `/etc/wireguard` is root-only. | Helper never reads full config or private-key commands; only public key and selected live fields are allowed; seeded private-key tests across logs/API/errors. | Root compromise or an unrelated root service logging the key is out of the web control, but bounded logs must still redact it. |
| Accidental fail-open routing | Transit falls through the host main uplink during repair/disconnect/failure. | Independent semantic kill switch; v0.4.1 scoped policy routing. | Verify kill switch before mutation; never change main default; disconnect removes project rules while retaining guard; postcondition checks; failures preserve intent and suppress recovery. | Kernel/nftables defects or independent root modification can violate assumptions and must surface as failed. |
| Disabling/bypassing kill switch | Direct transit leak or loss of fail-closed guarantee. | Firewall guard lifetime is independent and stop is a no-op. | No API/helper verb to disable/remove/reload it; helper cannot call firewall removal; every mutation checks semantic drop rule; UI offers no disable control. | Root/local administrator actions outside the console can still alter nftables. |
| Recovery defeats intentional disconnect | Health timer or Admin health run reconnects WARP after deliberate shutdown. | v0.4.1 recovery has explicit prerequisites but no intentional state yet. | Atomic root-owned `/run` intent; health/monitor check before any recovery; stop/suppress recovery during disconnect; corrupt intent suppresses recovery; reboot/guarded CLI start may clear. | A root actor can delete the runtime record; reboot intentionally clears it and reconnects through normal boot. |
| Web-server compromise | Attacker falsifies UI, steals web-held data, or invokes all helper verbs. | Dataplane is already independent of any web component. | Unprivileged account; minimal dependencies; read-only application files; systemd sandboxing; helper assumes hostile caller; no dataplane startup dependency. | Admin-equivalent bounded disruption and access to web-held hashes/sessions/TLS key remain possible. |
| Authentication database theft | Enables offline password cracking or session analysis. | Future web state is separated from root WARP state. | `0700` state directory; Argon2id with per-user salt; session token digests; no plaintext passwords/tokens; backup documentation must classify it sensitive. | Weak user passwords can be cracked offline; a live web compromise can observe future logins. |
| TLS downgrade/misconfiguration | Credentials/session exposed over plaintext or wrong interface. | No current web listener. | No HTTP listener; loopback HTTPS default; startup refusal without valid key/cert; no wildcard/transit bind; HSTS; explicit opt-in management/reverse-proxy modes. | Users can ignore certificate warnings or misconfigure an opt-in proxy; documentation and validation reduce but cannot remove this risk. |
| Dependency/supply-chain compromise | Malicious package gains web identity or reaches root helper. | Released project pins/reviews artifacts and runs CI. | Minimize dependencies; lock versions/check hashes; prefer OS-supported components; generate SBOM; review transitive dependencies; no CDN scripts; helper dependency set kept smaller than web stack. | Trusted upstream/build systems can be compromised; root helper dependencies have especially high impact. |
| Audit-log injection or omission | Hides actions or misattributes an operator. | Journald provides host-controlled timestamps/metadata. | Structured fields; escaping and length bounds; application and helper events with same request ID; root-side records include sudo caller and result; never trust actor for authorization. | A compromised web process can lie about asserted username; helper logs still establish the local service caller, not human cryptographic non-repudiation. |
| Configuration injection | Shell syntax in `warp-gateway.env` executes as root in helper. | Existing runtime sources root-owned configuration. | Helper uses a strict non-executing parser, fixed path, allowlisted keys, owner/mode/type checks, and per-field validation. | A root attacker can replace both config and binaries; root compromise is out of scope. |
| Confused-deputy role bypass | Viewer causes `warp-web` to invoke an Admin helper verb through a route/parser bug. | Roles are new in v0.5.0. | Central deny-by-default authorization; generated route-to-role table tests; CSRF on all controls; helper operations remain intrinsically scoped/fail closed. | Because helper sees one Unix service identity, it cannot independently prove the human role; web authorization remains a critical layer. |
| UI reports false health | Operator trusts a green state based only on unit activity or stale cached data. | v0.4.1 validates live policy objects and WARP trace. | Required live evidence; explicit timestamps/ages/unknowns; systemd is telemetry only; deterministic four-state model; no missing-evidence-as-healthy rule. | External reachability can change immediately after sampling; timestamps expose this unavoidable observation gap. |
| Cross-host/proxy header spoofing | Attacker controls source IP/audit identity or bypasses secure-transport assumptions. | Default listener is local direct TLS. | Ignore forwarded headers by default; reverse-proxy mode uses a fixed local socket and explicit trusted-proxy configuration; application auth always required. | A compromised trusted proxy can spoof source metadata and observe sessions. |

## Abuse cases that must be tested

- A request uses `verb="systemctl"`, adds an unknown JSON field, duplicates a
  key, exceeds 8 KiB, or supplies an array/object where an enum is expected.
- `logs-read` supplies `source="../../etc/shadow"`, `window="--since boot"`,
  a leading-hyphen cursor, a regular expression, or more than 500 records.
- The environment contains hostile `PATH`, `LD_PRELOAD`, `PYTHONPATH`,
  `BASH_ENV`, config paths, locale, or proxy variables.
- Root configuration contains shell substitutions or newline/argument payloads;
  strict parsing rejects rather than executes them.
- A log record includes HTML/script, ANSI controls, fake JSON, a seeded
  `PrivateKey`, cookie, password, and a multi-megabyte message.
- Disconnect is requested with a missing/invalid kill switch, during a routing
  repair, twice with different idempotency keys, or while a timer is firing.
- Health/monitor runs with valid, corrupt, unsafe-mode, and symlink intent
  records; none may recover WARP while intent is active/unsafe.
- Routing repair is attempted with absent WireGuard, missing WARP IPv4, invalid
  config, inactive kill switch, or intentional disconnect.
- A status response has `systemd_active=true` while policy rules are missing;
  top-level state must be `failed`.
- Main default route and unrelated rule/nftables fixtures are hashed before and
  after every mutating test and must remain unchanged.

## Residual-risk acceptance

Phase 0 accepts that a compromised Admin session or `warp-web` process can
invoke the fixed disconnect action and cause a fail-closed transit outage. It
does not accept arbitrary root execution, secret access, kill-switch removal,
main-route changes, or transit fallback. The console is an administrative
surface, so operators must retain SSH/CLI access and management-network controls
for recovery.
