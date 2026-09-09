#!/usr/bin/env python3
"""Fresh released-Core / isolated Admin foundation integration fixtures.

No production paths, services, sudo or network probes are used. The installed
helper and official shell evaluator run for real; fixture-only path/UID literals
redirect the evaluator into a temporary filesystem and strict command doubles.
"""

from contextlib import ExitStack
import hashlib
import importlib.util
import importlib.machinery
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))
from admin import helper as source_helper
from admin.protocol import encode_request
from admin_console_test import open_session, request, running_server

BUNDLE_PATH = "/opt/warp-egress-admin-console/readonly/v1"
LAUNCHER_PATH = BUNDLE_PATH + "/evaluate.py"
SHELL_FILES = ("health-readonly.sh", "common.sh", "routing.sh", "admin-lock.sh",
               "healthcheck-lib.sh", "observation-entrypoints.sh")
FILES = ("evaluate.py", *SHELL_FILES)
RELEASED_SHA256 = {
    "routing.sh": "c621a8884c225b555a5a2374af2c6fda452339d79a27c904cc05e914822ea547",
    "healthcheck-lib.sh": "ce8773cf00cd632698bb64a09b45af4ac4ea9e36d429951a50b3e732c172f373",
    "warp-gateway": "266dfa80689354cf9fbdf8b91114cc2289d093faec0bf1bf71b83a87003ec6e8",
}
CORE = "usr/local/lib/warp-egress-gateway"
REQUEST_ID = "123e4567-e89b-42d3-a456-426614174000"

PROBES = r'''#!/usr/bin/python3
from pathlib import Path
import json, sys
root = Path(__file__).parent
name, args = Path(sys.argv[0]).name, sys.argv[1:]
state = json.loads((root / "state.json").read_text())
with (root / "commands.log").open("a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
def refused():
    with (root / "mutations.log").open("a") as stream:
        stream.write(json.dumps([name, *args]) + "\n")
    raise SystemExit(97)
if name == "ip":
    if args == ["link", "show", "warp0"]:
        raise SystemExit(0 if state.get("wg", True) else 1)
    elif args == ["-4", "-o", "address", "show", "dev", "warp0", "scope", "global"]:
        print("7: warp0 inet 172.16.0.2/32 scope global warp0")
    elif args == ["-4", "-o", "address", "show", "dev", "ens160", "scope", "global"]:
        print("2: ens160 inet 192.0.2.10/24 scope global ens160")
    elif args == ["-4", "rule", "show"]:
        if state.get("route", True): print("100: from 172.16.0.2 lookup warp_gateway")
        print("110: from all iif ens192 lookup warp_gateway")
    elif args == ["-4", "route", "show", "table", "100", "default"]:
        print("default dev warp0 scope link")
    else: refused()
elif name == "systemctl":
    allowed = {"warp-gateway-firewall.service", "wg-quick@warp0.service", "warp-gateway.service",
               "warp-gateway-healthcheck.timer", "warp-monitor.timer"}
    if args[:2] != ["is-active", "--quiet"] or not args[2:] or not set(args[2:]) <= allowed: refused()
    if not state.get("wg", True) and "wg-quick@warp0.service" in args: raise SystemExit(1)
elif name == "wg":
    if args != ["show", "warp0"]: refused()
    raise SystemExit(0 if state.get("wg", True) else 1)
elif name == "nft":
    if args != ["list", "table", "inet", "warp_gateway"]: refused()
    if not state.get("nft", True): raise SystemExit(1)
    print('iifname "ens192" oifname != "warp0" counter drop comment "WARP_KILL_SWITCH"')
elif name == "curl":
    if args[:4] != ["-4", "--silent", "--show-error", "--fail"] or "--max-time" not in args: refused()
    address = args[args.index("--interface") + 1]
    if address == "192.0.2.10": print("ip=198.51.100.10\nwarp=off")
    elif address == "172.16.0.2":
        if not state.get("warp", True): raise SystemExit(28)
        print("ip=203.0.113.10\nwarp=on")
    else: refused()
elif name == "ping":
    if args != ["-I", "ens192", "-c", "1", "-W", "1", "10.1.1.221"]: refused()
else: refused()
'''


