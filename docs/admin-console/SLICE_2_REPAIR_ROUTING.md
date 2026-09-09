# Slice 2: bounded Repair Routing

This unreleased Admin action builds on the qualified runtime-parent, isolated
read-only evaluator, management listener, serialized polling, listener restart,
and site-neutral Dashboard prerequisites. VERSION remains 0.5.1. It does not
deploy or qualify itself on a production host. Status and Health remain
read-only; Connect and Disconnect remain unsupported (404).

## HTTP and helper boundary

`POST /api/actions/repair-routing` accepts exactly
`{"confirmation":"repair-routing"}`. The existing exact management Host/Origin,
session binding, HttpOnly/SameSite=Strict cookie and CSRF checks apply. JSON must
have the exact content type, one bounded decimal Content-Length, no transfer or
content encoding, no duplicate keys, and no extra fields. Limits are 3 attempts
per binding and 6 globally per 60 seconds; Status/Health limits are unchanged.

The only sudo command remains the existing zero-argument root-owned
`/usr/local/libexec/warp-egress-gateway/warp-admin-helper`. Its bounded stdin
contains only protocol=1, canonical UUIDv4 request_id, and a fixed operation.
No caller can select paths, interfaces, tables, commands, units, configuration,
or environment. No new sudo authority, capabilities or helper support bundle is
installed. The implementation is in the existing helper, not a native shell
route-repair transaction. The unprivileged Dashboard has no helper authority.

## Trust and transaction

1. Open the existing `/run/warp-egress-gateway/admin-mutation.lock`, without
   symlink following. Require parent root:root 0700 and regular, single-linked
   lock root:root 0600. Acquire exclusive flock within 3 seconds and verify its
   path still identifies the opened inode. Never create, truncate or replace it.
2. Under that same lock, parse the fixed gateway config's required WARP/uplink/
   transit roles, table ID/name and rule priorities. Require distinct bounded
   interface names, not `lo`; priorities 100/110; canonical name `warp_gateway`;
   canonical decimal table ID 1..4294967295, excluding reserved 253/254/255.
   Ignore unrelated assignment keys; never source or evaluate any value.
   Cross-check the fixed Admin network projection and Dashboard listener config
   for the management address/roles. All paths and parents are root-owned,
   non-symlink, non-group/other-writable; file reads are regular, bounded and
   checked for metadata changes. No configuration is written.
3. Require the configured interface UP and actually WireGuard, one usable
   global /32 IPv4 source, management addressing consistent with the projection,
   a public identity/peer/endpoint observation, and a semantic active kill
   switch. Any object at the authoritative fixed
   `/run/warp-egress-gateway/intentional-disconnect.json` path blocks repair,
   including corrupt data or symlinks; this action never changes intent.
4. Capture all bounded IPv4 rule/route observations, main default, relevant
   addressing, WARP link/public identity/peer/endpoint, normalized project nft
   semantics, and forwarding. Reject conflicting/duplicate owned rules or
   unsafe defaults. Exactly one main unicast default must use the uplink.
5. Add only missing source rule 100, transit-ingress rule 110, and direct default
   on the configured WARP interface in the configured table. Never delete,
   replace, flush, call a shell repair script, or change other network state.
6. Recheck safety and immutable evidence after each successful write and again
   before success. The final owned rules/default must be exact. Main default,
   unrelated bounded IPv4 rules/routes, addresses, public identity, link,
   peer/endpoint, forwarding and normalized nft semantics must be unchanged.
   Hold the same lock through completion audit. No nested native locking.

Numeric table IDs and canonical `warp_gateway` observations are supported.
`scope link`, protocol, and other explicitly allowed harmless default metadata
are accepted. Gateway/via, nexthops, nhid, wrong device/table, non-unicast,
duplicate/default ambiguity, unexpected selectors, or another rule referring
to the owned table fail closed. Missing objects are repairable only when the
rest of the observed state is safe. A WARP default in the wrong table is not
silently treated as a missing default.

The nft proof includes the actual inet/warp_gateway forward filter hook,
configured transit equality, configured WARP egress inequality, and drop. A
comment alone, incorrect expression, or preceding accept/jump is insufficient.
Runtime handles and counter values are excluded from immutable comparisons;
rule order and other semantics are retained.

## Results, audit and UI

| Condition | HTTP / result |
|---|---|
| Already healthy, safety and final evidence verified | 200 / ok / changed=false |
| Missing objects restored and verified | 200 / ok / changed=true |
| Lock busy | 409 / mutation_lock_busy |
| Unsafe precondition | 409 / unsafe_precondition; no mutation |
| Helper unavailable / sudo denied | 503 / helper_unavailable or privilege_denied |
| Bounded command timeout | 504 / operation_timeout |
| Write fails after an attempt | 500 / partial_mutation_failure |
| Missing final object or changed immutable/safety evidence | 500 / postcondition_failed |
| Malformed / oversized / wrong content type | 400 / 413 / 415 |
| Host / Origin / session / CSRF rejection | 403 |
| Rate exceeded | 429 |

Successful repair is not a full dataplane health evaluation: its response state
is `degraded`, with verified wireguard/routing/kill_switch evidence and unknown
unprobed connectivity fields. Status/Health provide independent health evidence.
`changed=true` denotes a **verified successful repair**, never Status/Health.
A failed response's changed=false does **not** prove no partial write occurred;
the explicit partial/timeout/postcondition result and UI warning must be read.
There is no automatic mutation retry or broad rollback. Failed write attempts
get bounded best-effort read-only verification while still holding the lock.
The transaction has a 35-second observation/write budget, 2-second per-command
cap, and at most a further 5-second failure-inspection budget.

Helper and application audit only fixed protocol/request/action/state/duration/
result/changed fields. No raw command output, configuration, private material,
cookies or CSRF tokens are logged. The UI requires explicit confirmation, sends
the exact body, disables double-submit, and distinguishes running, no change,
changed, busy, unsafe, timeout and failure. Its live action message is separate
from the unchanged serialized Status polling. No Connect/Disconnect buttons.

## Qualification

`tests/admin_repair_test.py` retains the recovered RED fixture and exercises
HTTP/security, real temporary-file flock, all missing combinations, refusal,
partial failure, immutable state and CC/HQ/custom-role mock kernels.
`tests/admin_repair_namespace_test.py` performs real netlink/nft/WireGuard
fixture setup only after proving a new anonymous empty network namespace. It
runs all missing-object combinations, no-op and ambiguity with real kernel
observations. No default-namespace network mutation is permitted. Missing local
tools are an explicit skip; CI installs them and requires this test. TAR and ZIP
payloads run these regressions too. Existing install tests retain the constraint
that only the Admin service may restart; installation does not invoke repair.
