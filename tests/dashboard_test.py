#!/usr/bin/env python3
"""Focused behavior tests for the v0.5.0 read-only dashboard."""

from __future__ import annotations

import copy
from contextlib import contextmanager
import http.client
from html.parser import HTMLParser
import json
import os
import stat
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from web.dashboard.schema import (  # noqa: E402
    StatusValidationError,
    is_stale,
    loads_status,
    validate_status,
)


def healthy_status() -> dict[str, object]:
    return {
        "schema_version": 1,
        "generated_at": "2026-08-24T12:00:00Z",
        "overall": {"state": "online"},
        "system": {
            "hostname": "gateway-demo-01",
            "version": "0.4.1",
            "uptime_seconds": 390600,
        },
        "warp": {
            "state": "connected",
            "interface": "up",
            "handshake_age_seconds": 32,
            "public_ip": "203.0.113.42",
            "colo": "FRA",
            "location": "DE",
        },
        "paths": {
            "direct": {"state": "ok", "warp": "off"},
            "warp": {"state": "ok", "warp": "on"},
        },
        "routing": {
            "rule_100": "ok",
            "rule_110": "ok",
            "table_100": "ok",
            "main_default": "ok",
        },
        "safety": {"kill_switch": "active", "ipv4_forwarding": True},
        "monitoring": {
            "health": "ok",
            "monitor": "ok",
            "health_timer": "active",
            "monitor_timer": "active",
            "failed_units": 0,
        },
    }


class SchemaTests(unittest.TestCase):
    def test_complete_schema_is_accepted_without_rewriting_values(self) -> None:
        status = healthy_status()
        self.assertEqual(validate_status(status), status)

    def test_checked_in_demo_fixtures_are_schema_valid_and_synthetic(self) -> None:
        fixture_dir = ROOT / "web" / "dashboard" / "fixtures"
        for name, expected_state in (
            ("healthy", "online"),
            ("degraded", "degraded"),
            ("failed", "offline"),
        ):
            with self.subTest(name=name):
                raw = (fixture_dir / f"{name}.json").read_bytes()
                value = loads_status(raw)
                self.assertEqual(value["overall"]["state"], expected_state)
                self.assertTrue(value["system"]["hostname"].startswith("gateway-demo-"))
                public_ip = value["warp"]["public_ip"]
                self.assertTrue(public_ip is None or public_ip.startswith("203.0.113."))

    def test_duplicate_json_keys_are_rejected(self) -> None:
        raw = json.dumps(healthy_status(), separators=(",", ":")).encode()
        raw = raw.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1', 1)
        with self.assertRaises(StatusValidationError):
            loads_status(raw)

    def test_unknown_and_secret_like_fields_are_rejected_recursively(self) -> None:
        cases: list[tuple[str, dict[str, object]]] = []
        unknown = healthy_status()
        unknown["extra"] = "not allowed"
        cases.append(("unknown", unknown))
        for key in (
            "PrivateKey",
            "PresharedKey",
            "password",
            "access_token",
            "cookie",
            "tls_private_material",
            "wgcf_account",
            "environment_dump",
            "sudoers_contents",
        ):
            value = healthy_status()
            value["monitoring"][key] = "forbidden"
            cases.append((key, value))
        for label, value in cases:
            with self.subTest(label=label), self.assertRaises(StatusValidationError):
                validate_status(value)

    def test_observation_values_may_be_explicitly_unknown(self) -> None:
        status = healthy_status()
        status["system"]["version"] = "unknown"
        status["system"]["uptime_seconds"] = None
        status["safety"]["ipv4_forwarding"] = None
        status["monitoring"]["failed_units"] = None
        self.assertEqual(validate_status(status), status)

    def test_missing_fields_invalid_enums_and_wrong_primitives_are_rejected(self) -> None:
        cases: list[tuple[str, dict[str, object]]] = []
        missing = healthy_status()
        del missing["routing"]["rule_100"]
        cases.append(("missing", missing))
        invalid_state = healthy_status()
        invalid_state["overall"]["state"] = "ok"
        cases.append(("enum", invalid_state))
        bool_as_int = healthy_status()
        bool_as_int["monitoring"]["failed_units"] = True
        cases.append(("bool-as-int", bool_as_int))
        negative_age = healthy_status()
        negative_age["warp"]["handshake_age_seconds"] = -1
        cases.append(("negative-age", negative_age))
        bad_time = healthy_status()
        bad_time["generated_at"] = "2026-08-24 12:00:00"
        cases.append(("timestamp", bad_time))
        for label, value in cases:
            with self.subTest(label=label), self.assertRaises(StatusValidationError):
                validate_status(value)

    def test_stale_threshold_is_strictly_older_than_thirty_seconds(self) -> None:
        now = datetime(2026, 8, 24, 12, 0, 30, tzinfo=timezone.utc)
        status = healthy_status()
        self.assertFalse(is_stale(status, now=now))
        self.assertTrue(is_stale(status, now=now + timedelta(microseconds=1)))


