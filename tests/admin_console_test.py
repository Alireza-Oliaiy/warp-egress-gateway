#!/usr/bin/env python3
"""Focused contracts for the v0.6.0 Slice 1B Admin Console."""

from __future__ import annotations

from contextlib import contextmanager
import http.client
import json
import os
from pathlib import Path
import re
import socket
import sys
import tempfile
import threading
import unittest
import uuid
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from admin.application import (
    AdminError,
    AdminHTTPServer,
    BIND_PORT,
    HELPER_COMMAND,
    RateLimiter,
    SessionStore,
    validate_installed_application_metadata,
)
from admin.helper import (
    CommandResult,
    HelperRuntimeError,
    handle_request,
    parse_health_output,
    validate_installed_metadata,
)
from admin.protocol import (
    MAX_HELPER_INPUT_BYTES,
    MAX_HELPER_OUTPUT_BYTES,
    MAX_HTTP_BODY_BYTES,
    OPERATIONS,
    PROTOCOL_VERSION,
    ProtocolError,
    encode_request,
    encode_response,
    loads_request,
    loads_response,
    unknown_evidence,
    validate_response,
)


REQUEST_ID = "123e4567-e89b-42d3-a456-426614174000"
MANAGEMENT_ADDRESS = "172.21.31.5"
EXPECTED_HOST = f"{MANAGEMENT_ADDRESS}:8788"
EXPECTED_ORIGIN = f"http://{EXPECTED_HOST}"
HEALTHY_LINE = (
    b"EVALUATION=completed HEALTH=OK reason=none wg=up direct=ok direct_rc=0 "
    b"warp=on warp_rc=0 route=ok nft=ok upstream=ok services=ok timers=ok recovery=none\n"
)


def helper_response(operation: str, request_id: str, *, state: str = "ok") -> dict[str, object]:
    value = {
        "protocol": 1,
        "request_id": request_id,
        "operation": operation,
        "ok": True,
        "result_code": "ok" if state == "ok" else "evaluation_unhealthy",
        "changed": False,
        "state": state,
        "evidence": {
            "version": "0.5.1",
            "wireguard": "up",
            "handshake": "unknown",
            "handshake_age_seconds": None,
            "direct": "ok",
            "warp": "on",
            "routing": "ok",
            "kill_switch": "active",
            "forwarding": "unknown",
            "monitoring": "ok",
            "failed_units": None,
        },
    }
    return validate_response(value)


class FakeHelper:
    def __init__(self, *, error: str | None = None) -> None:
        self.calls: list[tuple[str, str]] = []
        self.error = error

    def invoke(self, operation: str, request_id: str) -> dict[str, object]:
        self.calls.append((operation, request_id))
        if self.error:
            raise AdminError(self.error)
        return helper_response(operation, request_id)


class FakeAudit:
    def __init__(self) -> None:
        self.events: list[dict[str, object]] = []

    def emit(self, **fields: object) -> None:
        self.events.append(fields)


@contextmanager
def running_server(
    *,
    helper: FakeHelper | None = None,
    sessions: SessionStore | None = None,
    limiter: RateLimiter | None = None,
    audit: FakeAudit | None = None,
    management_address: str = MANAGEMENT_ADDRESS,
):
    actual_helper = helper or FakeHelper()
    actual_sessions = sessions or SessionStore()
    actual_audit = audit or FakeAudit()
    server = AdminHTTPServer(
        ("127.0.0.1", 0),
        management_address=management_address,
        helper=actual_helper,
        sessions=actual_sessions,
        limiter=limiter or RateLimiter(),
        static_directory=ROOT / "admin" / "static",
        audit=actual_audit,
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, actual_helper, actual_sessions, actual_audit
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def request(
    server: AdminHTTPServer,
    method: str,
    target: str,
    *,
    headers: list[tuple[str, str]] | None = None,
    body: bytes | None = None,
) -> tuple[int, dict[str, str], bytes]:
    connection = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=3)
    connection.putrequest(method, target, skip_host=True, skip_accept_encoding=True)
    for name, value in (headers if headers is not None else [("Host", server.expected_host)]):
        connection.putheader(name, value)
    connection.endheaders(body)
    response = connection.getresponse()
    result = response.status, {name.lower(): value for name, value in response.getheaders()}, response.read()
    connection.close()
    return result


