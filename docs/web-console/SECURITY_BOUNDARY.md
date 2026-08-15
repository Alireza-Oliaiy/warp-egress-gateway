# Web Console Security Boundary

## Purpose

This document defines the only permitted privilege transition for the v0.5.0
Web Management Console. Any implementation that grants `warp-web` a second
sudo command, direct root capability, or a general command/path interface
violates the Phase 0 design.

## Trust zones

| Zone | Trust | May contain secrets | Privilege |
|---|---|---|---|
| Browser | Hostile input even after authentication | Session and CSRF tokens only | Remote user |
| `warp-web` | Compromise is assumed possible | Password hashes, session digests, TLS key when using direct TLS | Dedicated unprivileged user |
| `warp-web-helper` | Small trusted computing base | Reads trusted gateway configuration but never returns secret fields | Short-lived root process |
| Gateway configuration/state | Root-controlled | WARP profile and account material | Root-only files |
| Kernel/systemd/journal | Trusted host control plane with hostile log content | Operational metadata may be sensitive | Root interfaces |

Authentication and role checks protect the normal application path, but the
root helper must remain safe if an attacker completely controls `warp-web`.
Compromise of the web process therefore grants, at most, repeated access to the
helper's fixed verbs; it must not grant general root execution or a fail-open
network operation.

## Process identities and files

The future implementation must use a dedicated system account with no login
shell and no supplementary administrative groups:

```text
warp-web:x:<allocated>:<allocated>:WARP Web Console:/var/lib/warp-web:/usr/sbin/nologin
```

Frozen ownership targets:

| Path | Owner | Mode | Purpose |
|---|---|---:|---|
| `/usr/local/libexec/warp-egress-gateway/warp-web-helper` | `root:root` | `0755` | Sole sudo entry point |
| `/etc/sudoers.d/warp-web` | `root:root` | `0440` | Exact helper authorization |
| `/etc/warp-egress-gateway/warp-gateway.env` | `root:root` | `0600` | Existing trusted gateway configuration |
| `/run/warp-egress-gateway` | `root:root` | `0700` | Root runtime intent state |
| `/run/warp-egress-gateway/mutation.lock` | `root:root` | `0600` | Shared host mutation lock; stable for the boot |
| `/run/warp-egress-gateway/intentional-disconnect.json` | `root:root` | `0600` | Ephemeral intentional-disconnect record |
| `/var/lib/warp-web` | `warp-web:warp-web` | `0700` | Authentication/session state |
| TLS certificate | `root:root` | `0644` | Public certificate |
| Direct-TLS private key | `root:warp-web` | `0640` | Host-provisioned key, readable only when direct TLS is selected |

The console never reads `/etc/wireguard/*.conf`,
`/var/lib/warp-egress-gateway/wgcf-account.toml`, backup payloads, SSH keys, or
arbitrary files. The helper may query WireGuard public state using fixed
commands, but it must never request or serialize `PrivateKey`.

## Single sudo entry point

`warp-web` executes exactly this shape:

```text
sudo -n -- /usr/local/libexec/warp-egress-gateway/warp-web-helper
```

There are zero command-line arguments after the helper path. The sudoers rule
must express an empty argument list and apply `NOSETENV`. It must not contain a
wildcard command path, shell, interpreter, project script, or executable
directory. `secure_path`, a fixed `umask`, and sudo logging remain enabled.

The helper accepts one JSON object on standard input and then closes input. A
conceptual request is:

```json
{
  "protocol": 1,
  "verb": "routing-status",
  "parameters": {},
  "request_id": "0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7",
  "audit_context": {
    "asserted_actor": "admin-example",
    "asserted_role": "Admin",
    "asserted_source_ip": "127.0.0.1"
  }
}
```

