#!/usr/bin/env python3
"""Static deployment boundary tests for the Slice 1B Admin Console."""

from __future__ import annotations

from pathlib import Path
import configparser
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "admin" / "deploy"


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
