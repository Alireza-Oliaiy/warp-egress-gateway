#!/usr/bin/python3 -I
"""Bounded read-only collector for the WARP Gateway dashboard."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import grp
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import threading
import time
from typing import Callable, Mapping, Sequence
import uuid

from web.dashboard.schema import StatusValidationError, validate_status


TRACE_URL = "https://www.cloudflare.com/cdn-cgi/trace"
STATUS_PATH = Path("/run/warp-egress-dashboard/status.json")
VERSION_PATH = Path("/opt/warp-egress-gateway/VERSION")
UPTIME_PATH = Path("/proc/uptime")
MAX_FILE_BYTES = 4096


class ObservationFailed(RuntimeError):
    """A bounded observation did not produce usable evidence."""


class SnapshotWriteError(RuntimeError):
    """The validated status snapshot could not be published safely."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


def _terminate(process: subprocess.Popen[bytes]) -> None:
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
        process.wait(timeout=0.25)
    except (OSError, ProcessLookupError, subprocess.TimeoutExpired):
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except (OSError, ProcessLookupError):
            pass


@dataclass(frozen=True)
class BoundedRunner:
    timeout_seconds: float = 10.0
    output_limit: int = 64 * 1024
    working_directory: str = "/"
    environment: Mapping[str, str] = field(
        default_factory=lambda: {
            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
        }
    )

    def run(self, argv: tuple[str, ...]) -> CommandResult:
        if not argv or not argv[0].startswith("/") or self.timeout_seconds <= 0 or self.output_limit <= 0:
            raise ObservationFailed("invalid fixed command")
        try:
            process = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=self.working_directory,
                env=dict(self.environment),
                shell=False,
                start_new_session=True,
            )
        except OSError as exc:
            raise ObservationFailed("command unavailable") from exc

        stdout = bytearray()
        stderr = bytearray()
        overflow = threading.Event()

        def read_stream(stream: object, target: bytearray) -> None:
            while True:
                chunk = stream.read(4096)  # type: ignore[attr-defined]
                if not chunk:
                    return
                remaining = self.output_limit + 1 - len(target)
                if remaining > 0:
                    target.extend(chunk[:remaining])
                if len(target) > self.output_limit or len(chunk) > remaining:
                    overflow.set()
                    return

        threads = (
            threading.Thread(target=read_stream, args=(process.stdout, stdout), daemon=True),
            threading.Thread(target=read_stream, args=(process.stderr, stderr), daemon=True),
        )
        for thread in threads:
            thread.start()
        deadline = time.monotonic() + self.timeout_seconds
        timed_out = False
        while process.poll() is None:
            if overflow.is_set():
                _terminate(process)
                break
            if time.monotonic() >= deadline:
                timed_out = True
                _terminate(process)
                break
            time.sleep(0.005)
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            _terminate(process)
        for thread in threads:
            thread.join(timeout=0.5)
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        if timed_out:
            raise ObservationFailed("command timed out")
        if overflow.is_set():
            raise ObservationFailed("command output exceeded bound")
        if process.returncode != 0:
            raise ObservationFailed("command returned nonzero")
        return CommandResult(process.returncode, bytes(stdout), bytes(stderr))


@dataclass(frozen=True)
class CollectorRuntime:
    runner: object = field(default_factory=BoundedRunner)
    version_path: Path = VERSION_PATH
    uptime_path: Path = UPTIME_PATH
    now: Callable[[], datetime] = field(default=lambda: datetime.now(timezone.utc))
    epoch_now: Callable[[], int] = field(default=lambda: int(time.time()))


def _strict_json(raw: bytes) -> object:
    def pairs(items: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in items:
            if key in result:
                raise ObservationFailed("duplicate JSON key")
            result[key] = value
        return result

    try:
        return json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ObservationFailed("constant")),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ObservationFailed) as exc:
        raise ObservationFailed("invalid structured output") from exc


def _safe_read(path: Path, *, maximum: int = MAX_FILE_BYTES) -> bytes:
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0 or metadata.st_size > maximum:
            raise ObservationFailed("fixed file is unsafe")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        try:
            payload = os.read(descriptor, maximum + 1)
        finally:
            os.close(descriptor)
    except OSError as exc:
        raise ObservationFailed("fixed file unavailable") from exc
    if not payload or len(payload) > maximum:
        raise ObservationFailed("fixed file exceeded bound")
    return payload