This is a protocol illustration, not permission to add arbitrary fields.
Input is limited to 8 KiB, must be UTF-8 JSON, must contain exactly the fields
defined for protocol version 1, and rejects duplicate keys, unknown keys,
invalid Unicode, control characters, non-integer numeric forms, and trailing
data. `audit_context` is required, length bounded, and its role is exactly
`Viewer` or `Admin`; its three `asserted_*` values are **untrusted audit data
only**. They never authorize a verb and never select a command, executable,
file, path, interface, service, parameter, environment value, or safety
decision.

The helper verifies that its real/effective identity and sudo caller match the
expected deployment. It clears the inherited environment and constructs a
minimal fixed environment, including a fixed `PATH`, locale, timezone policy,
and umask. `LD_*`, `PYTHON*`, `BASH_ENV`, `ENV`, locale overrides, config-path
overrides, and all caller variables are ignored.

## Trusted configuration

The helper reads configuration only from the compiled/fixed path:

```text
/etc/warp-egress-gateway/warp-gateway.env
```

It must not honor `WARP_GATEWAY_CONFIG_DIR`, `WARP_GATEWAY_CONFIG_FILE`, a
request path, working directory, symlink supplied by `warp-web`, or an
environment override. It opens the file safely, verifies expected root
ownership and restrictive mode, rejects an unexpected file type, and parses
only an allowlist of data assignments.

The helper must not `source` the shell-format configuration. A strict parser
accepts only the keys required by the selected verb and validates each value:

- interface identifiers use the kernel interface-name grammar and length;
- routing table IDs and priorities are bounded decimal integers;
- table names use a conservative identifier grammar;
- trusted source is a valid IPv4 CIDR;
- booleans and timeouts use exact enumerated/decimal forms.

Even after validation, callers cannot replace these values. They are used only
in fixed command argument positions and compared against live project-owned
objects.

## Shared root mutation lock

Every root path capable of changing WARP lifecycle or project routing uses one
exclusive host lock at `/run/warp-egress-gateway/mutation.lock`: periodic or
manual health recovery, helper `routing-repair`, `warp-disconnect`, route-up or
policy activation, and any future explicit reconnect/start. Application-only
serialization is insufficient because timers, systemd units, the CLI, and the
helper are separate processes.

The root-owned `0700` parent and `0600` lock object are opened without following
unsafe links. The lock object is stable and is not deleted or replaced while
services may run, preventing different processes from locking different
inodes. The exclusive lock file descriptor remains held through all mutation
and final postcondition checks.

Acquisition waits at most five seconds. Timeout returns structured
`mutation_busy`, performs no mutation, and is never followed by an unlocked
fallback. Read-only observation may proceed without the lock. If observation
indicates recovery, the recovery path first acquires the lock and then re-reads
intent and all safety prerequisites under the lock immediately before any
mutation. Valid, corrupt, unsafe, or inconsistent intent forbids recovery.

The firewall guard is intentionally independent of this lock: it may install
or refresh only the fail-closed nftables safety transaction and never activates
WARP or project routing.

## Verb allowlist

| Verb | Mutation | Role enforced by web | Helper purpose |
|---|---|---|---|
| `status` | No | Viewer | Aggregate live dataplane and safety evidence. |
| `health-read` | No | Viewer | Read latest approved health/monitor evidence. |
| `health-run` | Possible | Admin | Run existing health semantics and report any recovery. |
| `routing-status` | No | Viewer | Validate exact project-owned rules/table. |
| `routing-repair` | Yes | Admin | Repair only the v0.4.1 project-owned routing state. |
| `warp-disconnect` | Yes | Admin | Establish intent, make recovery refuse under that intent, remove routing, and stop WARP while retaining the kill switch. |
| `logs-read` | No | Viewer; `networkd` source requires Admin | Return bounded, approved, redacted journal records. |
| `version` | No | Viewer | Read the fixed installed project version. |

Unknown verbs fail before configuration loading or external command
execution. There is deliberately no `kill-switch-disable`, `firewall-remove`,
`command`, `script`, `file-read`, `systemctl`, or generic diagnostic verb.

## Parameter schemas

Every verb except `logs-read` has an empty `parameters` object. In particular,
callers cannot supply interface names, service names, rule priorities, table
IDs, paths, URLs, addresses, or timeouts.

