#!/usr/bin/python3 -I
"""Strict fixed-path launcher for the production dashboard service."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import ipaddress
import os
from pathlib import Path
import stat
import sys
from typing import Sequence


APPLICATION_ROOT = Path("/opt/warp-egress-dashboard/app")
CONFIG_PATH = Path("/etc/warp-egress-dashboard/dashboard.env")
MAX_CONFIG_BYTES = 4096
CONFIG_KEYS = {"DASHBOARD_LISTEN", "DASHBOARD_PORT"}


class ConfigError(RuntimeError):
    """The deployment configuration is missing, malformed, or unsafe."""


@dataclass(frozen=True)
class DashboardConfig:
    listen: str
    port: int


def _read_config(path: Path, *, require_trusted_metadata: bool) -> str:
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0 or metadata.st_size > MAX_CONFIG_BYTES:
            raise ConfigError("dashboard configuration metadata is unsafe")
        if require_trusted_metadata and (
            metadata.st_uid != 0
            or metadata.st_gid != 0
            or stat.S_IMODE(metadata.st_mode) & 0o022
        ):
            raise ConfigError("dashboard configuration ownership or mode is unsafe")
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_dev != metadata.st_dev
                or opened.st_ino != metadata.st_ino
                or opened.st_size != metadata.st_size
            ):
                raise ConfigError("dashboard configuration changed while opening")
            payload = os.read(descriptor, MAX_CONFIG_BYTES + 1)
        finally:
            os.close(descriptor)
        if len(payload) != metadata.st_size:
            raise ConfigError("dashboard configuration changed while reading")
        return payload.decode("ascii", errors="strict")
    except ConfigError:
        raise
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError("dashboard configuration is unavailable or malformed") from exc


def load_config(path: Path, *, require_trusted_metadata: bool = False) -> DashboardConfig:
    values: dict[str, str] = {}
    for line in _read_config(path, require_trusted_metadata=require_trusted_metadata).splitlines():
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ConfigError("dashboard configuration line is malformed")
        key, value = line.split("=", 1)
        if key not in CONFIG_KEYS or key in values or not value or value.strip() != value:
            raise ConfigError("dashboard configuration field is invalid")
        values[key] = value
    if set(values) != CONFIG_KEYS:
        raise ConfigError("dashboard configuration fields are incomplete")

    listen = values["DASHBOARD_LISTEN"]
    try:
        address = ipaddress.ip_address(listen)
    except ValueError as exc:
        raise ConfigError("DASHBOARD_LISTEN must be one explicit IPv4 address") from exc
    if (
        type(address) is not ipaddress.IPv4Address
        or address.is_unspecified
        or address.is_multicast
        or address == ipaddress.IPv4Address("255.255.255.255")
        or (address.is_loopback and address != ipaddress.IPv4Address("127.0.0.1"))
    ):
        raise ConfigError("DASHBOARD_LISTEN must be loopback or one explicit management IPv4")

    port_text = values["DASHBOARD_PORT"]
    if not port_text.isascii() or not port_text.isdecimal():
        raise ConfigError("DASHBOARD_PORT must be a decimal TCP port")
    port = int(port_text, 10)
    if not 1 <= port <= 65535:
        raise ConfigError("DASHBOARD_PORT must be between 1 and 65535")
    return DashboardConfig(str(address), port)


def server_arguments(config: DashboardConfig) -> tuple[str, str, str, str]:
    return ("--listen", config.listen, "--port", str(config.port))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Launch the WARP read-only dashboard from trusted configuration")
    parser.add_argument("--check-config", type=Path, metavar="PATH")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.check_config is not None:
            config = load_config(arguments.check_config)
            print(f"DASHBOARD_LISTEN={config.listen}")
            print(f"DASHBOARD_PORT={config.port}")
            return 0
        config = load_config(CONFIG_PATH, require_trusted_metadata=True)
    except ConfigError as exc:
        print(f"DASHBOARD_CONFIG_INVALID: {exc}", file=sys.stderr)
        return 2

    sys.path.insert(0, str(APPLICATION_ROOT))
    from web.dashboard.server import main as server_main

    return server_main(server_arguments(config))


if __name__ == "__main__":
    raise SystemExit(main())