def open_session(server: AdminHTTPServer) -> tuple[str, str]:
    status, headers, body = request(server, "GET", "/")
    if status != 200:
        raise AssertionError((status, body))
    cookie = headers["set-cookie"].split(";", 1)[0]
    match = re.search(rb'<meta name="csrf-token" content="([A-Za-z0-9_-]{43})">', body)
    if match is None:
        raise AssertionError("CSRF token was not rendered")
    return cookie, match.group(1).decode("ascii")


class FrozenBoundaryTests(unittest.TestCase):
    def test_runtime_exact_host_and_origin_at_both_sites(self) -> None:
        for address in (MANAGEMENT_ADDRESS, "172.20.31.5"):
            with self.subTest(address=address), running_server(management_address=address) as (server, helper, _, _):
                cookie, csrf = open_session(server)
                for origin in (f"http://{address}:8788", "http://127.0.0.1:8788",
                               "http://localhost:8788", "http://172.20.31.6:8788",
                               f"https://{address}:8788", f"http://{address}:8787", f"http://{address}:8788/"):
                    status, _, _ = request(
                        server, "POST", "/api/actions/health",
                        headers=[("Host", f"{address}:8788"), ("Origin", origin),
                                 ("Cookie", cookie), ("X-CSRF-Token", csrf),
                                 ("Content-Type", "application/json"), ("Content-Length", "2")],
                        body=b"{}",
                    )
                    self.assertEqual(status, 200 if origin == f"http://{address}:8788" else 403)
                for host in ("127.0.0.1:8788", "localhost:8788", "172.20.31.6:8788", "10.1.1.222:8788",
                             address, f"{address}:8787", "0.0.0.0:8788", "[::1]:8788"):
                    self.assertEqual(request(server, "GET", "/", headers=[("Host", host)])[0], 403)
                self.assertEqual(len(helper.calls), 1)

    def test_listener_and_helper_authority_are_fixed(self) -> None:
        self.assertEqual(BIND_PORT, 8788)
        self.assertEqual(
            HELPER_COMMAND,
            (
                "/usr/bin/sudo",
                "-n",
                "--",
                "/usr/local/libexec/warp-egress-gateway/warp-admin-helper",
            ),
        )

    def test_slice_2_protocol_exposes_only_observations_and_bounded_repair(self) -> None:
        self.assertEqual(PROTOCOL_VERSION, 1)
        self.assertEqual(OPERATIONS, frozenset({"status", "health", "repair-routing"}))

    def test_production_server_has_no_bind_override(self) -> None:
        from admin import application

        from admin.network import ManagementConfig, NetworkConfigError
        for address in (MANAGEMENT_ADDRESS, "172.20.31.5"):
            with mock.patch.object(application, "AdminHTTPServer") as server_type, \
                    mock.patch.object(application, "load_runtime_config",
                                      return_value=ManagementConfig(address, "ens160", "ens192")):
                with mock.patch.dict(os.environ, {"ADMIN_LISTEN": "0.0.0.0", "ADMIN_PORT": "9999"}):
                    application.create_server()
                self.assertEqual(server_type.call_args.args[0], (address, 8788))
                self.assertEqual(server_type.call_args.kwargs["management_address"], address)
        with mock.patch.object(application, "AdminHTTPServer") as server_type, \
                mock.patch.object(application, "load_runtime_config", side_effect=NetworkConfigError):
            self.assertEqual(application.main([]), 78)
            server_type.assert_not_called()
        self.assertEqual(application.AdminHTTPServer.address_family, socket.AF_INET)
        self.assertEqual(application.main(["--listen", "0.0.0.0"]), 64)
        source = (ROOT / "admin" / "application.py").read_text(encoding="utf-8")
        for forbidden in ("172.21.31.5", "10.1.1.222", "127.0.0.2", "::1", "0.0.0.0"):
            self.assertNotIn(forbidden, source)

    def test_isolated_application_import_chain_metadata_is_strict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "opt" / "warp-egress-admin-console" / "app" / "admin"
            app.mkdir(parents=True, mode=0o755)
            application_path = app / "application.py"
            protocol_path = app / "protocol.py"
            network_path = app / "network.py"
            network_path.write_text("network", encoding="ascii")
            network_path.chmod(0o644)
            application_path.write_text("application", encoding="ascii")
            protocol_path.write_text("protocol", encoding="ascii")
            application_path.chmod(0o644)
            protocol_path.chmod(0o644)
            parents = (app, app.parent, app.parent.parent, app.parent.parent.parent)
            self.assertTrue(
                validate_installed_application_metadata(
                    application_path,
                    protocol_path,
                    network_path,
                    required_uid=os.getuid(),
                    required_gid=os.getgid(),
                    parents=parents,
                )
            )
            app.chmod(0o775)
            self.assertFalse(
                validate_installed_application_metadata(
                    application_path,
                    protocol_path,
                    network_path,
                    required_uid=os.getuid(),
                    required_gid=os.getgid(),
                    parents=parents,
                )
            )


