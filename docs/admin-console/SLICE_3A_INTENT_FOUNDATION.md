# Slice 3A: runtime intent and recovery suppression

Base: `585bc8f671df4e9d275b058950a68b1fc575b7b2` (qualified Slice 2).
Development VERSION remains `0.5.1`. This is a foundation, not a lifecycle action
release: no Connect/Disconnect helper operation, endpoint or button is exposed.

## Intent and locking contract

The fixed record is `/run/warp-egress-gateway/intentional-disconnect.json`.
Its parent is root:root `0700`; the regular single-link file is root:root `0600`.
The exact schema (maximum 1,024 bytes) contains only:

- `schema`: integer `1`;
- `request_id`: canonical UUIDv4, correlation only, never authorization;
- `created_at`: validated UTC `YYYY-MM-DDTHH:MM:SSZ`;
- `main_default_sha256`: lowercase SHA-256 of the canonical JSON main-default
  snapshot, so disconnected observations can verify the unchanged baseline.

No credentials, configuration contents, account material, public/private keys,
browser tokens, arbitrary paths or commands are recorded. Duplicate/unknown
fields, malformed values, unsafe metadata, hardlinks and symlink traversal are
rejected. Errors expose only bounded categories, never record contents.

`IntentStore.create` is an internal root implementation primitive; it has no
write/clear CLI and is not reachable from the Admin helper's operation allowlist.
It requires the already-held **exclusive** authoritative lock descriptor. It
validates the complete fixed path and the descriptor's current inode/metadata
and Linux fdinfo flock ownership. It does not acquire another lock or convert,
replace, truncate or unlink the authoritative lock. Shared observers use that
same descriptor under the existing native shared lock.

Publication uses a fixed-parent, unpredictable, exclusively created no-follow
temporary file, exact ownership/mode, deterministic JSON serialization, file
fsync, Linux `renameat2(RENAME_NOREPLACE)`, then parent fsync. A competing file is
never overwritten. A valid existing record is an idempotent no-write result;
corrupt/unsafe state is never rewritten. Failed directory fsync reports failure
while retaining the already-published suppression record. There is no clear
primitive in this slice.

The existing root-owned `/run/warp-egress-gateway/admin-mutation.lock` is the
only coordination inode. Native callbacks pass their dynamically scoped open
descriptor to the read-only primitive. No environment/HTTP input selects a
path, command, interface, unit, lock or timeout. Filesystem/command substitutions
in Python constructors are internal test seams only.

## Audited writers and observers

| Path | Slice 3A behavior |
|---|---|
| `policy_routing_apply_locked`, `policy_routing_repair_locked` | Refuse any intent before all rule/table writes, including automatic policy recovery |
| `route-up.sh`, `route-repair.sh`, `route-down.sh` transaction callbacks | Refuse any intent under the existing exclusive lock; no unlocked teardown exception |
| `wg-quick-locked.sh` / `wg_quick_transaction_locked` | Refuse up/down/reload with valid or unsafe intent, before invoking WireGuard |
| Native `wg-quick` systemd drop-in | Already uses the locked wrapper for start/stop/reload; unit policy and boot ordering unchanged |
| `healthcheck_run`, policy recovery and tunnel finalization | Observe under shared lock, suppress recovery for present intent; recheck at exclusive mutation/dispatch boundaries |
| Timer/CLI tunnel restart | No outer lock across `systemctl` (avoids callback deadlock); actual ExecStop/ExecStart callbacks independently recheck intent under exclusive lock |
| `warp-gateway start/restart/lockdown` | Fixed locked absence gate before systemd dispatch; no implicit intent clearing |
| Firewall apply/remove transactions | Refuse any intent; retain existing guard, forwarding and shutdown behavior |
| Native install/uninstall; managed upgrade and automatic rollback | Locked absence precondition before maintenance begins; do not proceed from present/unsafe intent |
| Manual Native rollback | Requires installed intent-aware absence gate before restoring potentially older Core files; missing gate fails closed |
| Admin Repair Routing | Existing any-intent refusal remains unchanged under its exclusive same-inode lock |
| Native monitor, Health, Admin Status/Health | Read-only shared-lock observation, with explicit intentional-state verification |
| Dashboard | Entire runtime, roles, file permissions and no-sudo privilege boundary unchanged |
| Docker | No Admin support or intent integration in this Native-only slice; Docker runtime unchanged |

No new routing deletion/restoration or WireGuard lifecycle action was added.
Existing no-intent behavior remains covered by the original recovery tests.
The monitor has no recovery writer of its own. Direct operator calls to Linux
tools, edits by root, or manually executing old external release scripts are
outside the project coordination boundary and are not an alternate supported
way to clear intent. Maintenance must not be run concurrently with future
Admin lifecycle transactions; their full orchestration remains a later-slice
review gate, not an action provided here.

## Read-only state semantics

The installed Admin evaluator uses a new immutable `readonly/v2` bundle; it
never rewrites an installed v1 bundle or imports mutable native Core files.
The bundle includes the same intent reader and isolated shell evaluator.

`intentionally_disconnected` is reported only when the validated record agrees
with successful read-only observations proving:

- the configured WARP interface is absent and WARP/routing units are stopped;
- rules 100/110 and all references/routes in the owned table are absent;
- the exact main-default fingerprint and trusted uplink are unchanged;
- the semantic forward-chain kill switch is active (runtime handles/counters
  do not affect semantics, earlier accept/jump rules cannot bypass its check);
- direct trace succeeds with `warp=off`, required upstream is healthy, and
  firewall/timer telemetry is healthy.

The successful Admin response remains `changed=false`, `result_code=ok` and
adds the evidence value `routing=absent`; WARP is `off`, WireGuard is `down`.
Contradictory, unqueryable or unsafe intent conditions remain `failed`, never
generic success. No state decision relies on `systemd active` alone. Existing
`ok`/`degraded`/`failed` contracts and the Repair Routing API remain intact.
Native monitor emits `STATUS=INTENTIONALLY_DISCONNECTED` for matching intent;
unsafe/mismatched conditions emit `STATUS=FAIL`, so `warp-gateway failures`
continues to show genuine failures without treating an intentional outage as one.

Intent is deliberately volatile. Real reboot removes `/run` intent naturally;
the established sysctl -> guard -> forwarding -> network-pre -> WireGuard ->
policy-routing startup resumes with no persistent `/etc` or `/var` intent.
No automatic expiry, repair, deletion or reconnect is implemented.

## Review and deployment gates

Local tests cover actual filesystem metadata, inherited/shared flock, atomic
publication and failure retention, semantic disconnected observations, installed
isolated evaluator/helper/HTTP behavior, suppression tripwires, unchanged
Slice 2 repair, Dashboard/no-sudo boundaries and packaged payload execution.
No production hosts are used by these tests.

After exact-SHA CI and review, **CC / Anzali is the test host**; controlled
destructive qualification and reboot require the separately approved runbook.
**HQ / Tehran is production** and must not receive Slice 3 until the exact same
SHA fully passes CC qualification. Slice 3A does not authorize deployment,
Connect/Disconnect exposure, Slice 3B or Slice 3C.
