#!/usr/bin/env python3
"""Slice 2 tests: synthetic routing only, with the real shared flock boundary."""
from pathlib import Path
import copy
import base64
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from admin import application, helper, protocol
from admin_console_test import running_server, request, open_session, REQUEST_ID, EXPECTED_HOST, EXPECTED_ORIGIN

BODY = b'{"confirmation":"repair-routing"}'


def repair_response(changed=False):
    evidence = protocol.unknown_evidence(version="0.5.1")
    evidence.update(wireguard="up", routing="ok", kill_switch="active")
    return dict(protocol=1, request_id=REQUEST_ID, operation="repair-routing", ok=True,
                result_code="ok", changed=changed, state="degraded", evidence=evidence)


class RepairProtocolTests(unittest.TestCase):
    def test_repair_request_is_accepted_but_no_other_new_operation(self):
        self.assertEqual(protocol.loads_request(protocol.encode_request("repair-routing", REQUEST_ID))["operation"], "repair-routing")
        for operation in ("connect", "disconnect", "shell", "route-repair", "unknown"):
            with self.subTest(operation=operation), self.assertRaises(protocol.ProtocolError):
                protocol.encode_request(operation, REQUEST_ID)

    def test_only_repair_success_can_report_changed(self):
        for changed in (False, True):
            value = repair_response(changed)
            self.assertEqual(protocol.loads_response(protocol.encode_response(value)), value)
        for operation in ("status", "health"):
            value = repair_response(True)
            value["operation"] = operation
            with self.subTest(operation=operation), self.assertRaises(protocol.ProtocolError):
                protocol.validate_response(value)

    def test_invalid_ids_codes_secrets_and_bounds_are_rejected(self):
        for rid in (REQUEST_ID.upper(), REQUEST_ID.replace("42d3", "12d3"), "bad"):
            with self.assertRaises(protocol.ProtocolError):
                protocol.encode_request("repair-routing", rid)
        for key, value in (("result_code", "unknown"), ("changed", 1)):
            data = repair_response()
            data[key] = value
            with self.assertRaises(protocol.ProtocolError):
                protocol.validate_response(data)
        data = repair_response()
        data["evidence"]["environment"] = "seed-canary"
        with self.assertRaises(protocol.ProtocolError):
            protocol.validate_response(data)
        for decoder, size in ((protocol.loads_request, 4096), (protocol.loads_response, 65536)):
            with self.assertRaises(protocol.ProtocolError):
                decoder(b" " * (size + 1))


