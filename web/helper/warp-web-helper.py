#!/usr/bin/python3 -I
"""Phase 1A privileged helper core for the future optional web console."""

from __future__ import annotations

from dataclasses import dataclass
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
from typing import Any, Mapping, Sequence
import uuid


PROTOCOL_VERSION = 1
MAX_INPUT_BYTES = 8192
MAX_CONFIG_BYTES = 32768
MAX_VERSION_BYTES = 64
MAX_RESPONSE_BYTES = 65536
TOP_LEVEL_FIELDS = {
    "protocol",
    "verb",
    "parameters",
    "request_id",
    "audit_context",
}
AUDIT_FIELDS = {"asserted_actor", "asserted_role", "asserted_source_ip"}
IMPLEMENTED_VERBS = {"version", "routing-status"}
FUTURE_VERBS = {
    "status",
    "health-read",
    "health-run",
    "routing-repair",
    "warp-disconnect",
    "logs-read",
}
ALL_VERBS = IMPLEMENTED_VERBS | FUTURE_VERBS
SEMVER_RE = re.compile(
    r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\Z"
)
INTERFACE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}\Z")
TABLE_NAME_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,31}\Z")
AUDIT_ACTOR_RE = re.compile(r"[\x20-\x7e]{1,128}\Z")
SAFE_VALUE_RE = re.compile(r"[A-Za-z0-9_./:@+?&=%,-]*\Z")
KNOWN_CONFIG_KEYS = {
    "TRANSIT_IF",
    "MANAGE_TRANSIT_ADDRESS",
    "TRANSIT_CIDR",
    "TRUSTED_SOURCE_CIDR",
    "UPLINK_IF",
    "UPLINK_GATEWAY",
    "WARP_IF",
    "WARP_MTU",
    "PERSISTENT_KEEPALIVE",
    "TCP_MSS",
    "ROUTING_TABLE_ID",
    "ROUTING_TABLE_NAME",
    "SOURCE_RULE_PRIORITY",
    "INGRESS_RULE_PRIORITY",
    "WGCF_VERSION",
    "ACCEPT_CLOUDFLARE_TOS",
    "EXISTING_WARP_PROFILE",
    "HEALTHCHECK_URL",
    "HEALTHCHECK_INTERVAL",
    "HEALTHCHECK_TIMEOUT",
    "AUTO_RECOVER",
    "MONITOR_INTERVAL",
    "MONITOR_HANDSHAKE_WARN_SEC",
    "MONITOR_CURL_TIMEOUT",
    "UPSTREAM_MONITOR_IP",
    "ENABLE_IPV6_TRANSIT",
}
REQUIRED_ROUTING_KEYS = {
    "TRANSIT_IF",
    "TRUSTED_SOURCE_CIDR",
    "WARP_IF",
    "ROUTING_TABLE_ID",
    "ROUTING_TABLE_NAME",
    "SOURCE_RULE_PRIORITY",
    "INGRESS_RULE_PRIORITY",
}


class HelperError(Exception):
    def __init__(self, code: str, message: str, exit_code: int) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_code = exit_code


class InvalidRequest(HelperError):
    def __init__(self, message: str = "The helper request is invalid.") -> None:
        super().__init__("invalid_request", message, 2)


class UnsafeConfig(HelperError):
    def __init__(self, message: str = "Trusted configuration validation failed.") -> None:
        super().__init__("unsafe_config", message, 3)


class QueryFailed(HelperError):
    def __init__(self) -> None:
        super().__init__("query_failed", "A fixed routing query failed.", 5)


class ChildTimeout(HelperError):
    def __init__(self) -> None:
        super().__init__("child_timeout", "A fixed routing query timed out.", 6)


class ChildOutputLimit(HelperError):
    def __init__(self) -> None:
        super().__init__("child_output_limit", "A fixed routing query exceeded its output bound.", 7)


@dataclass(frozen=True)
class HelperRuntime:
    """Injected only by the import-based test harness; production uses constants."""

    version_path: Path
    config_path: Path
    ip_argv: tuple[str, ...]
    working_directory: Path
    expected_uid: int | None
    enforce_permissions: bool
    child_environment: Mapping[str, str]
    child_timeout_seconds: float = 3.0
    child_output_limit: int = 65536


@dataclass(frozen=True)
class HelperRequest:
    verb: str
    request_id: str