def parse_trace(raw: bytes) -> dict[str, str]:
    try:
        text = raw.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise ObservationFailed("trace is not ASCII") from exc
    result: dict[str, str] = {}
    for line in text.splitlines():
        if not line:
            continue
        if "=" not in line:
            raise ObservationFailed("trace line is malformed")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[a-z]{1,16}", key) or len(value) > 128 or any(ord(ch) < 32 for ch in value):
            raise ObservationFailed("trace field is malformed")
        if key in result:
            raise ObservationFailed("trace key is duplicated")
        if key in {"warp", "ip", "colo", "loc"}:
            result[key] = value
    if result.get("warp") not in {"on", "off"}:
        raise ObservationFailed("trace lacks WARP state")
    if "ip" in result:
        try:
            ipaddress.ip_address(result["ip"])
        except ValueError as exc:
            raise ObservationFailed("trace IP is invalid") from exc
    return result


def parse_handshake_age(raw: bytes, *, now_epoch: int) -> int | None:
    try:
        lines = raw.decode("ascii", errors="strict").splitlines()
        timestamps = [int(line.split()[1]) for line in lines if line.strip()]
    except (UnicodeDecodeError, ValueError, IndexError) as exc:
        raise ObservationFailed("handshake output is malformed") from exc
    usable = [value for value in timestamps if value > 0 and value <= now_epoch]
    return now_epoch - max(usable) if usable else None


def parse_default_route(raw: bytes, *, expected_device: str, allow_gateway: bool) -> bool:
    routes = _strict_json(raw)
    if type(routes) is not list or len(routes) != 1 or type(routes[0]) is not dict:
        return False
    route = routes[0]
    if route.get("dst") != "default" or route.get("dev") != expected_device:
        return False
    if route.get("type", "unicast") != "unicast" or any(key in route for key in ("nexthops", "nhid")):
        return False
    if not allow_gateway and any(key in route for key in ("gateway", "via")):
        return False
    return True


def _parse_main_default(raw: bytes) -> bool:
    routes = _strict_json(raw)
    if type(routes) is not list or len(routes) != 1 or type(routes[0]) is not dict:
        return False
    route = routes[0]
    return (
        route.get("dst") == "default"
        and type(route.get("dev")) is str
        and route.get("dev") != "warp0"
        and route.get("type", "unicast") == "unicast"
        and "nexthops" not in route
        and "nhid" not in route
    )


def _parse_interface(raw: bytes) -> str:
    links = _strict_json(raw)
    if type(links) is not list or len(links) != 1 or type(links[0]) is not dict:
        raise ObservationFailed("interface output is malformed")
    state = links[0].get("operstate")
    if state == "UP":
        return "up"
    if state in {"DOWN", "LOWERLAYERDOWN", "NOTPRESENT", "DORMANT"}:
        return "down"
    return "unknown"


def _parse_warp_ipv4(raw: bytes) -> str:
    try:
        text = raw.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise ObservationFailed("address output is malformed") from exc
    for line in text.splitlines():
        tokens = line.split()
        if "inet" in tokens:
            try:
                return str(ipaddress.IPv4Address(tokens[tokens.index("inet") + 1].split("/", 1)[0]))
            except (ValueError, IndexError) as exc:
                raise ObservationFailed("WARP address is invalid") from exc
    raise ObservationFailed("WARP address is missing")


def _parse_rule_states(raw: bytes, warp_ipv4: str | None) -> tuple[str, str]:
    try:
        lines = [line.split() for line in raw.decode("ascii", errors="strict").splitlines() if line.strip()]
    except UnicodeDecodeError as exc:
        raise ObservationFailed("rule output is malformed") from exc
    rule_100 = [tokens for tokens in lines if tokens[0] == "100:"]
    rule_110 = [tokens for tokens in lines if tokens[0] == "110:"]
    table_names = {"100", "warp_gateway"}
    state_100 = "unknown" if warp_ipv4 is None else (
        "ok" if len(rule_100) == 1 and len(rule_100[0]) == 5 and rule_100[0][1:4] == ["from", warp_ipv4, "lookup"] and rule_100[0][4] in table_names else "failed"
    )
    state_110 = "ok" if len(rule_110) == 1 and len(rule_110[0]) == 7 and rule_110[0][1:6] == ["from", "all", "iif", "ens192", "lookup"] and rule_110[0][6] in table_names else "failed"
    return state_100, state_110