class ProtocolTests(unittest.TestCase):
    def test_request_round_trip_is_exact(self) -> None:
        raw = encode_request("status", REQUEST_ID)
        self.assertEqual(
            loads_request(raw),
            {"protocol": 1, "operation": "status", "request_id": REQUEST_ID},
        )

    def test_request_rejects_future_operations_and_arbitrary_fields(self) -> None:
        for operation in ("connect", "disconnect", "unknown"):
            raw = json.dumps({"protocol": 1, "operation": operation, "request_id": REQUEST_ID}).encode()
            with self.subTest(operation=operation), self.assertRaises(ProtocolError):
                loads_request(raw)
        for raw in (
            b'[]',
            b'{"protocol":1,"operation":"status"}',
            b'{"protocol":1,"operation":"status","request_id":"123e4567-e89b-42d3-a456-426614174000","path":"/tmp"}',
            b'{"protocol":1,"protocol":1,"operation":"status","request_id":"123e4567-e89b-42d3-a456-426614174000"}',
            b'{"protocol":1,"operation":"status","request_id":"123e4567-e89b-42d3-a456-426614174000"} trailing',
            b'\xff',
        ):
            with self.subTest(raw=raw), self.assertRaises(ProtocolError):
                loads_request(raw)

    def test_uuid_and_input_bounds_fail_closed(self) -> None:
        invalid = (
            "123e4567-e89b-12d3-a456-426614174000",
            "123E4567-E89B-42D3-A456-426614174000",
            "123e4567e89b42d3a456426614174000",
            str(uuid.uuid1()),
        )
        for request_id in invalid:
            raw = json.dumps({"protocol": 1, "operation": "health", "request_id": request_id}).encode()
            with self.subTest(request_id=request_id), self.assertRaises(ProtocolError):
                loads_request(raw)
        with self.assertRaises(ProtocolError):
            loads_request(b"{" + b" " * MAX_HELPER_INPUT_BYTES + b"}")

    def test_response_schema_is_exact_bounded_and_read_only(self) -> None:
        value = helper_response("health", REQUEST_ID)
        self.assertEqual(loads_response(encode_response(value)), value)
        for key, changed_value in (
            ("changed", True),
            ("operation", "connect"),
            ("state", "active"),
        ):
            invalid = dict(value)
            invalid[key] = changed_value
            with self.subTest(key=key), self.assertRaises(ProtocolError):
                validate_response(invalid)
        extra = dict(value)
        extra["raw_stderr"] = "forbidden"
        with self.assertRaises(ProtocolError):
            validate_response(extra)
        with self.assertRaises(ProtocolError):
            loads_response(b"{" + b" " * MAX_HELPER_OUTPUT_BYTES + b"}")


