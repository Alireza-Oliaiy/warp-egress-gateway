"""Fixed-path management binding; no environment, DNS, or request-derived address."""
from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

DASHBOARD = "etc/warp-egress-dashboard/dashboard.env"
GATEWAY = "etc/warp-egress-gateway/warp-gateway.env"
PROJECTION = "etc/warp-egress-admin-console/network.json"
PORT = 8788
MAX_CONFIG = 4096
MAX_GATEWAY = 65536
MAX_ADDRESS_OUTPUT = 65536
INTERFACE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}", re.ASCII)


class NetworkConfigError(RuntimeError):
    """A trusted setting or local observation is unavailable, ambiguous, or unsafe."""


def management_ipv4(value: str) -> str:
    if type(value) is not str:
        raise NetworkConfigError("management address must be text")
    try:
        address = ipaddress.IPv4Address(value)
    except (ValueError, TypeError) as exc:
        raise NetworkConfigError("one explicit management IPv4 is required") from exc
    if (address.is_unspecified or address.is_loopback or address.is_multicast
            or address.is_link_local or address.is_reserved):
        raise NetworkConfigError("unsafe management address")
    return str(address)


def _interface(value: str) -> str:
    if type(value) is not str or not INTERFACE.fullmatch(value) or value == "lo":
        raise NetworkConfigError("invalid interface role")
    return value


@dataclass(frozen=True)
class ManagementConfig:
    address: str
    uplink_if: str
    transit_if: str

    def __post_init__(self):
        management_ipv4(self.address)
        if _interface(self.uplink_if) == _interface(self.transit_if):
            raise NetworkConfigError("interface roles must be distinct")

    @property
    def host(self):
        return f"{self.address}:{PORT}"

    @property
    def origin(self):
        return f"http://{self.host}"

    def serialize(self):
        return json.dumps({"address": self.address, "uplink_if": self.uplink_if,
                           "transit_if": self.transit_if},
                          sort_keys=True, separators=(",", ":")) + "\n"


def _read(root, relative, maximum, uid, gid):
    """Walk trusted directory descriptors; never follow file or parent symlinks."""
    descriptors = []
    try:
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(directory)
        for component in Path(relative).parts[:-1]:
            directory = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=directory)
            descriptors.append(directory)
            metadata = os.fstat(directory)
            if (metadata.st_uid != uid or metadata.st_gid != gid
                    or stat.S_IMODE(metadata.st_mode) & 0o022):
                raise NetworkConfigError("unsafe configuration directory")
        descriptor = os.open(Path(relative).name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory)
        descriptors.append(descriptor)
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != uid or before.st_gid != gid
                or stat.S_IMODE(before.st_mode) & 0o022 or not 0 < before.st_size <= maximum):
            raise NetworkConfigError("unsafe configuration metadata")
        raw = os.read(descriptor, maximum + 1)
        after = os.fstat(descriptor)
        if (len(raw) != before.st_size or before.st_mtime_ns != after.st_mtime_ns
                or before.st_ctime_ns != after.st_ctime_ns):
            raise NetworkConfigError("configuration changed during read")
        return raw.decode("ascii")
    except (OSError, UnicodeError) as exc:
        raise NetworkConfigError("trusted configuration unavailable") from exc
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _dashboard_address(root, uid, gid):
    values = {}
    for line in _read(root, DASHBOARD, MAX_CONFIG, uid, gid).splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if (not separator or key not in {"DASHBOARD_LISTEN", "DASHBOARD_PORT"}
                or key in values or not value or value.strip() != value):
            raise NetworkConfigError("invalid Dashboard configuration")
        values[key] = value
    if set(values) != {"DASHBOARD_LISTEN", "DASHBOARD_PORT"}:
        raise NetworkConfigError("incomplete Dashboard configuration")
    port = values["DASHBOARD_PORT"]
    if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise NetworkConfigError("invalid Dashboard port")
    return management_ipv4(values["DASHBOARD_LISTEN"])


