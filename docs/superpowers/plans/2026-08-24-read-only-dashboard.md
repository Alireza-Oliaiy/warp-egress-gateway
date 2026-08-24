# v0.5.0 Read-Only Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dependency-free, monitoring-only dashboard backed by a sanitized atomic status snapshot.

**Architecture:** A one-shot collector publishes a strict schema-versioned JSON file under `/run/warp-egress-dashboard`; an independent loopback-only HTTP server revalidates and serves that file; a vanilla frontend polls the API and renders operational state. HTTP handlers do not import the collector or execute subprocesses.

**Tech Stack:** Python 3 standard library, HTML5, CSS, browser JavaScript, Bash test runner, `unittest`.

**Spec:** `docs/superpowers/specs/2026-08-24-read-only-dashboard-design.md`

## Global Constraints

- Do not modify `native/`, `web/helper/`, `web/sudoers/`, or `VERSION`.
- `VERSION` must remain exactly `0.4.1`.
- Use `/run/warp-egress-dashboard/status.json`; never read `/run/warp-egress-gateway`.
- Bind only `127.0.0.1`; no TLS, authentication, sudo, helper, or mutation endpoint.
- Use Python standard library only; no Flask, FastAPI, Node, npm, or frontend framework.
- Do not commit, push, deploy, or access CC/HQ.

---

### Task 1: Strict schema and safe fixtures

**Files:**
- Create: `web/__init__.py`
- Create: `web/dashboard/__init__.py`
- Create: `web/dashboard/schema.py`
- Create: `web/dashboard/status-schema.json`
- Create: `web/dashboard/fixtures/healthy.json`
- Create: `web/dashboard/fixtures/degraded.json`
- Create: `web/dashboard/fixtures/failed.json`
- Create: `tests/dashboard_test.py`

**Interfaces:**
- Produces: `validate_status(value: object) -> dict[str, object]`, `loads_status(raw: bytes) -> dict[str, object]`, and `is_stale(value: Mapping[str, object], now: datetime, threshold_seconds: int = 30) -> bool`.

- [ ] Write tests that load all three literal fixtures, reject missing/unknown/duplicate/secret-like fields, enforce every enum/type, and classify stale timestamps.
- [ ] Run `python3 tests/dashboard_test.py SchemaTests -v` and require failure because `web.dashboard.schema` does not exist.
- [ ] Implement duplicate-key rejecting JSON parsing, exact-key validation, recursive secret-name rejection, RFC3339 UTC timestamp parsing, and the checked-in JSON Schema contract.
- [ ] Run the schema tests and require all pass.

### Task 2: Bounded collector and atomic publisher

**Files:**
- Create: `web/dashboard/collector.py`
- Modify: `tests/dashboard_test.py`

**Interfaces:**
- Produces: `BoundedRunner.run(argv: tuple[str, ...]) -> CommandResult`, pure parsers for trace/routes/handshake/monitor telemetry, `collect_status(runtime: CollectorRuntime) -> dict[str, object]`, and `write_atomic_status(path: Path, status: Mapping[str, object]) -> None`.
- Consumes: `validate_status()` from Task 1.

- [ ] Add tests for bounded success, missing executable, timeout, output overflow, parser variants, observation failure isolation, exact read-only argv history, no mutation tokens, and atomic replacement under a hostile umask.
- [ ] Run `python3 tests/dashboard_test.py CollectorTests AtomicSnapshotTests -v` and require failure for missing collector interfaces.
- [ ] Implement a fixed-runtime collector with `Popen(shell=False)`, bounded readers, process-group timeout termination, fixed command tuples, and safe parsing.
- [ ] Implement same-directory `O_EXCL|O_NOFOLLOW` temporary creation, fsync, `os.replace`, and parent fsync; validate before writing.
- [ ] Run collector and atomic tests and require all pass.

### Task 3: Loopback-only GET API

**Files:**
- Create: `web/dashboard/server.py`
- Modify: `tests/dashboard_test.py`

