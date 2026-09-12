#!/usr/bin/env python3
"""Real installed isolated evaluator/helper/HTTP intent observations, fixtures only."""
import fcntl
import json
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from admin_foundation_test import AdminFoundationTests, PROBES
from admin_console_test import open_session, request, running_server
from intent_state_test import intent, MAIN, REQUEST


class AdminIntentTests(AdminFoundationTests):
    # Inherit fixtures, not the parent test methods (covered by the original suite).
    def setUp(self):
        super().setUp()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        parent = self.rootfs / "run/warp-egress-gateway"
        lock = parent / "admin-mutation.lock"
        lock.touch(mode=0o600)
        fd = os.open(lock, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            intent.IntentStore(root=self.rootfs, uid=os.getuid(), gid=os.getgid()).create(fd, REQUEST, MAIN)
        finally:
            os.close(fd)
        self.intent = parent / "intentional-disconnect.json"
        # Exact read-only structured observations for stopped WARP/routing.
        extra = '''
if name == "ip" and "-j" in args:
    if args == ["-j", "link", "show"]:
        print(json.dumps([{"ifname":"lo"},{"ifname":"ens160"},{"ifname":"ens192"}]))
    elif args == ["-j", "-N", "-4", "rule", "show"]:
        print(json.dumps([{"priority":0,"table":255},{"priority":32766,"table":254}]))
    elif args == ["-j", "-N", "-4", "route", "show", "table", "all"]:
        print("[]")
    elif args == ["-j", "-4", "route", "show", "table", "main", "default"]:
        print(json.dumps([{"dst":"default","dev":"ens160","gateway":state.get("gateway","192.0.2.1"),"protocol":"static"}]))
    else: refused()
    raise SystemExit(0)
if name == "systemctl" and args[:3] == ["show", "--property=ActiveState", "--value"]:
    if args[3:] not in (["wg-quick@warp0.service"], ["warp-gateway.service"]): refused()
    print("inactive"); raise SystemExit(0)
if name == "nft" and args == ["-j", "list", "table", "inet", "warp_gateway"]:
    print(json.dumps({"nftables":[
      {"chain":{"family":"inet","table":"warp_gateway","name":"forward","type":"filter","hook":"forward","prio":0}},
      {"rule":{"family":"inet","table":"warp_gateway","chain":"forward","comment":"WARP_KILL_SWITCH","expr":[
         {"match":{"op":"==","left":{"meta":{"key":"iifname"}},"right":"ens192"}},
         {"match":{"op":"!=","left":{"meta":{"key":"oifname"}},"right":"warp0"}}, {"drop":None}]}}]}))
    raise SystemExit(0)
'''
        (self.probes / "probe").write_text(PROBES.replace('if name == "ip":', extra + '\nif name == "ip":'))
        self.intent_before = self.intent.read_bytes()

    def prepare_execution_copy(self):
        execution = super().prepare_execution_copy()
        path = execution / "intent-state.py"
        text = path.read_text().replace('store, fd = IntentStore(), int(sys.argv[2])',
                f'store, fd = IntentStore(root=Path({str(self.rootfs)!r}), uid={os.getuid()}, gid={os.getgid()}), int(sys.argv[2])')
        for original, name in (("/usr/sbin/ip", "ip"), ("/usr/sbin/nft", "nft"), ("/usr/bin/systemctl", "systemctl")):
            text = text.replace(original, str(self.probes / name))
        path.write_text(text)
        return execution

    def test_installed_intent_health_status_are_readonly(self):
        module = self.installed_helper()
        for op in ("status", "health"):
            result = self.observe(module, op)
            self.assertEqual(result["state"], "intentionally_disconnected", result)
            self.assertTrue(result["ok"])
            self.assertFalse(result["changed"])
            self.assertEqual(result["evidence"]["routing"], "absent")
        self.assertEqual(self.intent.read_bytes(), self.intent_before)
        self.assert_core_unchanged()
        self.assertFalse((self.probes / "mutations.log").exists())

    def test_intent_corruption_and_main_change_fail_without_mutation(self):
        module = self.installed_helper()
        (self.probes / "state.json").write_text('{"gateway":"192.0.2.99"}')
        self.assertEqual(self.observe(module)["state"], "failed")
        self.intent.write_text('{"schema":1,"unexpected":"SYNTHETIC_SECRET_CANARY"}')
        result = self.observe(module, "health")
        self.assertEqual(result["state"], "failed")
        self.assertNotIn("SYNTHETIC_SECRET_CANARY", json.dumps(result))
        self.assertFalse(result["changed"])
        self.assertFalse((self.probes / "mutations.log").exists())
        self.assert_core_unchanged()

    def test_intent_http_readonly_and_no_lifecycle_routes(self):
        case, module = self, self.installed_helper()
        class Bridge:
            def invoke(self, operation, request_id):
                result = case.observe(module, operation)
                result["request_id"] = request_id
                return result
        with running_server(helper=Bridge(), management_address="192.0.2.10") as (server, _, _, _):
            cookie, csrf = open_session(server)
            status, _, body = request(server, "GET", "/api/status", headers=[("Host", server.expected_host), ("Cookie", cookie)])
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["state"], "intentionally_disconnected")
            headers = [("Host", server.expected_host), ("Origin", server.expected_origin), ("Cookie", cookie),
                       ("X-CSRF-Token", csrf), ("Content-Type", "application/json"), ("Content-Length", "2")]
            status, _, body = request(server, "POST", "/api/actions/health", headers=headers, body=b"{}")
            self.assertEqual(status, 200)
            self.assertFalse(json.loads(body)["changed"])
            for action in ("connect", "disconnect"):
                self.assertEqual(request(server, "POST", "/api/actions/" + action, headers=headers, body=b"{}")[0], 404)


if __name__ == "__main__":
    names = [name for name in AdminIntentTests.__dict__ if name.startswith("test_")]
    suite = unittest.TestSuite(AdminIntentTests(name) for name in names)
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