class FakeRunner:
    def __init__(self, outputs: dict[tuple[str, ...], bytes | Exception]) -> None:
        self.outputs = outputs
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...]):
        from web.dashboard.collector import CommandResult, ObservationFailed

        self.calls.append(argv)
        value = self.outputs.get(argv, ObservationFailed("fixture command missing"))
        if isinstance(value, Exception):
            raise value
        return CommandResult(returncode=0, stdout=value, stderr=b"")


def collector_outputs() -> dict[tuple[str, ...], bytes | Exception]:
    return {
        ("/usr/bin/hostname", "-s"): b"gateway-demo-collector\n",
        ("/usr/sbin/ip", "-j", "-4", "link", "show", "dev", "warp0"): b'[{"ifname":"warp0","operstate":"UP"}]\n',
        ("/usr/sbin/ip", "-4", "-o", "address", "show", "dev", "warp0", "scope", "global"): b"7: warp0 inet 172.16.0.2/32 scope global warp0\n",
        ("/usr/bin/wg", "show", "warp0", "latest-handshakes"): b"peer-public-key\t1787572770\n",
        ("/usr/bin/curl", "-4", "--silent", "--show-error", "--fail", "--interface", "ens160", "--connect-timeout", "5", "--max-time", "10", "https://www.cloudflare.com/cdn-cgi/trace"): b"ip=198.51.100.8\nvisit_scheme=https\nsome_future_field=value\nloc=DE\ncolo=FRA\nwarp=off\n",
        ("/usr/bin/curl", "-4", "--silent", "--show-error", "--fail", "--interface", "172.16.0.2", "--connect-timeout", "5", "--max-time", "10", "https://www.cloudflare.com/cdn-cgi/trace"): b"ip=203.0.113.77\nvisit_scheme=https\nsome_future_field=value\nloc=DE\ncolo=FRA\nwarp=on\n",
        ("/usr/sbin/ip", "-4", "rule", "show"): b"0: from all lookup local\n100: from 172.16.0.2 lookup warp_gateway\n110: from all iif ens192 lookup warp_gateway\n32766: from all lookup main\n",
        ("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "100", "default"): b'[{"dst":"default","dev":"warp0","scope":"link"}]\n',
        ("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "main", "default"): b'[{"dst":"default","gateway":"192.0.2.1","dev":"ens160"}]\n',
        ("/usr/sbin/nft", "-j", "list", "table", "inet", "warp_gateway"): json.dumps({"nftables": [{"rule": {"family": "inet", "table": "warp_gateway", "chain": "forward", "comment": "WARP_KILL_SWITCH", "expr": [{"match": {"left": {"meta": {"key": "iifname"}}, "op": "==", "right": "ens192"}}, {"match": {"left": {"meta": {"key": "oifname"}}, "op": "!=", "right": "warp0"}}, {"drop": None}]}}]}).encode(),
        ("/usr/sbin/sysctl", "-n", "net.ipv4.ip_forward"): b"1\n",
        ("/usr/bin/systemctl", "is-active", "warp-gateway-healthcheck.timer"): b"active\n",
        ("/usr/bin/systemctl", "is-active", "warp-monitor.timer"): b"active\n",
        ("/usr/bin/systemctl", "--failed", "--no-legend", "--plain", "--no-pager"): b"",
        ("/usr/bin/journalctl", "-u", "warp-gateway-healthcheck.service", "-n", "20", "--no-pager", "-o", "cat"): b"HEALTH=OK recovery=none\n",
        ("/usr/bin/journalctl", "-t", "warp-monitor", "-n", "20", "--no-pager", "-o", "cat"): b"STATUS=OK wg=up handshake=ok\n",
    }


class CollectorTests(unittest.TestCase):
    def test_production_version_path_uses_native_install_contract(self) -> None:
        from web.dashboard.collector import CollectorRuntime, VERSION_PATH

        expected = Path("/etc/warp-egress-gateway/VERSION")
        self.assertEqual(VERSION_PATH, expected)
        self.assertEqual(CollectorRuntime().version_path, expected)
        self.assertNotEqual(VERSION_PATH, Path("/opt/warp-egress-gateway/VERSION"))

    def test_bounded_runner_returns_stdout_without_a_shell(self) -> None:
        from web.dashboard.collector import BoundedRunner

        result = BoundedRunner(timeout_seconds=1, output_limit=128).run(
            (sys.executable, "-c", "print('bounded-ok')")
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"bounded-ok\n")

    def test_bounded_runner_fails_closed_for_missing_timeout_and_overflow(self) -> None:
        from web.dashboard.collector import BoundedRunner, ObservationFailed

        cases = (
            (("/definitely/missing/warp-dashboard-command",), 1.0, 128),
            ((sys.executable, "-c", "import time; time.sleep(2)"), 0.05, 128),
            ((sys.executable, "-c", "print('x' * 4096)"), 1.0, 64),
        )
        for argv, timeout, limit in cases:
            with self.subTest(argv=argv), self.assertRaises(ObservationFailed):
                BoundedRunner(timeout_seconds=timeout, output_limit=limit).run(argv)

    def test_parsers_accept_semantic_metadata_and_reject_unsafe_routes(self) -> None:
        from web.dashboard.collector import (
            parse_default_route,
            parse_handshake_age,
            parse_trace,
        )

        self.assertEqual(parse_trace(b"ip=203.0.113.7\ncolo=FRA\nloc=DE\nwarp=on\n")["warp"], "on")
        self.assertEqual(parse_handshake_age(b"peer\t90\n", now_epoch=120), 30)
        self.assertTrue(parse_default_route(b'[{"dst":"default","dev":"warp0","scope":"link"}]', expected_device="warp0", allow_gateway=False))
        self.assertFalse(parse_default_route(b'[{"dst":"default","dev":"warp0","gateway":"192.0.2.1"}]', expected_device="warp0", allow_gateway=False))
        self.assertFalse(parse_default_route(b'[{"dst":"default","dev":"warp0"},{"dst":"default","dev":"warp0"}]', expected_device="warp0", allow_gateway=False))

    def test_trace_parser_ignores_unconsumed_cloudflare_fields(self) -> None:
        from web.dashboard.collector import parse_trace

        realistic = (
            b"fl=example\n"
            b"h=www.cloudflare.com\n"
            b"ip=203.0.113.42\n"
            b"ts=1234567890.123\n"
            b"visit_scheme=https\n"
            b"uag=curl/8.0.0\n"
            b"colo=SOF\n"
            b"http=http/2\n"
            b"loc=TJ\n"
            b"tls=TLSv1.3\n"
            b"sni=plaintext\n"
            b"warp=on\n"
            b"gateway=off\n"
            b"rbi=off\n"
        )
        self.assertEqual(
            parse_trace(realistic),
            {"ip": "203.0.113.42", "colo": "SOF", "loc": "TJ", "warp": "on"},
        )
        self.assertEqual(
            parse_trace(
                b"some_future_field=first\n"
                b"some_future_field=second\n"
                b"warp=off\n"
            ),
            {"warp": "off"},
        )

    def test_trace_parser_rejects_malformed_consumed_fields(self) -> None:
        from web.dashboard.collector import ObservationFailed, parse_trace

        malformed = (
            b"warp=on\nwarp=off\n",
            b"ip=203.0.113.42\nip=203.0.113.43\nwarp=on\n",
            b"ip=not-an-ip\nwarp=on\n",
            b"warp=maybe\n",
            b"line-without-equals\nwarp=on\n",
            b"colo=SOF\x01\nwarp=on\n",
            b"colo=SOF\x7f\nwarp=on\n",
            b"loc=" + (b"A" * 33) + b"\nwarp=on\n",
        )
        for raw in malformed:
            with self.subTest(raw=raw), self.assertRaises(ObservationFailed):
                parse_trace(raw)

    def test_interface_parser_uses_valid_administrative_up_flags(self) -> None:
        from web.dashboard.collector import ObservationFailed, _parse_interface

        cases = (
            (b'[{"ifname":"warp0","operstate":"UP"}]', "up"),
            (b'[{"ifname":"warp0","operstate":"UNKNOWN","flags":["POINTOPOINT","NOARP","UP","LOWER_UP"]}]', "up"),
            (b'[{"ifname":"warp0","operstate":"DOWN","flags":["POINTOPOINT","NOARP"]}]', "down"),
            (b'[{"ifname":"warp0","operstate":"UNKNOWN","flags":["POINTOPOINT","NOARP"]}]', "unknown"),
        )
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(_parse_interface(raw), expected)

        for raw in (
            b'[{"ifname":"warp0","operstate":"UP","flags":"UP"}]',
            b'[{"ifname":"warp0","operstate":"UP","flags":["UP",1]}]',
            b'[{"ifname":"warp0","operstate":"UP","flags":{"UP":true}}]',
        ):
            with self.subTest(malformed=raw), self.assertRaises(ObservationFailed):
                _parse_interface(raw)

    def test_live_wireguard_link_shape_produces_connected_status(self) -> None:
        from web.dashboard.collector import CollectorRuntime, collect_status

        outputs = collector_outputs()
        outputs[("/usr/sbin/ip", "-j", "-4", "link", "show", "dev", "warp0")] = (
            b'[{"ifname":"warp0","operstate":"UNKNOWN","flags":["POINTOPOINT","NOARP","UP","LOWER_UP"]}]\n'
        )
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            version = temporary_path / "VERSION"
            uptime = temporary_path / "uptime"
            version.write_text("0.4.1\n", encoding="ascii")
            uptime.write_text("390600.00 100.00\n", encoding="ascii")
            status = collect_status(
                CollectorRuntime(
                    runner=FakeRunner(outputs),
                    version_path=version,
                    uptime_path=uptime,
                    now=lambda: datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc),
                    epoch_now=lambda: 1787572800,
                )
            )

        self.assertEqual(status["warp"]["interface"], "up")
        self.assertEqual(status["warp"]["state"], "connected")

    @unittest.skipUnless(Path("/proc/uptime").exists(), "procfs uptime semantics require Linux")
    def test_proc_uptime_is_read_when_metadata_size_is_zero(self) -> None:
        from web.dashboard.collector import CollectorRuntime, collect_status

        self.assertEqual(Path("/proc/uptime").stat().st_size, 0)
        with tempfile.TemporaryDirectory() as temporary:
            version = Path(temporary) / "VERSION"
            version.write_text("0.4.1\n", encoding="ascii")
            status = collect_status(
                CollectorRuntime(
                    runner=FakeRunner(collector_outputs()),
                    version_path=version,
                    now=lambda: datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc),
                    epoch_now=lambda: 1787572800,
                )
            )

        self.assertIs(type(status["system"]["uptime_seconds"]), int)
        self.assertGreaterEqual(status["system"]["uptime_seconds"], 0)

    def test_virtual_uptime_reader_does_not_weaken_fixed_version_reader(self) -> None:
        from web.dashboard.collector import CollectorRuntime, collect_status

        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            version = temporary_path / "VERSION"
            uptime = temporary_path / "uptime"
            version.touch()
            uptime.write_text("390600.00 100.00\n", encoding="ascii")
            status = collect_status(
                CollectorRuntime(
                    runner=FakeRunner(collector_outputs()),
                    version_path=version,
                    uptime_path=uptime,
                    now=lambda: datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc),
                    epoch_now=lambda: 1787572800,
                )
            )

        self.assertEqual(status["system"]["version"], "unknown")
        self.assertEqual(status["system"]["uptime_seconds"], 390600)

    def test_transient_trace_failure_stays_unknown_and_never_becomes_ok(self) -> None:
        from web.dashboard.collector import CollectorRuntime, ObservationFailed, collect_status

        outputs = collector_outputs()
        outputs[("/usr/bin/curl", "-4", "--silent", "--show-error", "--fail", "--interface", "ens160", "--connect-timeout", "5", "--max-time", "10", "https://www.cloudflare.com/cdn-cgi/trace")] = ObservationFailed("transient probe failure")
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            version = temporary_path / "VERSION"
            uptime = temporary_path / "uptime"
            version.write_text("0.4.1\n", encoding="ascii")
            uptime.write_text("390600.00 100.00\n", encoding="ascii")
            status = collect_status(
                CollectorRuntime(
                    runner=FakeRunner(outputs),
                    version_path=version,
                    uptime_path=uptime,
                    now=lambda: datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc),
                    epoch_now=lambda: 1787572800,
                )
            )

        self.assertEqual(status["paths"]["direct"], {"state": "unknown", "warp": "unknown"})
        self.assertEqual(status["paths"]["warp"], {"state": "ok", "warp": "on"})
        self.assertEqual(status["overall"]["state"], "degraded")

    def test_collector_builds_healthy_valid_status_using_only_read_only_commands(self) -> None:
        from web.dashboard.collector import CollectorRuntime, collect_status

        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            version = temporary_path / "VERSION"
            uptime = temporary_path / "uptime"
            version.write_text("0.4.1\n", encoding="ascii")
            uptime.write_text("390600.00 100.00\n", encoding="ascii")
            runner = FakeRunner(collector_outputs())
            runtime = CollectorRuntime(
                runner=runner,
                version_path=version,
                uptime_path=uptime,
                now=lambda: datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc),
                epoch_now=lambda: 1787572800,
            )
            status = collect_status(runtime)

        self.assertEqual(validate_status(status)["overall"]["state"], "online")
        self.assertEqual(status["system"]["version"], "0.4.1")
        self.assertEqual(status["paths"]["direct"], {"state": "ok", "warp": "off"})
        self.assertEqual(status["paths"]["warp"], {"state": "ok", "warp": "on"})
        self.assertEqual(status["warp"]["public_ip"], "203.0.113.77")
        self.assertEqual(status["warp"]["colo"], "FRA")
        self.assertEqual(status["warp"]["location"], "DE")
        self.assertEqual(status["routing"], {"rule_100": "ok", "rule_110": "ok", "table_100": "ok", "main_default": "ok"})
        tokens = {argument.lower() for call in runner.calls for argument in call}
        joined = "\n".join(" ".join(call).lower() for call in runner.calls)
        for forbidden in ("sudo", "restart", "stop", "start", "add", "delete", "replace", "flush"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, tokens)
        for forbidden_path in ("warp-web-helper", "web-routing", "web-health", "web-warp"):
            with self.subTest(forbidden_path=forbidden_path):
                self.assertNotIn(forbidden_path, joined)

    def test_failed_observations_produce_unknown_snapshot_instead_of_crashing(self) -> None:
        from web.dashboard.collector import CollectorRuntime, ObservationFailed, collect_status

        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "missing"
            runtime = CollectorRuntime(
                runner=FakeRunner({}),
                version_path=missing,
                uptime_path=missing,
                now=lambda: datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc),
                epoch_now=lambda: 1787572800,
            )
            status = collect_status(runtime)

        self.assertEqual(validate_status(status)["overall"]["state"], "unknown")
        self.assertEqual(status["system"]["version"], "unknown")
        self.assertIsNone(status["system"]["uptime_seconds"])
        self.assertIsNone(status["safety"]["ipv4_forwarding"])
        self.assertIsNone(status["monitoring"]["failed_units"])


