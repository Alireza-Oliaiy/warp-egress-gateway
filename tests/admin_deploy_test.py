#!/usr/bin/env python3
"""Static deployment boundary tests for the Slice 1B Admin Console."""

from __future__ import annotations

from pathlib import Path
import configparser
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "admin" / "deploy"


# Stateful systemd/ss double: start is deliberately a no-op for an active
# process. Only restart replaces its PID and reloads installed app/config.
# No real systemctl, sockets, service accounts or production paths are used.
SERVICE_DOUBLE = r'''
import json, pathlib, sys, time
root = pathlib.Path(__file__).parent
state_path = root / "service.json"
state = json.loads(state_path.read_text())
kind, *args = sys.argv[1:]
state["actions"].append([kind, *args])
def finish(code=0):
    state_path.write_text(json.dumps(state))
    raise SystemExit(code)
if kind == "systemctl":
    command = args[0]
    if command != "daemon-reload" and args[-1] != "warp-admin.service":
        finish(98)
    if command == "daemon-reload":
        state["reloaded"] = True
    elif command == "enable":
        state["enabled"] = True
    if command in ("start", "restart") or (command == "enable" and "--now" in args):
        if command == "restart" and state["scenario"] == "restart-timeout":
            state_path.write_text(json.dumps(state))
            time.sleep(5)
        if command == "restart" and state["scenario"] == "restart-failure":
            finish(1)
        if command == "restart" or state["active"] != "active":
            assert state["reloaded"] and state["enabled"]
            installed = root / "rootfs/opt/warp-egress-admin-console/app/admin"
            expected = root / "payload/admin"
            for path in expected.rglob("*"):
                if path.is_file() and path.parent.name != "deploy" and path.suffix in (".py", ".js", ".css", ".html") and path.name != "helper.py":
                    relative = path.relative_to(expected)
                    assert (installed / relative).read_bytes() == path.read_bytes()
            config = json.loads((root / "rootfs/etc/warp-egress-admin-console/network.json").read_text())
            assert config["address"] == "172.21.31.5"
            state.update(active="active", sub="running", pid=4243,
                         started=time.monotonic_ns() // 1000, restarts=0,
                         listeners=[config["address"] + ":8788"], replacements=state["replacements"] + 1)
            scenario = state["scenario"]
            bad = {"loopback": ["127.0.0.1:8788"], "wildcard": ["0.0.0.0:8788"],
                   "transit": ["10.1.1.222:8788"], "ipv6": ["[::1]:8788"],
                   "wrong-management": ["172.20.31.5:8788"],
                   "multiple": ["172.21.31.5:8788", "127.0.0.1:8788"], "bind-failure": []}
            state["listeners"] = bad.get(scenario, state["listeners"])
            if scenario == "stale-pid": state["started"] = 1
            if scenario == "missing-pid": state["pid"] = 0
            if scenario == "not-running": state["sub"] = "start"
            if scenario == "crash-loop": state["restarts"] = 3
    if command == "show":
        state["shows"] += 1
        if state["scenario"] == "replacement-during-readiness" and state["shows"] >= 2:
            state["pid"] += 1
        for key, value in (("ActiveState", state["active"]), ("SubState", state["sub"]),
                           ("MainPID", state["pid"]), ("ExecMainStartTimestampMonotonic", state["started"]),
                           ("NRestarts", state["restarts"])):
            print(f"{key}={value}")
    elif command == "is-active":
        if "--quiet" not in args: print(state["active"])
        finish(0 if state["active"] == "active" else 3)
    elif command == "is-enabled":
        finish(0 if state["enabled"] else 1)
    elif command not in ("daemon-reload", "enable", "start", "restart"):
        finish(99)
elif kind == "ss":
    for listener in state["listeners"]:
        print(f"LISTEN 0 128 {listener} 0.0.0.0:*")
else:
    finish(99)
finish()
'''


