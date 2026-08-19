#!/usr/bin/env python3
from __future__ import annotations

import copy
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT_TOOL = ROOT / "native" / "scripts" / "nft-semantic-snapshot.py"


def ruleset_fixture() -> dict:
    return {
        "nftables": [
            {"metainfo": {"json_schema_version": 1}},
            {"table": {"family": "inet", "name": "warp_gateway", "handle": 7}},
            {
                "chain": {
                    "family": "inet",
                    "table": "warp_gateway",
                    "name": "forward",
                    "type": "filter",
                    "hook": "forward",
                    "prio": 0,
                    "policy": "drop",
                    "handle": 8,
                }
            },
            {
                "rule": {
                    "family": "inet",
                    "table": "warp_gateway",
                    "chain": "forward",
                    "handle": 9,
                    "expr": [
                        {
                            "match": {
                                "op": "==",
                                "left": {"meta": {"key": "iifname"}},
                                "right": "eth1",
                            }
                        },
                        {
                            "match": {
                                "op": "!=",
                                "left": {"meta": {"key": "oifname"}},
                                "right": "warp0",
                            }
                        },
                        {"counter": {"packets": 41, "bytes": 4096}},
                        {"drop": None},
                    ],
                    "comment": "WARP_KILL_SWITCH",
                }
            },
            {
                "rule": {
                    "family": "inet",
                    "table": "warp_gateway",
                    "chain": "postrouting",
                    "handle": 10,
                    "expr": [
                        {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}}, "right": "198.51.100.1"}},
                        {"mangle": {"key": {"payload": {"protocol": "tcp", "field": "maxseg"}}, "value": 1360}},
                        {"snat": {"addr": "192.0.2.2"}},
                    ],
                    "comment": "WARP_NAT_MSS",
                }
            },
        ]
    }


class NftSemanticSnapshotTests(unittest.TestCase):
    def snapshot(self, value: object) -> str:
        completed = subprocess.run(
            [sys.executable, "-I", str(SNAPSHOT_TOOL)],
            input=json.dumps(value, separators=(",", ":")).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", errors="replace"))
        fingerprint = completed.stdout.decode("ascii").strip()
        self.assertRegex(fingerprint, re.compile(r"[0-9a-f]{64}\Z"))
        return fingerprint

    def test_packet_counter_changes_are_ignored(self) -> None:
        before = ruleset_fixture()
        after = copy.deepcopy(before)
        counter = after["nftables"][3]["rule"]["expr"][2]["counter"]
        counter["packets"] = 9001
        self.assertEqual(self.snapshot(before), self.snapshot(after))

    def test_byte_counter_changes_are_ignored(self) -> None:
        before = ruleset_fixture()
        after = copy.deepcopy(before)
        counter = after["nftables"][3]["rule"]["expr"][2]["counter"]
        counter["bytes"] = 987654321
        self.assertEqual(self.snapshot(before), self.snapshot(after))

    def test_rule_handle_changes_are_ignored(self) -> None:
        before = ruleset_fixture()
        after = copy.deepcopy(before)
        after["nftables"][3]["rule"]["handle"] = 91
        self.assertEqual(self.snapshot(before), self.snapshot(after))

    def test_table_handle_changes_are_ignored(self) -> None:
        before = ruleset_fixture()
        after = copy.deepcopy(before)
        after["nftables"][1]["table"]["handle"] = 71
        self.assertEqual(self.snapshot(before), self.snapshot(after))

    def test_chain_handle_changes_are_ignored(self) -> None:
        before = ruleset_fixture()
        after = copy.deepcopy(before)
        after["nftables"][2]["chain"]["handle"] = 81
        self.assertEqual(self.snapshot(before), self.snapshot(after))

    def test_live_reboot_handle_renumbering_is_ignored(self) -> None:
        before = ruleset_fixture()
        after = copy.deepcopy(before)
        after["nftables"][1]["table"]["handle"] = 6
        after["nftables"][2]["chain"]["handle"] = 17
        after["nftables"][3]["rule"]["handle"] = 28
        after["nftables"][4]["rule"]["handle"] = 29
        self.assertEqual(self.snapshot(before), self.snapshot(after))

    def test_non_counter_packet_or_byte_fields_remain_semantic(self) -> None:
        before = ruleset_fixture()
        after = copy.deepcopy(before)
        before["nftables"].append({"quota": {"bytes": 1024, "used": 10}})
        after["nftables"].append({"quota": {"bytes": 2048, "used": 10}})
        self.assertNotEqual(self.snapshot(before), self.snapshot(after))

    def test_every_project_ruleset_semantic_remains_significant(self) -> None:
        baseline = ruleset_fixture()
        changes = {
            "table_family": lambda value: value["nftables"][1]["table"].update(family="ip"),
            "table_name": lambda value: value["nftables"][1]["table"].update(name="other"),
            "chain_name": lambda value: value["nftables"][2]["chain"].update(name="input"),
            "chain_type": lambda value: value["nftables"][2]["chain"].update(type="nat"),
            "chain_hook": lambda value: value["nftables"][2]["chain"].update(hook="input"),
            "chain_priority": lambda value: value["nftables"][2]["chain"].update(prio=10),
            "chain_policy": lambda value: value["nftables"][2]["chain"].update(policy="accept"),
            "interface_match": lambda value: value["nftables"][3]["rule"]["expr"][0]["match"].update(right="eth9"),
            "rule_address_match": lambda value: value["nftables"][4]["rule"]["expr"][0]["match"].update(right="203.0.113.0/24"),
            "verdict": lambda value: value["nftables"][3]["rule"]["expr"].__setitem__(3, {"accept": None}),
            "nat": lambda value: value["nftables"][4]["rule"]["expr"][2]["snat"].update(addr="192.0.2.3"),
            "mss": lambda value: value["nftables"][4]["rule"]["expr"][1]["mangle"].update(value=1280),
            "comment": lambda value: value["nftables"][4]["rule"].update(comment="CHANGED"),
        }
        baseline_fingerprint = self.snapshot(baseline)
        for name, mutate in changes.items():
            with self.subTest(name=name):
                changed = copy.deepcopy(baseline)
                mutate(changed)
                self.assertNotEqual(baseline_fingerprint, self.snapshot(changed))

    def test_malformed_or_duplicate_json_is_rejected(self) -> None:
        invalid = [b"{", b'{"nftables":[],"nftables":[]}']
        for payload in invalid:
            with self.subTest(payload=payload):
                completed = subprocess.run(
                    [sys.executable, "-I", str(SNAPSHOT_TOOL)],
                    input=payload,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                    timeout=5,
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertEqual(completed.stdout, b"")


if __name__ == "__main__":
    unittest.main(verbosity=2)