`logs-read` accepts only:

```json
{
  "source": "gateway|firewall|healthcheck|monitor|wireguard|networkd",
  "window": "15m|1h|6h|24h|7d",
  "limit": 1,
  "cursor": null
}
```

- `limit` is an integer from 1 through 500; default is 100.
- `cursor` is null or a helper-issued opaque, authenticated cursor no longer
  than 256 characters. It is not a journal expression or file position.
- `networkd` is optional deployment functionality and requires Admin.
- There is no caller-selected unit, tag, boot, field, output format, grep,
  regex, time string, path, executable, or maximum-byte override.

The helper maps each source to fixed journal match arguments:

| Source | Fixed approved origin |
|---|---|
| `gateway` | `warp-gateway.service` |
| `firewall` | `warp-gateway-firewall.service` |
| `healthcheck` | `warp-gateway-healthcheck.service` |
| `monitor` | syslog identifier `warp-monitor` |
| `wireguard` | configured `wg-quick@<trusted WARP_IF>.service` |
| `networkd` | `systemd-networkd.service`, with stricter redaction |

## External execution rules

The helper may use only reviewed absolute executables needed for a verb. It
constructs an argument vector directly and never invokes `/bin/sh -c`,
`bash -c`, `eval`, command substitution, or an interpreter selected by input.

For each child process it applies:

- a fixed working directory not writable by `warp-web`;
- closed unrelated file descriptors;
- no inherited stdin after the request is parsed;
- bounded stdout and stderr pipes;
- a verb-specific wall-clock timeout;
- process-group termination on timeout;
- no caller environment;
- exact allowed exit-code translation.

Raw stderr is retained only in bounded privileged diagnostics and is never
returned to the browser. The helper converts known command output to its own
schema. Unexpected output is an internal failure, not a passthrough response.

## Time and output bounds

| Verb | Hard helper deadline | Maximum structured output |
|---|---:|---:|
| `version` | 1 second | 4 KiB |
| `routing-status` | 3 seconds | 16 KiB |
| `health-read` | 3 seconds | 32 KiB |
| `status` | 15 seconds | 64 KiB |
| `logs-read` | 5 seconds | 256 KiB and 500 records |
| `routing-repair` | 15 seconds | 32 KiB |
| `warp-disconnect` | 30 seconds | 32 KiB |
| `health-run` | 45 seconds | 32 KiB |

The status deadline permits bounded direct/WARP evidence without allowing
unbounded probe behavior. An implementation may use shorter internal probe
budgets but may not raise these limits without revisiting Phase 0.

## Exit codes

The helper returns structured JSON whenever it can safely do so and uses these
process exit codes:

| Code | Class | Meaning |
|---:|---|---|
| 0 | success | Verb completed; the returned state may still be degraded or failed. |
| 2 | invalid_request | Protocol, verb, parameter, or schema rejection. |
| 3 | unsafe_config | Trusted configuration ownership, mode, syntax, or semantics failed validation. |
| 4 | unsafe_precondition | A fail-closed prerequisite, including the kill switch, was not satisfied. |
| 5 | operation_failed | Fixed operation ran but did not meet its verified postconditions. |
| 6 | timeout | A fixed deadline expired and the process group was terminated. |
| 7 | output_limit | A child or result exceeded its bound. |
| 8 | internal_error | Unexpected helper/parser failure. |
| 9 | mutation_busy | The shared root mutation lock was not acquired within five seconds; no mutation occurred. |

HTTP mapping is owned by `warp-web`; process exit values are never exposed as
arbitrary shell return codes in the public API.

## Intentional-disconnect protection

The root helper is the only web-console component allowed to mutate the intent
record. Creation uses a root-owned temporary file in the same directory,
`0600` mode, bounded serialization, flush/sync, and atomic rename. The helper
does not follow a caller-controlled symlink and refuses an unsafe directory or
existing record type.