class HelperTests(unittest.TestCase):
    class Runner:
        def __init__(self, result: CommandResult) -> None:
            self.result = result
            self.calls = 0

        def run(self) -> CommandResult:
            self.calls += 1
            return self.result

    def _version(self, temporary: str) -> Path:
        path = Path(temporary) / "VERSION"
        path.write_text("0.5.1\n", encoding="ascii")
        return path

    def test_status_and_health_use_same_read_only_observation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            for operation in ("status", "health"):
                runner = self.Runner(CommandResult(0, HEALTHY_LINE, b""))
                result = handle_request(
                    encode_request(operation, REQUEST_ID),
                    runner=runner,
                    version_path=self._version(temporary),
                    require_root_metadata=False,
                )
                self.assertEqual(runner.calls, 1)
                self.assertTrue(result["ok"])
                self.assertFalse(result["changed"])
                self.assertEqual(result["state"], "ok")

    def test_unhealthy_is_completed_evaluation_not_helper_failure(self) -> None:
        line = HEALTHY_LINE.replace(b"HEALTH=OK", b"HEALTH=FAIL").replace(b"warp=on", b"warp=fail")
        with tempfile.TemporaryDirectory() as temporary:
            result = handle_request(
                encode_request("health", REQUEST_ID),
                runner=self.Runner(CommandResult(0, line, b"")),
                version_path=self._version(temporary),
                require_root_metadata=False,
            )
        self.assertTrue(result["ok"])
        self.assertEqual(result["result_code"], "evaluation_unhealthy")
        self.assertEqual(result["state"], "failed")

    def test_lock_contention_and_observation_failure_are_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            version = self._version(temporary)
            busy = handle_request(
                encode_request("status", REQUEST_ID),
                runner=self.Runner(CommandResult(75, b"", b"EVALUATION=failed reason=mutation_lock_busy\n")),
                version_path=version,
                require_root_metadata=False,
            )
            failed = handle_request(
                encode_request("status", REQUEST_ID),
                runner=self.Runner(CommandResult(73, b"", b"seed-private-key-canary")),
                version_path=version,
                require_root_metadata=False,
            )
        self.assertEqual(busy["result_code"], "mutation_lock_busy")
        self.assertEqual(failed["result_code"], "observation_unavailable")
        self.assertNotIn("seed-private-key-canary", json.dumps(failed))

    def test_parser_is_strict_and_recovery_must_be_none(self) -> None:
        self.assertEqual(parse_health_output(HEALTHY_LINE)["HEALTH"], "OK")
        malformed = (
            b"",
            HEALTHY_LINE + HEALTHY_LINE,
            HEALTHY_LINE.replace(b"recovery=none", b"recovery=policy"),
            HEALTHY_LINE.replace(b"wg=up", b"wg=up wg=up"),
            HEALTHY_LINE.replace(b"nft=ok", b"nft=maybe"),
            HEALTHY_LINE + b"PrivateKey=secret",
        )
        for raw in malformed:
            with self.subTest(raw=raw), self.assertRaises(HelperRuntimeError):
                parse_health_output(raw)

    def test_runner_invokes_only_fixed_health_readonly_entrypoint(self) -> None:
        from admin import helper

        expected = ("/opt/warp-egress-admin-console/readonly/v3/evaluate.py",)
        with mock.patch.object(helper, "validate_readonly_metadata", return_value=True) as metadata, \
                mock.patch.object(helper, "_bounded_process", return_value=CommandResult(0, HEALTHY_LINE, b"")) as run:
            helper.HealthReadonlyRunner().run()
        metadata.assert_called_once_with()
        self.assertEqual(run.call_args.args[0], expected)
        flattened = " ".join(expected)
        for forbidden in (" health ", "route-repair", "systemctl", "nft", "wg ", "sysctl", "intent"):
            self.assertNotIn(forbidden, f" {flattened} ")

        with mock.patch.object(helper, "validate_readonly_metadata", return_value=False), \
                mock.patch.object(helper, "_bounded_process") as run:
            with self.assertRaises(HelperRuntimeError):
                helper.HealthReadonlyRunner().run()
            run.assert_not_called()

    def test_bounded_runner_fails_closed_on_timeout_and_output_overflow(self) -> None:
        from admin import helper

        with self.assertRaises(HelperRuntimeError) as timeout:
            helper._bounded_process(
                (sys.executable, "-c", "import time; time.sleep(2)"),
                timeout=0.05,
                stdout_limit=128,
                stderr_limit=128,
            )
        self.assertEqual(timeout.exception.code, "operation_timeout")
        with self.assertRaises(HelperRuntimeError) as overflow:
            helper._bounded_process(
                (sys.executable, "-c", "print('x' * 4096)"),
                timeout=2,
                stdout_limit=64,
                stderr_limit=64,
            )
        self.assertEqual(overflow.exception.code, "observation_unavailable")

    def test_main_rejects_argv_and_non_root_before_reading_stdin(self) -> None:
        from admin import helper

        self.assertEqual(helper.main(["helper", "status"], euid=0), 64)
        self.assertEqual(helper.main(["helper"], euid=1000), 77)

    def test_helper_import_chain_metadata_is_strict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            parent = root / "usr" / "local" / "libexec" / "warp-egress-gateway"
            parent.mkdir(parents=True, mode=0o755)
            helper_path = parent / "warp-admin-helper"
            protocol_path = parent / "protocol.py"
            helper_path.write_text("helper", encoding="ascii")
            protocol_path.write_text("protocol", encoding="ascii")
            helper_path.chmod(0o755)
            protocol_path.chmod(0o644)
            parents = (parent, parent.parent, parent.parent.parent, parent.parent.parent.parent)
            self.assertTrue(
                validate_installed_metadata(
                    helper_path,
                    protocol_path,
                    required_uid=os.getuid(),
                    required_gid=os.getgid(),
                    parents=parents,
                )
            )
            protocol_path.chmod(0o664)
            self.assertFalse(
                validate_installed_metadata(
                    helper_path,
                    protocol_path,
                    required_uid=os.getuid(),
                    required_gid=os.getgid(),
                    parents=parents,
                )
            )
            protocol_path.unlink()
            protocol_path.symlink_to(helper_path)
            self.assertFalse(
                validate_installed_metadata(
                    helper_path,
                    protocol_path,
                    required_uid=os.getuid(),
                    required_gid=os.getgid(),
                    parents=parents,
                )
            )