**Interfaces:**
- Produces: `SnapshotProvider.read()`, `FixtureProvider.read()`, `create_server(listen: str, port: int, provider: StatusProvider)`, and `main(argv: Sequence[str] | None = None) -> int`.
- Consumes: `loads_status()` and `validate_status()` from Task 1.

- [ ] Add real HTTP tests for `/`, `/api/status`, `/healthz`, assets, missing/unsafe snapshots, unsupported mutation methods, fixture loading, and bind rejection for `0.0.0.0`, `::`, hostnames, and non-loopback IPs.
- [ ] Patch `subprocess.Popen` only as a tripwire and prove GET requests still succeed, demonstrating the request path executes no commands.
- [ ] Run `python3 tests/dashboard_test.py ServerTests -v` and require failure because the server is absent.
- [ ] Implement a `ThreadingHTTPServer` factory that accepts only literal `127.0.0.1`, GET/HEAD handling, bounded validated snapshot reads, security/cache headers, and sanitized errors.
- [ ] Run server tests and require all pass.

### Task 4: Polished responsive frontend

**Files:**
- Create: `web/dashboard/static/index.html`
- Create: `web/dashboard/static/styles.css`
- Create: `web/dashboard/static/app.js`
- Modify: `tests/dashboard_test.py`

**Interfaces:**
- Produces: a semantic dashboard shell and client renderer polling `/api/status` every 5000 ms with a 30000 ms stale threshold.

- [ ] Add asset tests for every required status field, loading/API-unavailable/stale states, local assets, five-second polling, and absence of controls or external dependencies.
- [ ] Run `python3 tests/dashboard_test.py FrontendTests ScopeGuardTests -v` and require failure for absent assets.
- [ ] Implement accessible HTML, local CSS tokens/cards/badges, responsive breakpoints, and defensive DOM rendering with no HTML injection.
- [ ] Run frontend/scope tests and require all pass.

### Task 5: Repository integration and authoritative documentation

**Files:**
- Create: `tests/dashboard.sh`
- Modify: `tests/run-all.sh`
- Modify: `tests/syntax.sh`
- Create: `docs/web-console/READ_ONLY_DASHBOARD.md`
- Modify: `docs/web-console/ARCHITECTURE.md`
- Modify: `docs/web-console/API_CONTRACT.md`
- Modify: `docs/web-console/PHASE_0_DECISIONS.md`
- Modify: `docs/web-console/THREAT_MODEL.md`
- Modify: `docs/web-console/SECURITY_BOUNDARY.md`
- Create: `web/dashboard/README.md`

**Interfaces:**
- Produces: canonical focused-test entry point and local demo/run documentation.

- [ ] Add a failing integration assertion that the canonical suite does not yet run `tests/dashboard.sh`.
- [ ] Register dashboard tests and Python syntax checks without weakening existing tests.
- [ ] Document the separate runtime directory, `root:warp-web` modes, loopback HTTP/SSH-forward access, demo commands, cadence, stale threshold, and deferred privileged design.
- [ ] Mark historical control-plane documents as deferred/future without deleting their contents.
- [ ] Run `bash tests/dashboard.sh` and require pass.

### Task 6: Visual and full verification

**Files:**
- No production file changes expected.

**Interfaces:**
- Consumes: the complete dashboard and fixtures.

- [ ] Run `bash tests/run-all.sh`, `git diff --check`, Python compile checks, and the focused dashboard suite.
- [ ] Run scope/secret audits proving no mutation routes, privileged request execution, forbidden secret fields, or dependencies on helper/sudoers.
- [ ] Start `python3 -m web.dashboard.server --fixture healthy --listen 127.0.0.1 --port 8787`, verify all three GET routes, polling, and console behavior.
- [ ] Inspect screenshots at desktop and mobile widths, then switch among healthy/degraded/failed fixtures and verify badge/state rendering.
- [ ] Confirm diff counts under `native/`, `web/helper/`, and `web/sudoers/` are zero; confirm `VERSION=0.4.1`; stop without commit/push/deploy.
