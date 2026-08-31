# Slice 1A: read-only health and lock foundation

This note records the v0.6.0 Slice 1A implementation beneath the frozen Admin
Console design. It adds no Admin web process, helper, sudoers rule, mutation
action, or deployment.

## Runtime writer inventory

The v0.5.1-derived Native runtime had these writers of state observed by health
and status:

- `warp-gateway.service` invokes route-up and route-down for rules 100/110 and
  routing table 100.
- the networkd dispatcher repair hook invokes route-repair for the same policy
  state.
- the health timer may repair policy routing and, when `AUTO_RECOVER=true`,
  restart `wg-quick@warp0` before restoring policy routing.
- the firewall guard installs or removes the project nftables table and enables
  forwarding after the fail-closed transaction.
- `wg-quick@warp0` starts, stops, or reloads the WireGuard interface.
- `warp-gateway start`, `restart`, and `lockdown`, plus install, uninstall,
  upgrade, and rollback, delegate those mutations to the same systemd units.

The passive monitor does not recover or restart anything in this runtime. It is
a reader and now takes the shared side of the lock.

## Lock contract and lifetime

All coordination uses `flock` on the fixed path:

```text
/run/warp-egress-gateway/admin-mutation.lock
```

The library creates only the final fixed parent and lock name. It validates the
parent as a non-symlink root-owned `0700` directory and the lock as a
non-symlink root-owned `0600` regular file. Unsafe existing metadata is never
repaired or overwritten. The opened descriptor is checked against the on-disk
device/inode before use. Acquisition has a fixed three-second bound; contention
returns exit 75 and unsafe metadata returns exit 73.

Shared users are the official no-recovery health evaluator, status, passive
monitor sampling, diagnostics collection, and the observation stage of the
normal health path. Exclusive users are policy apply/repair, route up/down,
firewall apply/remove, WireGuard up/down/reload, and the mutation/final
verification stages of automatic recovery. CLI and lifecycle operations reach
only these locked systemd mutation entrypoints. An uninstall never falls back
to an unlocked nftables deletion.

## Official read-only evaluation

The fixed entrypoint is:

```text
/usr/local/lib/warp-egress-gateway/health-readonly.sh
```

It is also exposed as `warp-gateway health-readonly`. Its internal evaluator
has no recovery flag, recovery callback, mutation adapter, routing repair, or
systemd lifecycle branch. It observes WireGuard, direct and WARP traces, exact
policy routing, the semantic kill switch, configured upstream reachability,
and relevant service/timer state while holding a shared lock.

An unhealthy gateway is emitted as `EVALUATION=completed HEALTH=FAIL` and the
command succeeds because the evaluation completed. A lock/config/entrypoint
failure remains a nonzero evaluation failure; lock contention is identified as
`mutation_lock_busy`. The existing `warp-gateway health` command retains its
qualified repair and `AUTO_RECOVER` behavior.

## Deadlock avoidance

Public entrypoints own locks; internal functions ending in `_locked` require an
already-held lock and never reacquire one. In particular, health recovery does
not hold the project lock while calling `systemctl restart wg-quick@...`.
Stopping WireGuard can cause systemd to stop `warp-gateway.service`, whose
route-down path must independently acquire the same lock. The WireGuard unit
itself acquires the exclusive lock through its fixed wrapper, and health then
acquires a new exclusive transaction for policy restoration and verification.

This deliberate staged orchestration prevents a cross-process systemd
deadlock. A shared reader can observe a coherent transitional *unhealthy*
state between stages, but cannot observe any route, firewall, or WireGuard
mutation while it is in progress.

## Acceptance coverage

Local regression coverage exercises real flock contention and filesystem
metadata, unsafe path/symlink rejection, shared-reader overlap, reader/writer
exclusion, fixed timeouts, no nested lock across systemd recovery, each fixed
writer under an exclusive lock, existing recovery behavior, healthy/unhealthy
read-only evaluations, and mutation tripwires for `ip`, `systemctl`, `wg`,
`nft`, `sysctl`, recovery functions, intent/config files, and state snapshots.
