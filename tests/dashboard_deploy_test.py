#!/usr/bin/env python3
"""Behavioral and contract tests for packaged dashboard deployment assets."""

from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
DEPLOY = ROOT / "web" / "dashboard" / "deploy"


class DeploymentConfigTests(unittest.TestCase):
    def write_config(self, directory: Path, content: str) -> Path:
        path = directory / "dashboard.env"
        path.write_text(content, encoding="ascii")
        return path

    def test_accepts_exact_loopback_and_management_ipv4_contracts(self) -> None:
        from web.dashboard.deploy.launcher import DashboardConfig, load_config

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            loopback = self.write_config(
                directory,
                "DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_PORT=8787\n",
            )
            self.assertEqual(load_config(loopback), DashboardConfig("127.0.0.1", 8787))
            management = self.write_config(
                directory,
                "# Explicit management listener\n\n"
                "DASHBOARD_LISTEN=192.0.2.10\nDASHBOARD_PORT=9443\n",
            )
            self.assertEqual(load_config(management), DashboardConfig("192.0.2.10", 9443))

    def test_rejects_wildcard_invalid_port_and_non_contract_syntax(self) -> None:
        from web.dashboard.deploy.launcher import ConfigError, load_config

        invalid = {
            "wildcard": "DASHBOARD_LISTEN=0.0.0.0\nDASHBOARD_PORT=8787\n",
            "ipv6": "DASHBOARD_LISTEN=::1\nDASHBOARD_PORT=8787\n",
            "hostname": "DASHBOARD_LISTEN=localhost\nDASHBOARD_PORT=8787\n",
            "other_loopback": "DASHBOARD_LISTEN=127.0.0.2\nDASHBOARD_PORT=8787\n",
            "port_zero": "DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_PORT=0\n",
            "port_large": "DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_PORT=65536\n",
            "port_text": "DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_PORT=eight\n",
            "unknown": "DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_PORT=8787\nEXTRA=yes\n",
            "duplicate": "DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_LISTEN=192.0.2.10\nDASHBOARD_PORT=8787\n",
            "missing": "DASHBOARD_LISTEN=127.0.0.1\n",
            "malformed": "DASHBOARD_LISTEN 127.0.0.1\nDASHBOARD_PORT=8787\n",
            "quoted": "DASHBOARD_LISTEN='127.0.0.1'\nDASHBOARD_PORT=8787\n",
        }
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name, content in invalid.items():
                with self.subTest(name=name):
                    path = self.write_config(directory, content)
                    with self.assertRaises(ConfigError):
                        load_config(path)

    def test_rejects_oversized_non_ascii_symlink_and_writable_trusted_config(self) -> None:
        from web.dashboard.deploy.launcher import ConfigError, load_config

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            oversized = self.write_config(
                directory,
                "DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_PORT=8787\n" + "#" * 4097,
            )
            with self.assertRaises(ConfigError):
                load_config(oversized)
            non_ascii = directory / "non-ascii.env"
            non_ascii.write_bytes(b"DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_PORT=8787\n#\xff\n")
            with self.assertRaises(ConfigError):
                load_config(non_ascii)
            target = self.write_config(
                directory,
                "DASHBOARD_LISTEN=127.0.0.1\nDASHBOARD_PORT=8787\n",
            )
            symlink = directory / "symlink.env"
            symlink.symlink_to(target)
            with self.assertRaises(ConfigError):
                load_config(symlink, require_trusted_metadata=True)
            os.chmod(target, 0o666)
            with self.assertRaises(ConfigError):
                load_config(target, require_trusted_metadata=True)

    def test_builds_fixed_server_arguments_without_shell(self) -> None:
        from web.dashboard.deploy.launcher import DashboardConfig, server_arguments

        self.assertEqual(
            server_arguments(DashboardConfig("192.0.2.10", 8787)),
            ("--listen", "192.0.2.10", "--port", "8787"),
        )


class DeploymentAssetTests(unittest.TestCase):
    def test_required_deployment_assets_exist(self) -> None:
        required = {
            "install.sh",
            "uninstall.sh",
            "dashboard.env.example",
            "launcher.py",
            "__init__.py",
            "systemd/warp-dashboard.service",
            "systemd/warp-dashboard-collector.service",
            "systemd/warp-dashboard-collector.timer",
            "tmpfiles/warp-egress-dashboard.conf",
        }
        self.assertEqual(
            {
                path.relative_to(DEPLOY).as_posix()
                for path in DEPLOY.rglob("*")
                if path.is_file() and "__pycache__" not in path.parts
            },
            required,
        )

    def test_tmpfiles_and_units_encode_the_production_boundaries(self) -> None:
        tmpfiles = (DEPLOY / "tmpfiles" / "warp-egress-dashboard.conf").read_text(encoding="ascii")
        collector = (DEPLOY / "systemd" / "warp-dashboard-collector.service").read_text(encoding="ascii")
        timer = (DEPLOY / "systemd" / "warp-dashboard-collector.timer").read_text(encoding="ascii")
        web = (DEPLOY / "systemd" / "warp-dashboard.service").read_text(encoding="ascii")
        self.assertEqual(tmpfiles, "d /run/warp-egress-dashboard 0750 root warp-web -\n")
        self.assertIn("Type=oneshot", collector)
        self.assertIn("User=root", collector)
        self.assertIn("WorkingDirectory=/opt/warp-egress-dashboard/app", collector)
        self.assertIn("ExecStart=/usr/bin/python3 -m web.dashboard.collector", collector)
        self.assertIn("Environment=PYTHONDONTWRITEBYTECODE=1", collector)
        self.assertIn("OnBootSec=5s", timer)
        self.assertIn("OnUnitActiveSec=15s", timer)
        self.assertIn("Unit=warp-dashboard-collector.service", timer)
        self.assertIn("User=warp-web", web)
        self.assertIn("Group=warp-web", web)
        self.assertIn(
            "ExecStart=/usr/bin/python3 -I /opt/warp-egress-dashboard/app/web/dashboard/deploy/launcher.py",
            web,
        )
        self.assertIn("NoNewPrivileges=true", web)
        self.assertIn("PrivateTmp=true", web)
        self.assertIn("CapabilityBoundingSet=", web)
        self.assertIn("Environment=PYTHONDONTWRITEBYTECODE=1", web)
        self.assertNotIn("EnvironmentFile", web)
        self.assertNotIn("bash -c", web)

    def test_deployment_scripts_contain_no_gateway_or_privilege_escalation_paths(self) -> None:
        scripts = "\n".join(
            (DEPLOY / name).read_text(encoding="utf-8")
            for name in ("install.sh", "uninstall.sh")
        )
        for forbidden in (
            "web/helper",
            "web/sudoers",
            "/etc/sudoers",
            "ip rule",
            "ip route",
            " nft ",
            " wg ",
            "wg-quick@",
            "warp-gateway.service",
            "warp-gateway-firewall.service",
            "/run/warp-egress-gateway",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, scripts)


if __name__ == "__main__":
    unittest.main(verbosity=2)