class AtomicSnapshotTests(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "Unix mode and no-follow semantics required")
    def test_atomic_writer_publishes_complete_mode_0640_snapshot_under_hostile_umask(self) -> None:
        from web.dashboard.collector import write_atomic_status

        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "status.json"
            previous_umask = os.umask(0o002)
            replace_inputs: list[bytes] = []
            real_replace = os.replace

            def inspecting_replace(source: str | os.PathLike[str], target: str | os.PathLike[str]) -> None:
                replace_inputs.append(Path(source).read_bytes())
                real_replace(source, target)

            try:
                with mock.patch("web.dashboard.collector.os.replace", side_effect=inspecting_replace):
                    write_atomic_status(destination, healthy_status())
            finally:
                os.umask(previous_umask)

            self.assertEqual(len(replace_inputs), 1)
            self.assertEqual(loads_status(replace_inputs[0]), healthy_status())
            self.assertEqual(loads_status(destination.read_bytes()), healthy_status())
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o640)
            self.assertEqual(list(destination.parent.glob(".status.json.*")), [])

    @unittest.skipIf(os.name == "nt", "Unix symlink semantics required")
    def test_atomic_writer_refuses_existing_symlink(self) -> None:
        from web.dashboard.collector import SnapshotWriteError, write_atomic_status

        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "target"
            target.write_text("unchanged", encoding="ascii")
            destination = Path(temporary) / "status.json"
            destination.symlink_to(target)
            with self.assertRaises(SnapshotWriteError):
                write_atomic_status(destination, healthy_status())
            self.assertEqual(target.read_text(encoding="ascii"), "unchanged")