class AdminInstallerMigrationTests(unittest.TestCase):
    """Run the complete installer with isolated files and stateful service I/O."""

    def run_migration(self, initial="active", scenario="healthy"):
        with tempfile.TemporaryDirectory(prefix="warp-admin-migration-") as temporary:
            area = Path(temporary)
            payload = area / "payload"
            shutil.copytree(ROOT / "admin", payload / "admin")
            # Windows checkout modes are not meaningful on Linux-mounted paths.
            for path in payload.rglob("*"):
                path.chmod(0o755 if path.is_dir() else 0o644)
            rootfs = area / "rootfs"
            rootfs.mkdir()
            subprocess.run(["python3", str(ROOT / "tests/admin_network_fixture.py"), str(rootfs)], check=True)
            dashboard = rootfs / "etc/warp-egress-dashboard/dashboard.env"
            dashboard.write_text(dashboard.read_text().replace("192.0.2.10", "172.21.31.5"))
            addresses = rootfs / "network-addresses.json"
            addresses.write_text(addresses.read_text().replace("192.0.2.10", "172.21.31.5"))
            state_path = area / "service.json"
            state_path.write_text(json.dumps(dict(
                active="active" if initial == "active" else "inactive", sub="running",
                pid=4242, started=1, restarts=0, enabled=initial != "fresh", reloaded=False,
                listeners=["127.0.0.1:8788"] if initial == "active" else [],
                replacements=0, shows=0, scenario=scenario, actions=[])))
            double = area / "service_double.py"
            double.write_text(SERVICE_DOUBLE)
            installer = payload / "admin/deploy/install.sh"
            source = installer.read_text()
            # Use the production service/readiness branch after the complete
            # isolated installation. Never substitute its activation decisions.
            anchor = "\nif [[ ${TEST_MODE} == true ]]; then\n  printf 'systemctl daemon-reload"
            self.assertEqual(source.count(anchor), 1)
            source = source.replace(anchor, "\nTEST_MODE=false" + anchor)
            for command in ("systemctl", "ss"):
                source = source.replace(f"/usr/bin/{command}", f"/usr/bin/python3 {shlex.quote(str(double))} {command}")
            if scenario == "restart-timeout":
                # Exercise the real timeout wrapper with a shorter fixture-only
                # deadline; the deployed restart bound stays fixed at 30s.
                self.assertIn("/usr/bin/timeout --kill-after=5s 30s", source)
                source = source.replace("/usr/bin/timeout --kill-after=5s 30s", "/usr/bin/timeout --kill-after=1s 1s")
            # HTTP is covered by the real application suite, not this service double.
            source = source.replace("if [[ ${TEST_MODE} == true ]]; then\n  printf 'http GET", "if true; then\n  printf 'http GET")
            installer.write_text(source)
            result = subprocess.run(["bash", str(installer)], capture_output=True, text=True, timeout=25,
                                    env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "WARP_ADMIN_TEST_MODE": "1",
                                         "WARP_ADMIN_TEST_ROOT": str(rootfs), "WARP_ADMIN_TEST_ACCOUNT": "safe"})
            state = json.loads(state_path.read_text())
            commands = [a for a in state["actions"] if a[0] == "systemctl"]
            self.assertTrue(all(a[-1] == "warp-admin.service" for a in commands if a[1] != "daemon-reload"))
            self.assertLessEqual(sum(a[1] == "restart" for a in commands), 1, "no restart retry loop")
            return result, state

    def test_active_old_loopback_is_replaced_after_installing_new_configuration(self):
        result, state = self.run_migration()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state["pid"], 4243)
        self.assertEqual(state["listeners"], ["172.21.31.5:8788"])
        self.assertEqual(state["replacements"], 1)
        self.assertGreaterEqual(state["shows"], 3)
        commands = [a for a in state["actions"] if a[0] == "systemctl"]
        self.assertEqual([a for a in commands if a[1] == "restart"], [["systemctl", "restart", "warp-admin.service"]])
        self.assertTrue(all(a[-1] == "warp-admin.service" for a in commands if a[1] != "daemon-reload"))

    def test_fresh_and_enabled_inactive_services_start_new_configuration(self):
        for initial in ("fresh", "inactive"):
            with self.subTest(initial=initial):
                result, state = self.run_migration(initial=initial)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(state["enabled"])
                self.assertEqual(state["replacements"], 1)
                self.assertEqual(state["listeners"], ["172.21.31.5:8788"])

    def test_restart_failure_stops_without_listener_or_http_success(self):
        for scenario in ("restart-failure", "restart-timeout"):
            with self.subTest(scenario=scenario):
                result, state = self.run_migration(scenario=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GATE_SERVICE", result.stderr)
                self.assertEqual(state["pid"], 4242)
                self.assertFalse(any(a[0] == "ss" for a in state["actions"]))
                self.assertNotIn("ADMIN_INSTALL_OK", result.stdout)

    def test_unsafe_and_absent_listeners_still_fail_closed(self):
        for scenario in ("loopback", "wildcard", "transit", "ipv6", "wrong-management", "multiple", "bind-failure"):
            with self.subTest(scenario=scenario):
                result, state = self.run_migration(scenario=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state["replacements"], 1)
                self.assertIn("GATE_LISTENER", result.stderr)
                self.assertNotIn("ADMIN_INSTALL_OK", result.stdout)

    def test_stale_missing_unstable_or_crashing_process_fails_closed(self):
        for scenario in ("stale-pid", "missing-pid", "not-running", "crash-loop", "replacement-during-readiness"):
            with self.subTest(scenario=scenario):
                result, _ = self.run_migration(scenario=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GATE_SERVICE", result.stderr)
                self.assertNotIn("ADMIN_INSTALL_OK", result.stdout)


class AdminDeploymentAssetTests(unittest.TestCase):
    def test_required_assets_exist_with_expected_repository_modes(self) -> None:
        required = (
            ROOT / "admin" / "application.py",
            ROOT / "admin" / "protocol.py",
            ROOT / "admin" / "helper.py",
            ROOT / "admin" / "static" / "index.html",
            ROOT / "admin" / "static" / "admin.css",
            ROOT / "admin" / "static" / "admin.js",
            DEPLOY / "install.sh",
            DEPLOY / "uninstall.sh",
            DEPLOY / "systemd" / "warp-admin.service",
            DEPLOY / "sudoers" / "warp-egress-gateway-admin",
        )
        for path in required:
            with self.subTest(path=path):
                self.assertTrue(path.is_file() and not path.is_symlink())

    def test_systemd_unit_is_unprivileged_fixed_and_hardened(self) -> None:
        unit = (DEPLOY / "systemd" / "warp-admin.service").read_text(encoding="utf-8")
        for exact in (
            "User=warp-admin",
            "Group=warp-admin",
            "ExecStart=/usr/bin/python3 -I /opt/warp-egress-admin-console/app/admin/application.py",
            "RuntimeDirectory=warp-egress-admin-console",
            "RuntimeDirectoryMode=0700",
            "ProtectSystem=strict",
            "ReadWritePaths=/run/warp-egress-gateway",
            "ProtectHome=true",
            "ProtectKernelTunables=true",
            "ProtectKernelModules=true",
            "ProtectControlGroups=true",
            "RestrictSUIDSGID=true",
            "LockPersonality=true",
            "RestrictRealtime=true",
            "MemoryDenyWriteExecute=true",
            "AmbientCapabilities=",
            "RestrictAddressFamilies=AF_INET AF_UNIX AF_NETLINK",
        ):
            self.assertIn(exact, unit)
        self.assertNotIn("User=root", unit)
        self.assertNotIn("NoNewPrivileges=true", unit)
        self.assertNotIn("0.0.0.0", unit)
        self.assertNotIn("172.21.31.5", unit)
        self.assertNotIn("warp-dashboard", unit)
        self.assertIn("After=network.target warp-gateway-firewall.service", unit)

    def test_capability_policy_drops_inheritable_setup_caps_and_preserves_sudo(self) -> None:
        # Parse active directives, not comments/substrings. Duplicate directives
        # are rejected so a later reset cannot silently undo the restriction.
        unit = configparser.ConfigParser(interpolation=None, strict=True)
        unit.optionxform = str
        unit.read(DEPLOY / "systemd" / "warp-admin.service", encoding="utf-8")
        service = unit["Service"]
        policy = service.get("CapabilityBoundingSet", "")
        self.assertTrue(policy.startswith("~"), "an explicit subtractive bounding policy is required")
        excluded = set(policy[1:].split())
        self.assertEqual(excluded, {"CAP_SETPCAP", "CAP_SYS_ADMIN"})
        for retained in ("CAP_SETUID", "CAP_SETGID", "CAP_NET_ADMIN", "CAP_NET_RAW"):
            self.assertNotIn(retained, excluded)
        self.assertEqual(service["AmbientCapabilities"], "")
        self.assertNotIn("NoNewPrivileges", service)
        self.assertNotIn("PrivateUsers", service)
        self.assertNotIn("SecureBits", service)
        self.assertEqual(service["User"], "warp-admin")
        self.assertEqual(service["Group"], "warp-admin")
        self.assertEqual(
            service["ExecStart"],
            "/usr/bin/python3 -I /opt/warp-egress-admin-console/app/admin/application.py",
        )

    def test_systemd_verifies_actual_unit(self) -> None:
        analyzer = shutil.which("systemd-analyze")
        if analyzer is None:
            self.skipTest("systemd-analyze unavailable; unit syntax verification not performed")
        # Keep the real unit bytes and executable; isolate unrelated host units
        # and Windows-mounted file permissions from the syntax check.
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "warp-admin.service"
            path.write_bytes((DEPLOY / "systemd" / path.name).read_bytes())
            path.chmod(0o644)
            for name in ("sysinit", "basic", "shutdown", "network"):
                (directory / f"{name}.target").write_text(
                    "[Unit]\nDefaultDependencies=no\n", encoding="ascii",
                )
            result = subprocess.run(
                [analyzer, "verify", str(path)],
                env={**os.environ, "SYSTEMD_UNIT_PATH": temporary},
                capture_output=True, text=True, check=False, timeout=30,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for invalid in ("Unknown", "Failed to parse", "Invalid"):
            self.assertNotIn(invalid, result.stderr)

    def test_deployment_scripts_are_admin_scoped(self) -> None:
        combined = "\n".join(
            (DEPLOY / name).read_text(encoding="utf-8") for name in ("install.sh", "uninstall.sh")
        )
        for required in (
            "/opt/warp-egress-admin-console",
            "/run/warp-egress-admin-console",
            "/usr/local/libexec/warp-egress-gateway/warp-admin-helper",
            "/etc/systemd/system/warp-admin.service",
            "/etc/sudoers.d/warp-egress-gateway-admin",
        ):
            self.assertIn(required, combined)
        for forbidden in (
            "systemctl restart warp-dashboard",
            "systemctl stop warp-dashboard",
            "userdel warp-web",
            "ip rule",
            "ip route",
            "nft ",
            "wg-quick",
            "net.ipv4.ip_forward",
        ):
            self.assertNotIn(forbidden, combined)


if __name__ == "__main__":
    unittest.main()