def _roles(root, uid, gid):
    # Never source the shell file. Only these role declarations are interpreted;
    # no other installation settings are copied into the public projection.
    roles = {}
    required = {"UPLINK_IF", "TRANSIT_IF", "WARP_IF"}
    for line in _read(root, GATEWAY, MAX_GATEWAY, uid, gid).splitlines():
        key, separator, value = line.partition("=")
        if key.strip() not in required:
            continue
        if not separator or key in roles or key != key.strip():
            raise NetworkConfigError("ambiguous gateway roles")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        roles[key] = _interface(value)
    if set(roles) != required or len(set(roles.values())) != 3:
        raise NetworkConfigError("missing or conflicting gateway roles")
    return roles


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise NetworkConfigError("duplicate JSON field")
        result[key] = value
    return result


def _json(raw):
    try:
        return json.loads(raw, object_pairs_hook=_pairs, parse_constant=_invalid_constant)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise NetworkConfigError("invalid JSON observation") from exc


def _invalid_constant(_value):
    raise NetworkConfigError("invalid JSON constant")


def read_addresses(interface):
    _interface(interface)
    try:
        result = subprocess.run(
            ["/usr/sbin/ip", "-j", "-4", "address", "show", "dev", interface],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"},
            timeout=3, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise NetworkConfigError("local address inspection failed") from exc
    if result.returncode != 0 or not 0 < len(result.stdout) <= MAX_ADDRESS_OUTPUT:
        raise NetworkConfigError("local address inspection failed")
    return _json(result.stdout)


def _addresses(observation, interface):
    if (type(observation) is not list or len(observation) != 1
            or type(observation[0]) is not dict or observation[0].get("ifname") != interface
            or type(observation[0].get("addr_info")) is not list):
        raise NetworkConfigError("ambiguous interface observation")
    found = []
    for info in observation[0]["addr_info"]:
        if (type(info) is not dict or info.get("family") != "inet"
                or type(info.get("local")) is not str or type(info.get("prefixlen")) is not int
                or not 0 <= info["prefixlen"] <= 32 or type(info.get("scope")) is not str):
            raise NetworkConfigError("malformed address observation")
        try:
            address = ipaddress.IPv4Address(info["local"])
        except ValueError as exc:
            raise NetworkConfigError("malformed local IPv4") from exc
        found.append((str(address), info["scope"]))
    return found


def _verify(config, observe):
    uplink = _addresses(observe(config.uplink_if), config.uplink_if)
    transit = _addresses(observe(config.transit_if), config.transit_if)
    if ([address for address, scope in uplink if scope == "global"] != [config.address]
            or any(address == config.address for address, _ in transit)):
        raise NetworkConfigError("management address is absent, ambiguous, or transit")
    return config


def resolve_install(*, root=Path("/"), observe=read_addresses, required_uid=0, required_gid=0):
    address = _dashboard_address(root, required_uid, required_gid)
    roles = _roles(root, required_uid, required_gid)
    return _verify(ManagementConfig(address, roles["UPLINK_IF"], roles["TRANSIT_IF"]), observe)


def load_runtime_config(*, root=Path("/"), observe=read_addresses, required_uid=0, required_gid=0):
    value = _json(_read(root, PROJECTION, MAX_CONFIG, required_uid, required_gid))
    if type(value) is not dict or set(value) != {"address", "uplink_if", "transit_if"}:
        raise NetworkConfigError("invalid management projection")
    config = ManagementConfig(**value)
    if config.address != _dashboard_address(root, required_uid, required_gid):
        raise NetworkConfigError("management configuration changed; rerun Admin installer")
    return _verify(config, observe)


def main():
    if sys.argv[1:] != ["--resolve"] or os.geteuid() != 0:
        return 64
    try:
        print(resolve_install().serialize(), end="")
    except NetworkConfigError:
        print("ADMIN_NETWORK_INVALID", file=sys.stderr)
        return 78
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