@contextmanager
def running_dashboard_server(provider: object):
    from web.dashboard.server import create_server

    with tempfile.TemporaryDirectory() as temporary:
        static_directory = Path(temporary)
        (static_directory / "index.html").write_text("<!doctype html><title>Dashboard test</title>", encoding="utf-8")
        (static_directory / "styles.css").write_text("body { color: #fff; }", encoding="utf-8")
        (static_directory / "app.js").write_text("'use strict';", encoding="utf-8")
        server = create_server(
            "127.0.0.1",
            0,
            provider,
            static_directory=static_directory,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server.server_address[1]
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


def http_request(port: int, method: str, path: str) -> tuple[int, dict[str, str], bytes]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request(method, path)
        response = connection.getresponse()
        return response.status, {key.lower(): value for key, value in response.getheaders()}, response.read()
    finally:
        connection.close()


class ServerTests(unittest.TestCase):
    def test_status_api_returns_only_validated_snapshot_and_stale_header(self) -> None:
        from web.dashboard.server import SnapshotProvider

        with tempfile.TemporaryDirectory() as temporary:
            snapshot = Path(temporary) / "status.json"
            snapshot.write_text(json.dumps(healthy_status()), encoding="utf-8")
            with running_dashboard_server(SnapshotProvider(snapshot)) as port:
                status, headers, body = http_request(port, "GET", "/api/status")
        self.assertEqual(status, 200)
        self.assertEqual(loads_status(body), healthy_status())
        self.assertEqual(headers["content-type"], "application/json; charset=utf-8")
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertEqual(headers["x-warp-status-stale"], "true")

    def test_fixture_provider_loads_allowlisted_fixture_and_refreshes_timestamp(self) -> None:
        from web.dashboard.server import FixtureProvider

        provider = FixtureProvider(
            "degraded",
            now=lambda: datetime(2026, 8, 24, 14, 15, 16, tzinfo=timezone.utc),
        )
        value = provider.read()
        self.assertEqual(value["overall"]["state"], "degraded")
        self.assertEqual(value["generated_at"], "2026-08-24T14:15:16Z")
        with self.assertRaises(ValueError):
            FixtureProvider("../../etc/passwd")

    def test_dashboard_health_and_assets_are_get_only(self) -> None:
        from web.dashboard.server import FixtureProvider

        with running_dashboard_server(FixtureProvider("healthy")) as port:
            index_status, index_headers, index_body = http_request(port, "GET", "/")
            health_status, _health_headers, health_body = http_request(port, "GET", "/healthz")
            css_status, _css_headers, _css_body = http_request(port, "GET", "/assets/styles.css")
            js_status, _js_headers, _js_body = http_request(port, "GET", "/assets/app.js")
            rejected = {method: http_request(port, method, "/api/status")[0] for method in ("POST", "PUT", "PATCH", "DELETE")}
        self.assertEqual(index_status, 200)
        self.assertIn(b"Dashboard test", index_body)
        self.assertEqual(index_headers["content-security-policy"], "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.assertEqual(health_status, 200)
        self.assertEqual(json.loads(health_body), {"ok": True})
        self.assertEqual(css_status, 200)
        self.assertEqual(js_status, 200)
        self.assertEqual(rejected, {"POST": 501, "PUT": 501, "PATCH": 501, "DELETE": 501})

    def test_explicit_management_ipv4_is_passed_unchanged_to_socket(self) -> None:
        from web.dashboard.server import FixtureProvider, create_server

        provider = FixtureProvider("healthy")
        static_directory = Path("/synthetic/dashboard/assets")
        sentinel = object()
        with mock.patch("web.dashboard.server.DashboardHTTPServer", return_value=sentinel) as constructor:
            try:
                server = create_server("192.0.2.10", 8787, provider, static_directory=static_directory)
            except ValueError as exc:
                self.fail(f"explicit management IPv4 was rejected: {exc}")

        self.assertIs(server, sentinel)
        constructor.assert_called_once_with(("192.0.2.10", 8787), provider, static_directory)

    def test_unsafe_listener_addresses_are_rejected_before_socket_creation(self) -> None:
        from web.dashboard.server import FixtureProvider, create_server

        provider = FixtureProvider("healthy")
        for listen in (
            "0.0.0.0",
            "::",
            "2001:db8::10",
            "localhost",
            "not-an-ip",
            "224.0.0.1",
            "255.255.255.255",
            "127.0.0.2",
            "",
        ):
            with self.subTest(listen=listen), self.assertRaises(ValueError):
                create_server(listen, 0, provider)

    def test_non_string_listener_is_rejected_before_socket_creation(self) -> None:
        from web.dashboard.server import FixtureProvider, create_server

        with mock.patch("web.dashboard.server.DashboardHTTPServer") as constructor:
            with self.assertRaises(ValueError):
                create_server(1, 0, FixtureProvider("healthy"))  # type: ignore[arg-type]

        constructor.assert_not_called()

    def test_startup_log_reports_actual_bound_ipv4(self) -> None:
        from web.dashboard.server import main

        server = mock.Mock()
        server.server_address = ("192.0.2.10", 8787)
        server.serve_forever.side_effect = KeyboardInterrupt
        with mock.patch("web.dashboard.server.create_server", return_value=server), mock.patch("builtins.print") as printer:
            result = main(["--fixture", "healthy", "--listen", "192.0.2.10", "--port", "8787"])

        self.assertEqual(result, 0)
        printer.assert_called_once_with(
            "WARP dashboard listening on http://192.0.2.10:8787",
            flush=True,
        )
        server.server_close.assert_called_once_with()

    def test_missing_malformed_and_symlink_snapshots_fail_without_details(self) -> None:
        from web.dashboard.server import SnapshotProvider

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            missing = directory / "missing.json"
            malformed = directory / "malformed.json"
            malformed.write_text('{"schema_version":1}', encoding="utf-8")
            symlink = directory / "symlink.json"
            symlink.symlink_to(malformed)
            for path in (missing, malformed, symlink):
                with self.subTest(path=path), running_dashboard_server(SnapshotProvider(path)) as port:
                    status, _headers, body = http_request(port, "GET", "/api/status")
                    self.assertEqual(status, 503)
                    self.assertEqual(json.loads(body), {"error": "status_unavailable"})

    def test_http_request_path_never_starts_a_subprocess(self) -> None:
        from web.dashboard.server import FixtureProvider

        with mock.patch("subprocess.Popen", side_effect=AssertionError("HTTP path executed a command")):
            with running_dashboard_server(FixtureProvider("failed")) as port:
                for path in ("/", "/api/status", "/healthz", "/assets/styles.css", "/assets/app.js"):
                    with self.subTest(path=path):
                        self.assertEqual(http_request(port, "GET", path)[0], 200)


class _ElementAudit(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.tags: list[str] = []
        self.ids: set[str] = set()
        self.external_references: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.tags.append(tag)
        values = dict(attrs)
        if values.get("id"):
            self.ids.add(values["id"] or "")
        for key in ("href", "src"):
            value = values.get(key)
            if value and not value.startswith("/"):
                self.external_references.append(value)


class FrontendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.static = ROOT / "web" / "dashboard" / "static"
        self.html = (self.static / "index.html").read_text(encoding="utf-8")
        self.css = (self.static / "styles.css").read_text(encoding="utf-8")
        self.javascript = (self.static / "app.js").read_text(encoding="utf-8")

    def test_dashboard_contains_every_required_status_field(self) -> None:
        audit = _ElementAudit()
        audit.feed(self.html)
        required_ids = {
            "overall-state",
            "hostname",
            "version",
            "uptime",
            "last-updated",
            "warp-tunnel",
            "warp-interface",
            "handshake",
            "public-ip",
            "colo",
            "location",
            "direct-path",
            "warp-path",
            "rule-100",
            "rule-110",
            "table-100",
            "main-default",
            "kill-switch",
            "ipv4-forwarding",
            "health",
            "monitor",
            "health-timer",
            "monitor-timer",
            "failed-units",
        }
        self.assertEqual(required_ids.difference(audit.ids), set())
        self.assertIn("main", audit.tags)
        self.assertIn('aria-live="polite"', self.html)

    def test_frontend_copy_describes_polling_uplink_and_read_only_scope_accurately(self) -> None:
        self.assertIn("Read-only monitoring", self.html)
        self.assertIn("UI polls every 5s", self.html)
        self.assertIn("Telemetry refreshes every ~15s", self.html)
        self.assertIn("Direct uplink path", self.html)
        self.assertNotIn("Snapshot-only monitoring", self.html)
        self.assertNotIn("Direct management path", self.html)

    def test_frontend_has_loading_unavailable_and_stale_behaviors(self) -> None:
        self.assertIn("const POLL_INTERVAL_MS = 5000", self.javascript)
        self.assertIn("const STALE_AFTER_MS = 30000", self.javascript)
        self.assertIn('fetch("/api/status"', self.javascript)
        self.assertIn("setInterval(refreshStatus, POLL_INTERVAL_MS)", self.javascript)
        self.assertIn('setUiState("loading")', self.javascript)
        self.assertIn('setUiState("unavailable")', self.javascript)
        self.assertIn('setUiState("stale")', self.javascript)
        self.assertIn("textContent", self.javascript)
        self.assertNotIn("innerHTML", self.javascript)

    def test_assets_are_local_responsive_and_contain_no_control_elements(self) -> None:
        audit = _ElementAudit()
        audit.feed(self.html)
        self.assertEqual(audit.external_references, [])
        self.assertNotIn("button", audit.tags)
        self.assertNotIn("form", audit.tags)
        self.assertIn("@media (max-width: 720px)", self.css)
        self.assertIn("grid-template-columns", self.css)
        self.assertNotIn("@import", self.css)
        for control in ("Disconnect WARP", "Connect WARP", "Repair Routing", "Restart WARP", "Run Health"):
            with self.subTest(control=control):
                self.assertNotIn(control, self.html)
                self.assertNotIn(control, self.javascript)


class ScopeGuardTests(unittest.TestCase):
    def test_server_has_no_mutation_handlers_or_command_capability(self) -> None:
        server_source = (ROOT / "web" / "dashboard" / "server.py").read_text(encoding="utf-8")
        for forbidden in (
            "def do_POST",
            "def do_PUT",
            "def do_PATCH",
            "def do_DELETE",
            "subprocess",
            "dashboard.collector",
            "warp-web-helper",
            "web/sudoers",
            "/usr/sbin/ip",
            "/usr/sbin/nft",
            "/usr/bin/wg",
            "/usr/bin/systemctl",
            "/usr/bin/curl",
            "/usr/bin/sudo",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, server_source)

    def test_dashboard_runtime_does_not_reference_gateway_runtime_state(self) -> None:
        dashboard = ROOT / "web" / "dashboard"
        combined = "\n".join(
            path.read_text(encoding="utf-8", errors="strict")
            for path in dashboard.rglob("*")
            if path.is_file() and path.suffix in {".py", ".js", ".html", ".css", ".json", ".md"}
        )
        self.assertNotIn("/run/warp-egress-gateway", combined)
        self.assertNotIn("mutation.lock", combined)
        self.assertNotIn("intentional-disconnect.json", combined)


class RepositoryIntegrationTests(unittest.TestCase):
    def test_canonical_runner_registers_dashboard_suite(self) -> None:
        runner = (ROOT / "tests" / "run-all.sh").read_text(encoding="utf-8")
        syntax = (ROOT / "tests" / "syntax.sh").read_text(encoding="utf-8")
        self.assertIn("dashboard.sh", runner)
        self.assertIn("web/dashboard/collector.py", syntax)
        self.assertIn("web/dashboard/server.py", syntax)
        self.assertIn("tests/dashboard_test.py", syntax)


if __name__ == "__main__":
    unittest.main(verbosity=2)