Health and monitor timers remain enabled and active during intentional
disconnect. They check the record through root-controlled runtime logic and,
before any recovery, acquire the shared mutation lock and re-read the record
under that lock. While intent is active:

- policy-only repair is suppressed;
- automatic WireGuard restart is suppressed regardless of `AUTO_RECOVER`;
- health and monitor report `intentionally_disconnected` as a successful
  observation rather than a failed systemd unit;
- they verify kill switch active, project routing absent, WireGuard stopped,
  direct management alive, and transit blocked;
- deletion by `warp-web` is impossible;
- the kill switch remains mandatory and independently verified.

If the record is corrupt or its ownership/mode is unsafe, recovery remains
suppressed and the state is `failed`, not silently reconnected.

Route-up and policy activation also acquire the lock and refuse to install
project routing whenever intent exists. Repeated service starts cannot defeat
disconnect. Reboot clears `/run`, so normal fail-closed boot reconnects. A
future explicit reconnect/start must use the same lock and a fixed guarded
intent transition; it is not a caller-controlled bypass.

## Audit boundary

Two audit layers are required:

1. `warp-web` records authentication, authorization, request, CSRF,
   rate-limit, and API results.
2. The helper independently records every invocation, validated verb,
   root-side result, safety refusal, timeout, and postcondition failure.

Application events record the authenticated username, role, and observed
source IP. Root helper events record web-provided values only as
`asserted_actor`, `asserted_role`, and `asserted_source_ip`. Authoritative root
identity fields are the helper's effective UID, the verified sudo caller
(`warp-web`), fixed helper path/protocol, and validated verb. Required fields
also include timestamp, request/correlation ID, target class, result, stable
reason code, and duration. Mutating actions record bounded before/after state
categories, never raw secret-bearing command output.

Audit logs never contain passwords, password hashes, session/CSRF tokens, TLS
private keys, WireGuard private keys, account data, request cookies, or full
authorization headers. User-supplied strings are length-bounded, escaped, and
recorded as data rather than a log format.

## Secret and response denylist

These values must never enter helper output, application logs, audit fields,
API responses, or UI state:

- WireGuard `PrivateKey` or preshared keys;
- `wgcf-account.toml` content;
- WARP account identifiers/tokens not explicitly classified as public;
- `/etc/wireguard` configuration contents;
- arbitrary environment variables or files;
- passwords, password hashes, session tokens, CSRF tokens in logs;
- TLS private keys;
- sudo tickets or API credentials.

WireGuard public keys are permitted as diagnostics. Public IP addresses,
Cloudflare colo/location, configured project routing identifiers, and bounded
interface state are operational metadata and require an authenticated Viewer.

## Mandatory implementation review tests

Future implementation is not complete until tests demonstrate:

- sudo rejects every command except the zero-argument helper entry point;
- every unknown verb/field/value and oversized request is rejected;
- malicious environment variables and working directories have no effect;
- config parsing never executes shell syntax;
- command, argument, path, and journal injection attempts cannot affect argv;
- helper output never contains seeded secret markers;
- timeouts kill process groups and output limits truncate/refuse safely;
- disconnect intent cannot be written by `warp-web` and inhibits recovery;
- each mutation verifies the kill switch and exact postconditions;
- main-table routes and unrelated nftables/rules are unchanged;
- raw child stdout/stderr never becomes an API response.
- healthcheck already running when disconnect begins is serialized safely;
- disconnect already running when the health timer fires cannot be raced;
- routing repair racing health recovery produces only one locked mutation;
- repeated route service starts cannot apply routes while intent exists;
- health timer stays active during intentional disconnect;
- monitor timer stays active during intentional disconnect;
- health reports `intentionally_disconnected` without a failed health unit;
- lock timeout never permits an unlocked mutation;
- recovery rechecks intent under lock immediately before mutation;
- route-up cannot reapply project routing while intent exists;
- clearing `/run` on reboot restores the normal fail-closed boot path;
- asserted audit metadata cannot affect authorization or command construction.