class RepairHTTPTests(unittest.TestCase):
    def headers(self, cookie, csrf, body=BODY):
        return [("Host", EXPECTED_HOST), ("Origin", EXPECTED_ORIGIN), ("Cookie", cookie),
                ("X-CSRF-Token", csrf), ("Content-Type", "application/json"), ("Content-Length", str(len(body)))]

    def test_fixed_route_selects_operation_and_requires_confirmation(self):
        with running_server() as (server, client, _, _):
            cookie, csrf = open_session(server)
            code, _, _ = request(server, "POST", "/api/actions/repair-routing", headers=self.headers(cookie, csrf), body=BODY)
            self.assertEqual(code, 200)
            self.assertEqual([call[0] for call in client.calls], ["repair-routing"])

    def test_invalid_bodies_headers_methods_and_browser_boundaries_do_not_invoke_helper(self):
        with running_server() as (server, client, _, _):
            cookie, csrf = open_session(server)
            for body in (b'{}', b'null', b'[]', b'"repair-routing"', b'{', b'\xff', BODY + b'{}',
                         b'{"confirmation":"connect"}', b'{"confirmation":"repair-routing","x":1}',
                         b'{"confirmation":"repair-routing","confirmation":"repair-routing"}'):
                with self.subTest(body=body):
                    code, _, _ = request(server, "POST", "/api/actions/repair-routing", headers=self.headers(cookie, csrf, body), body=body)
                    self.assertEqual(code, 400)
            cases = (("Host", "127.0.0.1:8788", 403), ("Origin", None, 403), ("Origin", "http://evil.invalid", 403),
                     ("Cookie", None, 403), ("X-CSRF-Token", "x" * 43, 403), ("Content-Type", "text/plain", 415),
                     ("Content-Length", None, 400), ("Content-Length", "1025", 413))
            for key, value, expected in cases:
                headers = [(k, v) for k, v in self.headers(cookie, csrf) if k != key]
                if value is not None: headers.append((key, value))
                with self.subTest(key=key, value=value):
                    self.assertEqual(request(server, "POST", "/api/actions/repair-routing", headers=headers, body=BODY)[0], expected)
            for extra in (("Transfer-Encoding", "chunked"), ("Content-Encoding", "gzip"), ("Content-Length", str(len(BODY)))):
                self.assertEqual(request(server, "POST", "/api/actions/repair-routing", headers=self.headers(cookie, csrf) + [extra], body=BODY)[0], 400)
            for method, path, expected in (("GET", "/api/actions/repair-routing", 404),
                                           ("POST", "/api/actions/repair-routing?x=1", 400),
                                           ("POST", "/api/actions/connect", 404), ("POST", "/api/actions/disconnect", 404)):
                self.assertEqual(request(server, method, path, headers=self.headers(cookie, csrf), body=BODY)[0], expected)
            self.assertEqual(client.calls, [])

    def test_three_per_binding_six_global_before_helper_and_status_availability(self):
        with running_server() as (server, client, _, audit):
            for expected in ((200, 200, 200, 429), (200, 200, 200, 429), (429,)):
                cookie, csrf = open_session(server)
                for code in expected:
                    self.assertEqual(request(server, "POST", "/api/actions/repair-routing", headers=self.headers(cookie, csrf), body=BODY)[0], code)
            self.assertEqual(len(client.calls), 6)
            self.assertEqual(len(audit.events), 18)
            status, headers, _ = request(server, "GET", "/api/status", headers=[("Host", EXPECTED_HOST), ("Cookie", cookie)])
            self.assertEqual(status, 200)
            self.assertEqual(headers["x-warp-admin-repair-routing"], "requires-safety-check")

    def test_exact_error_mapping_and_changed_values(self):
        for code, expected in (("mutation_lock_busy", 409), ("unsafe_precondition", 409),
                               ("operation_timeout", 504), ("partial_mutation_failure", 500),
                               ("postcondition_failed", 500)):
            with self.subTest(code=code), running_server() as (server, client, _, _):
                cookie, csrf = open_session(server)
                client.invoke = lambda operation, rid: helper._failure_response(
                    dict(operation=operation, request_id=rid), code, version="0.5.1")
                status, _, raw = request(server, "POST", "/api/actions/repair-routing", headers=self.headers(cookie, csrf), body=BODY)
                self.assertEqual(status, expected)
                self.assertFalse(json.loads(raw)["changed"])
        for changed in (False, True):
            with running_server() as (server, client, _, _):
                cookie, csrf = open_session(server)
                client.invoke = lambda operation, rid: dict(repair_response(changed), request_id=rid)
                status, _, raw = request(server, "POST", "/api/actions/repair-routing", headers=self.headers(cookie, csrf), body=BODY)
                self.assertEqual(status, 200)
                self.assertIs(json.loads(raw)["changed"], changed)
        for error in ("helper_unavailable", "privilege_denied"):
            with running_server() as (server, client, _, _):
                cookie, csrf = open_session(server)
                client.invoke = mock.Mock(side_effect=application.AdminError(error))
                self.assertEqual(request(server, "POST", "/api/actions/repair-routing", headers=self.headers(cookie, csrf), body=BODY)[0], 503)

    def test_length_and_session_edge_cases_never_invoke_helper(self):
        with running_server() as (server, client, _, _):
            cookie, csrf = open_session(server)
            for length in ("-1", "0", "01", "nan", "1.0", " 1", "1"):
                headers = [(k, v) for k, v in self.headers(cookie, csrf) if k != "Content-Length"] + [("Content-Length", length)]
                self.assertEqual(request(server, "POST", "/api/actions/repair-routing", headers=headers, body=BODY)[0], 400)
            for key, value in (("Cookie", "warp_admin_session=" + "x" * 43), ("Origin", "http://127.0.0.1:8788")):
                headers = [(k, v) for k, v in self.headers(cookie, csrf) if k != key] + [(key, value)]
                self.assertEqual(request(server, "POST", "/api/actions/repair-routing", headers=headers, body=BODY)[0], 403)
            self.assertEqual(client.calls, [])

    def test_very_long_content_length_is_bounded_before_integer_conversion(self):
        with running_server() as (server, client, _, _):
            cookie, csrf = open_session(server)
            headers = [(key, value) for key, value in self.headers(cookie, csrf) if key != "Content-Length"]
            headers.append(("Content-Length", "9" * 5000))
            self.assertEqual(request(server, "POST", "/api/actions/repair-routing", headers=headers, body=BODY)[0], 413)
            self.assertEqual(client.calls, [])