class SessionAndRateLimitTests(unittest.TestCase):
    def test_session_tokens_have_256_bits_and_expire(self) -> None:
        clock = [100.0]
        store = SessionStore(now=lambda: clock[0], inactivity_seconds=10, absolute_seconds=20)
        binding, csrf = store.issue()
        self.assertEqual(len(binding), 43)
        self.assertEqual(len(csrf), 43)
        self.assertNotEqual(binding, csrf)
        self.assertTrue(store.validate(binding, csrf=csrf))
        clock[0] = 111.0
        self.assertFalse(store.validate(binding, csrf=csrf))

    def test_session_rotation_revokes_the_previous_binding(self) -> None:
        store = SessionStore()
        first, first_csrf = store.issue()
        second, second_csrf = store.issue(replace=first)
        self.assertFalse(store.validate(first, csrf=first_csrf))
        self.assertTrue(store.validate(second, csrf=second_csrf))

    def test_csrf_comparison_uses_constant_time_primitive(self) -> None:
        store = SessionStore()
        binding, csrf = store.issue()
        with mock.patch("admin.application.hmac.compare_digest", wraps=__import__("hmac").compare_digest) as compare:
            self.assertTrue(store.validate(binding, csrf=csrf))
        compare.assert_called_once()

    def test_rate_limiter_enforces_per_binding_and_global_windows(self) -> None:
        limiter = RateLimiter(per_binding={"status": 1, "health": 1}, global_limits={"status": 2, "health": 2})
        self.assertTrue(limiter.allow("a", "status"))
        self.assertFalse(limiter.allow("a", "status"))
        self.assertTrue(limiter.allow("b", "status"))
        self.assertFalse(limiter.allow("c", "status"))


class AuditTests(unittest.TestCase):
    def test_application_and_helper_audits_are_bounded_and_secret_free(self) -> None:
        from admin import application, helper

        for sink_type in (application.JournalAudit, helper.JournalAudit):
            with self.subTest(sink=sink_type.__module__), mock.patch(
                f"{sink_type.__module__}.subprocess.run"
            ) as run:
                sink_type().emit(
                    request_id=REQUEST_ID,
                    action="health",
                    state="completed",
                    result_code="ok",
                    duration_ms=12,
                    cookie="seed-cookie-canary",
                    csrf="seed-csrf-canary",
                )
                command = " ".join(run.call_args.args[0])
                self.assertIn(f"request_id={REQUEST_ID}", command)
                self.assertIn("action=health", command)
                self.assertIn("state=completed", command)
                self.assertIn("changed=false", command)
                self.assertNotIn("seed-cookie-canary", command)
                self.assertNotIn("seed-csrf-canary", command)
            with mock.patch(f"{sink_type.__module__}.subprocess.run") as rejected:
                sink_type().emit(
                    request_id="bad\nrequest",
                    action="health",
                    state="failed",
                    result_code="seed_secret_canary",
                    duration_ms=0,
                )
                rejected.assert_not_called()


