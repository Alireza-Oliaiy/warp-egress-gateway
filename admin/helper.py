#!/usr/bin/python3 -I
"""Fixed Admin observations and exclusive, missing-object-only routing repair."""

from __future__ import annotations

from dataclasses import dataclass
from contextlib import contextmanager
import base64
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import threading
import time
from typing import Protocol, Sequence
import uuid


INSTALLED_HELPER = Path("/usr/local/libexec/warp-egress-gateway/warp-admin-helper")
INSTALLED_PROTOCOL = Path("/usr/local/libexec/warp-egress-gateway/warp_admin_protocol.py")


def validate_installed_metadata(
    helper_path: Path = INSTALLED_HELPER,
    protocol_path: Path = INSTALLED_PROTOCOL,
    *,
    required_uid: int = 0,
    required_gid: int = 0,
    parents: Sequence[Path] | None = None,
) -> bool:
    """Validate the executable/import chain before loading project code."""

    try:
        helper_meta = helper_path.lstat()
        protocol_meta = protocol_path.lstat()
        if (
            not stat.S_ISREG(helper_meta.st_mode)
            or stat.S_IMODE(helper_meta.st_mode) != 0o755
            or helper_meta.st_uid != required_uid
            or helper_meta.st_gid != required_gid
            or not stat.S_ISREG(protocol_meta.st_mode)
            or stat.S_IMODE(protocol_meta.st_mode) != 0o644
            or protocol_meta.st_uid != required_uid
            or protocol_meta.st_gid != required_gid
        ):
            return False
        checked_parents = parents or (
            helper_path.parent,
            helper_path.parent.parent,
            helper_path.parent.parent.parent,
            helper_path.parent.parent.parent.parent,
            helper_path.parent.parent.parent.parent.parent,
        )
        for parent in checked_parents:
            metadata = parent.lstat()
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != required_uid
                or metadata.st_gid != required_gid
                or stat.S_IMODE(metadata.st_mode) & 0o022
            ):
                return False
        return True
    except OSError:
        return False


# The installed script validates its root-owned import chain before importing
# the shared project protocol. Package imports used by local tests do not claim
# to be the privileged executable.
if __name__ == "__main__":
    if os.geteuid() != 0:
        raise SystemExit(77)
    if Path(__file__) != INSTALLED_HELPER or not validate_installed_metadata():
        raise SystemExit(78)
    sys.path.insert(0, str(INSTALLED_HELPER.parent))

sys.dont_write_bytecode = True

try:  # Script deployment and package import deliberately share one source.
    from .protocol import (
        MAX_HELPER_INPUT_BYTES,
        ProtocolError,
        encode_response,
        loads_request,
        loads_exact_json,
        unknown_evidence,
        validate_response,
    )
except ImportError:  # pragma: no cover - exercised by installed-script fixtures
    from warp_admin_protocol import (  # type: ignore[no-redef]
        MAX_HELPER_INPUT_BYTES,
        ProtocolError,
        encode_response,
        loads_request,
        loads_exact_json,
        unknown_evidence,
        validate_response,
    )


READONLY_BUNDLE = Path("/opt/warp-egress-admin-console/readonly/v2")
HEALTH_READONLY_PATH = str(READONLY_BUNDLE / "evaluate.py")
READONLY_FILES = (
    "evaluate.py", "health-readonly.sh", "common.sh", "routing.sh", "admin-lock.sh",
    "healthcheck-lib.sh", "observation-entrypoints.sh", "intent-state.sh", "intent-state.py",
)
GATEWAY_CONFIG = Path("/etc/warp-egress-gateway/warp-gateway.env")
VERSION_PATH = Path("/etc/warp-egress-gateway/VERSION")
LOGGER_PATH = "/usr/bin/logger"
FIXED_ENVIRONMENT = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME": "/root",
    "LANG": "C",
    "LC_ALL": "C",
}
OBSERVATION_TIMEOUT_SECONDS = 45.0
OBSERVATION_STDOUT_LIMIT = 4096
OBSERVATION_STDERR_LIMIT = 4096
MAX_VERSION_BYTES = 128
_SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")

_HEALTH_KEYS = frozenset(
    {
        "EVALUATION",
        "HEALTH",
        "reason",
        "wg",
        "direct",
        "direct_rc",
        "warp",
        "warp_rc",
        "route",
        "nft",
        "upstream",
        "services",
        "timers",
        "recovery",
    }
)
_TOKEN_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")


