#!/usr/bin/env python3
"""Intent foundation: real temporary files/flock; no host network or secrets."""
import fcntl
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("intent_state", ROOT / "native/scripts/intent-state.py")
intent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(intent)
REQUEST = "123e4567-e89b-42d3-a456-426614174000"
MAIN = [{"dst": "default", "gateway": "192.0.2.1", "dev": "ens160", "protocol": "static"}]


class IntentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.parent = self.root / "run/warp-egress-gateway"
        self.parent.mkdir(parents=True, mode=0o700)
        self.lock = self.parent / "admin-mutation.lock"
        self.lock.touch(mode=0o600)
        self.fd = os.open(self.lock, os.O_RDWR)
        self.addCleanup(os.close, self.fd)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        self.path = self.parent / "intentional-disconnect.json"
        self.store = intent.IntentStore(root=self.root, uid=os.getuid(), gid=os.getgid())

    def create(self):
        return self.store.create(self.fd, REQUEST, MAIN)

    def test_absent_and_valid_exact_schema(self):
        self.assertIsNone(self.store.read(self.fd))
        self.assertTrue(self.create())
        value = self.store.read(self.fd)
        self.assertEqual(set(value), {"schema", "request_id", "created_at", "main_default_sha256"})
        self.assertEqual(value["request_id"], REQUEST)
        self.assertEqual(value["main_default_sha256"], intent.main_fingerprint(MAIN))
        meta = self.path.stat()
        self.assertEqual((meta.st_uid, meta.st_gid, stat.S_IMODE(meta.st_mode)),
                         (os.getuid(), os.getgid(), 0o600))
        self.assertEqual(stat.S_IMODE(self.parent.stat().st_mode), 0o700)

    def test_atomic_order_and_idempotence(self):
        events = []
        sync, rename = os.fsync, intent.rename_no_replace
        def fsync(fd):
            events.append("directory" if stat.S_ISDIR(os.fstat(fd).st_mode) else "file")
            return sync(fd)
        def publish(*args, **kwargs):
            self.assertFalse(self.path.exists())
            events.append("rename")
            return rename(*args, **kwargs)
        with mock.patch.object(intent.os, "fsync", side_effect=fsync), mock.patch.object(intent, "rename_no_replace", side_effect=publish):
            self.create()
        self.assertEqual(events, ["file", "rename", "directory"])
        before = (self.path.read_bytes(), self.path.stat().st_ino, self.path.stat().st_mtime_ns)
        self.assertFalse(self.create())
        self.assertEqual(before, (self.path.read_bytes(), self.path.stat().st_ino, self.path.stat().st_mtime_ns))
        self.assertEqual({p.name for p in self.parent.iterdir()}, {self.path.name, self.lock.name})

    def test_bad_json_and_unknown_duplicate_fields_preserved(self):
        self.create()
        good = self.path.read_bytes()
        values = [b"{", b"[]", good[:-2] + b',"extra":1}\n',
                  good.replace(b'"schema":1', b'"schema":1,"schema":1'),
                  good.replace(b'"schema":1', b'"schema":true'),
                  good.replace(REQUEST.encode(), b"not-a-uuid"), b"x" * 4097,
                  good + b"{}", good.replace(b'"schema":1', b'"schema":NaN')]
        for raw in values:
            with self.subTest(raw_length=len(raw)):
                self.path.write_bytes(raw)
                with self.assertRaises(intent.IntentError): self.store.read(self.fd)
                with self.assertRaises(intent.IntentError): self.create()
                self.assertEqual(self.path.read_bytes(), raw)

    def test_symlink_hardlink_wrong_mode_and_directory_refused(self):
        other = self.parent / "other"
        other.write_text("unchanged")
        self.path.symlink_to(other)
        with self.assertRaises(intent.IntentError): self.create()
        self.path.unlink()
        os.link(other, self.path)
        with self.assertRaises(intent.IntentError): self.store.read(self.fd)
        self.path.unlink()
        self.create()
        self.path.chmod(0o640)
        with self.assertRaises(intent.IntentError): self.store.read(self.fd)
        self.path.unlink()
        self.path.mkdir()
        with self.assertRaises(intent.IntentError): self.store.read(self.fd)
        self.assertEqual(other.read_text(), "unchanged")

    def test_owner_group_parent_and_lock_metadata(self):
        self.create()
        for uid, gid in ((os.getuid() + 1, os.getgid()), (os.getuid(), os.getgid() + 1)):
            with self.assertRaises(intent.IntentError):
                intent.IntentStore(root=self.root, uid=uid, gid=gid).read(self.fd)
        for path, mode in ((self.parent, 0o755), (self.lock, 0o644), (self.path, 0o666)):
            original = stat.S_IMODE(path.stat().st_mode)
            path.chmod(mode)
            with self.assertRaises(intent.IntentError): self.store.read(self.fd)
            path.chmod(original)

    def test_shared_read_exclusive_create_and_unlocked_refusal(self):
        self.create()
        fcntl.flock(self.fd, fcntl.LOCK_SH)
        self.assertIsNotNone(self.store.read(self.fd))
        with self.assertRaises(intent.IntentError): self.create()
        other = os.open(self.lock, os.O_RDWR)
        try:
            with self.assertRaises(BlockingIOError): fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally: os.close(other)
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        with self.assertRaises(intent.IntentError): self.store.read(self.fd)

    def test_replaced_lock_and_parent_refused(self):
        self.lock.rename(self.parent / "old-lock")
        self.lock.touch(mode=0o600)
        with self.assertRaises(intent.IntentError): self.store.read(self.fd)
        self.parent.rename(self.parent.with_name("old-parent"))
        self.parent.symlink_to(self.parent.with_name("old-parent"))
        with self.assertRaises(intent.IntentError): self.store.read(self.fd)

    def test_replacement_during_read_refused(self):
        self.create()
        real_read = os.read
        def replace(fd, size):
            value = real_read(fd, size)
            self.path.unlink()
            self.path.write_bytes(value)
            self.path.chmod(0o600)
            return value
        with mock.patch.object(intent.os, "read", side_effect=replace):
            with self.assertRaises(intent.IntentError): self.store.read(self.fd)

    def test_fsync_failure_never_publishes(self):
        with mock.patch.object(intent.os, "fsync", side_effect=OSError("fixture")):
            with self.assertRaises(intent.IntentError): self.create()
        self.assertFalse(self.path.exists())
        self.assertEqual(list(self.parent.iterdir()), [self.lock])

    def test_reboot_equivalent_runtime_loss(self):
        self.create()
        self.path.unlink()  # isolated /run-loss simulation, never a production clear API
        self.assertIsNone(self.store.read(self.fd))
        self.assertFalse((self.root / "etc").exists())
        self.assertFalse((self.root / "var").exists())

    def test_main_fingerprint_is_semantic_but_immutable(self):
        self.assertEqual(intent.main_fingerprint(MAIN), intent.main_fingerprint([dict(reversed(list(MAIN[0].items())))]))
        self.assertNotEqual(intent.main_fingerprint(MAIN), intent.main_fingerprint([{**MAIN[0], "gateway": "192.0.2.2"}]))

    def test_reads_may_update_atime_without_becoming_corrupt(self):
        self.create()
        os.utime(self.path, ns=(1, self.path.stat().st_mtime_ns))
        self.assertIsNotNone(self.store.read(self.fd))

    def inspection_fixture(self):
        config = self.root / "etc/warp-egress-gateway/warp-gateway.env"
        config.parent.mkdir(parents=True)
        config.write_text("WARP_IF=warp0\nUPLINK_IF=ens160\nTRANSIT_IF=ens192\nROUTING_TABLE_ID=100\n"
                          "ROUTING_TABLE_NAME=warp_gateway\nSOURCE_RULE_PRIORITY=100\nINGRESS_RULE_PRIORITY=110\n")
        config.chmod(0o600)
        self.create()
        self.observed = {
            "links": [{"ifname": "lo"}, {"ifname": "ens160"}, {"ifname": "ens192"}],
            "rules": [{"priority": 0, "table": 255}, {"priority": 32766, "table": 254}],
            "routes": [{**MAIN[0], "table": 254}], "main": MAIN,
            "service": "inactive",
            "nft": {"nftables": [
                {"chain": {"family": "inet", "table": "warp_gateway", "name": "forward", "type": "filter", "hook": "forward", "prio": 0}},
                {"rule": {"family": "inet", "table": "warp_gateway", "chain": "forward", "comment": "WARP_KILL_SWITCH", "handle": 123,
                          "expr": [{"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": "ens192"}},
                                   {"match": {"op": "!=", "left": {"meta": {"key": "oifname"}}, "right": "warp0"}},
                                   {"counter": {"bytes": 12, "packets": 1}}, {"drop": None}]}}]},
        }
        self.commands = []
        def query(argv):
            self.commands.append(argv)
            self.assertFalse({"add", "del", "replace", "flush", "start", "stop", "restart", "set"} & set(argv))
            if argv[0].endswith("systemctl"): key = "service"
            elif "nft" in argv[0]: key = "nft"
            elif "link" in argv: key = "links"
            elif "rule" in argv: key = "rules"
            elif "main" in argv: key = "main"
            else: key = "routes"
            return copy.deepcopy(self.observed[key])
        return query

    def test_disconnected_semantics_and_runtime_handles(self):
        query = self.inspection_fixture()
        before = (self.path.read_bytes(), self.path.stat().st_mtime_ns)
        self.assertTrue(self.store.disconnected(self.fd, command=query))
        self.observed["nft"]["nftables"][1]["rule"]["handle"] = 456
        self.assertTrue(self.store.disconnected(self.fd, command=query))
        self.assertEqual(before, (self.path.read_bytes(), self.path.stat().st_mtime_ns))
        self.assertTrue(self.commands)

    def test_disconnected_refuses_remaining_or_ambiguous_state(self):
        query = self.inspection_fixture()
        bad_values = [
            ("links", [{"ifname": "ens160"}, {"ifname": "warp0", "flags": []}]),
            ("links", []), ("links", "malformed"), ("service", "active"), ("service", "activating"),
            ("rules", [{"priority": 100, "table": 100}]), ("rules", [{"priority": 110, "table": 100}]),
            ("rules", [{"priority": 111, "table": "warp_gateway"}]), ("rules", [{}]),
            ("rules", [{"priority": 112, "table": {}}]), ("rules", [{"priority": 112, "table": True}]),
            ("routes", [{"dst": "default", "table": 100, "dev": "warp0"}]),
            ("routes", [{"dst": "10.0.0.0/24", "table": 100}]),
            ("routes", [{"dst": "default", "table": "ambiguous"}]),
            ("main", [{**MAIN[0], "gateway": "192.0.2.9"}]),
            ("main", MAIN * 2), ("main", []), ("nft", {"nftables": []}),
        ]
        for key, value in bad_values:
            with self.subTest(key=key, value=value):
                previous = self.observed[key]
                self.observed[key] = value
                with self.assertRaises(intent.IntentError): self.store.disconnected(self.fd, command=query)
                self.observed[key] = previous
        rule = self.observed["nft"]["nftables"][1]["rule"]
        rule["expr"][-1] = {"accept": None}
        with self.assertRaises(intent.IntentError): self.store.disconnected(self.fd, command=query)

    def test_no_probe_when_intent_corrupt_and_no_write_cli(self):
        self.create()
        self.path.write_text('{"schema":1,"arbitrary":"SYNTHETIC_SECRET_CANARY"}')
        query = mock.Mock()
        with self.assertRaises(intent.IntentError): self.store.disconnected(self.fd, command=query)
        query.assert_not_called()
        with mock.patch.object(intent.sys, "argv", ["intent-state.py", "create", str(self.fd)]):
            self.assertEqual(intent.main(), 64)

    def test_competing_publish_is_never_overwritten(self):
        original = intent.rename_no_replace
        def compete(parent, temporary):
            self.path.write_bytes(b"corrupt competing intent")
            return original(parent, temporary)
        with mock.patch.object(intent, "rename_no_replace", side_effect=compete):
            with self.assertRaises(intent.IntentError): self.create()
        self.assertEqual(self.path.read_bytes(), b"corrupt competing intent")

    @unittest.skipUnless(os.geteuid() == 0, "root-only ownership failure fixtures")
    def test_actual_file_uid_gid_failures(self):
        self.create()
        for uid, gid in ((12345, 0), (0, 12345)):
            os.chown(self.path, uid, gid)
            with self.assertRaises(intent.IntentError): self.store.read(self.fd)
            os.chown(self.path, 0, 0)

    def test_failed_parent_fsync_retains_published_suppression(self):
        real = os.fsync
        def fsync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode): raise OSError("fixture")
            return real(fd)
        with mock.patch.object(intent.os, "fsync", side_effect=fsync):
            with self.assertRaises(intent.IntentError): self.create()
        self.assertIsNotNone(self.store.read(self.fd))


if __name__ == "__main__":
    unittest.main()