class HTTPBoundaryTests(unittest.TestCase):
    def test_root_issues_strict_cookie_and_security_headers(self) -> None:
        with running_server() as (server, _helper, _sessions, _audit):
            status, headers, body = request(server, "GET", "/")
        self.assertEqual(status, 200)
        cookie = headers["set-cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertIn("Path=/", cookie)
        self.assertNotIn("Domain=", cookie)
        self.assertNotIn("Secure", cookie)
        self.assertIn(b"Admin Console", body)
        for name in (
            "cache-control",
            "x-content-type-options",
            "referrer-policy",
            "x-frame-options",
            "content-security-policy",
            "permissions-policy",
        ):
            self.assertIn(name, headers)
        self.assertNotIn("access-control-allow-origin", headers)
        self.assertNotIn("access-control-allow-credentials", headers)

    def test_host_proxy_and_absolute_form_rejections_precede_helper(self) -> None:
        cases = (
            [],
            [("Host", "localhost:8788")],
            [("Host", "127.0.0.1")],
            [("Host", "127.0.0.1:9999")],
            [("Host", EXPECTED_HOST), ("Host", EXPECTED_HOST)],
            [("Host", EXPECTED_HOST), ("Forwarded", "host=127.0.0.1:8788")],
            [("Host", EXPECTED_HOST), ("X-Forwarded-Host", EXPECTED_HOST)],
        )
        with running_server() as (server, helper, _sessions, _audit):
            for headers in cases:
                with self.subTest(headers=headers):
                    status, _response_headers, _body = request(server, "GET", "/api/status", headers=headers)
                    self.assertEqual(status, 403)
            status, _headers, _body = request(
                server,
                "GET",
                "http://127.0.0.1:8788/api/status",
                headers=[("Host", EXPECTED_HOST)],
            )
            self.assertEqual(status, 400)
        self.assertEqual(helper.calls, [])

    def test_valid_status_and_health_are_correlated_and_read_only(self) -> None:
        audit = FakeAudit()
        with running_server(audit=audit) as (server, helper, _sessions, _audit):
            cookie, csrf = open_session(server)
            status_code, _headers, raw = request(
                server,
                "GET",
                "/api/status",
                headers=[("Host", EXPECTED_HOST), ("Cookie", cookie)],
            )
            self.assertEqual(status_code, 200)
            status_value = loads_response(raw)
            health_code, _headers, raw = request(
                server,
                "POST",
                "/api/actions/health",
                headers=[
                    ("Host", EXPECTED_HOST),
                    ("Cookie", cookie),
                    ("Origin", EXPECTED_ORIGIN),
                    ("X-CSRF-Token", csrf),
                    ("Content-Type", "application/json"),
                    ("Content-Length", "2"),
                ],
                body=b"{}",
            )
            self.assertEqual(health_code, 200)
            health_value = loads_response(raw)
        self.assertEqual([call[0] for call in helper.calls], ["status", "health"])
        self.assertEqual(helper.calls[0][1], status_value["request_id"])
        self.assertEqual(helper.calls[1][1], health_value["request_id"])
        self.assertTrue(all(event.get("changed", False) is False for event in audit.events))
        event_text = json.dumps(audit.events)
        self.assertNotIn(cookie, event_text)
        self.assertNotIn(csrf, event_text)
        self.assertEqual([event["state"] for event in audit.events], ["requested", "started", "completed"] * 2)

    def test_csrf_cookie_and_origin_failures_never_invoke_helper(self) -> None:
        with running_server() as (server, helper, _sessions, _audit):
            cookie, csrf = open_session(server)
            cases = (
                [("Host", EXPECTED_HOST), ("Origin", EXPECTED_ORIGIN), ("X-CSRF-Token", csrf)],
                [("Host", EXPECTED_HOST), ("Cookie", "warp_admin_session=" + "x" * 43), ("Origin", EXPECTED_ORIGIN), ("X-CSRF-Token", csrf)],
                [("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", EXPECTED_ORIGIN)],
                [("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", EXPECTED_ORIGIN), ("X-CSRF-Token", "x" * 43)],
                [("Host", EXPECTED_HOST), ("Cookie", cookie), ("X-CSRF-Token", csrf)],
                [("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", "null"), ("X-CSRF-Token", csrf)],
                [("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", "http://evil.invalid"), ("X-CSRF-Token", csrf)],
                [("Host", EXPECTED_HOST), ("Cookie", cookie), ("Referer", EXPECTED_ORIGIN + "/"), ("X-CSRF-Token", csrf)],
                [("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", EXPECTED_ORIGIN), ("Origin", EXPECTED_ORIGIN), ("X-CSRF-Token", csrf)],
            )
            for headers in cases:
                headers = list(headers) + [("Content-Type", "application/json"), ("Content-Length", "2")]
                with self.subTest(headers=headers):
                    code, _response_headers, _body = request(server, "POST", "/api/actions/health", headers=headers, body=b"{}")
                    self.assertEqual(code, 403)
        self.assertEqual(helper.calls, [])

    def test_expired_session_fails_before_helper(self) -> None:
        clock = [0.0]
        sessions = SessionStore(now=lambda: clock[0], inactivity_seconds=5, absolute_seconds=10)
        with running_server(sessions=sessions) as (server, helper, _sessions, _audit):
            cookie, csrf = open_session(server)
            clock[0] = 6.0
            code, _headers, _body = request(
                server,
                "POST",
                "/api/actions/health",
                headers=[
                    ("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", EXPECTED_ORIGIN),
                    ("X-CSRF-Token", csrf), ("Content-Type", "application/json"), ("Content-Length", "2"),
                ],
                body=b"{}",
            )
        self.assertEqual(code, 403)
        self.assertEqual(helper.calls, [])

    def test_body_parser_accepts_only_exact_empty_object_schema(self) -> None:
        invalid_cases = (
            (b"{}", [("Content-Type", "text/plain"), ("Content-Length", "2")], 415),
            (b"{}", [("Content-Type", "application/json")], 400),
            (b"{}", [("Content-Type", "application/json"), ("Content-Length", "2"), ("Content-Length", "2")], 400),
            (b"{}", [("Content-Type", "application/json"), ("Content-Length", "2"), ("Transfer-Encoding", "chunked")], 400),
            (b"{}", [("Content-Type", "application/json"), ("Content-Length", "2"), ("Content-Encoding", "gzip")], 400),
            (b'{"x":1}', [("Content-Type", "application/json"), ("Content-Length", "7")], 400),
            (b'{"x":1,"x":2}', [("Content-Type", "application/json"), ("Content-Length", "13")], 400),
            (b"[]", [("Content-Type", "application/json"), ("Content-Length", "2")], 400),
            (b"{} trailing", [("Content-Type", "application/json"), ("Content-Length", "11")], 400),
            (b"\xff", [("Content-Type", "application/json"), ("Content-Length", "1")], 400),
            (b" " * (MAX_HTTP_BODY_BYTES + 1), [("Content-Type", "application/json"), ("Content-Length", str(MAX_HTTP_BODY_BYTES + 1))], 413),
        )
        with running_server() as (server, helper, _sessions, _audit):
            for body, body_headers, expected in invalid_cases:
                cookie, csrf = open_session(server)
                headers = [("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", EXPECTED_ORIGIN), ("X-CSRF-Token", csrf)] + list(body_headers)
                with self.subTest(body=body, headers=body_headers):
                    code, _response_headers, _body = request(server, "POST", "/api/actions/health", headers=headers, body=body)
                    self.assertEqual(code, expected)
            cookie, csrf = open_session(server)
            code, _headers, _body = request(
                server,
                "POST",
                "/api/actions/health?operation=health",
                headers=[("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", EXPECTED_ORIGIN), ("X-CSRF-Token", csrf), ("Content-Type", "application/json"), ("Content-Length", "2")],
                body=b"{}",
            )
            self.assertEqual(code, 400)
        self.assertEqual(helper.calls, [])

    def test_mutation_and_generic_routes_are_unavailable(self) -> None:
        paths = (
            "/api/actions/connect",
            "/api/actions/disconnect",
            "/api/action",
            "/api/command",
            "/exec",
            "/shell",
        )
        with running_server() as (server, helper, _sessions, _audit):
            cookie, csrf = open_session(server)
            for path in paths:
                code, _headers, _body = request(
                    server,
                    "POST",
                    path,
                    headers=[("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", EXPECTED_ORIGIN), ("X-CSRF-Token", csrf), ("Content-Type", "application/json"), ("Content-Length", "2")],
                    body=b"{}",
                )
                self.assertEqual(code, 404)
        self.assertEqual(helper.calls, [])

    def test_options_has_no_cors_and_action_get_is_not_executed(self) -> None:
        with running_server() as (server, helper, _sessions, _audit):
            code, headers, _body = request(server, "OPTIONS", "/api/actions/health")
            self.assertEqual(code, 405)
            self.assertNotIn("access-control-allow-origin", headers)
            code, _headers, _body = request(server, "GET", "/api/actions/health")
            self.assertEqual(code, 404)
        self.assertEqual(helper.calls, [])

    def test_rate_limit_returns_429_before_helper(self) -> None:
        limiter = RateLimiter(per_binding={"status": 1, "health": 1}, global_limits={"status": 2, "health": 2})
        with running_server(limiter=limiter) as (server, helper, _sessions, _audit):
            cookie, _csrf = open_session(server)
            headers = [("Host", EXPECTED_HOST), ("Cookie", cookie)]
            self.assertEqual(request(server, "GET", "/api/status", headers=headers)[0], 200)
            self.assertEqual(request(server, "GET", "/api/status", headers=headers)[0], 429)
        self.assertEqual(len(helper.calls), 1)

    def test_health_and_global_limits_return_429_before_helper(self) -> None:
        health_limiter = RateLimiter(
            per_binding={"status": 10, "health": 1},
            global_limits={"status": 20, "health": 2},
        )
        with running_server(limiter=health_limiter) as (server, helper, _sessions, _audit):
            cookie, csrf = open_session(server)
            headers = [
                ("Host", EXPECTED_HOST), ("Cookie", cookie), ("Origin", EXPECTED_ORIGIN),
                ("X-CSRF-Token", csrf), ("Content-Type", "application/json"), ("Content-Length", "2"),
            ]
            self.assertEqual(request(server, "POST", "/api/actions/health", headers=headers, body=b"{}")[0], 200)
            self.assertEqual(request(server, "POST", "/api/actions/health", headers=headers, body=b"{}")[0], 429)
        self.assertEqual(len(helper.calls), 1)

        global_limiter = RateLimiter(
            per_binding={"status": 10, "health": 10},
            global_limits={"status": 1, "health": 20},
        )
        with running_server(limiter=global_limiter) as (server, helper, _sessions, _audit):
            first, _csrf = open_session(server)
            second, _csrf = open_session(server)
            self.assertEqual(request(server, "GET", "/api/status", headers=[("Host", EXPECTED_HOST), ("Cookie", first)])[0], 200)
            self.assertEqual(request(server, "GET", "/api/status", headers=[("Host", EXPECTED_HOST), ("Cookie", second)])[0], 429)
        self.assertEqual(len(helper.calls), 1)

    def test_stable_helper_failure_mapping(self) -> None:
        expected = {
            "helper_unavailable": 503,
            "privilege_denied": 503,
            "operation_timeout": 504,
            "helper_protocol_error": 502,
        }
        for error, status in expected.items():
            with self.subTest(error=error), running_server(helper=FakeHelper(error=error)) as (server, _helper, _sessions, _audit):
                cookie, _csrf = open_session(server)
                code, _headers, body = request(server, "GET", "/api/status", headers=[("Host", EXPECTED_HOST), ("Cookie", cookie)])
                self.assertEqual(code, status)
                self.assertEqual(json.loads(body)["error"], error)


class UIContractTests(unittest.TestCase):
    def test_ui_is_local_text_only_and_exposes_only_health_and_repair(self) -> None:
        html = (ROOT / "admin" / "static" / "index.html").read_text(encoding="utf-8")
        script = (ROOT / "admin" / "static" / "admin.js").read_text(encoding="utf-8")
        self.assertIn("Admin Console", html)
        self.assertIn("Run Health", html)
        self.assertIn("Repair Routing", html)
        self.assertIn("Management network · read-only", html)
        self.assertNotIn("ssh -L", html)
        self.assertNotIn("SSH tunnel", html)
        for absent in ("Connect WARP", "Disconnect WARP", "terminal", "config editor", "logs console"):
            self.assertNotIn(absent, html)
        for forbidden in ("innerHTML", "eval(", "Function(", "document.write", "http://", "https://"):
            self.assertNotIn(forbidden, script)
        self.assertIn("textContent", script)
        self.assertIn('method: "POST"', script)
        self.assertIn('"/api/actions/health"', script)
        self.assertNotRegex(html, r"<(script|link)[^>]+(?:src|href)=\"https?://")


class ApplicationHelperClientTests(unittest.TestCase):
    def test_helper_result_is_validated_and_correlated(self) -> None:
        from admin import application

        valid = encode_response(helper_response("status", REQUEST_ID)) + b"\n"
        with mock.patch.object(application, "_helper_available", return_value=True), mock.patch.object(
            application, "_invoke_bounded", return_value=(0, valid)
        ):
            self.assertEqual(application.SudoHelperClient().invoke("status", REQUEST_ID)["state"], "ok")

        wrong = encode_response(helper_response("health", REQUEST_ID))
        with mock.patch.object(application, "_helper_available", return_value=True), mock.patch.object(
            application, "_invoke_bounded", return_value=(0, wrong)
        ), self.assertRaises(AdminError) as mismatch:
            application.SudoHelperClient().invoke("status", REQUEST_ID)
        self.assertEqual(mismatch.exception.code, "helper_protocol_error")

    def test_missing_helper_and_sudo_denial_are_distinct(self) -> None:
        from admin import application

        with mock.patch.object(application, "_helper_available", return_value=False), self.assertRaises(AdminError) as missing:
            application.SudoHelperClient().invoke("status", REQUEST_ID)
        self.assertEqual(missing.exception.code, "helper_unavailable")
        with mock.patch.object(application, "_helper_available", return_value=True), mock.patch.object(
            application, "_invoke_bounded", return_value=(1, b"")
        ), self.assertRaises(AdminError) as denied:
            application.SudoHelperClient().invoke("status", REQUEST_ID)
        self.assertEqual(denied.exception.code, "privilege_denied")


if __name__ == "__main__":
    unittest.main()