CONFIG = ('UPLINK_IF="ens160"\nTRANSIT_IF="ens192"\nWARP_IF="warp0"\n'
          'ROUTING_TABLE_ID="100"\nROUTING_TABLE_NAME="warp_gateway"\n'
          'SOURCE_RULE_PRIORITY="100"\nINGRESS_RULE_PRIORITY="110"\n')
SOURCE_RULE = dict(priority=100, src="172.16.0.2", table=100)
INGRESS_RULE = dict(priority=110, src="all", iif="ens192", table=100)
WARP_ROUTE = dict(dst="default", dev="warp0", table=100, scope="link", protocol="boot", flags=[])
KILL_EXPR = [dict(match=dict(op="==", left=dict(meta=dict(key="iifname")), right="ens192")),
             dict(match=dict(op="!=", left=dict(meta=dict(key="oifname")), right="warp0")),
             dict(counter=dict(packets=2, bytes=100)), dict(drop=None)]


class KernelDouble:
    def __init__(self, root):
        self.root = root
        self.calls, self.writes = [], []
        self.link = [dict(ifname="warp0", flags=["UP"], linkinfo=dict(info_kind="wireguard"))]
        self.public_key = base64.b64encode(b"p" * 32) + b"\n"
        self.peers = base64.b64encode(b"q" * 32) + b"\n"
        self.endpoints = self.peers.strip() + b"\t192.0.2.1:2408\n"
        self.forwarding = b"1\n"
        self.addresses = {name: [dict(ifname=name, addr_info=[dict(family="inet", local=ip, prefixlen=prefix, scope="global")])]
                          for name, ip, prefix in (("warp0", "172.16.0.2", 32), ("ens160", "172.21.31.5", 24), ("ens192", "10.1.1.222", 30))}
        self.rules = [dict(priority=0, src="all", table=255), copy.deepcopy(SOURCE_RULE), copy.deepcopy(INGRESS_RULE),
                      dict(priority=200, src="192.0.2.1", table=200), dict(priority=32766, src="all", table=254)]
        self.routes = [copy.deepcopy(WARP_ROUTE), dict(dst="default", gateway="172.21.31.1", dev="ens160", table=254),
                       dict(dst="192.0.2.0/24", dev="ens192", table=200), dict(dst="198.51.100.0/24", dev="warp0", table=100)]
        self.nft = dict(nftables=[dict(table=dict(family="inet", name="warp_gateway", handle=1)),
                                 dict(chain=dict(family="inet", table="warp_gateway", name="forward", type="filter", hook="forward", prio=0, policy="accept", handle=2)),
                                 dict(rule=dict(family="inet", table="warp_gateway", chain="forward", handle=3, comment="WARP_KILL_SWITCH", expr=copy.deepcopy(KILL_EXPR)))])
        self.query_failure = None
        self.raw_override = None
        self.fail_write = None
        self.timeout_write = False
        self.ignore_write = False
        self.after_write = lambda: None

    def __call__(self, argv, **_limits):
        # Every observation AND write must be inside the same real exclusive lock.
        with (self.root / "run/warp-egress-gateway/admin-mutation.lock").open("rb") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("routing command ran outside exclusive shared-project lock")
        self.calls.append(tuple(argv))
        if self.query_failure and self.query_failure in argv:
            return helper.CommandResult(1, b"", b"seed-private-canary")
        if self.raw_override is not None:
            return helper.CommandResult(0, self.raw_override, b"")
        args = tuple(argv[1:])
        if argv[0] == "/usr/bin/wg" and args[:2] == ("show", self.link[0]["ifname"]):
            return helper.CommandResult(0, {"public-key": self.public_key, "peers": self.peers, "endpoints": self.endpoints}[args[2]], b"")
        if argv == ("/usr/sbin/sysctl", "-n", "net.ipv4.ip_forward"):
            return helper.CommandResult(0, self.forwarding, b"")
        if argv[0] == "/usr/sbin/nft" and args == ("-j", "list", "table", "inet", "warp_gateway"):
            result = self.nft
        elif argv[0] == "/usr/sbin/ip":
            if args == ("-j", "-d", "link", "show", "dev", "warp0"): result = self.link
            elif args[:5] == ("-j", "-4", "address", "show", "dev"): result = self.addresses[args[5]]
            elif args == ("-j", "-N", "-4", "rule", "show"): result = self.rules
            elif args == ("-j", "-N", "-4", "route", "show", "table", "all"): result = self.routes
            elif args == ("-j", "-4", "route", "show", "table", "main", "default"):
                result = [r for r in self.routes if r.get("table") == 254 and r.get("dst") == "default"]
            elif args in (("-4", "rule", "add", "pref", "100", "from", "172.16.0.2/32", "lookup", "100"),
                          ("-4", "rule", "add", "pref", "110", "iif", "ens192", "lookup", "100"),
                          ("-4", "route", "add", "default", "dev", "warp0", "table", "100")):
                self.writes.append(args)
                if self.timeout_write: raise helper.HelperRuntimeError("operation_timeout")
                if self.fail_write == len(self.writes): return helper.CommandResult(1, b"", b"seed-private-canary")
                if not self.ignore_write:
                    if args[1] == "route": self.routes.append(copy.deepcopy(WARP_ROUTE))
                    else: self.rules.append(copy.deepcopy(SOURCE_RULE if args[4] == "100" else INGRESS_RULE))
                self.after_write()
                return helper.CommandResult(0, b"", b"")
            else: raise AssertionError(f"unapproved routing command: {args}")
        else: raise AssertionError("unapproved privileged executable")
        return helper.CommandResult(0, json.dumps(result).encode(), b"")


class RepairSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.uid, self.gid = os.getuid(), os.getgid()
        for relative, content in (("etc/warp-egress-gateway/warp-gateway.env", CONFIG),
                                  ("etc/warp-egress-dashboard/dashboard.env", "DASHBOARD_LISTEN=172.21.31.5\nDASHBOARD_PORT=8787\n"),
                                  ("etc/warp-egress-admin-console/network.json", '{"address":"172.21.31.5","uplink_if":"ens160","transit_if":"ens192"}')):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            path.chmod(0o600)
        self.lock = self.root / "run/warp-egress-gateway/admin-mutation.lock"
        self.lock.parent.mkdir(parents=True, mode=0o700)
        self.lock.touch(mode=0o600)
        self.kernel = KernelDouble(self.root)

    def execute(self, **kwargs):
        repair = helper.RoutingRepair(root=self.root, required_uid=self.uid, required_gid=self.gid,
                                      command=self.kernel, lock_timeout=0.05)
        req = dict(protocol=1, operation="repair-routing", request_id=REQUEST_ID)
        return repair.run(req, version="0.5.1", **kwargs)

    def test_healthy_and_each_missing_combination_only_restore_missing_objects(self):
        for missing in ((), (100,), (110,), ("default",), (100, 110), (100, "default"), (110, "default"), (100, 110, "default")):
            with self.subTest(missing=missing):
                self.kernel = KernelDouble(self.root)
                self.kernel.rules = [r for r in self.kernel.rules if r["priority"] not in missing]
                if "default" in missing: self.kernel.routes.remove(WARP_ROUTE)
                result = self.execute()
                self.assertEqual(result["result_code"], "ok")
                self.assertEqual(result["changed"], bool(missing))
                self.assertEqual(len(self.kernel.writes), len(missing))
                before = len(self.kernel.writes)
                self.assertFalse(self.execute()["changed"])
                self.assertEqual(len(self.kernel.writes), before)

    def test_wrong_or_ambiguous_routes_and_rules_never_mutate(self):
        cases = [lambda k, key=key, value=value: k.routes[0].update({key: value}) for key, value in (
            ("gateway", "192.0.2.1"), ("via", {}), ("nexthops", []), ("nhid", 1), ("dev", "ens160"), ("type", "blackhole"))]
        cases += [lambda k: k.routes.append(copy.deepcopy(WARP_ROUTE)),
                  lambda k: k.rules[1].update(table=254), lambda k: k.rules[1].update(priority=99),
                  lambda k: k.rules[2].update(iif="ens160"), lambda k: k.rules.append(copy.deepcopy(SOURCE_RULE))]
        for change in cases:
            self.kernel = KernelDouble(self.root)
            change(self.kernel)
            self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
            self.assertEqual(self.kernel.writes, [])

    def test_bad_warp_safety_and_main_query_never_mutate(self):
        cases = [lambda k: k.link.clear(), lambda k: k.link[0]["linkinfo"].update(info_kind="dummy"),
                 lambda k: k.addresses["warp0"][0]["addr_info"].clear(),
                 lambda k: k.addresses["warp0"][0]["addr_info"].append(copy.deepcopy(k.addresses["warp0"][0]["addr_info"][0])),
                 lambda k: k.nft.update(nftables=[]), lambda k: k.nft["nftables"][2]["rule"]["expr"].pop(),
                 lambda k: setattr(k, "query_failure", "main")]
        for change in cases:
            self.kernel = KernelDouble(self.root)
            change(self.kernel)
            self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
            self.assertEqual(self.kernel.writes, [])

    def test_unsafe_config_lock_and_intent_fail_closed(self):
        config = self.root / "etc/warp-egress-gateway/warp-gateway.env"
        original = config.read_text()
        for bad in (original + 'WARP_IF="warp0"\n', original + 'evil shell\n', original.replace('"100"', '"200"'), original.replace('"warp0"', '"$(id)"')):
            config.write_text(bad)
            self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
        config.write_text(original)
        config.chmod(0o666)
        self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
        config.chmod(0o600)
        config.unlink()
        config.symlink_to(self.root / "missing")
        self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
        config.unlink()
        config.write_text(original)
        for path in (self.lock.parent / "intentional-disconnect.json",):
            path.touch()
            self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
            path.unlink()
        self.lock.chmod(0o644)
        self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
        self.lock.unlink()
        self.lock.symlink_to(self.root / "missing")
        self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
        self.assertEqual(self.kernel.writes, [])

    def test_postconditions_detect_missing_write_and_unrelated_state_changes(self):
        changes = [lambda k: k.routes[1].update(gateway="192.0.2.1"), lambda k: k.routes[2].update(dev="ens160"),
                   lambda k: k.rules[0].update(table=254), lambda k: k.addresses["ens160"][0]["addr_info"][0].update(local="172.21.31.6"),
                   lambda k: k.nft["nftables"][2]["rule"].update(expr=[]),
                   lambda k: (self.lock.parent / "intentional-disconnect.json").touch()]
        for change in changes:
            self.kernel = KernelDouble(self.root)
            self.kernel.rules.remove(SOURCE_RULE)
            self.kernel.after_write = lambda: change(self.kernel)
            self.assertEqual(self.execute()["result_code"], "postcondition_failed")
            (self.lock.parent / "intentional-disconnect.json").unlink(missing_ok=True)
        self.kernel = KernelDouble(self.root)
        self.kernel.rules.remove(SOURCE_RULE)
        self.kernel.ignore_write = True
        self.assertEqual(self.execute()["result_code"], "postcondition_failed")

    def test_partial_failure_timeout_and_no_secret_response(self):
        for timeout in (False, True):
            self.kernel = KernelDouble(self.root)
            self.kernel.rules = [r for r in self.kernel.rules if r["priority"] not in (100, 110)]
            self.kernel.fail_write = 2
            self.kernel.timeout_write = timeout
            result = self.execute()
            self.assertEqual(result["result_code"], "operation_timeout" if timeout else "partial_mutation_failure")
            self.assertFalse(result["ok"])
            self.assertNotIn("seed-private-canary", json.dumps(result))

    def test_json_duplicates_and_malformed_observations_fail_closed(self):
        for raw in (b"{", b"null", b"[]", b'[{"ifname":"warp0","ifname":"warp0"}]'):
            self.kernel.raw_override = raw
            self.assertEqual(self.execute()["result_code"], "unsafe_precondition")

    def test_identity_peer_endpoint_forwarding_changes_fail_postcondition(self):
        for field, value in (("public_key", base64.b64encode(b"r" * 32) + b"\n"),
                             ("peers", base64.b64encode(b"s" * 32) + b"\n"),
                             ("endpoints", self.kernel.peers.strip() + b"\t192.0.2.2:2408\n"),
                             ("forwarding", b"0\n")):
            with self.subTest(field=field):
                self.kernel = KernelDouble(self.root)
                self.kernel.rules.remove(SOURCE_RULE)
                self.kernel.after_write = lambda: setattr(self.kernel, field, value)
                self.assertEqual(self.execute()["result_code"], "postcondition_failed")

    def test_lock_busy_no_commands_and_completion_audit_inside_lock(self):
        with self.lock.open("rb") as stream:
            fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)
            self.assertEqual(self.execute()["result_code"], "mutation_lock_busy")
            self.assertEqual(self.kernel.calls, [])
        def completed(response):
            self.assertEqual(response["result_code"], "ok")
            with self.lock.open("rb") as stream:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.execute(completed=completed)
        self.assertEqual(self.lock.stat().st_mode & 0o777, 0o600)

    def test_helper_dispatch_selects_repair_not_readonly_evaluator(self):
        repair = mock.Mock()
        repair.run.return_value = repair_response(True)
        runner = mock.Mock()
        with mock.patch.object(helper, "RoutingRepair", return_value=repair):
            response = helper.handle_request(protocol.encode_request("repair-routing", REQUEST_ID), runner=runner)
        self.assertTrue(response["changed"])
        repair.run.assert_called_once()
        runner.run.assert_not_called()

    def test_partial_changed_true_is_rejected_and_audit_success_has_real_changed(self):
        for code in ("unsafe_precondition", "partial_mutation_failure", "postcondition_failed", "operation_timeout"):
            value = helper._failure_response(dict(operation="repair-routing", request_id=REQUEST_ID), code, version="0.5.1")
            self.assertEqual(value["result_code"], code)
            value["changed"] = True
            with self.assertRaises(protocol.ProtocolError): protocol.validate_response(value)
        for audit in (helper.JournalAudit(), application.JournalAudit()):
            with mock.patch.object(subprocess, "run") as run:
                audit.emit(request_id=REQUEST_ID, action="repair-routing", state="completed", result_code="ok", duration_ms=1, changed=True)
            run.assert_called_once()
            self.assertIn("changed=true", run.call_args.args[0][-1])

    def test_hq_and_custom_role_table_profiles(self):
        for uplink, transit, warp, table in (("ens33", "ens35", "warp0", 100), ("uplink.10", "transit_20", "wg-egress", 4242)):
            with self.subTest(table=table):
                self.kernel = KernelDouble(self.root)
                mapping = {"ens160": uplink, "ens192": transit, "warp0": warp}
                config = CONFIG
                for old, new in mapping.items(): config = config.replace(old, new)
                config = config.replace('ROUTING_TABLE_ID="100"', f'ROUTING_TABLE_ID="{table}"')
                (self.root / "etc/warp-egress-gateway/warp-gateway.env").write_text(config)
                (self.root / "etc/warp-egress-admin-console/network.json").write_text(json.dumps(
                    dict(address="172.21.31.5", uplink_if=uplink, transit_if=transit)))
                original = self.kernel
                # Translate only the fixture's synthetic kernel vocabulary. The
                # production transaction sees actual site/custom identifiers.
                def site_command(argv, **limits):
                    translated = tuple(next((old for old, new in mapping.items() if arg == new), arg) for arg in argv)
                    if "add" in translated:
                        self.assertEqual(translated[-1], str(table))
                        translated = (*translated[:-1], "100")
                    result = original(translated, **limits)
                    if not result.stdout or argv[0] in ("/usr/bin/wg", "/usr/sbin/sysctl"):
                        return result
                    def remap(value):
                        if type(value) is list: return [remap(item) for item in value]
                        if type(value) is dict:
                            return {key: table if key == "table" and item == 100 else remap(item) for key, item in value.items()}
                        return mapping.get(value, value) if type(value) is str else value
                    return helper.CommandResult(result.returncode, json.dumps(remap(json.loads(result.stdout))).encode(), result.stderr)
                original.rules.remove(SOURCE_RULE)
                original.routes.remove(WARP_ROUTE)
                repair = helper.RoutingRepair(root=self.root, required_uid=self.uid, required_gid=self.gid, command=site_command)
                result = repair.run(dict(operation="repair-routing", request_id=REQUEST_ID))
                self.assertEqual(result["result_code"], "ok")
                self.assertTrue(result["changed"])

    def test_additional_unsafe_metadata_rules_and_defaults(self):
        for change in (lambda k: k.rules.append(copy.deepcopy(INGRESS_RULE)),
                       lambda k: k.rules[1].update(src="172.16.0.3"),
                       lambda k: k.rules[2].update(table=200),
                       lambda k: k.routes[0].update(table=200),
                       lambda k: k.routes[0].update(table="invalid"),
                       lambda k: k.routes[1].update(nexthops=[]),
                       lambda k: setattr(k, "public_key", b"(none)\n"),
                       lambda k: k.link[0].update(flags=[])):
            self.kernel = KernelDouble(self.root)
            change(self.kernel)
            self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
            self.assertEqual(self.kernel.writes, [])
        for kind in ("missing", "directory", "fifo", "owner", "group", "oversize"):
            path = self.root / "etc/warp-egress-gateway/warp-gateway.env"
            path.unlink()
            if kind == "directory": path.mkdir()
            elif kind == "fifo": os.mkfifo(path)
            elif kind != "missing": path.write_text(CONFIG if kind != "oversize" else "#" * 65537)
            if kind in {"owner", "group"}:
                repair = helper.RoutingRepair(root=self.root, required_uid=self.uid + (kind == "owner"),
                                              required_gid=self.gid + (kind == "group"), command=self.kernel)
                result = repair.run(dict(operation="repair-routing", request_id=REQUEST_ID))
            else: result = self.execute()
            self.assertEqual(result["result_code"], "unsafe_precondition")
            if kind == "directory": path.rmdir()
            elif path.exists(): path.unlink()
            path.write_text(CONFIG)
            path.chmod(0o600)

    def test_boundaries_and_ignored_configuration_do_not_add_authority(self):
        config = self.root / "etc/warp-egress-gateway/warp-gateway.env"
        config.write_text(CONFIG + 'UNRELATED="$(false)"\nUNRELATED="ignored"\n')
        self.assertEqual(self.execute()["result_code"], "ok")
        for table in ("0", "253", "254", "255", "4294967296", "0100", "+100", "bad"):
            config.write_text(CONFIG.replace('ROUTING_TABLE_ID="100"', f'ROUTING_TABLE_ID="{table}"'))
            self.assertEqual(self.execute()["result_code"], "unsafe_precondition")
        for key in ("path", "interface", "table", "command", "unit", "config", "environment"):
            data = dict(protocol=1, operation="repair-routing", request_id=REQUEST_ID)
            data[key] = "forbidden"
            with self.assertRaises(protocol.ProtocolError): protocol.loads_request(json.dumps(data).encode())
        self.assertEqual(self.kernel.writes, [])


class RepairTransactionTests(unittest.TestCase):
    def test_transaction_implementation_exists(self):
        self.assertTrue(hasattr(helper, "RoutingRepair"), "exclusive fixed Repair Routing transaction is missing")


if __name__ == "__main__":
    unittest.main()
