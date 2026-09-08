# Slice 1B: read-only Admin Console

Slice 1B adds a separate, management-network administrative observation plane to
the v0.5.1-derived Native gateway. It implements only Passive Status and Run
Health. It does not add routing repair, WARP lifecycle, intentional-disconnect,
configuration, upgrade, rollback, reboot, or another mutation authority.

## Installed boundary

The dedicated resources are:

```text
/opt/warp-egress-admin-console/app/admin/
/run/warp-egress-admin-console/
/etc/warp-egress-admin-console/network.json
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

The only production socket is one IPv4 `AF_INET` listener at
`<management-ip>:8788`. Admin reuses the explicit `DASHBOARD_LISTEN` setting
in root-owned `/etc/warp-egress-dashboard/dashboard.env`; it does not import
or change the Dashboard application. The zero-argument root installer reads
only the uplink/transit/WARP interface roles from
`/etc/warp-egress-gateway/warp-gateway.env`, without sourcing shell code.
These fixed-path inputs and their parent directories must be root-owned,
non-symlink, and not group/other writable; reads are bounded.

The selected address must be the sole global IPv4 assigned to the trusted
uplink and must not also appear on transit. Fixed read-only
`ip -j -4 address show dev <trusted-interface>` observations verify membership.
No DNS, first-interface guessing, request data, environment, command-line
address override, or wildcard fallback is used. Missing, duplicate, malformed,
ambiguous, unassigned, loopback, wildcard, multicast, link-local, transit, and
IPv6 configurations fail closed before account creation or installation.

The installer atomically writes a non-secret root:root 0644 projection,
`/etc/warp-egress-admin-console/network.json`, with only the address and
uplink/transit interface names. Its parent stays root:root 0755; the account
marker remains 0600 and the private runtime directory remains warp-admin 0700.
This is generated data, not a second independently editable address setting.
At startup the unprivileged service validates that projection, checks the
current Dashboard address still agrees, and repeats local address membership
inspection. It never reads the root-private gateway file. After trusted
address/interface-role changes, rerun the Admin installer under the reviewed
deployment procedure; stale or unsafe inputs do not fall back to loopback.

Open `http://<management-ip>:8788` directly from the trusted management network.
For example, CC uses `http://172.21.31.5:8788`; an HQ configuration can select
`http://172.20.31.5:8788` without source edits. The Dashboard remains at
`http://<management-ip>:8787`. SSH tunneling is not the product access model.

HTTP is unencrypted and this slice adds no individual operator authentication.
Every client able to reach the management listener can establish a browser
binding and invoke the two read-only operations. The network must therefore
already restrict access to trusted management clients. Binding and CSRF are
not authentication or protection against an on-path attacker. This installer
does not create firewall rules or claim that address binding is a source-network
ACL. No TLS, proxy, external identity service, or new privilege is added.

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

Every request requires the single exact `Host: <management-ip>:8788`. Missing,
duplicate, alternate, absolute-form, forwarded-host, and proxy-style requests
fail before helper invocation. Query strings are not accepted.

`GET /` creates independent 256-bit opaque binding and CSRF values. The
binding cookie is host-only, `HttpOnly`, `SameSite=Strict`, `Path=/`, has no
`Domain`, and deliberately has no misleading `Secure` attribute on the
explicit HTTP URL. Records exist only in process memory, expire after 15
minutes of inactivity or eight hours absolute, are bounded to 1,024 entries,
and rotate on restart. POST requires the valid binding, a constant-time CSRF
match, and exact `Origin: http://<management-ip>:8788`; Referer is not a fallback.

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
source IP:

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

The service account must start with zero inheritable, permitted, effective,
and ambient capabilities, a
private temporary/device view, strict system/home/kernel/control-group
protection, memory-write/execute denial, personality/realtime restrictions,
and only `AF_INET`, `AF_UNIX`, and `AF_NETLINK`. `AF_NETLINK` is required by
the fixed root evaluator's WireGuard/nftables observations. The service is
ordered after the early firewall guard and exposes only the existing
root-owned `/run/warp-egress-gateway` directory as writable inside its strict
mount namespace; Unix ownership and mode still deny `warp-admin`, while the
root helper can open the established shared lock.