def _kill_switch_active(raw: bytes) -> bool:
    value = _strict_json(raw)
    if type(value) is not dict or set(value) != {"nftables"} or type(value["nftables"]) is not list:
        raise ObservationFailed("nft output is malformed")
    for item in value["nftables"]:
        if type(item) is not dict or type(item.get("rule")) is not dict:
            continue
        rule = item["rule"]
        if rule.get("family") != "inet" or rule.get("table") != "warp_gateway" or rule.get("comment") != "WARP_KILL_SWITCH":
            continue
        expressions = rule.get("expr")
        if type(expressions) is not list:
            continue
        ingress = egress = dropped = False
        for expression in expressions:
            if type(expression) is not dict:
                continue
            if "drop" in expression:
                dropped = True
            match = expression.get("match")
            if type(match) is not dict:
                continue
            left = match.get("left")
            meta = left.get("meta") if type(left) is dict else None
            if type(meta) is not dict:
                continue
            if meta.get("key") == "iifname" and match.get("op") == "==" and match.get("right") == "ens192":
                ingress = True
            if meta.get("key") == "oifname" and match.get("op") == "!=" and match.get("right") == "warp0":
                egress = True
        if ingress and egress and dropped:
            return True
    return False


def _health_state(raw: bytes, prefix: str) -> str:
    try:
        lines = raw.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError as exc:
        raise ObservationFailed("monitor output is malformed") from exc
    value = next((line for line in reversed(lines) if line.startswith(prefix)), "")
    token = value[len(prefix):].split(maxsplit=1)[0] if value else ""
    if token == "OK":
        return "ok"
    if token in {"WARN", "DEGRADED"}:
        return "warn"
    if token == "FAIL":
        return "failed"
    return "unknown"


def _run(runtime: CollectorRuntime, argv: tuple[str, ...]) -> bytes | None:
    try:
        return runtime.runner.run(argv).stdout  # type: ignore[attr-defined]
    except (ObservationFailed, OSError, AttributeError):
        return None


def _fixed_text(path: Path) -> str | None:
    try:
        return _safe_read(path).decode("ascii", errors="strict").strip()
    except (ObservationFailed, UnicodeDecodeError):
        return None


def _trace_command(interface: str) -> tuple[str, ...]:
    return (
        "/usr/bin/curl", "-4", "--silent", "--show-error", "--fail",
        "--interface", interface, "--connect-timeout", "5", "--max-time", "10", TRACE_URL,
    )