class HelperRuntimeError(RuntimeError):
    """The fixed observation primitive was unavailable, unsafe, or malformed."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


class ObservationRunner(Protocol):
    def run(self) -> CommandResult:
        """Execute the fixed official no-recovery evaluator."""


class AuditSink(Protocol):
    def emit(self, **fields: object) -> None:
        """Write one bounded sanitized event."""


class NullAudit:
    def emit(self, **_fields: object) -> None:
        return


def _kill_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except OSError:
            pass


def _bounded_process(
    argv: tuple[str, ...],
    *,
    timeout: float,
    stdout_limit: int,
    stderr_limit: int,
) -> CommandResult:
    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd="/",
            env=FIXED_ENVIRONMENT,
            close_fds=True,
            start_new_session=True,
        )
    except OSError as exc:
        raise HelperRuntimeError("observation_unavailable") from exc

    output = {"stdout": bytearray(), "stderr": bytearray()}
    overflow = threading.Event()

    def drain(name: str, stream: object, limit: int) -> None:
        while True:
            chunk = stream.read(4096)  # type: ignore[attr-defined]
            if not chunk:
                return
            remaining = limit + 1 - len(output[name])
            if remaining > 0:
                output[name].extend(chunk[:remaining])
            if len(output[name]) > limit or len(chunk) > remaining:
                overflow.set()

    threads = [
        threading.Thread(target=drain, args=("stdout", process.stdout, stdout_limit), daemon=True),
        threading.Thread(target=drain, args=("stderr", process.stderr, stderr_limit), daemon=True),
    ]
    for thread in threads:
        thread.start()
    deadline = time.monotonic() + timeout
    timed_out = False
    while process.poll() is None:
        if overflow.wait(0.01):
            _kill_process_group(process)
            break
        if time.monotonic() >= deadline:
            timed_out = True
            _kill_process_group(process)
            break
    try:
        returncode = process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        _kill_process_group(process)
        returncode = process.wait()
    for thread in threads:
        thread.join(timeout=2)
    if process.stdout is not None:
        process.stdout.close()
    if process.stderr is not None:
        process.stderr.close()
    if timed_out:
        raise HelperRuntimeError("operation_timeout")
    if overflow.is_set():
        raise HelperRuntimeError("observation_unavailable")
    return CommandResult(returncode, bytes(output["stdout"]), bytes(output["stderr"]))


def validate_readonly_metadata(
    bundle: Path = READONLY_BUNDLE,
    config: Path = GATEWAY_CONFIG,
    *,
    required_uid: int = 0,
    required_gid: int = 0,
    parents: Sequence[Path] | None = None,
) -> bool:
    """Gate the complete fixed executable/source/configuration chain, not Core.

    Parameters exist for isolated filesystem tests; production always calls this
    with no arguments. No request field or environment value selects a path.
    """
    try:
        checked_parents = ((bundle, *bundle.parents, *config.parents)
                           if parents is None else (bundle, *parents))
        for parent in checked_parents:
            info = parent.lstat()
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid != required_uid
                    or info.st_gid != required_gid or stat.S_IMODE(info.st_mode) & 0o022):
                return False
        if {path.name for path in bundle.iterdir()} != set(READONLY_FILES):
            return False
        for path in (*(bundle / name for name in READONLY_FILES), config):
            info = path.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != required_uid
                    or info.st_gid != required_gid):
                return False
            mode = stat.S_IMODE(info.st_mode)
            if path == config:
                if mode not in (0o600, 0o640, 0o644):
                    return False
            elif mode != (0o755 if path.name == "evaluate.py" else 0o644):
                return False
        return True
    except OSError:
        return False


class HealthReadonlyRunner:
    def run(self) -> CommandResult:
        if not validate_readonly_metadata():
            raise HelperRuntimeError("observation_unavailable")
        return _bounded_process(
            (HEALTH_READONLY_PATH,),
            timeout=OBSERVATION_TIMEOUT_SECONDS,
            stdout_limit=OBSERVATION_STDOUT_LIMIT,
            stderr_limit=OBSERVATION_STDERR_LIMIT,
        )


class RoutingRepair:
    """Fixed, missing-object-only transaction; the native flock inode is shared.

    Constructor substitutions are internal test seams, never stdin/argv/env.
    The installed helper constructs this with no arguments. No shell entrypoint
    is invoked, so no native entrypoint can recursively acquire our lock.
    """

    def __init__(self, *, root=Path("/"), required_uid=0, required_gid=0,
                 command=None, lock_timeout=3.0):
        self.root, self.uid, self.gid = root, required_uid, required_gid
        self.command = command or _bounded_process
        self.lock_timeout = lock_timeout
        self.deadline = 0.0

    def _metadata(self, descriptor, mode=None, directory=False):
        meta = os.fstat(descriptor)
        correct_type = stat.S_ISDIR(meta.st_mode) if directory else stat.S_ISREG(meta.st_mode)
        if (not correct_type or meta.st_uid != self.uid or meta.st_gid != self.gid
                or stat.S_IMODE(meta.st_mode) & 0o022
                or (mode is not None and stat.S_IMODE(meta.st_mode) != mode)):
            raise HelperRuntimeError("unsafe_precondition")
        return meta

    @contextmanager
    def _directory(self, relative):
        fds = []
        try:
            fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            fds.append(fd)
            self._metadata(fd, directory=True)
            for part in Path(relative).parts:
                fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                fds.append(fd)
                self._metadata(fd, directory=True)
            yield fd
        finally:
            for fd in reversed(fds):
                os.close(fd)

    def _read(self, relative, maximum=65536):
        with self._directory(str(Path(relative).parent)) as parent:
            fd = os.open(Path(relative).name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            try:
                before = self._metadata(fd)
                if not 0 < before.st_size <= maximum:
                    raise HelperRuntimeError("unsafe_precondition")
                raw = os.read(fd, maximum + 1)
                after = os.fstat(fd)
                if (len(raw) != before.st_size or before.st_mtime_ns != after.st_mtime_ns
                        or before.st_ctime_ns != after.st_ctime_ns):
                    raise HelperRuntimeError("unsafe_precondition")
                return raw
            finally:
                os.close(fd)

    @contextmanager
    def _exclusive(self):
        # Reuse the foundation's already-existing lock. Missing/unsafe metadata
        # fails closed; this action never repairs or substitutes lock files.
        with self._directory("run/warp-egress-gateway") as parent:
            self._metadata(parent, mode=0o700, directory=True)
            fd = os.open("admin-mutation.lock", os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            try:
                meta = self._metadata(fd, mode=0o600)
                if meta.st_nlink != 1:
                    raise HelperRuntimeError("unsafe_precondition")
                deadline = time.monotonic() + self.lock_timeout
                while True:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise HelperRuntimeError("mutation_lock_busy")
                        time.sleep(0.01)
                disk = os.stat("admin-mutation.lock", dir_fd=parent, follow_symlinks=False)
                if (disk.st_dev, disk.st_ino) != (meta.st_dev, meta.st_ino):
                    raise HelperRuntimeError("unsafe_precondition")
                self._metadata(fd, mode=0o600)
                yield parent
            finally:
                os.close(fd)

    @staticmethod
    def _assert(condition):
        if not condition:
            raise HelperRuntimeError("unsafe_precondition")

    @staticmethod
    def _assignments(raw, required):
        values = {}
        for line in raw.decode("ascii").splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            key, separator, _value = line.partition("=")
            if key.strip() not in required:
                if separator and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                    continue
                raise HelperRuntimeError("unsafe_precondition")
            match = re.fullmatch(r'''([A-Z][A-Z0-9_]*)=(?:"([^"$`\\]*)"|'([^'\n]*)'|([A-Za-z0-9_./:@+\-]*))''', line)
            if match is None or match[1] in values:
                raise HelperRuntimeError("unsafe_precondition")
            values[match[1]] = next(v for v in match.groups()[1:] if v is not None)
        if set(values) != required:
            raise HelperRuntimeError("unsafe_precondition")
        return values

    def _configuration(self):
        required = {"WARP_IF", "UPLINK_IF", "TRANSIT_IF", "ROUTING_TABLE_ID", "ROUTING_TABLE_NAME",
                    "SOURCE_RULE_PRIORITY", "INGRESS_RULE_PRIORITY"}
        values = self._assignments(self._read("etc/warp-egress-gateway/warp-gateway.env"), required)
        roles = [values[key] for key in ("WARP_IF", "UPLINK_IF", "TRANSIT_IF")]
        self._assert(len(set(roles)) == 3 and all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}", role) and role != "lo" for role in roles))
        table_id = values["ROUTING_TABLE_ID"]
        self._assert(re.fullmatch(r"[1-9][0-9]{0,9}", table_id) is not None
                     and int(table_id) <= 4294967295 and int(table_id) not in {253, 254, 255})
        for key, expected in (("ROUTING_TABLE_NAME", "warp_gateway"),
                              ("SOURCE_RULE_PRIORITY", "100"), ("INGRESS_RULE_PRIORITY", "110")):
            self._assert(values[key] == expected)
        projection = loads_exact_json(self._read("etc/warp-egress-admin-console/network.json", 4096), maximum=4096)
        self._assert(type(projection) is dict and set(projection) == {"address", "uplink_if", "transit_if"})
        dashboard = self._assignments(self._read("etc/warp-egress-dashboard/dashboard.env", 4096),
                                      {"DASHBOARD_LISTEN", "DASHBOARD_PORT"})
        self._assert(projection["address"] == dashboard["DASHBOARD_LISTEN"])
        self._assert(projection["uplink_if"] == roles[1] and projection["transit_if"] == roles[2])
        self._ipv4(projection["address"])
        return {key: values[key] for key in required} | {"management": projection["address"]}

    def _command(self, argv):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise HelperRuntimeError("operation_timeout")
        result = self.command(tuple(argv), timeout=min(2.0, remaining), stdout_limit=262144, stderr_limit=4096)
        if result.returncode != 0:
            raise HelperRuntimeError("unsafe_precondition")
        return result.stdout

    def _json(self, argv):
        return loads_exact_json(self._command(argv), maximum=262144)

    @staticmethod
    def _canonical(value):
        return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)

    @classmethod
    def _bag(cls, value):
        cls._assert(type(value) is list and len(value) <= 4096 and all(type(item) is dict for item in value))
        return sorted(cls._canonical(item) for item in value)

    @classmethod
    def _ipv4(cls, value):
        cls._assert(type(value) is str)
        address = ipaddress.IPv4Address(value)
        cls._assert(not (address.is_unspecified or address.is_loopback or address.is_multicast
                        or address.is_link_local or address.is_reserved))
        return str(address)

    def _addresses(self, config):
        addresses = {}
        for role in ("WARP_IF", "UPLINK_IF", "TRANSIT_IF"):
            interface = config[role]
            data = self._json(("/usr/sbin/ip", "-j", "-4", "address", "show", "dev", interface))
            self._assert(type(data) is list and len(data) == 1 and type(data[0]) is dict
                         and data[0].get("ifname") == interface and type(data[0].get("addr_info")) is list)
            observed = []
            for info in data[0]["addr_info"]:
                self._assert(type(info) is dict and info.get("family") == "inet"
                             and type(info.get("prefixlen")) is int and 0 <= info["prefixlen"] <= 32)
                observed.append((self._ipv4(info.get("local")), info["prefixlen"], info.get("scope")))
            addresses[role] = sorted(observed)
        self._assert(len(addresses["WARP_IF"]) == 1 and addresses["WARP_IF"][0][1:] == (32, "global"))
        self._assert(len(addresses["UPLINK_IF"]) == 1 and addresses["UPLINK_IF"][0][0] == config["management"]
                     and addresses["UPLINK_IF"][0][2] == "global")
        self._assert(all(ip != config["management"] for ip, _, _ in addresses["TRANSIT_IF"]))
        return addresses

    @staticmethod
    def _table(value, project_table):
        if type(value) is int:
            return value
        if type(value) is str:
            return {"warp_gateway": project_table, "main": 254, "local": 255, "default": 253}.get(value, int(value) if re.fullmatch(r"[1-9][0-9]{0,9}", value) else -1)
        return -1

    def _routing(self, rules, routes, config, source):
        self._bag(rules)
        self._bag(routes)
        missing, unrelated_rules, unrelated_routes = [], [], []
        table = int(config["ROUTING_TABLE_ID"])
        for priority in (100, 110):
            selected = [r for r in rules if r.get("priority") == priority]
            self._assert(len(selected) <= 1)
            if not selected:
                missing.append(priority)
                continue
            rule = selected[0]
            self._assert(set(rule) <= {"priority", "src", "dst", "iif", "table", "protocol", "type", "flags"}
                         and self._table(rule.get("table"), table) == table and rule.get("type", "unicast") == "unicast"
                         and rule.get("flags", []) == [] and rule.get("dst", "all") in {"all", "0.0.0.0/0"})
            if priority == 100:
                self._assert(rule.get("src") in {source, source + "/32"} and "iif" not in rule)
            else:
                self._assert(rule.get("src") == "all" and rule.get("iif") == config["TRANSIT_IF"])
        for rule in rules:
            self._assert(type(rule.get("priority")) is int)
            if rule["priority"] not in (100, 110):
                self._assert(self._table(rule.get("table"), table) != table)
                unrelated_rules.append(rule)
        defaults = []
        for route in routes:
            self._assert(type(route.get("dst")) is str)
            route_table = self._table(route.get("table", 254), table)
            self._assert(1 <= route_table <= 4294967295)
            # A WARP default misplaced in another table is not a missing-only repair.
            self._assert(not (route["dst"] == "default" and route.get("dev") == config["WARP_IF"] and route_table != table))
            if route_table == table and route["dst"] == "default":
                defaults.append(route)
            else:
                unrelated_routes.append(route)
        self._assert(len(defaults) <= 1)
        if not defaults:
            missing.append("default")
        else:
            route = defaults[0]
            self._assert(set(route) <= {"dst", "dev", "table", "type", "protocol", "scope", "flags", "prefsrc", "metric"}
                         and route.get("dev") == config["WARP_IF"] and route.get("type", "unicast") == "unicast"
                         and route.get("flags", []) == [] and route.get("prefsrc", source) == source)
        return missing, self._bag(unrelated_rules), self._bag(unrelated_routes)

    def _nft(self, config):
        document = self._json(("/usr/sbin/nft", "-j", "list", "table", "inet", "warp_gateway"))
        self._assert(type(document) is dict and set(document) == {"nftables"} and type(document["nftables"]) is list)
        objects = []
        for item in document["nftables"]:
            self._assert(type(item) is dict and len(item) == 1)
            kind, body = next(iter(item.items()))
            if kind == "metainfo":
                continue
            self._assert(kind in {"table", "chain", "rule"} and type(body) is dict)
            body = dict(body)
            body.pop("handle", None)
            if kind == "rule":
                self._assert(type(body.get("expr")) is list)
                body["expr"] = [{"counter": {}} if type(expr) is dict and set(expr) == {"counter"} else expr for expr in body["expr"]]
            objects.append({kind: body})
        chains = [item["chain"] for item in objects if "chain" in item and item["chain"].get("name") == "forward"]
        self._assert(len(chains) == 1)
        chain = chains[0]
        self._assert(all(chain.get(key) == value for key, value in {"family": "inet", "table": "warp_gateway", "hook": "forward", "type": "filter", "prio": 0}.items()))
        rules = [item["rule"] for item in objects if "rule" in item and item["rule"].get("chain") == "forward"]
        guards = [r for r in rules if r.get("comment") == "WARP_KILL_SWITCH"]
        self._assert(len(guards) == 1)
        guard = guards[0]
        self._assert(guard.get("family") == "inet" and guard.get("table") == "warp_gateway")
        expressions = [expr for expr in guard["expr"] if expr != {"counter": {}}]
        self._assert(expressions == [
            {"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": config["TRANSIT_IF"]}},
            {"match": {"op": "!=", "left": {"meta": {"key": "oifname"}}, "right": config["WARP_IF"]}},
            {"drop": None}])
        # A matching comment after an earlier accept/jump is not a safety proof.
        for preceding in rules[:rules.index(guard)]:
            expressions = [expr for expr in preceding["expr"] if expr != {"counter": {}}]
            self._assert(expressions and expressions[-1] == {"drop": None}
                         and all(type(expr) is dict and set(expr) == {"match"} for expr in expressions[:-1]))
        return self._canonical(objects)

    def _snapshot(self, config, parent):
        try:
            os.stat("intentional-disconnect.json", dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise HelperRuntimeError("unsafe_precondition")
        self._assert(self._configuration() == config)
        link = self._json(("/usr/sbin/ip", "-j", "-d", "link", "show", "dev", config["WARP_IF"]))
        self._assert(type(link) is list and len(link) == 1 and type(link[0]) is dict
                     and link[0].get("ifname") == config["WARP_IF"] and type(link[0].get("flags")) is list
                     and "UP" in link[0]["flags"] and type(link[0].get("linkinfo")) is dict
                     and link[0]["linkinfo"].get("info_kind") == "wireguard")
        addresses = self._addresses(config)
        source = addresses["WARP_IF"][0][0]
        rules = self._json(("/usr/sbin/ip", "-j", "-N", "-4", "rule", "show"))
        routes = self._json(("/usr/sbin/ip", "-j", "-N", "-4", "route", "show", "table", "all"))
        missing, other_rules, other_routes = self._routing(rules, routes, config, source)
        main = self._json(("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "main", "default"))
        self._bag(main)
        self._assert(len(main) == 1 and main[0].get("dst") == "default" and main[0].get("dev") == config["UPLINK_IF"])
        self._assert(main[0].get("type", "unicast") == "unicast" and "nexthops" not in main[0] and "nhid" not in main[0])
        # Read only public identity material. Never use wg showconf/dump/private-key.
        public = self._command(("/usr/bin/wg", "show", config["WARP_IF"], "public-key")).strip()
        self._assert(len(public) == 44 and len(base64.b64decode(public, validate=True)) == 32)
        peers = self._command(("/usr/bin/wg", "show", config["WARP_IF"], "peers")).splitlines()
        self._assert(len(peers) == 1 and len(peers[0]) == 44 and len(base64.b64decode(peers[0], validate=True)) == 32)
        endpoints = self._command(("/usr/bin/wg", "show", config["WARP_IF"], "endpoints")).splitlines()
        self._assert(len(endpoints) == 1 and endpoints[0].split(b"\t")[0] == peers[0]
                     and len(endpoints[0]) <= 256 and endpoints[0].count(b"\t") == 1)
        forwarding = self._command(("/usr/sbin/sysctl", "-n", "net.ipv4.ip_forward")).strip()
        self._assert(forwarding in {b"0", b"1"})
        lifecycle = {key: link[0].get(key) for key in ("ifindex", "ifname", "mtu", "flags", "linkinfo")}
        return missing, {"addresses": addresses, "main": self._bag(main), "rules": other_rules,
                         "routes": other_routes, "nft": self._nft(config), "link": lifecycle,
                         "public": public, "peers": peers, "endpoints": endpoints, "forwarding": forwarding}, source

    def run(self, request, *, version="unknown", completed=None):
        response = None
        try:
            with self._exclusive() as parent:
                self.deadline = time.monotonic() + 35.0
                attempted, verifying = False, False
                try:
                    config = self._configuration()
                    missing, before, source = self._snapshot(config, parent)
                    table = config["ROUTING_TABLE_ID"]
                    for obj in missing:
                        if obj == "default":
                            argv = ("/usr/sbin/ip", "-4", "route", "add", "default", "dev", config["WARP_IF"], "table", table)
                        elif obj == 100:
                            argv = ("/usr/sbin/ip", "-4", "rule", "add", "pref", "100", "from", source + "/32", "lookup", table)
                        else:
                            argv = ("/usr/sbin/ip", "-4", "rule", "add", "pref", "110", "iif", config["TRANSIT_IF"], "lookup", table)
                        attempted = True
                        self._command(argv)
                        verifying = True
                        pending, checkpoint, _ = self._snapshot(config, parent)
                        self._assert(before == checkpoint and obj not in pending)
                        verifying = False
                    verifying = True
                    remaining, after, _ = self._snapshot(config, parent)
                    self._assert(not remaining and before == after)
                    evidence = unknown_evidence(version=version)
                    evidence.update(wireguard="up", routing="ok", kill_switch="active")
                    response = validate_response(dict(protocol=1, request_id=request["request_id"], operation="repair-routing",
                                                      ok=True, result_code="ok", changed=bool(missing), state="degraded", evidence=evidence))
                except (HelperRuntimeError, OSError, ValueError, KeyError, TypeError) as exc:
                    code = ("operation_timeout" if isinstance(exc, HelperRuntimeError) and exc.code == "operation_timeout"
                            else "postcondition_failed" if verifying else "partial_mutation_failure" if attempted else "unsafe_precondition")
                    # Read-only best-effort failure inspection, still locked. No
                    # retry of writes, deletion, flush, rollback, or convergence.
                    if attempted and not verifying:
                        self.deadline = time.monotonic() + 5.0
                        try:
                            self._snapshot(config, parent)
                        except (HelperRuntimeError, OSError, ValueError, KeyError, TypeError):
                            pass
                    response = _failure_response(request, code, version=version)
                if completed is not None:
                    completed(response)  # audit completion is inside the same lock
                return response
        except (HelperRuntimeError, OSError) as exc:
            code = "mutation_lock_busy" if isinstance(exc, HelperRuntimeError) and exc.code == "mutation_lock_busy" else "unsafe_precondition"
            response = _failure_response(request, code, version=version)
            if completed is not None:
                completed(response)
            return response


class JournalAudit:
    """Emit fixed-field records without passing secrets or raw output."""

    _ALLOWED_STATES = frozenset({"requested", "started", "completed", "failed"})
    _RESULT_CODES = frozenset(
        {"pending", "ok", "evaluation_unhealthy", "mutation_lock_busy", "observation_unavailable", "operation_timeout",
         "unsafe_precondition", "partial_mutation_failure", "postcondition_failed"}
    )

    def emit(self, **fields: object) -> None:
        request_id = fields.get("request_id", "unavailable")
        action = fields.get("action", "invalid")
        state_name = fields.get("state", "failed")
        result_code = fields.get("result_code", "pending")
        duration_ms = fields.get("duration_ms", 0)
        if (
            type(request_id) is not str
            or not _canonical_uuid_text(request_id)
            or type(action) is not str
            or action not in {"status", "health", "repair-routing", "invalid"}
            or type(state_name) is not str
            or state_name not in self._ALLOWED_STATES
            or type(result_code) is not str
            or result_code not in self._RESULT_CODES
            or type(duration_ms) is not int
            or not 0 <= duration_ms <= 3_600_000
            or type(fields.get("changed", False)) is not bool
            or (fields.get("changed", False) and (action != "repair-routing" or result_code != "ok"))
        ):
            return
        message = (
            "WARP_ADMIN_HELPER protocol=1 "
            f"request_id={request_id} action={action} state={state_name} "
            f"duration_ms={duration_ms} result_code={result_code} changed={str(fields.get('changed', False)).lower()}"
        )
        try:
            subprocess.run(
                (LOGGER_PATH, "--tag", "warp-admin-helper", "--", message),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                cwd="/",
                env=FIXED_ENVIRONMENT,
                close_fds=True,
                timeout=2,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass


def _canonical_uuid_text(value: str) -> bool:
    try:
        parsed = uuid.UUID(value)
        return parsed.version == 4 and parsed.variant == uuid.RFC_4122 and str(parsed) == value
    except (ValueError, AttributeError):
        return False


def _read_version(path: Path = VERSION_PATH, *, require_root_metadata: bool = True) -> str:
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size <= 0
            or metadata.st_size > MAX_VERSION_BYTES
            or (require_root_metadata and (metadata.st_uid != 0 or metadata.st_gid != 0 or stat.S_IMODE(metadata.st_mode) & 0o022))
        ):
            return "unknown"
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_dev != metadata.st_dev
                or opened.st_ino != metadata.st_ino
                or opened.st_size != metadata.st_size
            ):
                return "unknown"
            raw = os.read(descriptor, MAX_VERSION_BYTES + 1)
        finally:
            os.close(descriptor)
        if len(raw) != metadata.st_size:
            return "unknown"
        value = raw.decode("ascii", errors="strict").strip()
        if not value or len(value) > 64 or not _SEMVER_RE.fullmatch(value):
            return "unknown"
        return value
    except (OSError, UnicodeDecodeError):
        return "unknown"


def parse_health_output(raw: bytes) -> dict[str, str]:
    try:
        text = raw.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise HelperRuntimeError("observation_unavailable") from exc
    lines = text.splitlines()
    if len(lines) != 1 or not lines[0]:
        raise HelperRuntimeError("observation_unavailable")
    values: dict[str, str] = {}
    for token in lines[0].split(" "):
        if token.count("=") != 1:
            raise HelperRuntimeError("observation_unavailable")
        key, value = token.split("=", 1)
        if key in values or key not in _HEALTH_KEYS or not value or any(ch not in _TOKEN_CHARS for ch in value):
            raise HelperRuntimeError("observation_unavailable")
        values[key] = value
    if set(values) != _HEALTH_KEYS:
        raise HelperRuntimeError("observation_unavailable")
    if values["EVALUATION"] != "completed" or values["HEALTH"] not in {"OK", "FAIL", "INTENTIONALLY_DISCONNECTED"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["wg"] not in {"up", "down"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["direct"] not in {"ok", "fail"} or values["warp"] not in {"on", "off", "fail"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["nft"] not in {"ok", "fail"} or values["upstream"] not in {"ok", "fail", "skip"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["services"] not in {"ok", "fail"} or values["timers"] not in {"ok", "fail"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["recovery"] != "none":
        raise HelperRuntimeError("observation_unavailable")
    if values["HEALTH"] == "INTENTIONALLY_DISCONNECTED" and not (
        values["reason"] == "intentionally_disconnected" and values["wg"] == "down"
        and values["route"] == "absent" and values["warp"] == "off" and values["nft"] == "ok"
        and values["direct"] == "ok" and values["upstream"] != "fail"
        and values["services"] == "ok" and values["timers"] == "ok"
    ):
        raise HelperRuntimeError("observation_unavailable")
    if values["HEALTH"] == "OK" and not (
        values["wg"] == "up"
        and values["direct"] == "ok"
        and values["warp"] == "on"
        and values["route"] == "ok"
        and values["nft"] == "ok"
        and values["upstream"] != "fail"
        and values["services"] == "ok"
        and values["timers"] == "ok"
    ):
        raise HelperRuntimeError("observation_unavailable")
    return values


def _response_from_observation(
    request: dict[str, object],
    observation: dict[str, str],
    *,
    version: str,
) -> dict[str, object]:
    healthy = observation["HEALTH"] == "OK"
    disconnected = observation["HEALTH"] == "INTENTIONALLY_DISCONNECTED"
    route_state = "ok" if observation["route"] == "ok" else "failed"
    if disconnected:
        route_state = "absent"
    monitoring = (
        "ok"
        if observation["services"] == "ok"
        and observation["timers"] == "ok"
        and observation["upstream"] != "fail"
        else "failed"
    )
    evidence = {
        "version": version,
        "wireguard": observation["wg"],
        "handshake": "unknown",
        "handshake_age_seconds": None,
        "direct": "ok" if observation["direct"] == "ok" else "failed",
        "warp": "off" if disconnected else ("on" if observation["warp"] == "on" else "failed"),
        "routing": route_state,
        "kill_switch": "active" if observation["nft"] == "ok" else "inactive",
        "forwarding": "unknown",
        "monitoring": monitoring,
        "failed_units": None,
    }
    return validate_response(
        {
            "protocol": 1,
            "request_id": request["request_id"],
            "operation": request["operation"],
            "ok": True,
            "result_code": "ok" if healthy or disconnected else "evaluation_unhealthy",
            "changed": False,
            "state": "intentionally_disconnected" if disconnected else ("ok" if healthy else "failed"),
            "evidence": evidence,
        }
    )


def _failure_response(request: dict[str, object], code: str, *, version: str) -> dict[str, object]:
    allowed = {"mutation_lock_busy", "observation_unavailable", "operation_timeout"}
    if request["operation"] == "repair-routing":
        allowed |= {"unsafe_precondition", "partial_mutation_failure", "postcondition_failed"}
    if code not in allowed:
        code = "observation_unavailable"
    return validate_response(
        {
            "protocol": 1,
            "request_id": request["request_id"],
            "operation": request["operation"],
            "ok": False,
            "result_code": code,
            "changed": False,
            "state": "failed",
            "evidence": unknown_evidence(version=version),
        }
    )


def handle_request(
    raw: bytes,
    *,
    runner: ObservationRunner | None = None,
    version_path: Path = VERSION_PATH,
    require_root_metadata: bool = True,
    completed=None,
) -> dict[str, object]:
    request = loads_request(raw)
    runtime = runner or HealthReadonlyRunner()
    version = _read_version(version_path, require_root_metadata=require_root_metadata)
    if request["operation"] == "repair-routing":
        return RoutingRepair().run(request, version=version, completed=completed)
    try:
        result = runtime.run()
        if result.returncode != 0:
            code = "mutation_lock_busy" if result.returncode == 75 else "observation_unavailable"
            return _failure_response(request, code, version=version)
        observation = parse_health_output(result.stdout)
        return _response_from_observation(request, observation, version=version)
    except HelperRuntimeError as exc:
        return _failure_response(request, exc.code, version=version)


def main(
    argv: Sequence[str] | None = None,
    *,
    euid: int | None = None,
    audit: AuditSink | None = None,
) -> int:
    arguments = list(sys.argv if argv is None else argv)
    if len(arguments) != 1:
        return 64
    if (os.geteuid() if euid is None else euid) != 0:
        return 77
    raw = sys.stdin.buffer.read(MAX_HELPER_INPUT_BYTES + 1)
    if not raw or len(raw) > MAX_HELPER_INPUT_BYTES:
        return 65
    try:
        request = loads_request(raw)
    except ProtocolError:
        return 65
    sink = audit or JournalAudit()
    request_id = str(request["request_id"])
    operation = str(request["operation"])
    started = time.monotonic()
    sink.emit(request_id=request_id, action=operation, state="requested", result_code="pending", duration_ms=0)
    sink.emit(request_id=request_id, action=operation, state="started", result_code="pending", duration_ms=0)
    def completed(response):
        sink.emit(request_id=request_id, action=operation,
                  state="completed" if response["ok"] else "failed", result_code=response["result_code"],
                  duration_ms=min(int((time.monotonic() - started) * 1000), 3_600_000), changed=response["changed"])
    response = handle_request(raw, completed=completed)
    if operation != "repair-routing":
        completed(response)
    sys.stdout.buffer.write(encode_response(response) + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