PRODUCTION_RUNTIME = HelperRuntime(
    version_path=Path("/etc/warp-egress-gateway/VERSION"),
    config_path=Path("/etc/warp-egress-gateway/warp-gateway.env"),
    ip_argv=("/usr/sbin/ip",),
    working_directory=Path("/"),
    expected_uid=0,
    enforce_permissions=True,
    child_environment={
        "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
    },
)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise InvalidRequest("Duplicate JSON keys are not allowed.")
        value[key] = item
    return value


def parse_request(raw: bytes) -> HelperRequest:
    if not raw or len(raw) > MAX_INPUT_BYTES:
        raise InvalidRequest()
    try:
        text = raw.decode("utf-8", errors="strict")
        value = json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda _value: (_ for _ in ()).throw(InvalidRequest()),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as exc:
        raise InvalidRequest() from exc
    if type(value) is not dict or set(value) != TOP_LEVEL_FIELDS:
        raise InvalidRequest()
    if type(value["protocol"]) is not int or value["protocol"] != PROTOCOL_VERSION:
        raise InvalidRequest()
    if type(value["verb"]) is not str or value["verb"] not in ALL_VERBS:
        raise InvalidRequest()
    if type(value["parameters"]) is not dict or value["parameters"]:
        raise InvalidRequest()

    request_id = value["request_id"]
    if type(request_id) is not str:
        raise InvalidRequest()
    try:
        parsed_id = uuid.UUID(request_id)
    except ValueError as exc:
        raise InvalidRequest() from exc
    if parsed_id.version != 4 or str(parsed_id) != request_id:
        raise InvalidRequest()

    audit = value["audit_context"]
    if type(audit) is not dict or set(audit) != AUDIT_FIELDS:
        raise InvalidRequest()
    actor = audit["asserted_actor"]
    role = audit["asserted_role"]
    source_ip = audit["asserted_source_ip"]
    if type(actor) is not str or not AUDIT_ACTOR_RE.fullmatch(actor):
        raise InvalidRequest()
    if type(role) is not str or role not in {"Viewer", "Admin"}:
        raise InvalidRequest()
    if type(source_ip) is not str or len(source_ip) > 64:
        raise InvalidRequest()
    try:
        ipaddress.ip_address(source_ip)
    except ValueError as exc:
        raise InvalidRequest() from exc

    # The asserted audit values are deliberately discarded here. Dispatch is
    # determined solely by the separately validated verb.
    return HelperRequest(verb=value["verb"], request_id=request_id)


def safe_read_file(
    path: Path,
    *,
    maximum: int,
    runtime: HelperRuntime,
    allow_world_read: bool,
) -> bytes:
    try:
        before = path.lstat()
    except OSError as exc:
        raise UnsafeConfig() from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise UnsafeConfig()
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise UnsafeConfig() from exc
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
            before.st_dev,
            before.st_ino,
        ):
            raise UnsafeConfig()
        if runtime.enforce_permissions:
            if runtime.expected_uid is None or opened.st_uid != runtime.expected_uid:
                raise UnsafeConfig()
            forbidden = 0o022 if allow_world_read else 0o077
            if stat.S_IMODE(opened.st_mode) & forbidden:
                raise UnsafeConfig()
        if opened.st_size < 1 or opened.st_size > maximum:
            raise UnsafeConfig()
        chunks: list[bytes] = []
        total = 0
        while total <= maximum:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        payload = b"".join(chunks)
        if len(payload) > maximum:
            raise UnsafeConfig()
        return payload
    finally:
        os.close(descriptor)


def parse_config(runtime: HelperRuntime) -> dict[str, str]:
    payload = safe_read_file(
        runtime.config_path,
        maximum=MAX_CONFIG_BYTES,
        runtime=runtime,
        allow_world_read=False,
    )
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise UnsafeConfig() from exc

    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(.*)", line)
        if match is None:
            raise UnsafeConfig()
        key, encoded = match.groups()
        if key not in KNOWN_CONFIG_KEYS or key in values:
            raise UnsafeConfig()
        if len(encoded) >= 2 and encoded[0] == encoded[-1] and encoded[0] in "\"'":
            decoded = encoded[1:-1]
        else:
            decoded = encoded
        if not SAFE_VALUE_RE.fullmatch(decoded):
            raise UnsafeConfig()
        values[key] = decoded

    if not REQUIRED_ROUTING_KEYS.issubset(values):
        raise UnsafeConfig()
    for key in ("TRANSIT_IF", "WARP_IF"):
        if not INTERFACE_RE.fullmatch(values[key]):
            raise UnsafeConfig()
    if not TABLE_NAME_RE.fullmatch(values["ROUTING_TABLE_NAME"]):
        raise UnsafeConfig()
    try:
        network = ipaddress.ip_network(values["TRUSTED_SOURCE_CIDR"], strict=False)
        if network.version != 4:
            raise ValueError
        for key in ("ROUTING_TABLE_ID", "SOURCE_RULE_PRIORITY", "INGRESS_RULE_PRIORITY"):
            number = int(values[key], 10)
            if str(number) != values[key] or not 1 <= number <= 2_147_483_647:
                raise ValueError
    except ValueError as exc:
        raise UnsafeConfig() from exc
    return values


