#!/usr/bin/env python3
"""Site-neutral Dashboard observations and real trusted-config filesystem gates."""

from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from web.dashboard import collector
from web.dashboard.schema import validate_status
from dashboard_test import FakeRunner, collector_outputs

CC = ("ens160", "ens192", "warp0", "100")
HQ = ("ens33", "ens35", "warp0", "100")
CUSTOM = ("uplink.10", "transit_20", "wg-egress", "4242")
KEYS = ("UPLINK_IF", "TRANSIT_IF", "WARP_IF", "ROUTING_TABLE_ID")


def role_config(roles=HQ):
    return "".join(f'{key}="{value}"\n' for key, value in zip(KEYS, roles)).encode()


def site_outputs(roles=HQ, *, numeric_table=False):
    replacements = dict(zip(CC[:3], roles[:3]))
    outputs = {}
    for command, raw in collector_outputs().items():
        command = tuple(replacements.get(argument, argument) for argument in command)
        if command[:7] == ("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "100"):
            command = (*command[:6], roles[3], *command[7:])
        if isinstance(raw, bytes):
            for old, new in replacements.items():
                raw = raw.replace(old.encode(), new.encode())
            if numeric_table and command == ("/usr/sbin/ip", "-4", "rule", "show"):
                raw = raw.replace(b"lookup warp_gateway", f"lookup {roles[3]}".encode())
        outputs[command] = raw
    return outputs


@contextmanager
def trusted_gateway(raw=role_config()):
    """Map only the reader's root fd to a private filesystem, never real /etc.

    All traversal, no-follow, file reads and mode checks are real. Unprivileged
    CI maps its own fixture UID to root; root local runs check actual ownership.
    There is deliberately no production path/UID argument or env override.
    """
    with tempfile.TemporaryDirectory(prefix="dashboard-roles-") as temporary:
        root = Path(temporary)
        directory = root / "etc/warp-egress-gateway"
        directory.mkdir(parents=True)
        root.chmod(0o700)
        (root / "etc").chmod(0o755)
        directory.chmod(0o700)
        config = directory / "warp-gateway.env"
        config.write_bytes(raw)
        config.chmod(0o600)
        (root / "VERSION").write_text("0.5.1\n")
        (root / "uptime").write_text("390600.00 100.00\n")
        original_open, original_stat = os.open, os.fstat

        def fixture_open(path, flags, *args, **kwargs):
            return original_open(root if path == "/" else path, flags, *args, **kwargs)

        def fixture_stat(descriptor):
            metadata = original_stat(descriptor)
            if os.getuid() == 0 or metadata.st_uid != os.getuid():
                return metadata
            values = {name: getattr(metadata, name) for name in dir(metadata) if name.startswith("st_")}
            values["st_uid"] = 0
            return SimpleNamespace(**values)

        with mock.patch.object(collector.os, "open", side_effect=fixture_open), \
                mock.patch.object(collector.os, "fstat", side_effect=fixture_stat):
            yield root, config


def collect(root, outputs=None):
    runner = FakeRunner(site_outputs() if outputs is None else outputs)
    runtime = collector.CollectorRuntime(
        runner=runner, version_path=root / "VERSION", uptime_path=root / "uptime",
        now=lambda: datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc),
        epoch_now=lambda: 1787572800,
    )
    return collector.collect_status(runtime), runner