def snapshot(root):
    return {str(path.relative_to(root)): (hashlib.sha256(path.read_bytes()).hexdigest(),
            stat.S_IMODE(path.stat().st_mode), path.stat().st_ino)
            for path in root.rglob("*") if path.is_file()}


class AdminFoundationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="admin-foundation-")
        self.addCleanup(self.temporary.cleanup)
        self.area = Path(self.temporary.name)
        self.rootfs = self.area / "rootfs"
        self.rootfs.mkdir()
        self.payload = self.area / "payload"
        shutil.copytree(ROOT / "admin", self.payload / "admin")
        shutil.copytree(ROOT / "native/scripts", self.payload / "native/scripts")
        for path in self.payload.rglob("*"):
            path.chmod(0o755 if path.is_dir() else 0o644)
        subprocess.run([sys.executable, str(ROOT / "tests/admin_network_fixture.py"), str(self.rootfs)], check=True)
        self.config = self.rootfs / "etc/warp-egress-gateway/warp-gateway.env"
        with self.config.open("a") as stream:
            stream.write("TRUSTED_SOURCE_CIDR=10.1.1.221/32\nROUTING_TABLE_ID=100\n"
                         "ROUTING_TABLE_NAME=warp_gateway\nSOURCE_RULE_PRIORITY=100\n"
                         "INGRESS_RULE_PRIORITY=110\nHEALTHCHECK_TIMEOUT=1\nAUTO_RECOVER=true\n")
        (self.config.parent / "VERSION").write_text("0.5.1\n")
        # Actual v0.5.1 bytes, not copies of the candidate's newer foundation.
        for name in ("routing.sh", "healthcheck-lib.sh", "warp-gateway"):
            path = self.rootfs / ("usr/local/sbin/warp-gateway" if name == "warp-gateway" else CORE + "/" + name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / "tests/fixtures/admin-native-v051" / (name + ".fixture")).read_bytes())
            path.chmod(0o755)
        for relative in ("etc/systemd/system/warp-gateway.service", "etc/systemd/system/wg-quick@warp0.service",
                         "etc/systemd/system/warp-gateway-firewall.service", "etc/systemd/system/warp-dashboard.service",
                         "usr/local/lib/warp-egress-dashboard/collector.py"):
            path = self.rootfs / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("unchanged installed Core/Dashboard fixture\n")
            path.chmod(0o644)
        self.core_before = snapshot(self.rootfs / "usr/local")
        self.config_before = snapshot(self.rootfs / "etc")
        self.bundle = self.rootfs / BUNDLE_PATH.lstrip("/")
        self.env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "WARP_ADMIN_TEST_MODE": "1",
                    "WARP_ADMIN_TEST_ROOT": str(self.rootfs), "WARP_ADMIN_TEST_ACCOUNT": "safe"}
        self.probes = self.area / "probes"
        self.probes.mkdir()
        (self.probes / "probe").write_text(PROBES)
        (self.probes / "probe").chmod(0o755)
        for name in ("ip", "systemctl", "wg", "nft", "curl", "ping"):
            (self.probes / name).symlink_to("probe")
        (self.probes / "state.json").write_text("{}")

    def install(self):
        return subprocess.run(["bash", str(self.payload / "admin/deploy/install.sh")], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def assert_core_unchanged(self):
        after = snapshot(self.rootfs / "usr/local")
        for name, values in self.core_before.items():
            self.assertEqual(after[name], values, name)
        self.assertEqual(snapshot(self.rootfs / CORE),
                         {name.removeprefix("lib/warp-egress-gateway/"): values for name, values in self.core_before.items()
                          if name.startswith("lib/warp-egress-gateway/")})
        after_config = snapshot(self.rootfs / "etc")
        for name, values in self.config_before.items():
            self.assertEqual(after_config[name], values, name)
        actions = self.rootfs / "var/lib/warp-egress-admin-console/test-actions.log"
        if actions.exists():
            self.assertLessEqual(set(actions.read_text().splitlines()), {
                "systemctl daemon-reload", "systemctl enable warp-admin.service",
                "systemctl restart warp-admin.service", "systemctl disable --now warp-admin.service",
                "listener 192.0.2.10:8788 AF_INET only", "http GET / then GET /api/status",
                "listener poll=1 service=active count=1 addresses=192.0.2.10:8788"})

    def installed_helper(self):
        path = self.rootfs / "usr/local/libexec/warp-egress-gateway/warp-admin-helper"
        protocol = path.parent / "warp_admin_protocol.py"
        self.assertTrue(source_helper.validate_installed_metadata(path, protocol, required_uid=os.getuid(),
                        required_gid=os.getgid(), parents=tuple(path.parents)[:-2]))
        spec = importlib.util.spec_from_file_location("admin_foundation_installed_helper", path,
                    loader=importlib.machinery.SourceFileLoader("admin_foundation_installed_helper", str(path)))
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        with mock.patch.object(sys, "path", [str(path.parent), *sys.path]):
            spec.loader.exec_module(module)
        return module

    def prepare_execution_copy(self):
        """Only fixed paths/UID/root checks are relocated; evaluator logic is intact."""
        destination = self.area / "execution"
        if destination.exists():
            return destination
        shutil.copytree(self.bundle, destination)
        for path in destination.iterdir():
            text = path.read_text()
            text = text.replace(BUNDLE_PATH, str(destination))
            text = text.replace('"PATH": "/usr/sbin:/usr/bin:/sbin:/bin"',
                                f'"PATH": "{self.probes}:/usr/sbin:/usr/bin:/sbin:/bin"')
            text = text.replace('"/etc/${PROJECT_NAME}"', f'"{self.rootfs}/etc/${{PROJECT_NAME}}"')
            text = text.replace('${WARP_GATEWAY_CONFIG_DIR:-/etc/${PROJECT_NAME}}',
                                '${WARP_GATEWAY_CONFIG_DIR:-' + str(self.rootfs) + '/etc/${PROJECT_NAME}}')
            text = text.replace("'/run/warp-egress-gateway", "'" + str(self.rootfs) + "/run/warp-egress-gateway")
            text = text.replace('0 0 "${ADMIN_LOCK_TIMEOUT_SEC}"', f'{os.getuid()} {os.getgid()} "${{ADMIN_LOCK_TIMEOUT_SEC}}"')
            text = text.replace('[[ ${EUID} -eq 0 ]]', f'[[ ${{EUID}} -eq {os.getuid()} ]]')
            text = text.replace('os.geteuid() != 0', f'os.geteuid() != {os.getuid()}')
            path.write_text(text)
        return destination

    def observe(self, module, operation="status"):
        actual_process = module._bounded_process
        def run(argv, **kwargs):
            self.assertEqual(argv, (module.HEALTH_READONLY_PATH,))
            installed = self.rootfs / argv[0].lstrip("/")
            if not installed.is_file():
                raise module.HelperRuntimeError("observation_unavailable")
            execution = self.prepare_execution_copy()
            return actual_process((str(execution / "evaluate.py"),), **kwargs)
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(module, "_bounded_process", side_effect=run))
            if hasattr(module, "validate_readonly_metadata"):
                validate = module.validate_readonly_metadata
                stack.enter_context(mock.patch.object(module, "validate_readonly_metadata", side_effect=lambda:
                    validate(self.bundle, self.config, required_uid=os.getuid(), required_gid=os.getgid(),
                             parents=tuple(self.bundle.parents)[:-2] + tuple(self.config.parent.parents)[:-2] + (self.config.parent,))))
            return module.handle_request(encode_request(operation, REQUEST_ID),
                         version_path=self.config.parent / "VERSION", require_root_metadata=False)

    def test_fresh_v051_status_and_health_use_isolated_foundation(self):
        self.assertFalse((self.rootfs / CORE / "health-readonly.sh").exists())
        for name in ("routing.sh", "healthcheck-lib.sh"):
            self.assertNotEqual((self.rootfs / CORE / name).read_bytes(), (ROOT / "native/scripts" / name).read_bytes())
        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        self.assertIn("ADMIN_INSTALL_OK http://192.0.2.10:8788", installed.stdout)
        module = self.installed_helper()
        for operation in ("status", "health"):
            result = self.observe(module, operation)
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["state"], "ok")
            self.assertFalse(result["changed"])
            self.assertEqual(result["evidence"]["version"], "0.5.1")
        self.assert_core_unchanged()
        self.assertFalse((self.probes / "mutations.log").exists())

    def test_release_fixture_provenance(self):
        for name, expected in RELEASED_SHA256.items():
            path = ROOT / "tests/fixtures/admin-native-v051" / (name + ".fixture")
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected)

    def test_real_http_status_and_health_and_future_routes(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        module = self.installed_helper()
        case = self
        class Bridge:
            def invoke(self, operation, request_id):
                result = case.observe(module, operation)
                result["request_id"] = request_id
                return result
        with running_server(helper=Bridge(), management_address="192.0.2.10") as (server, _, _, _):
            cookie, csrf = open_session(server)
            status, _, body = request(server, "GET", "/api/status", headers=[("Host", server.expected_host), ("Cookie", cookie)])
            self.assertEqual(status, 200)
            self.assertTrue(json.loads(body)["ok"])
            headers = [("Host", server.expected_host), ("Origin", server.expected_origin), ("Cookie", cookie),
                       ("X-CSRF-Token", csrf), ("Content-Type", "application/json"), ("Content-Length", "2")]
            status, _, body = request(server, "POST", "/api/actions/health", headers=headers, body=b"{}")
            self.assertEqual(status, 200)
            self.assertFalse(json.loads(body)["changed"])
            for operation in ("connect", "disconnect", "repair-routing"):
                self.assertEqual(request(server, "POST", "/api/actions/" + operation, headers=headers, body=b"{}")[0], 404)
        self.assert_core_unchanged()

    def test_bundle_is_complete_versioned_and_matches_packaged_sources(self):
        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertEqual({p.name for p in self.bundle.iterdir()}, set(FILES))
        for name in FILES:
            path = self.bundle / name
            self.assertTrue(path.is_file() and not path.is_symlink())
            info = path.stat()
            self.assertEqual((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)),
                             (os.getuid(), os.getgid(), 0o755 if name == "evaluate.py" else 0o644))
            source = ROOT / ("admin/deploy/readonly/evaluate.py" if name == "evaluate.py" else "native/scripts/" + name)
            self.assertEqual(path.read_bytes(), source.read_bytes())
        before = snapshot(self.bundle)
        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertEqual(snapshot(self.bundle), before)
        self.assert_core_unchanged()

    def test_no_recovery_even_with_auto_recover_and_failed_dataplane(self):
        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr)
        module = self.installed_helper()
        for state in ({"route": False}, {"warp": False}, {"wg": False}, {"nft": False}):
            (self.probes / "state.json").write_text(json.dumps(state))
            result = self.observe(module, "health")
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["result_code"], "evaluation_unhealthy")
            self.assertFalse(result["changed"])
        self.assertFalse((self.probes / "mutations.log").exists())
        self.assertEqual({p.name for p in (self.rootfs / "run/warp-egress-gateway").iterdir()}, {"admin-mutation.lock"})
        self.assert_core_unchanged()

    def test_shared_lock_busy_and_safe_inode_survives_uninstall(self):
        import fcntl
        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr)
        module = self.installed_helper()
        self.assertTrue(self.observe(module)["ok"])
        lock = self.rootfs / "run/warp-egress-gateway/admin-mutation.lock"
        before = lock.stat()
        with lock.open("rb") as opened:
            fcntl.flock(opened, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.observe(module)
            self.assertEqual(result["result_code"], "mutation_lock_busy")
        result = subprocess.run(["bash", str(self.payload / "admin/deploy/uninstall.sh")], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.bundle.exists())
        self.assertEqual((lock.stat().st_ino, stat.S_IMODE(lock.stat().st_mode)), (before.st_ino, 0o600))
        self.assert_core_unchanged()

    def test_unsafe_or_missing_bundle_fails_before_execution(self):
        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr)
        module = self.installed_helper()
        for name in FILES:
            path = self.bundle / name
            original = path.read_bytes()
            mode = path.stat().st_mode
            for damage in ("writable", "missing", "symlink"):
                with self.subTest(name=name, damage=damage):
                    if damage == "writable": path.chmod(0o777)
                    else:
                        path.unlink()
                        if damage == "symlink": path.symlink_to(self.config)
                    result = self.observe(module)
                    self.assertEqual(result["result_code"], "observation_unavailable")
                    self.assertFalse(result["ok"])
                    if path.is_symlink(): path.unlink()
                    path.write_bytes(original)
                    path.chmod(stat.S_IMODE(mode))
        for directory in (self.bundle, self.bundle.parent, self.bundle.parent.parent, self.config.parent):
            mode = directory.stat().st_mode
            directory.chmod(0o777)
            self.assertEqual(self.observe(module)["result_code"], "observation_unavailable")
            directory.chmod(stat.S_IMODE(mode))
        self.assertFalse((self.probes / "commands.log").exists())

    def test_reinstall_rejects_different_or_unsafe_existing_version(self):
        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stderr)
        path = self.bundle / "routing.sh"
        path.write_text("unexpected root-edited version\n")
        before = snapshot(self.bundle)
        actions = self.rootfs / "var/lib/warp-egress-admin-console/test-actions.log"
        before_actions = actions.read_bytes()
        failed = self.install()
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("GATE_FOUNDATION", failed.stderr)
        self.assertEqual(snapshot(self.bundle), before)
        self.assertEqual(actions.read_bytes(), before_actions)
        self.assert_core_unchanged()

    def test_wrong_uid_gid_and_config_chain_fail_before_execution(self):
        self.assertEqual(self.install().returncode, 0)
        module = self.installed_helper()
        original_lstat = Path.lstat
        for target in [*(self.bundle / name for name in FILES), self.bundle, self.bundle.parent, self.config]:
            for field in ("st_uid", "st_gid"):
                with self.subTest(target=target, field=field):
                    def metadata(path, *args, **kwargs):
                        info = original_lstat(path, *args, **kwargs)
                        if path != target:
                            return info
                        values = dict(st_uid=info.st_uid, st_gid=info.st_gid, st_mode=info.st_mode)
                        values[field] += 1
                        return SimpleNamespace(**values)
                    with mock.patch.object(Path, "lstat", metadata):
                        self.assertEqual(self.observe(module)["result_code"], "observation_unavailable")
        original = self.config.read_bytes()
        self.config.unlink()
        self.config.symlink_to(self.bundle / "common.sh")
        self.assertEqual(self.observe(module)["result_code"], "observation_unavailable")
        self.config.unlink()
        self.config.write_bytes(original)
        self.config.chmod(0o666)
        self.assertEqual(self.observe(module)["result_code"], "observation_unavailable")
        self.assertFalse((self.probes / "commands.log").exists())

    def test_launcher_zero_args_fixed_command_and_no_environment_override(self):
        spec = importlib.util.spec_from_file_location("admin_readonly_launcher", ROOT / "admin/deploy/readonly/evaluate.py")
        launcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launcher)
        with mock.patch.object(sys, "argv", [LAUNCHER_PATH, "health"]), mock.patch.object(launcher.os, "execve") as execute:
            self.assertEqual(launcher.main(), 64)
            execute.assert_not_called()
        with mock.patch.object(sys, "argv", [LAUNCHER_PATH]), mock.patch.object(launcher.os, "geteuid", return_value=1234):
            self.assertEqual(launcher.main(), 77)
        hostile = {"WARP_GATEWAY_CONFIG_FILE": "/caller/config", "WARP_ADMIN_TEST_ROOT": "/caller/root",
                   "BASH_ENV": "/caller/startup", "PATH": "/caller/bin", "PYTHONPATH": "/caller/import"}
        with mock.patch.dict(os.environ, hostile), mock.patch.object(sys, "argv", [LAUNCHER_PATH]), \
                mock.patch.object(launcher.os, "geteuid", return_value=0), \
                mock.patch.object(launcher.os, "execve", side_effect=RuntimeError("exec boundary")) as execute:
            with self.assertRaisesRegex(RuntimeError, "exec boundary"):
                launcher.main()
        self.assertEqual(execute.call_args.args, (
            "/usr/bin/bash", ("/usr/bin/bash", "--noprofile", "--norc", BUNDLE_PATH + "/health-readonly.sh"),
            {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "LANG": "C", "LC_ALL": "C"}))
        self.assertEqual(source_helper.HEALTH_READONLY_PATH, LAUNCHER_PATH)

    def test_incomplete_source_refused_before_installation(self):
        (self.payload / "native/scripts/admin-lock.sh").unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GATE_FOUNDATION", result.stderr)
        self.assertFalse((self.rootfs / "opt/warp-egress-admin-console").exists())
        self.assertFalse((self.rootfs / "var/lib/warp-egress-admin-console/test-actions.log").exists())
        self.assert_core_unchanged()

    def test_partial_bundle_install_failure_never_publishes_or_activates(self):
        # Exercise a real failing install command in the isolated TEST_MODE path.
        stub = self.probes / "install"
        stub.write_text('#!/bin/bash\nfor arg in "$@"; do\n'
                        'case "$arg" in */.v1.*/healthcheck-lib.sh.tmp.*) exit 91;; esac\ndone\n'
                        'exec /usr/bin/install "$@"\n')
        stub.chmod(0o755)
        self.env["PATH"] = str(self.probes) + ":" + os.environ["PATH"]
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.bundle.exists())
        self.assertFalse((self.rootfs / "usr/local/libexec/warp-egress-gateway/warp-admin-helper").exists())
        actions = self.rootfs / "var/lib/warp-egress-admin-console/test-actions.log"
        self.assertEqual(actions.read_text(), "")
        self.assert_core_unchanged()

    def test_unsafe_uninstall_tree_refused_before_any_removal(self):
        self.assertEqual(self.install().returncode, 0)
        actions = self.rootfs / "var/lib/warp-egress-admin-console/test-actions.log"
        before_actions = actions.read_bytes()
        for target in (self.bundle / "common.sh", self.bundle, self.bundle.parent, self.bundle.parent.parent):
            mode = target.stat().st_mode
            target.chmod(0o777)
            result = subprocess.run(["bash", str(self.payload / "admin/deploy/uninstall.sh")], env=self.env,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GATE_DESTINATION", result.stderr)
            self.assertTrue((self.bundle / "evaluate.py").is_file())
            self.assertEqual(actions.read_bytes(), before_actions)
            target.chmod(stat.S_IMODE(mode))
        self.assert_core_unchanged()

    def test_symlink_parent_and_unexpected_bundle_entry_rejected(self):
        self.assertEqual(self.install().returncode, 0)
        module = self.installed_helper()
        renamed = self.bundle.parent.with_name("readonly-saved")
        self.bundle.parent.rename(renamed)
        self.bundle.parent.symlink_to(renamed, target_is_directory=True)
        self.assertEqual(self.observe(module)["result_code"], "observation_unavailable")
        self.bundle.parent.unlink()
        renamed.rename(self.bundle.parent)
        (self.bundle / "unexpected").write_text("not in source allowlist")
        self.assertEqual(self.observe(module)["result_code"], "observation_unavailable")
        self.assertFalse((self.probes / "commands.log").exists())


if __name__ == "__main__":
    unittest.main()