def collect_status(runtime: CollectorRuntime | None = None) -> dict[str, object]:
    runtime = CollectorRuntime() if runtime is None else runtime
    now = runtime.now().astimezone(timezone.utc)
    hostname_raw = _run(runtime, ("/usr/bin/hostname", "-s"))
    hostname = hostname_raw.decode("ascii", errors="ignore").strip() if hostname_raw else "unknown"
    version = _fixed_text(runtime.version_path)
    if version is None or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", version):
        version = "unknown"
    uptime_text = _fixed_text(runtime.uptime_path)
    try:
        uptime_seconds: int | None = int(float(uptime_text.split()[0])) if uptime_text else None
    except (ValueError, IndexError):
        uptime_seconds = None

    interface_raw = _run(runtime, ("/usr/sbin/ip", "-j", "-4", "link", "show", "dev", "warp0"))
    try:
        interface = _parse_interface(interface_raw) if interface_raw is not None else "unknown"
    except ObservationFailed:
        interface = "unknown"
    address_raw = _run(runtime, ("/usr/sbin/ip", "-4", "-o", "address", "show", "dev", "warp0", "scope", "global"))
    try:
        warp_ipv4 = _parse_warp_ipv4(address_raw) if address_raw is not None else None
    except ObservationFailed:
        warp_ipv4 = None
    handshake_raw = _run(runtime, ("/usr/bin/wg", "show", "warp0", "latest-handshakes"))
    try:
        handshake_age = parse_handshake_age(handshake_raw, now_epoch=runtime.epoch_now()) if handshake_raw is not None else None
    except ObservationFailed:
        handshake_age = None

    direct_raw = _run(runtime, _trace_command("ens160"))
    warp_raw = _run(runtime, _trace_command(warp_ipv4)) if warp_ipv4 else None
    try:
        direct_trace = parse_trace(direct_raw) if direct_raw is not None else None
    except ObservationFailed:
        direct_trace = None
    try:
        warp_trace = parse_trace(warp_raw) if warp_raw is not None else None
    except ObservationFailed:
        warp_trace = None
    direct_path = "unknown" if direct_trace is None else ("ok" if direct_trace["warp"] == "off" else "failed")
    warp_path = "unknown" if warp_trace is None else ("ok" if warp_trace["warp"] == "on" else "failed")
    if interface == "down" or warp_path == "failed":
        warp_state = "disconnected"
    elif interface == "up" and warp_path == "ok":
        warp_state = "connected"
    else:
        warp_state = "unknown"

    rules_raw = _run(runtime, ("/usr/sbin/ip", "-4", "rule", "show"))
    try:
        rule_100, rule_110 = _parse_rule_states(rules_raw, warp_ipv4) if rules_raw is not None else ("unknown", "unknown")
    except ObservationFailed:
        rule_100 = rule_110 = "unknown"
    table_raw = _run(runtime, ("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "100", "default"))
    try:
        table_100 = "ok" if table_raw is not None and parse_default_route(table_raw, expected_device="warp0", allow_gateway=False) else ("unknown" if table_raw is None else "failed")
    except ObservationFailed:
        table_100 = "unknown"
    main_raw = _run(runtime, ("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "main", "default"))
    try:
        main_default = "ok" if main_raw is not None and _parse_main_default(main_raw) else ("unknown" if main_raw is None else "failed")
    except ObservationFailed:
        main_default = "unknown"

    nft_raw = _run(runtime, ("/usr/sbin/nft", "-j", "list", "table", "inet", "warp_gateway"))
    try:
        kill_switch = "active" if nft_raw is not None and _kill_switch_active(nft_raw) else ("unknown" if nft_raw is None else "inactive")
    except ObservationFailed:
        kill_switch = "unknown"
    forwarding_raw = _run(runtime, ("/usr/sbin/sysctl", "-n", "net.ipv4.ip_forward"))
    forwarding = None if forwarding_raw is None else forwarding_raw.strip() == b"1"

    health_raw = _run(runtime, ("/usr/bin/journalctl", "-u", "warp-gateway-healthcheck.service", "-n", "20", "--no-pager", "-o", "cat"))
    monitor_raw = _run(runtime, ("/usr/bin/journalctl", "-t", "warp-monitor", "-n", "20", "--no-pager", "-o", "cat"))
    health = _health_state(health_raw, "HEALTH=") if health_raw is not None else "unknown"
    monitor = _health_state(monitor_raw, "STATUS=") if monitor_raw is not None else "unknown"
    health_timer_raw = _run(runtime, ("/usr/bin/systemctl", "is-active", "warp-gateway-healthcheck.timer"))
    monitor_timer_raw = _run(runtime, ("/usr/bin/systemctl", "is-active", "warp-monitor.timer"))
    health_timer = "unknown" if health_timer_raw is None else ("active" if health_timer_raw.strip() == b"active" else "inactive")
    monitor_timer = "unknown" if monitor_timer_raw is None else ("active" if monitor_timer_raw.strip() == b"active" else "inactive")
    failed_raw = _run(runtime, ("/usr/bin/systemctl", "--failed", "--no-legend", "--plain", "--no-pager"))
    failed_units = None if failed_raw is None else len([line for line in failed_raw.splitlines() if line.strip()])

    hard_failures = (
        warp_state == "disconnected",
        direct_path == "failed",
        warp_path == "failed",
        any(state == "failed" for state in (rule_100, rule_110, table_100, main_default)),
        kill_switch == "inactive",
        forwarding is False,
        health == "failed",
        monitor == "failed",
        health_timer == "inactive",
        monitor_timer == "inactive",
        failed_units is not None and failed_units > 0,
    )
    observed = (interface, direct_path, warp_path, rule_100, rule_110, table_100, main_default, kill_switch, health, monitor, health_timer, monitor_timer)
    if any(hard_failures):
        overall = "offline"
    elif all(value == "unknown" for value in observed):
        overall = "unknown"
    elif any(value in {"unknown", "warn"} for value in observed) or handshake_age is None or handshake_age > 120 or forwarding is None or failed_units is None:
        overall = "degraded"
    else:
        overall = "online"

    status: dict[str, object] = {
        "schema_version": 1,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "overall": {"state": overall},
        "system": {"hostname": hostname or "unknown", "version": version, "uptime_seconds": uptime_seconds},
        "warp": {
            "state": warp_state,
            "interface": interface,
            "handshake_age_seconds": handshake_age,
            "public_ip": warp_trace.get("ip") if warp_trace else None,
            "colo": warp_trace.get("colo") if warp_trace else None,
            "location": warp_trace.get("loc") if warp_trace else None,
        },
        "paths": {
            "direct": {"state": direct_path, "warp": direct_trace.get("warp", "unknown") if direct_trace else "unknown"},
            "warp": {"state": warp_path, "warp": warp_trace.get("warp", "unknown") if warp_trace else "unknown"},
        },
        "routing": {"rule_100": rule_100, "rule_110": rule_110, "table_100": table_100, "main_default": main_default},
        "safety": {"kill_switch": kill_switch, "ipv4_forwarding": forwarding},
        "monitoring": {"health": health, "monitor": monitor, "health_timer": health_timer, "monitor_timer": monitor_timer, "failed_units": failed_units},
    }
    return validate_status(status)


def write_atomic_status(
    destination: Path,
    status_value: Mapping[str, object],
    *,
    owner_uid: int | None = None,
    group_gid: int | None = None,
) -> None:
    """Publish one validated snapshot without exposing a partial JSON file."""

    try:
        status = validate_status(status_value)
        parent_metadata = destination.parent.lstat()
        if not stat.S_ISDIR(parent_metadata.st_mode) or destination.parent.is_symlink():
            raise SnapshotWriteError("snapshot parent is unsafe")
        if destination.is_symlink():
            raise SnapshotWriteError("snapshot destination is a symlink")
        if destination.exists() and not destination.is_file():
            raise SnapshotWriteError("snapshot destination is not regular")
        encoded = json.dumps(status, ensure_ascii=True, allow_nan=False, separators=(",", ":"), sort_keys=True).encode("ascii") + b"\n"
    except (OSError, StatusValidationError, TypeError, ValueError) as exc:
        if isinstance(exc, SnapshotWriteError):
            raise
        raise SnapshotWriteError("snapshot validation failed") from exc

    temporary = destination.parent / f".{destination.name}.{os.getpid()}.{uuid.uuid4().hex}"
    descriptor: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o640)
        os.fchmod(descriptor, 0o640)
        if owner_uid is not None or group_gid is not None:
            os.fchown(descriptor, -1 if owner_uid is None else owner_uid, -1 if group_gid is None else group_gid)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = None
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_descriptor = os.open(destination.parent, directory_flags)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except (OSError, SnapshotWriteError) as exc:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        if isinstance(exc, SnapshotWriteError):
            raise
        raise SnapshotWriteError("atomic snapshot publication failed") from exc


def main(_argv: Sequence[str] | None = None) -> int:
    if not hasattr(os, "geteuid") or os.geteuid() != 0:
        raise SystemExit("collector must run as root for production snapshot ownership")
    status = collect_status()
    try:
        group_gid = grp.getgrnam("warp-web").gr_gid
    except KeyError as exc:
        raise SystemExit("warp-web group is unavailable") from exc
    write_atomic_status(STATUS_PATH, status, owner_uid=0, group_gid=group_gid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
