# Admin-owned read-only evaluator foundation

Admin must install successfully on a native **released v0.5.1** gateway with
Dashboard installed and no development health-readonly scripts in Core. A
previous installer accidentally depended on those scripts already being there:
the helper returned `observation_unavailable` and HTTP qualification failed.
The runtime-parent fix is a separate prerequisite and remains unchanged.

## Complete dependency closure

The fixed helper runs only
`/opt/warp-egress-admin-console/readonly/v1/evaluate.py` with zero arguments.
That launcher execs `/usr/bin/bash --noprofile --norc` with the fixed bundled
`health-readonly.sh` and a new fixed environment. No inherited PATH, BASH_ENV,
Python import path, gateway configuration override or caller argument survives.

The official source closure is exactly:

| Bundled file | Read-only use |
| --- | --- |
| health-readonly.sh | Root check, trusted configuration load, single observation entrypoint |
| common.sh | Configuration load and IPv4 address observation |
| admin-lock.sh | Existing shared mutation-lock metadata/FD/inode/flock contract |
| routing.sh | Policy rules, direct table default and kill-switch observation |
| healthcheck-lib.sh | Direct/WARP/upstream connectivity, service/timer observations and sanitized no-recovery result |
| observation-entrypoints.sh | Shared-lock wrapper around the no-recovery evaluator |

Imports/sourcing stay relative to this fixed bundle. `common.sh` reads only the
existing trusted `/etc/warp-egress-gateway/warp-gateway.env` configuration; no
further project source dependency is loaded on the read-only call path. The
native library path defined in `common.sh` is not used by this path. System
dependencies remain Bash, Python 3, flock, standard Unix utilities, iproute2,
WireGuard tools, nftables, systemctl, curl and ping.

The call sequence is:

```text
fixed helper metadata gate -> evaluate.py -> bundled health-readonly.sh
  -> healthcheck_readonly_public -> admin_lock_run_shared
  -> healthcheck_readonly_evaluate_locked -> observations -> recovery=none
```

Some shared official libraries also define mutation functions. They are never
dispatched by this entrypoint, which has no command selector. In particular it
never calls the recovering CLI health operation, `healthcheck_run`, routing
repair or WireGuard restart, even when trusted configuration has AUTO_RECOVER
enabled. Existing shared-lock initialization may create its root-only lock file;
it never creates disconnect intent or mutates dataplane state.

## Deployment, trust and reinstall

Source/package inputs are `admin/deploy/readonly/evaluate.py` plus the six
`native/scripts/` files above from the same immutable candidate. The installer
assembles these into **Admin-owned** `readonly/v1`; the destination is never
`/usr/local/lib/warp-egress-gateway`. This reuses authoritative sources without
maintaining a second independently edited evaluator implementation.

The installed launcher is root:root 0755; the six source files are root:root
0644, with root-controlled non-group/other-writable directory ancestors. Before
every evaluation, the helper checks the exact file set, regular-file types,
ownership, exact file modes, non-symlink directories and the fixed gateway
configuration/ancestor chain. Configuration must be root:root 0600, 0640 or
0644. Missing files, unexpected entries, unsafe ownership/modes or symlinks
return sanitized `observation_unavailable` before child execution. The existing
helper/protocol metadata gate is not weakened. Metadata validation relies on
root-owned directories to exclude unprivileged rename/write races; root remains
the trusted administrator.

Installation validates existing bundle state before any account, application or
service change. A complete new version is assembled in a private same-parent
temporary directory, validated against every source byte and published with one
directory rename before the new helper is installed. An identical reinstall
reuses the validated bundle without rewriting files or inodes. A different,
incomplete or unsafe existing `v1` fails closed; future bundle updates must use a
new version path, not mix or rewrite a live version. A failed assembly is never
published or activated; its Admin-owned temporary directory may remain for
inspection and is covered by Admin uninstall.

Only `warp-admin.service` may restart. Native Core files/CLI, Dashboard,
WireGuard, routes, nftables, forwarding, gateway service lifecycle, sudoers
authority, capability policy and VERSION are unchanged. The prior tmpfiles rule
still creates only root:root 0700 `/run/warp-egress-gateway` before Admin start.
Management IPv4:8788 resolution, exact Host/Origin, sessions, CSRF and read-only
HTTP contracts are unchanged. Connect/disconnect/repair-routing remain 404.

Uninstall's checked fixed Admin application tree includes `readonly/v1` and any
incomplete assembly directories. It does not remove the native library, CLI,
gateway configuration, WireGuard configuration, Dashboard or the shared runtime
parent/lock. Installer HTTP failure remains a failed installation, never success.

## Regression evidence

`tests/admin_foundation_test.py` installs into isolated filesystems containing
the actual released v0.5.1 routing/health libraries and CLI (SHA-pinned inert
fixtures). Both libraries demonstrably differ from the candidate. Tests run the
installed helper and real shell evaluator using only fixture path/UID relocation
and strict read-only command doubles; there is no production test-path override.
Status and Health also traverse the real HTTP application with valid session and
CSRF handling. Hashes, modes and inodes of all existing native library files/CLI,
gateway configuration, service files and Dashboard fixture files stay identical
across install/reinstall/evaluation/uninstall.

Failure-state command tripwires prove no recovery with AUTO_RECOVER enabled;
metadata failures prevent execution, and exclusive lock contention returns busy.
Existing tests retain malformed-output, bounded timeout/overflow, HTTP security,
sudoers/capability and runtime-parent coverage. TAR/ZIP checks verify all seven
bundle inputs byte-for-byte with expected modes. Extracted TAR runs fresh-host
deployment fixtures; extracted ZIP runs the full suite including those fixtures.