def terminate_process(process: subprocess.Popen[bytes]) -> None:
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
    except (OSError, ProcessLookupError):
        pass


def run_fixed_command(runtime: HelperRuntime, arguments: Sequence[str]) -> bytes:
    command = (*runtime.ip_argv, *arguments)
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=runtime.working_directory,
            env=dict(runtime.child_environment),
            shell=False,
            start_new_session=True,
        )
    except OSError as exc:
        raise QueryFailed() from exc

    stdout = bytearray()
    stderr = bytearray()
    overflow = threading.Event()

    def read_bounded(stream: Any, target: bytearray) -> None:
        while True:
            chunk = stream.read(4096)
            if not chunk:
                return
            remaining = runtime.child_output_limit + 1 - len(target)
            if remaining > 0:
                target.extend(chunk[:remaining])
            if len(target) > runtime.child_output_limit or len(chunk) > remaining:
                overflow.set()
                return

    threads = [
        threading.Thread(target=read_bounded, args=(process.stdout, stdout), daemon=True),
        threading.Thread(target=read_bounded, args=(process.stderr, stderr), daemon=True),
    ]
    for thread in threads:
        thread.start()
    deadline = time.monotonic() + runtime.child_timeout_seconds
    timed_out = False
    while process.poll() is None:
        if overflow.is_set():
            terminate_process(process)
            break
        if time.monotonic() >= deadline:
            timed_out = True
            terminate_process(process)
            break
        time.sleep(0.005)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        terminate_process(process)
        process.wait(timeout=1)
    for thread in threads:
        thread.join(timeout=1)
    if process.stdout is not None:
        process.stdout.close()
    if process.stderr is not None:
        process.stderr.close()

    if timed_out:
        raise ChildTimeout()
    if overflow.is_set():
        raise ChildOutputLimit()
    if process.returncode != 0:
        raise QueryFailed()
    try:
        stdout.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise QueryFailed() from exc
    return bytes(stdout)


def read_version(runtime: HelperRuntime) -> dict[str, str]:
    payload = safe_read_file(
        runtime.version_path,
        maximum=MAX_VERSION_BYTES,
        runtime=runtime,
        allow_world_read=True,
    )
    try:
        version = payload.decode("ascii", errors="strict").strip()
    except UnicodeDecodeError as exc:
        raise HelperError("invalid_version", "Installed VERSION is invalid.", 5) from exc
    if not SEMVER_RE.fullmatch(version):
        raise HelperError("invalid_version", "Installed VERSION is invalid.", 5)
    return {"version": version}


def component_state(actual_count: int, matches: int) -> str:
    if actual_count == 0:
        return "missing"
    if actual_count == 1 and matches == 1:
        return "ok"
    return "mismatch"


