#!/usr/bin/env python3
"""Management selection uses trusted configuration and read-only local evidence."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from admin import network


def addresses(interface, address):
    return [{"ifname": interface, "addr_info": [
        {"family": "inet", "local": address, "prefixlen": 24, "scope": "global"}
    ]}]


class ManagementNetworkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dashboard = self.root / "etc/warp-egress-dashboard/dashboard.env"
        self.gateway = self.root / "etc/warp-egress-gateway/warp-gateway.env"
        self.projection = self.root / "etc/warp-egress-admin-console/network.json"
        for path in (self.dashboard, self.gateway, self.projection):
            path.parent.mkdir(parents=True, exist_ok=True)
        self.gateway.write_text('UPLINK_IF="ens160"\nTRANSIT_IF="ens192"\nWARP_IF="warp0"\n')
        self.gateway.chmod(0o600)
        self.configure("172.21.31.5")

    def configure(self, address):
        self.dashboard.write_text(f"DASHBOARD_LISTEN={address}\nDASHBOARD_PORT=8787\n")
        self.dashboard.chmod(0o644)
        self.observed = {
            "ens160": addresses("ens160", address),
            "ens192": addresses("ens192", "10.1.1.222"),
        }

    def observe(self, interface):
        return self.observed[interface]

    def resolve(self):
        return network.resolve_install(root=self.root, observe=self.observe,
                                       required_uid=os.getuid(), required_gid=os.getgid())

    def runtime(self):
        return network.load_runtime_config(root=self.root, observe=self.observe,
                                           required_uid=os.getuid(), required_gid=os.getgid())

    def save_projection(self):
        config = self.resolve()
        self.projection.write_text(config.serialize())
        self.projection.chmod(0o644)
        return config

    def test_cc_and_hq_are_resolved_without_site_constants(self):
        for address in ("172.21.31.5", "172.20.31.5"):
            with self.subTest(address=address):
                self.configure(address)
                config = self.save_projection()
                self.assertEqual(config.address, address)
                self.assertEqual(config.host, f"{address}:8788")
                self.assertEqual(config.origin, f"http://{address}:8788")
                self.assertEqual(self.runtime(), config)
        source = (ROOT / "admin/network.py").read_text()
        for address in ("172.21.31.5", "172.20.31.5", "10.1.1.222"):
            self.assertNotIn(address, source)

    def test_invalid_address_classes_fail_closed(self):
        for value in ("0.0.0.0", "127.0.0.1", "127.2.3.4", "::1", "2001:db8::1",
                      "*", "bad", "172.21.31.5,172.20.31.5", "172.21.31.5/24",
                      "::", "169.254.1.1", "224.0.0.1", "255.255.255.255", "localhost"):
            with self.subTest(value=value):
                self.configure(value)
                with self.assertRaises(network.NetworkConfigError):
                    self.resolve()

    def test_missing_duplicate_unknown_or_malformed_dashboard_configuration(self):
        for content in ("", "DASHBOARD_PORT=8787\n",
                        "DASHBOARD_LISTEN=172.21.31.5\nDASHBOARD_PORT=8787\nDASHBOARD_LISTEN=172.20.31.5\n",
                        "DASHBOARD_LISTEN=172.21.31.5\nDASHBOARD_PORT=8787\nADMIN_LISTEN=1.2.3.4\n",
                        "DASHBOARD_LISTEN=172.21.31.5\nDASHBOARD_PORT=bad\n", "x" * 4097):
            with self.subTest(content=content):
                self.dashboard.write_text(content)
                with self.assertRaises(network.NetworkConfigError):
                    self.resolve()
        self.dashboard.unlink()
        with self.assertRaises(network.NetworkConfigError):
            self.resolve()

    def test_trusted_interface_roles_are_exact_and_distinct(self):
        for content in ('UPLINK_IF="ens160"\n', 'UPLINK_IF="../bad"\nTRANSIT_IF="ens192"\nWARP_IF="warp0"\n',
                        'UPLINK_IF="ens160"\nTRANSIT_IF="ens160"\nWARP_IF="warp0"\n',
                        'UPLINK_IF="ens160"\nTRANSIT_IF="ens192"\nWARP_IF="ens160"\n',
                        'UPLINK_IF="ens160"\nUPLINK_IF="ens161"\nTRANSIT_IF="ens192"\nWARP_IF="warp0"\n'):
            with self.subTest(content=content):
                self.gateway.write_text(content)
                with self.assertRaises(network.NetworkConfigError):
                    self.resolve()

    def test_transit_missing_wrong_or_ambiguous_live_addresses_fail(self):
        good = addresses("ens160", "172.21.31.5")
        for bad in ([], {}, addresses("wrong", "172.21.31.5"),
                    addresses("ens160", "172.21.31.6"), good + good,
                    [{"ifname": "ens160", "addr_info": good[0]["addr_info"] * 2}],
                    [{"ifname": "ens160", "addr_info": [{"local": "172.21.31.5"}]}]):
            with self.subTest(bad=bad):
                self.observed["ens160"] = bad
                with self.assertRaises(network.NetworkConfigError):
                    self.resolve()
        self.observed["ens160"] = good
        self.observed["ens192"] = addresses("ens192", "172.21.31.5")
        with self.assertRaises(network.NetworkConfigError):
            self.resolve()

    def test_unsafe_file_and_parent_metadata_rejected(self):
        for path in (self.dashboard, self.gateway):
            original = path.stat().st_mode & 0o777
            path.chmod(0o666)
            with self.assertRaises(network.NetworkConfigError):
                self.resolve()
            path.chmod(original)
            path.parent.chmod(0o777)
            with self.assertRaises(network.NetworkConfigError):
                self.resolve()
            path.parent.chmod(0o755)
        with self.assertRaises(network.NetworkConfigError):
            network.resolve_install(root=self.root, observe=self.observe,
                                    required_uid=os.getuid() + 1, required_gid=os.getgid())
        with self.assertRaises(network.NetworkConfigError):
            network.resolve_install(root=self.root, observe=self.observe,
                                    required_uid=os.getuid(), required_gid=os.getgid() + 1)
        self.dashboard.rename(self.dashboard.with_suffix(".real"))
        self.dashboard.symlink_to(self.dashboard.with_suffix(".real"))
        with self.assertRaises(network.NetworkConfigError):
            self.resolve()

    def test_runtime_revalidates_projection_dashboard_and_live_membership(self):
        self.save_projection()
        self.observed["ens160"] = addresses("ens160", "172.21.31.6")
        with self.assertRaises(network.NetworkConfigError):
            self.runtime()
        self.configure("172.20.31.5")
        with self.assertRaises(network.NetworkConfigError):
            self.runtime()
        self.save_projection()
        for text in ('{}', '[]', '{"address":"x","address":"y"}', 'not-json',
                     self.projection.read_text().replace('"uplink_if"', '"unknown"')):
            self.projection.write_text(text)
            with self.assertRaises(network.NetworkConfigError):
                self.runtime()
        self.save_projection()
        self.projection.chmod(0o666)
        with self.assertRaises(network.NetworkConfigError):
            self.runtime()

    def test_environment_cannot_override_trusted_address(self):
        with mock.patch.dict(os.environ, {"ADMIN_LISTEN": "0.0.0.0",
                                         "DASHBOARD_LISTEN": "127.0.0.1",
                                         "RECOVERY_EVIDENCE": "/tmp"}):
            self.assertEqual(self.save_projection(), self.runtime())

    def test_projection_values_and_parent_symlinks_are_not_trusted(self):
        good = json.loads(self.save_projection().serialize())
        for field, value in (("address", 1), ("address", None), ("uplink_if", []),
                             ("transit_if", "ens160"), ("address", "127.0.0.1")):
            with self.subTest(field=field, value=value):
                self.projection.write_text(json.dumps({**good, field: value}))
                with self.assertRaises(network.NetworkConfigError):
                    self.runtime()
        self.save_projection()
        self.projection.rename(self.projection.with_suffix(".real"))
        self.projection.symlink_to(self.projection.with_suffix(".real"))
        with self.assertRaises(network.NetworkConfigError):
            self.runtime()
        original = self.dashboard.parent
        moved = original.with_name(original.name + "-real")
        original.rename(moved)
        original.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(network.NetworkConfigError):
            self.resolve()

    def test_non_global_and_malformed_transit_observations_fail_closed(self):
        self.observed["ens160"][0]["addr_info"][0]["scope"] = "host"
        with self.assertRaises(network.NetworkConfigError):
            self.resolve()
        self.configure("172.21.31.5")
        for bad in ([], [{"ifname": "ens192", "addr_info": "bad"}],
                    addresses("ens192", "not-an-address")):
            self.observed["ens192"] = bad
            with self.assertRaises(network.NetworkConfigError):
                self.resolve()

    def test_ip_command_is_fixed_read_only_bounded_and_rejects_bad_json(self):
        good = json.dumps(addresses("ens160", "172.21.31.5")).encode()
        with mock.patch.object(network.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, good, b"")
            self.assertEqual(network.read_addresses("ens160"), json.loads(good))
            self.assertEqual(run.call_args.args[0],
                             ["/usr/sbin/ip", "-j", "-4", "address", "show", "dev", "ens160"])
            self.assertLessEqual(run.call_args.kwargs["timeout"], 5)
            for raw in (b"bad", b'[{"ifname":"ens160","ifname":"ens160"}]', b"x" * 65537):
                run.return_value = subprocess.CompletedProcess([], 0, raw, b"")
                with self.assertRaises(network.NetworkConfigError):
                    network.read_addresses("ens160")
            run.return_value = subprocess.CompletedProcess([], 1, good, b"")
            with self.assertRaises(network.NetworkConfigError):
                network.read_addresses("ens160")
            run.side_effect = subprocess.TimeoutExpired("ip", 3)
            with self.assertRaises(network.NetworkConfigError):
                network.read_addresses("ens160")


if __name__ == "__main__":
    unittest.main()