class SiteRoleTests(unittest.TestCase):
    def test_hq_rule_110_uses_ens35(self):
        with trusted_gateway() as (root, _):
            status, _ = collect(root)
        self.assertEqual(status["routing"]["rule_110"], "ok")

    def test_hq_direct_probe_uses_ens33(self):
        with trusted_gateway() as (root, _):
            status, runner = collect(root)
        self.assertEqual(status["paths"]["direct"], {"state": "ok", "warp": "off"})
        self.assertIn(collector._trace_command("ens33"), runner.calls)
        self.assertNotIn(collector._trace_command("ens160"), runner.calls)

    def test_hq_kill_switch_uses_ens35(self):
        with trusted_gateway() as (root, _):
            status, _ = collect(root)
        self.assertEqual(status["safety"]["kill_switch"], "active")

    def test_cc_hq_and_custom_roles_are_healthy_with_numeric_or_named_tables(self):
        for roles in (CC, HQ, CUSTOM):
            for numeric in (False, True):
                with self.subTest(roles=roles, numeric=numeric), trusted_gateway(role_config(roles)) as (root, _):
                    status, runner = collect(root, site_outputs(roles, numeric_table=numeric))
                    self.assertEqual(validate_status(status)["overall"]["state"], "online")
                    self.assertEqual(status["schema_version"], 1)
                    self.assertEqual(status["paths"], {"direct": {"state": "ok", "warp": "off"},
                                                      "warp": {"state": "ok", "warp": "on"}})
                    self.assertEqual(status["routing"], dict(rule_100="ok", rule_110="ok", table_100="ok", main_default="ok"))
                    self.assertEqual(status["safety"]["kill_switch"], "active")
                    self.assertEqual(status["warp"]["interface"], "up")
                    self.assertEqual(status["warp"]["handshake_age_seconds"], 30)
                    # Exact command set proves role use and no added mutations.
                    self.assertEqual(set(runner.calls), set(site_outputs(roles)))
                    self.assertEqual(len(runner.calls), len(site_outputs(roles)))

    def test_main_default_requires_configured_uplink_and_single_unicast_route(self):
        command = ("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "main", "default")
        good = {"dst": "default", "dev": "ens33", "gateway": "192.0.2.254", "scope": "global"}
        for routes in ([good], [dict(good, dev="ens160")], [dict(good, dev="ens35")],
                       [dict(good, dev="warp0")], [], [good, good], [dict(good, dst="192.0.2.0/24")],
                       [dict(good, type="blackhole")], [dict(good, nexthops=[])], [dict(good, nhid=7)]):
            with self.subTest(routes=routes), trusted_gateway() as (root, _):
                outputs = site_outputs()
                outputs[command] = json.dumps(routes).encode()
                status, _ = collect(root, outputs)
                self.assertEqual(status["routing"]["main_default"], "ok" if routes == [good] else "failed")

    def test_rule_validation_rejects_wrong_ingress_table_and_duplicate_rules(self):
        command = ("/usr/sbin/ip", "-4", "rule", "show")
        good = site_outputs(CUSTOM, numeric_table=True)[command]
        cases = (good.replace(b"transit_20", b"ens192"), good.replace(b"lookup 4242", b"lookup 100"),
                 good + b"110: from all iif transit_20 lookup 4242\n")
        for raw in cases:
            with self.subTest(raw=raw), trusted_gateway(role_config(CUSTOM)) as (root, _):
                outputs = site_outputs(CUSTOM)
                outputs[command] = raw
                status, _ = collect(root, outputs)
                self.assertEqual(status["routing"]["rule_110"], "failed")
                if b"lookup 100" in raw:
                    self.assertEqual(status["routing"]["rule_100"], "failed")

    def test_warp_table_must_use_configured_device_without_gateway_or_multipath(self):
        command = ("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "4242", "default")
        good = {"dst": "default", "dev": "wg-egress", "scope": "link"}
        for bad in ({"dev": "warp0"}, {"gateway": "192.0.2.1"}, {"via": {}},
                    {"nexthops": []}, {"nhid": 1}, {"type": "blackhole"}):
            with self.subTest(bad=bad), trusted_gateway(role_config(CUSTOM)) as (root, _):
                outputs = site_outputs(CUSTOM)
                outputs[command] = json.dumps([{**good, **bad}]).encode()
                status, _ = collect(root, outputs)
                self.assertEqual(status["routing"]["table_100"], "failed")

    def test_kill_switch_requires_configured_roles_and_all_existing_semantics(self):
        command = ("/usr/sbin/nft", "-j", "list", "table", "inet", "warp_gateway")
        original = site_outputs(CUSTOM)[command]
        cases = [(b'"transit_20"', b'"ens192"'), (b'"wg-egress"', b'"warp0"'),
                 (b'"inet"', b'"ip"'), (b'"warp_gateway"', b'"other"'),
                 (b'"WARP_KILL_SWITCH"', b'"OTHER"'), (b'"drop"', b'"accept"'),
                 (b'"!="', b'"=="'), (b'"=="', b'"!="')]
        for old, new in cases:
            with self.subTest(old=old, new=new), trusted_gateway(role_config(CUSTOM)) as (root, _):
                outputs = site_outputs(CUSTOM)
                outputs[command] = original.replace(old, new)
                status, _ = collect(root, outputs)
                self.assertEqual(status["safety"]["kill_switch"], "inactive")
        with trusted_gateway(role_config(CUSTOM)) as (root, _):
            outputs = site_outputs(CUSTOM)
            rule = json.loads(original)["nftables"][0]["rule"]
            rule["expr"] = [{"drop": None}]
            outputs[command] = json.dumps({"nftables": [{"rule": rule}]}).encode()
            status, _ = collect(root, outputs)
            self.assertEqual(status["safety"]["kill_switch"], "inactive")


class RoleConfigTests(unittest.TestCase):
    def assert_unknown(self, root):
        status, runner = collect(root)
        self.assertEqual(validate_status(status)["overall"]["state"], "degraded")
        self.assertEqual(status["paths"], {"direct": {"state": "unknown", "warp": "unknown"},
                                          "warp": {"state": "unknown", "warp": "unknown"}})
        self.assertEqual(set(status["routing"].values()), {"unknown"})
        self.assertEqual(status["safety"]["kill_switch"], "unknown")
        self.assertEqual(status["warp"]["interface"], "unknown")
        self.assertIsNone(status["warp"]["handshake_age_seconds"])
        for command in runner.calls:
            self.assertNotIn(command[0], {"/usr/sbin/ip", "/usr/bin/wg", "/usr/bin/curl", "/usr/sbin/nft"})
        return status

    def test_valid_quoting_unrelated_keys_and_native_example(self):
        for raw in (role_config(), role_config().replace(b'"', b"'"), role_config().replace(b'"', b""),
                    role_config() + b'UNRELATED="ignored"\nUNRELATED="also ignored"\n',
                    (ROOT / "native/config/warp-gateway.env.example").read_bytes()):
            with self.subTest(raw=raw[:20]), trusted_gateway(raw) as (root, _):
                status, _ = collect(root)
                self.assertEqual(status["overall"]["state"], "online")

    def test_read_only_file_modes_remain_supported(self):
        for mode in (0o600, 0o640, 0o644):
            with self.subTest(mode=mode), trusted_gateway() as (root, config):
                config.chmod(mode)
                status, _ = collect(root)
                self.assertEqual(status["overall"]["state"], "online")

    def test_required_declarations_reject_missing_duplicate_and_unsupported_forms(self):
        good = role_config()
        cases = [good + b'UPLINK_IF="ens35"\n', good + b'UPLINK_IF="ens33"\n',
                 good + b'export UPLINK_IF="ens35"\n', good + b' UPLINK_IF="ens35"\n',
                 good.replace(b'UPLINK_IF=', b'UPLINK_IF ='), good.replace(b'UPLINK_IF=', b'UPLINK_IF ')]
        cases += [b"\n".join(line for line in good.splitlines() if not line.startswith(key.encode()))
                  for key in KEYS]
        for raw in cases:
            with self.subTest(raw=raw[:50]), trusted_gateway(raw) as (root, _):
                self.assert_unknown(root)

    def test_invalid_interface_and_conflicting_roles_fail_closed(self):
        for value in ("", "lo", "ens33", "warp0", "-unsafe", "with space", "eth0:1", "eth/0",
                      "a" * 16, "eth\t0", "eth\x00x", "${UPLINK_IF}", "$(false)", "`false`"):
            with self.subTest(value=value), trusted_gateway(role_config(("ens33", value, "warp0", "100"))) as (root, _):
                self.assert_unknown(root)
        for roles in (("warp0", "ens35", "warp0", "100"), ("ens33", "ens35", "ens35", "100")):
            with self.subTest(roles=roles), trusted_gateway(role_config(roles)) as (root, _):
                self.assert_unknown(root)

    def test_table_id_is_canonical_bounded_decimal_without_fallback(self):
        for table in ("0", "-1", "4294967296", "1" * 50, "0100", "+100", "100 ", "main", "0x64", "1.0", ""):
            with self.subTest(table=table), trusted_gateway(role_config((*HQ[:3], table))) as (root, _):
                self.assert_unknown(root)
        for table in ("1", "4294967295"):
            roles = (*CUSTOM[:3], table)
            with self.subTest(table=table), trusted_gateway(role_config(roles)) as (root, _):
                status, _ = collect(root, site_outputs(roles, numeric_table=True))
                self.assertEqual(status["overall"]["state"], "online")

    def test_fixed_reader_has_no_caller_path_or_environment_override(self):
        import inspect
        self.assertEqual(collector.ROLE_CONFIG_PATH, Path("/etc/warp-egress-gateway/warp-gateway.env"))
        self.assertEqual(len(inspect.signature(collector.load_runtime_roles).parameters), 0)
        with trusted_gateway() as (root, config):
            config.unlink()
            alternate = root / "alternate.env"
            alternate.write_bytes(role_config(CC))
            with mock.patch.dict(os.environ, {"WARP_GATEWAY_CONFIG": str(alternate),
                                              "CONFIG_FILE": str(alternate), "UPLINK_IF": "ens160",
                                              "TRANSIT_IF": "ens192", "WARP_IF": "warp0", "ROUTING_TABLE_ID": "100"}):
                self.assert_unknown(root)

    def test_shell_looking_values_are_never_executed_or_disclosed(self):
        with trusted_gateway() as (root, config):
            marker = root / "must-not-exist"
            for value in (f"$(touch {marker})", f"`touch {marker}`", f"ens33; touch {marker}"):
                config.write_bytes(role_config((value, "ens35", "warp0", "100")))
                with mock.patch.object(collector.subprocess, "Popen", side_effect=AssertionError("shell execution")):
                    status = self.assert_unknown(root)
                self.assertFalse(marker.exists())
                self.assertNotIn(str(marker), json.dumps(status))
            config.write_bytes(role_config() + f'UNRELATED="$(touch {marker})"\n'.encode())
            with mock.patch.object(collector.subprocess, "Popen", side_effect=AssertionError("shell execution")):
                status, _ = collect(root)
            self.assertEqual(status["overall"]["state"], "online")
            self.assertFalse(marker.exists())

    def test_missing_symlink_nonregular_and_writable_files_fail_closed(self):
        for kind in ("missing", "symlink", "directory", "fifo", "group-write", "world-write", "empty", "oversized", "non-ascii"):
            with self.subTest(kind=kind), trusted_gateway() as (root, config):
                if kind in {"missing", "symlink", "directory", "fifo"}:
                    config.unlink()
                if kind == "symlink":
                    target = root / "target"
                    target.write_bytes(role_config())
                    config.symlink_to(target)
                elif kind == "directory":
                    config.mkdir()
                elif kind == "fifo":
                    os.mkfifo(config)
                elif kind in {"group-write", "world-write"}:
                    config.chmod(0o620 if kind == "group-write" else 0o602)
                elif kind in {"empty", "oversized", "non-ascii"}:
                    config.write_bytes({"empty": b"", "oversized": b"#" * 65537, "non-ascii": b"\xff"}[kind])
                self.assert_unknown(root)

    def test_nonroot_config_owner_fails_closed(self):
        with trusted_gateway() as (root, config):
            if os.getuid() == 0:
                os.chown(config, 1, 0)
                self.assert_unknown(root)
            else:
                original = collector.os.fstat
                inode = config.stat().st_ino
                def wrong_owner(fd):
                    info = original(fd)
                    if info.st_ino != inode:
                        return info
                    values = {name: getattr(info, name) for name in dir(info) if name.startswith("st_")}
                    values["st_uid"] = os.getuid() + 1
                    return SimpleNamespace(**values)
                with mock.patch.object(collector.os, "fstat", side_effect=wrong_owner):
                    self.assert_unknown(root)

    def test_parent_symlink_or_writable_directory_fails_closed(self):
        for kind in ("symlink", "group-write", "world-write"):
            with self.subTest(kind=kind), trusted_gateway() as (root, config):
                parent = config.parent
                if kind == "symlink":
                    target = root / "other"
                    parent.rename(target)
                    parent.symlink_to(target, target_is_directory=True)
                else:
                    parent.chmod(0o720 if kind == "group-write" else 0o702)
                self.assert_unknown(root)

    def test_changed_during_read_is_not_accepted(self):
        with trusted_gateway() as (root, config):
            original = collector.os.read
            inode = config.stat().st_ino
            def changing_read(fd, size):
                raw = original(fd, size)
                if collector.os.fstat(fd).st_ino == inode:
                    config.write_bytes(role_config(CC))
                return raw
            with mock.patch.object(collector.os, "read", side_effect=changing_read):
                self.assert_unknown(root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
