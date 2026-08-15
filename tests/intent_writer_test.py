#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
WRITER_PATH = ROOT / "native" / "scripts" / "runtime-state-intent.py"
VALIDATOR_PATH = ROOT / "native" / "scripts" / "runtime-state-validate.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class IntentWriterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "runtime"
        self.root.mkdir(mode=0o700)
        self.writer = load_module("runtime_state_intent", WRITER_PATH)
        self.validator = load_module("runtime_state_validate", VALIDATOR_PATH)
        self.runtime = self.writer.IntentRuntime(
            directory=self.root,
            intent_path=self.root / "intentional-disconnect.json",
            expected_uid=os.getuid() if hasattr(os, "getuid") else None,
            expected_gid=os.getgid() if hasattr(os, "getgid") else None,
            enforce_permissions=os.name != "nt",
        )
        self.payload = {
            "request_id": "0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7",
            "asserted_actor": "admin-example",
        }

    def test_create_uses_exact_deterministic_schema_and_mode(self) -> None:
        result = self.writer.create_intent(self.runtime, self.payload)
        self.assertTrue(result["created"])
        raw = self.runtime.intent_path.read_bytes()
        value = json.loads(raw)
        self.assertEqual(
            list(value), ["version", "state", "created_at", "request_id", "actor"]
        )
        self.assertEqual(value["version"], 1)
        self.assertEqual(value["state"], "intentionally_disconnected")
        self.assertEqual(value["request_id"], self.payload["request_id"])
        self.assertEqual(value["actor"], "admin-example")
        self.assertEqual(raw, json.dumps(value, separators=(",", ":")).encode() + b"\n")
        if os.name != "nt":
            opened = self.runtime.intent_path.stat()
            self.assertEqual(stat.S_IMODE(opened.st_mode), 0o600)
            self.assertEqual(opened.st_uid, os.getuid())
            self.assertEqual(opened.st_gid, os.getgid())
        self.assertEqual(list(self.root.glob(".intentional-disconnect.*")), [])

    def test_strict_input_rejects_duplicates_unknowns_and_malformed_values(self) -> None:
        invalid = [
            b'{"request_id":"0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7","request_id":"0e2b7a20-e84c-4c1e-9eb8-a673be3d69d7","asserted_actor":"a"}',
            json.dumps({**self.payload, "path": "/tmp/x"}).encode(),
            json.dumps({**self.payload, "asserted_actor": "a\nforged"}).encode(),
            json.dumps({**self.payload, "request_id": "not-a-uuid"}).encode(),
            b"x" * 4097,
        ]
        for raw in invalid:
            with self.subTest(raw=raw[:50]):
                with self.assertRaises(self.writer.IntentInputError):
                    self.writer.parse_input(raw)
        self.assertFalse(self.runtime.intent_path.exists())

    def test_canonical_actor_grammar_and_writer_validator_parity(self) -> None:
        valid_actors = [
            "admin-example",
            "user.name@example",
            "a" + "x" * 127,
        ]
        for actor in valid_actors:
            with self.subTest(actor=actor[:32], length=len(actor)):
                payload = {**self.payload, "asserted_actor": actor}
                encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
                self.assertEqual(self.writer.parse_input(encoded), payload)
                self.writer.create_intent(self.runtime, payload)
                self.validator.validate_path(self.runtime.intent_path)
                self.runtime.intent_path.unlink()

    def test_noncanonical_actor_is_rejected_before_intent_creation(self) -> None:
        invalid_actors = [
            "Admin User",
            'admin"quoted',
            "admin\\backslash",
            "admin\tcontrol",
            "a" * 129,
        ]
        for actor in invalid_actors:
            with self.subTest(actor=repr(actor[:32]), length=len(actor)):
                payload = {**self.payload, "asserted_actor": actor}
                encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
                with self.assertRaises(self.writer.IntentInputError):
                    self.writer.parse_input(encoded)
                self.assertFalse(self.runtime.intent_path.exists())

    def test_existing_valid_record_is_idempotent_and_never_rewritten(self) -> None:
        first = self.writer.create_intent(self.runtime, self.payload)
        before = self.runtime.intent_path.read_bytes()
        before_stat = self.runtime.intent_path.stat()
        second = self.writer.create_intent(self.runtime, self.payload)
        after_stat = self.runtime.intent_path.stat()
        self.assertFalse(second["created"])
        self.assertEqual(second["since"], first["since"])
        self.assertEqual(self.runtime.intent_path.read_bytes(), before)
        self.assertEqual((after_stat.st_dev, after_stat.st_ino), (before_stat.st_dev, before_stat.st_ino))

    def test_corrupt_or_unsafe_existing_record_is_never_overwritten(self) -> None:
        self.runtime.intent_path.write_text("not-json\n", encoding="utf-8")
        before = self.runtime.intent_path.read_bytes()
        with self.assertRaises(self.writer.IntentConflict):
            self.writer.create_intent(self.runtime, self.payload)
        self.assertEqual(self.runtime.intent_path.read_bytes(), before)

        if os.name != "nt":
            self.runtime.intent_path.unlink()
            target = self.root / "target"
            target.write_text("target\n", encoding="utf-8")
            self.runtime.intent_path.symlink_to(target)
            with self.assertRaises(self.writer.IntentConflict):
                self.writer.create_intent(self.runtime, self.payload)
            self.assertTrue(self.runtime.intent_path.is_symlink())


if __name__ == "__main__":
    unittest.main(verbosity=2)