Capability Evidence Harness V2 conclusively captured a stable CC Python
MainPID with `CapInh=0000000000200100` (`CAP_SETPCAP`, `CAP_SYS_ADMIN`), while
`CapPrm`, `CapEff`, and `CapAmb` were zero. This was latent inheritable
capability exposure, not active application privilege. Qualification stopped
and the dedicated uninstaller restored the Slice 1A baseline.

The minimal policy is now:

```ini
CapabilityBoundingSet=~CAP_SETPCAP CAP_SYS_ADMIN
AmbientCapabilities=
```

The inverted bounding policy removes only these two capabilities from the
otherwise available set. In Ubuntu 24.04's systemd 255 execution path, systemd
temporarily retains them to install seccomp filters without forcing
`NoNewPrivileges`, then explicitly drops them from inheritable, permitted and
effective sets when the requested bounding policy excludes them. See the
[systemd execution implementation](https://github.com/systemd/systemd/blob/v255/src/core/exec-invoke.c)
and [capability operations](https://github.com/systemd/systemd/blob/v255/src/basic/capability-util.c).

`CapBnd` intentionally remains non-zero; it is not a set of currently held
application privileges. `CAP_SETUID`/`CAP_SETGID` remain available for ordinary
setuid-root sudo, as do `CAP_NET_ADMIN`/`CAP_NET_RAW` for the fixed evaluator's
network observations. Neither excluded capability is needed by the helper's
status/health operations. The exact zero-argument `NOPASSWD:NOSETENV` sudoers
boundary is unchanged. An empty bounding set, `NoNewPrivileges=true`, and
`PrivateUsers=true` remain intentionally absent because they would constrain
or prevent that transition.

Older systemd versions may implicitly enable `NoNewPrivileges` with seccomp
hardening; merely omitting the directive is not proof of a working sudo path.
Local syntax and fixture results do not replace a **fresh full CC host
qualification**, including real process masks and the sudo/helper path.
The prior loopback candidate was qualified separately; the management-direct
change requires fresh full host qualification and is not deployed by local tests.

## Audit model

The application and helper emit linked, bounded journald records for
`requested`, `started`, and `completed` or `failed`. Records include protocol,
canonical request ID, fixed action, monotonic duration, stable result code,
and `changed=false`. Helper-side records are authoritative for privileged
execution. No individual operator identity is fabricated, and cookie/CSRF values,
secrets, raw HTTP bodies, raw child output, stderr, profiles, or environment
are never logged.

## Install, uninstall, and rollback scope

`admin/deploy/install.sh` creates or strictly validates the dedicated locked
identity, root-owned application/helper/protocol/unit/sudoers assets, private
runtime directory, sudoers syntax, service state, exact listener, and a
session-bound status smoke test. Conflicting identity, symlink, ownership, or
mode state fails closed. Reinstallation is deterministic and preserves a safe
pre-existing identity.

### Shared runtime prerequisite (fresh installation and reboot)

A fresh HQ installation exposed `226/NAMESPACE` before `ExecStart`: the mandatory
`ReadWritePaths=/run/warp-egress-gateway` directory did not exist. The lock helper
can create it only after execution starts, which is too late for systemd's mount
namespace setup. An already-existing directory had masked this on CC.

The packaged `admin/deploy/tmpfiles/warp-egress-admin-console.conf` is installed
at `/etc/tmpfiles.d/warp-egress-admin-console.conf` as a regular root:root `0644`
file, containing exactly:

```text
d /run/warp-egress-gateway 0700 root root -
```

Before installation, any existing shared parent must be a non-symlink directory
with exactly root:root `0700` metadata. Unsafe ownership, group, mode, or type is
rejected, not repaired by tmpfiles. The installer validates the root-controlled
packaged rule, installs it, invokes `systemd-tmpfiles --create` for **only that
fixed configuration**, and revalidates the parent before activating Admin.
Failure stops installation without an Admin success marker or a restart retry.

At boot, `systemd-tmpfiles-setup.service` recreates this ephemeral directory from
the rule. The Admin unit explicitly orders itself after that service. Normal
Ubuntu/systemd boot already pulls tmpfiles into sysinit (and `PrivateTmp=true`
also implies this ordering), so no new `Wants=` or `Requires=` is necessary.
See the [systemd v255 tmpfiles setup unit](https://github.com/systemd/systemd/blob/v255/units/systemd-tmpfiles-setup.service)
and [execution dependency documentation](https://github.com/systemd/systemd/blob/v255/man/systemd.exec.xml).
The sequence is tmpfiles setup → root-owned shared parent → Admin namespace
construction → unprivileged Admin process → exact management listener checks.
If creation fails and the path remains absent, namespace setup still fails
closed; the writable-path restriction is never made optional or broadened.

The rule neither creates nor removes `admin-mutation.lock`. Existing safe parent
and lock inodes survive reinstall; the authoritative root:root `0600` lock
contract remains unchanged. Uninstall removes the Admin-owned tmpfiles rule but
leaves the shared directory and lock in place for other project components.
There is no directory cleanup/expiry rule, root-shell service, change to Admin
ownership/capabilities/sudoers, or gateway/Dashboard restart. Isolated tests use
real tmpfiles creation and simulate an empty ephemeral parent, not a host reboot;
local and CI results do not constitute fresh host qualification.

After replacing and validating the application, network configuration, and unit,
the installer reloads systemd unit definitions, enables `warp-admin.service`, and
explicitly restarts **only that Admin service**. `restart` also starts an inactive
or never-started unit. Unlike `enable --now`, it replaces an already-active Python
process so the new application and management address actually take effect;
see the [systemctl command semantics](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html).
Gateway, WireGuard, firewall, Dashboard, networking, and systemd-networkd services
are not restarted, and no dataplane configuration is changed.

Each activation command has a 30-second timeout (with a five-second forced-exit
grace); failure or timeout stops the installer without a success marker or retry.
A timeout of the systemctl client does not cancel a job already submitted to
systemd, so it is a qualification failure, not proof that Admin stayed stopped.
Before exact-listener readiness, the installer requires `ActiveState=active`,
`SubState=running`, a positive `MainPID` with a monotonic start timestamp after
file installation, and `NRestarts=0`. The same PID/start timestamp and zero
automatic restarts must persist through listener and HTTP smoke validation.
The existing exact listener gate still rejects stale loopback, wildcard, transit,
IPv6, wrong-address, and multiple listeners. This local/CI migration coverage
does not replace fresh exact-candidate CC in-place host qualification.

The first controlled CC qualification safely stopped when systemd reported the
service active about one second before the Python process completed its socket
bind. The root cause was the installer's former single-shot listener assertion.
The installer now waits up to 10 seconds on a monotonic deadline, polling every
200 milliseconds for exactly one `AF_INET` listener at `<management-ip>:8788`.
Listener absence alone is retried; a failed/inactive service, any forbidden or
wildcard address, or multiple listeners fails immediately. The fixed listener
port, deadline, and service privilege boundary are unchanged. Slice 1B remains pending a fresh
CC host-qualification run.

`admin/deploy/uninstall.sh` stops/disables only `warp-admin.service`, removes
only exact Admin files and directories, and removes the account only when the
root-owned project marker and strict identity both agree. Ambiguous identities
are preserved or rejected, never guessed. It does not delete the shared lock,
restart gateway/Dashboard services, or touch WireGuard, policy routing,
nftables, forwarding, configuration, or identity material.

Release packaging normalizes executable, regular, and sudoers modes for TAR
and ZIP payloads. Extracted-payload validation reruns the same test suite.

## Qualification coverage and remaining non-goals

Focused tests cover immediate and delayed exact-listener readiness, bounded
no-listener timeout, failed/inactive/deactivating service transitions,
forbidden and multiple listeners, the fixed Host/proxy boundary, sessions/CSRF
and expiry, strict body parser, CORS/security headers, per-binding/global
limits, helper input/output and future-operation rejection, no-recovery
command, lock-contention mapping, mutation tripwires, secret canaries, exact
sudoers allow/deny matrix, service identity/hardening, text-only UI, safe
install/reinstall/uninstall, archive modes, Dashboard separation, and full
repository regression.

Slice 1B intentionally does not implement Repair Routing, Connect,
Disconnect, intentional-disconnect state, logs browsing, configuration,
arbitrary commands, Docker Admin Console support, a wildcard or transit listener,
deployment to a host, a version bump, merge, tag, or release.
