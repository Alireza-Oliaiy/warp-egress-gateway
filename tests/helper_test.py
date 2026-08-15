#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from dataclasses import replace
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "web" / "helper" / "warp-web-helper.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("warp_web_helper", HELPER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load helper module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class HelperTests(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.version = self.root / "VERSION"
        self.config = self.root / "warp-gateway.env"
        self.mode = self.root / "mode"
        self.argv_log = self.root / "argv.jsonl"
        self.fake_ip = self.root / "fake_ip.py"
        self.adapter_mode = self.root / "adapter-mode"
        self.adapter_log = self.root / "adapter-log.jsonl"
        self.audit_log = self.root / "audit-log.jsonl"
        self.fake_adapter = self.root / "fake_adapter.py"
        self.fake_logger = self.root / "fake_logger.py"
        self.version.write_text("0.4.1\n", encoding="utf-8")
        self.write_config()
        self.mode.write_text("healthy", encoding="ascii")
        self.adapter_mode.write_text("healthy", encoding="ascii")
        self.fake_ip.write_text(
            """#!/usr/bin/env python3
import json, os, pathlib, sys, time
mode = pathlib.Path(os.environ['FAKE_MODE_FILE']).read_text(encoding='ascii').strip()
args = sys.argv[1:]
with pathlib.Path(os.environ['FAKE_ARGV_LOG']).open('a', encoding='utf-8') as log:
    log.write(json.dumps(args) + '\\n')
if mode == 'sleep':
    time.sleep(2)
if mode == 'huge':
    print('x' * 200000)
    raise SystemExit(0)
if mode == 'stderr':
    print('RAW_PRIVATE_SECRET', file=sys.stderr)
    raise SystemExit(7)
if args == ['-4', '-o', 'address', 'show', 'dev', 'warp0', 'scope', 'global']:
    print('7: warp0    inet 192.0.2.2/32 scope global warp0')
elif args == ['-4', 'rule', 'show']:
    if mode == 'rule_fail':
        print('RAW_RULE_FAILURE', file=sys.stderr)
        raise SystemExit(2)
    print('100: from 192.0.2.2 lookup warp_gateway')
    print('110: from all iif eth1 lookup warp_gateway')
elif args == ['-4', 'route', 'show', 'table', '100', 'default']:
    if mode != 'route_missing':
        print('default dev warp0')
elif args == ['-4', 'route', 'show', 'table', 'main', 'default']:
    print('default via 203.0.113.1 dev eth0')
else:
    print('unexpected argv', file=sys.stderr)
    raise SystemExit(64)
""",
            encoding="utf-8",
        )
        self.fake_adapter.write_text(
            """#!/usr/bin/env python3
import json, os, pathlib, sys, time
verb = sys.argv[1]
raw = sys.stdin.buffer.read()
with pathlib.Path(os.environ['FAKE_ADAPTER_LOG']).open('a', encoding='utf-8') as log:
    log.write(json.dumps({'argv': sys.argv[1:], 'stdin': raw.decode('utf-8')}) + '\\n')
mode = pathlib.Path(os.environ['FAKE_ADAPTER_MODE']).read_text().strip()
if mode == 'sleep':
    time.sleep(2)
if mode == 'malformed':
    print('{not-json')
    raise SystemExit(0)
if mode == 'stderr':
    print('PrivateKey=SEEDED_PRIVATE', file=sys.stderr)
    raise SystemExit(9)
data = {
  'routing-repair': {'state':'ok','changed':True,'before':'source_rule_missing','after':'ok','wireguard_restarted':False,'killswitch_changed':False,'main_default_changed':False},
  'health-run': {'state':'ok','reason':'none','recovery':'policy','checks':{'wireguard':'up','direct':'ok','warp':'on','routing':'ok','killswitch':'ok'}},
  'warp-disconnect': {'state':'intentionally_disconnected','already_disconnected':False,'intent':{'active':True,'since':'2026-08-15T12:00:00Z'},'routing_removed':True,'wireguard_stopped':True,'killswitch':'active','transit_behavior':'blocked_by_kill_switch','main_default_changed':False,'automatic_recovery_suppressed':True,'health_timer_active':True,'monitor_timer_active':True},
}[verb]
print(json.dumps({'protocol':1,'verb':verb,'ok':True,'code':'ok','data':data}, separators=(',', ':')))
""",
            encoding="utf-8",
        )
        self.fake_logger.write_text(
            """#!/usr/bin/env python3
import os, pathlib, sys
raw = sys.stdin.buffer.read()
with pathlib.Path(os.environ['FAKE_AUDIT_LOG']).open('ab') as log:
    log.write(raw.rstrip(b'\\n') + b'\\n')
""",
            encoding="utf-8",
        )
        os.chmod(self.version, 0o644)
        os.chmod(self.config, 0o600)
        os.chmod(self.fake_ip, 0o755)
        os.chmod(self.fake_adapter, 0o755)
        os.chmod(self.fake_logger, 0o755)
        self.helper = load_helper()
        self.runtime = self.helper.HelperRuntime(
            version_path=self.version,
            config_path=self.config,
            ip_argv=(sys.executable, str(self.fake_ip)),
            working_directory=self.root,
            expected_uid=os.getuid() if hasattr(os, "getuid") else None,
            enforce_permissions=os.name != "nt",
            child_environment={
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "TZ": "UTC",
                "FAKE_MODE_FILE": str(self.mode),
                "FAKE_ARGV_LOG": str(self.argv_log),
                "FAKE_ADAPTER_MODE": str(self.adapter_mode),
                "FAKE_ADAPTER_LOG": str(self.adapter_log),
                "FAKE_AUDIT_LOG": str(self.audit_log),
            },
            child_timeout_seconds=0.5,
            child_output_limit=65536,
        )

    def mutation_runtime(self):
        return replace(
            self.runtime,
            adapter_argv={
                verb: (sys.executable, str(self.fake_adapter), verb)
                for verb in ("routing-repair", "health-run", "warp-disconnect")
            },
            adapter_timeout_seconds={
                "routing-repair": 0.5,
                "health-run": 0.5,
                "warp-disconnect": 0.5,
            },
            audit_argv=(sys.executable, str(self.fake_logger)),
        )

    def test_installed_shebang_uses_fixed_isolated_python(self) -> None:
        first_line = HELPER_PATH.read_text(encoding="utf-8").splitlines()[0]
        self.assertEqual(first_line, "#!/usr/bin/python3 -I")

    def write_config(self, extra: str = "") -> None:
        self.config.write_text(
            """TRANSIT_IF="eth1"
MANAGE_TRANSIT_ADDRESS="false"
TRANSIT_CIDR="198.51.100.2/30"
TRUSTED_SOURCE_CIDR="198.51.100.1/32"
UPLINK_IF="eth0"
UPLINK_GATEWAY="203.0.113.1"
WARP_IF="warp0"
WARP_MTU="1280"
PERSISTENT_KEEPALIVE="25"
TCP_MSS="1240"
ROUTING_TABLE_ID="100"
ROUTING_TABLE_NAME="warp_gateway"
SOURCE_RULE_PRIORITY="100"
INGRESS_RULE_PRIORITY="110"
WGCF_VERSION="2.2.31"
ACCEPT_CLOUDFLARE_TOS="no"
EXISTING_WARP_PROFILE=""
HEALTHCHECK_URL="https://www.cloudflare.com/cdn-cgi/trace"
HEALTHCHECK_INTERVAL="60"
HEALTHCHECK_TIMEOUT="15"
AUTO_RECOVER="false"
MONITOR_INTERVAL="60"
MONITOR_HANDSHAKE_WARN_SEC="120"
MONITOR_CURL_TIMEOUT="10"
UPSTREAM_MONITOR_IP="auto"
ENABLE_IPV6_TRANSIT="false"
"""
            + extra,
            encoding="utf-8",
        )
        os.chmod(self.config, 0o600)

    @staticmethod
    def request(verb: str, parameters: dict | None = None) -> dict:
        return {
            "protocol": 1,
            "verb": verb,
            "parameters": {} if parameters is None else parameters,
            "request_id": "0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7",
            "audit_context": {
                "asserted_actor": "admin-example",
                "asserted_role": "Admin",
                "asserted_source_ip": "127.0.0.1",
            },
        }

    def call(self, request: dict | bytes) -> tuple[int, dict]:
        raw = request if isinstance(request, bytes) else json.dumps(request).encode()
        code, response = self.helper.process_request(raw, self.runtime)
        json.dumps(response, allow_nan=False)
        return code, response

    def test_version_is_fixed_and_semver_validated(self) -> None:
        code, response = self.call(self.request("version"))
        self.assertEqual(code, 0)
        self.assertEqual(response["data"], {"version": "0.4.1"})
        self.version.write_text("not-a-version\n", encoding="utf-8")
        code, response = self.call(self.request("version"))
        self.assertNotEqual(code, 0)
        self.assertEqual(response["error"]["code"], "invalid_version")

    def test_routing_status_returns_parsed_evidence_not_raw_output(self) -> None:
        code, response = self.call(self.request("routing-status"))
        self.assertEqual(code, 0)
        data = response["data"]
        self.assertEqual(data["state"], "ok")
        self.assertEqual(data["source_rule"]["actual_count"], 1)
        self.assertEqual(data["source_rule"]["state"], "ok")
        self.assertEqual(data["transit_ingress_rule"]["actual_count"], 1)
        self.assertEqual(data["warp_default"]["actual_count"], 1)
        self.assertFalse(data["main_default"]["managed_by_project"])
        encoded = json.dumps(response)
        self.assertNotIn("default via 203.0.113.1", encoded)
        self.assertNotIn("from all iif", encoded)

    def test_missing_and_query_failure_are_distinct(self) -> None:
        self.mode.write_text("route_missing", encoding="ascii")
        code, response = self.call(self.request("routing-status"))
        self.assertEqual(code, 0)
        self.assertEqual(response["data"]["warp_default"]["state"], "missing")
        self.mode.write_text("rule_fail", encoding="ascii")
        code, response = self.call(self.request("routing-status"))
        self.assertNotEqual(code, 0)
        self.assertEqual(response["error"]["code"], "query_failed")
        self.assertNotIn("RAW_RULE_FAILURE", json.dumps(response))

    def test_unknown_and_future_verbs_never_execute(self) -> None:
        code, response = self.call(self.request("systemctl"))
        self.assertEqual(code, 2)
        self.assertEqual(response["error"]["code"], "invalid_request")
        for verb in (
            "status",
            "health-read",
            "logs-read",
        ):
            before = self.argv_log.read_bytes() if self.argv_log.exists() else b""
            code, response = self.call(self.request(verb))
            self.assertEqual(code, 5)
            self.assertEqual(
                response["error"]["code"], "not_implemented_in_this_slice"
            )
            after = self.argv_log.read_bytes() if self.argv_log.exists() else b""
            self.assertEqual(after, before)

    def test_mutation_verbs_have_exact_parameter_schemas(self) -> None:
        for verb in ("routing-repair", "health-run"):
            parsed = self.helper.parse_request(
                json.dumps(self.request(verb)).encode("utf-8")
            )
            self.assertEqual(parsed.parameters, {})

            request = self.request(verb, {"unexpected": True})
            code, response = self.call(request)
            self.assertEqual(code, 2)
            self.assertEqual(response["error"]["code"], "invalid_request")

        valid = self.request(
            "warp-disconnect",
            {"confirmation": "disconnect-and-block-transit"},
        )
        parsed = self.helper.parse_request(json.dumps(valid).encode("utf-8"))
        self.assertEqual(
            parsed.parameters,
            {"confirmation": "disconnect-and-block-transit"},
        )
        self.assertEqual(parsed.asserted_actor, "admin-example")

        invalid_parameters = [
            {},
            {"confirmation": "disconnect"},
            {"confirmation": "disconnect-and-block-transit", "path": "/tmp/x"},
            {"confirmation": ["disconnect-and-block-transit"]},
        ]
        for parameters in invalid_parameters:
            with self.subTest(parameters=parameters):
                code, response = self.call(self.request("warp-disconnect", parameters))
                self.assertEqual(code, 2)
                self.assertEqual(response["error"]["code"], "invalid_request")

    def test_fixed_mutation_adapters_return_validated_structured_data(self) -> None:
        runtime = self.mutation_runtime()
        for verb in ("routing-repair", "health-run"):
            code, response = self.helper.process_request(
                json.dumps(self.request(verb)).encode(), runtime
            )
            self.assertEqual(code, 0)
            self.assertEqual(response["data"]["state"], "ok")
        code, response = self.helper.process_request(
            json.dumps(
                self.request(
                    "warp-disconnect",
                    {"confirmation": "disconnect-and-block-transit"},
                )
            ).encode(),
            runtime,
        )
        self.assertEqual(code, 0)
        self.assertEqual(response["data"]["state"], "intentionally_disconnected")
        invocations = [json.loads(line) for line in self.adapter_log.read_text().splitlines()]
        self.assertEqual([item["argv"] for item in invocations], [["routing-repair"], ["health-run"], ["warp-disconnect"]])
        self.assertEqual(json.loads(invocations[0]["stdin"]), {})
        self.assertEqual(
            json.loads(invocations[2]["stdin"]),
            {
                "request_id": "0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7",
                "asserted_actor": "admin-example",
            },
        )

    def test_asserted_metadata_cannot_change_adapter_path_or_argv(self) -> None:
        runtime = self.mutation_runtime()
        request = self.request(
            "warp-disconnect", {"confirmation": "disconnect-and-block-transit"}
        )
        request["audit_context"] = {
            "asserted_actor": "routing-repair --path=/tmp/evil",
            "asserted_role": "Viewer",
            "asserted_source_ip": "192.0.2.99",
        }
        code, _response = self.helper.process_request(json.dumps(request).encode(), runtime)
        self.assertEqual(code, 0)
        invocation = json.loads(self.adapter_log.read_text().splitlines()[-1])
        self.assertEqual(invocation["argv"], ["warp-disconnect"])

    def test_mutations_validate_fixed_config_before_adapter_dispatch(self) -> None:
        runtime = self.mutation_runtime()
        self.write_config('UNREVIEWED_KEY="value"\n')
        code, response = self.helper.process_request(
            json.dumps(self.request("routing-repair")).encode(), runtime
        )
        self.assertEqual(code, 3)
        self.assertEqual(response["error"]["code"], "unsafe_config")
        self.assertFalse(self.adapter_log.exists())
        event = json.loads(self.audit_log.read_text().splitlines()[-1])
        self.assertEqual(event["result"], "failure")
        self.assertEqual(event["reason"], "unsafe_config")

    def test_adapter_timeout_malformed_output_and_stderr_fail_closed(self) -> None:
        runtime = self.mutation_runtime()
        for mode, expected in (
            ("sleep", "child_timeout"),
            ("malformed", "invalid_adapter_response"),
            ("stderr", "adapter_failed"),
        ):
            with self.subTest(mode=mode):
                self.adapter_mode.write_text(mode, encoding="ascii")
                code, response = self.helper.process_request(
                    json.dumps(self.request("routing-repair")).encode(), runtime
                )
                self.assertNotEqual(code, 0)
                self.assertEqual(response["error"]["code"], expected)
                self.assertNotIn("SEEDED_PRIVATE", json.dumps(response))

    def test_mutation_audit_is_structured_bounded_and_secret_free(self) -> None:
        runtime = self.mutation_runtime()
        request = self.request("routing-repair")
        request["audit_context"]["asserted_actor"] = "admin PrivateKey=SEEDED_PRIVATE"
        code, _response = self.helper.process_request(json.dumps(request).encode(), runtime)
        self.assertEqual(code, 0)
        event = json.loads(self.audit_log.read_text().splitlines()[-1])
        self.assertEqual(event["request_id"], request["request_id"])
        self.assertEqual(event["verb"], "routing-repair")
        self.assertEqual(event["target_class"], "project_routing")
        self.assertEqual(event["result"], "success")
        self.assertEqual(event["effective_uid"], os.geteuid() if hasattr(os, "geteuid") else None)
        self.assertIn("duration_ms", event)
        encoded = json.dumps(event)
        self.assertNotIn("SEEDED_PRIVATE", encoded)
        self.assertNotIn("child_stdout", encoded)

    def test_protocol_rejects_malformed_and_oversized_input(self) -> None:
        invalid_requests = [
            b'{"protocol":1,"protocol":1}',
            json.dumps({**self.request("version"), "unknown": True}).encode(),
            json.dumps({**self.request("version"), "protocol": 1.0}).encode(),
            json.dumps({**self.request("version"), "parameters": []}).encode(),
            json.dumps(self.request("version")).encode() + b" trailing",
            b"\xff\xfe",
            b"{",
            b"x" * 8193,
        ]
        for raw in invalid_requests:
            with self.subTest(raw=raw[:40]):
                code, response = self.call(raw)
                self.assertEqual(code, 2)
                self.assertEqual(response["error"]["code"], "invalid_request")

    def test_audit_context_is_bounded_and_audit_only(self) -> None:
        bad_contexts = [
            {},
            {"asserted_actor": "a", "asserted_role": "Root", "asserted_source_ip": "127.0.0.1"},
            {"asserted_actor": "a", "asserted_role": ["Admin"], "asserted_source_ip": "127.0.0.1"},
            {"asserted_actor": "a\nforged", "asserted_role": "Admin", "asserted_source_ip": "127.0.0.1"},
            {"asserted_actor": "a", "asserted_role": "Admin", "asserted_source_ip": "not-an-ip"},
            {"asserted_actor": "a", "asserted_role": "Admin", "asserted_source_ip": "127.0.0.1", "extra": "x"},
        ]
        for context in bad_contexts:
            request = self.request("version")
            request["audit_context"] = context
            code, response = self.call(request)
            self.assertEqual(code, 2)
            self.assertEqual(response["error"]["code"], "invalid_request")

        request = self.request("version")
        request["audit_context"] = {
            "asserted_actor": "routing-status",
            "asserted_role": "Viewer",
            "asserted_source_ip": "192.0.2.200",
        }
        code, response = self.call(request)
        self.assertEqual(code, 0)
        self.assertEqual(response["data"], {"version": "0.4.1"})
        self.assertFalse(self.argv_log.exists())

    def test_config_is_strict_data_and_never_shell(self) -> None:
        marker = self.root / "executed"
        self.write_config(f'WARP_IF="$(touch {marker})"\n')
        code, response = self.call(self.request("routing-status"))
        self.assertNotEqual(code, 0)
        self.assertEqual(response["error"]["code"], "unsafe_config")
        self.assertFalse(marker.exists())

        self.write_config('UNREVIEWED_KEY="value"\n')
        code, response = self.call(self.request("routing-status"))
        self.assertNotEqual(code, 0)
        self.assertEqual(response["error"]["code"], "unsafe_config")

    def test_hostile_environment_and_working_directory_do_not_change_argv(self) -> None:
        old = os.environ.copy()
        hostile_cwd = self.root / "hostile"
        hostile_cwd.mkdir()
        try:
            os.environ.update(
                {
                    "PATH": str(hostile_cwd),
                    "LD_PRELOAD": "evil.so",
                    "PYTHONPATH": str(hostile_cwd),
                    "BASH_ENV": str(hostile_cwd / "bashrc"),
                    "HTTPS_PROXY": "http://127.0.0.1:9",
                    "WARP_GATEWAY_CONFIG_FILE": str(hostile_cwd / "config"),
                }
            )
            previous = Path.cwd()
            os.chdir(hostile_cwd)
            try:
                code, _response = self.call(self.request("routing-status"))
            finally:
                os.chdir(previous)
        finally:
            os.environ.clear()
            os.environ.update(old)
        self.assertEqual(code, 0)
        invocations = [json.loads(line) for line in self.argv_log.read_text().splitlines()]
        self.assertEqual(
            invocations,
            [
                ["-4", "-o", "address", "show", "dev", "warp0", "scope", "global"],
                ["-4", "rule", "show"],
                ["-4", "route", "show", "table", "100", "default"],
                ["-4", "route", "show", "table", "main", "default"],
            ],
        )

    def test_child_timeout_output_limit_and_stderr_are_bounded(self) -> None:
        cases = [
            ("sleep", "child_timeout"),
            ("huge", "child_output_limit"),
            ("stderr", "query_failed"),
        ]
        for mode, expected in cases:
            with self.subTest(mode=mode):
                self.mode.write_text(mode, encoding="ascii")
                code, response = self.call(self.request("routing-status"))
                self.assertNotEqual(code, 0)
                self.assertEqual(response["error"]["code"], expected)
                encoded = json.dumps(response)
                self.assertNotIn("RAW_PRIVATE_SECRET", encoded)
                self.assertLess(len(encoded), 4096)

    def test_secret_markers_never_appear(self) -> None:
        self.write_config(
            "# PrivateKey=SEEDED_PRIVATE_KEY account_token=SEEDED_ACCOUNT_TOKEN\n"
        )
        code, response = self.call(self.request("routing-status"))
        self.assertEqual(code, 0)
        encoded = json.dumps(response)
        self.assertNotIn("SEEDED_PRIVATE_KEY", encoded)
        self.assertNotIn("SEEDED_ACCOUNT_TOKEN", encoded)

    @unittest.skipUnless(
        hasattr(os, "geteuid") and os.geteuid() != 0,
        "requires a non-root POSIX test runner",
    )
    def test_installed_entrypoint_requires_effective_root(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(HELPER_PATH)],
            input=json.dumps(self.request("version")).encode(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=3,
        )
        self.assertEqual(completed.returncode, 8)
        response = json.loads(completed.stdout)
        self.assertEqual(response["error"]["code"], "helper_requires_root")
        self.assertEqual(completed.stderr, b"")

    @unittest.skipIf(os.name == "nt", "Unix symlink/mode semantics required")
    def test_config_symlink_and_open_mode_are_rejected(self) -> None:
        target = self.root / "target-config"
        target.write_bytes(self.config.read_bytes())
        os.chmod(target, 0o600)
        self.config.unlink()
        self.config.symlink_to(target)
        code, response = self.call(self.request("routing-status"))
        self.assertNotEqual(code, 0)
        self.assertEqual(response["error"]["code"], "unsafe_config")


if __name__ == "__main__":
    unittest.main(verbosity=2)