def routing_status(runtime: HelperRuntime) -> dict[str, Any]:
    config = parse_config(runtime)
    warp_if = config["WARP_IF"]
    transit_if = config["TRANSIT_IF"]
    table_id = config["ROUTING_TABLE_ID"]
    table_name = config["ROUTING_TABLE_NAME"]
    source_priority = config["SOURCE_RULE_PRIORITY"]
    ingress_priority = config["INGRESS_RULE_PRIORITY"]

    address_output = run_fixed_command(
        runtime, ("-4", "-o", "address", "show", "dev", warp_if, "scope", "global")
    ).decode("utf-8")
    warp_ipv4: str | None = None
    for line in address_output.splitlines():
        tokens = line.split()
        if "inet" in tokens:
            candidate = tokens[tokens.index("inet") + 1].split("/", 1)[0]
            try:
                warp_ipv4 = str(ipaddress.IPv4Address(candidate))
                break
            except ipaddress.AddressValueError:
                continue

    rule_output = run_fixed_command(runtime, ("-4", "rule", "show")).decode("utf-8")
    rule_lines = [line.split() for line in rule_output.splitlines() if line.strip()]
    table_values = {table_id, table_name}
    source_candidates = [tokens for tokens in rule_lines if tokens and tokens[0] == f"{source_priority}:"]
    ingress_candidates = [tokens for tokens in rule_lines if tokens and tokens[0] == f"{ingress_priority}:"]
    source_matches = 0
    if warp_ipv4 is not None:
        source_matches = sum(
            len(tokens) == 5
            and tokens[1:4] == ["from", warp_ipv4, "lookup"]
            and tokens[4] in table_values
            for tokens in source_candidates
        )
    ingress_matches = sum(
        len(tokens) == 7
        and tokens[1:6] == ["from", "all", "iif", transit_if, "lookup"]
        and tokens[6] in table_values
        for tokens in ingress_candidates
    )

    route_output = run_fixed_command(
        runtime, ("-4", "route", "show", "table", table_id, "default")
    ).decode("utf-8")
    route_lines = [line.split() for line in route_output.splitlines() if line.strip()]
    route_matches = sum(tokens == ["default", "dev", warp_if] for tokens in route_lines)

    main_output = run_fixed_command(
        runtime, ("-4", "route", "show", "table", "main", "default")
    ).decode("utf-8")
    main_count = sum(1 for line in main_output.splitlines() if line.strip())

    source_state = component_state(len(source_candidates), source_matches)
    ingress_state = component_state(len(ingress_candidates), ingress_matches)
    route_state = component_state(len(route_lines), route_matches)
    overall = "ok" if warp_ipv4 and {source_state, ingress_state, route_state} == {"ok"} else "failed"
    return {
        "state": overall,
        "source_rule": {
            "priority": int(source_priority),
            "expected_source": f"{warp_ipv4}/32" if warp_ipv4 else None,
            "expected_table_id": int(table_id),
            "actual_count": len(source_candidates),
            "state": source_state if warp_ipv4 else "unverifiable",
        },
        "transit_ingress_rule": {
            "priority": int(ingress_priority),
            "expected_interface": transit_if,
            "expected_table_id": int(table_id),
            "actual_count": len(ingress_candidates),
            "state": ingress_state,
        },
        "warp_default": {
            "table_id": int(table_id),
            "expected_interface": warp_if,
            "actual_count": len(route_lines),
            "state": route_state,
        },
        "main_default": {
            "managed_by_project": False,
            "actual_count": main_count,
        },
    }


def success_response(request: HelperRequest, data: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "protocol": PROTOCOL_VERSION,
        "request_id": request.request_id,
        "ok": True,
        "verb": request.verb,
        "data": dict(data),
    }


def error_response(error: HelperError, request_id: str | None = None) -> dict[str, Any]:
    return {
        "protocol": PROTOCOL_VERSION,
        "request_id": request_id,
        "ok": False,
        "error": {"code": error.code, "message": error.message},
    }


def process_request(raw: bytes, runtime: HelperRuntime) -> tuple[int, dict[str, Any]]:
    request: HelperRequest | None = None
    try:
        request = parse_request(raw)
        if request.verb in FUTURE_VERBS:
            raise HelperError(
                "not_implemented_in_this_slice",
                "This fixed verb is not implemented in Phase 1A.",
                5,
            )
        if request.verb == "version":
            data = read_version(runtime)
        elif request.verb == "routing-status":
            data = routing_status(runtime)
        else:
            raise InvalidRequest()
        return 0, success_response(request, data)
    except HelperError as error:
        return error.exit_code, error_response(error, request.request_id if request else None)
    except Exception:
        internal = HelperError("internal_error", "The helper failed safely.", 8)
        return internal.exit_code, error_response(internal, request.request_id if request else None)


def production_main() -> int:
    if not hasattr(os, "geteuid") or os.geteuid() != 0:
        error = HelperError("helper_requires_root", "The helper requires effective UID 0.", 8)
        response = error_response(error)
        sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
        return error.exit_code

    os.chdir(PRODUCTION_RUNTIME.working_directory)
    os.environ.clear()
    os.environ.update(PRODUCTION_RUNTIME.child_environment)
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    exit_code, response = process_request(raw, PRODUCTION_RUNTIME)
    encoded = json.dumps(response, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        exit_code = 7
        encoded = json.dumps(
            error_response(HelperError("output_limit", "Helper output exceeded its bound.", 7)),
            separators=(",", ":"),
        )
    sys.stdout.write(encoded + "\n")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(production_main())
