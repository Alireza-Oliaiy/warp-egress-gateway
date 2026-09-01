#!/usr/bin/python3 -I
"""Short-lived root helper for read-only Admin Console observations."""

from __future__ import annotations

from dataclasses import dataclass
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
        unknown_evidence,
        validate_response,
    )
except ImportError:  # pragma: no cover - exercised by installed-script fixtures
    from warp_admin_protocol import (  # type: ignore[no-redef]
        MAX_HELPER_INPUT_BYTES,
        ProtocolError,
        encode_response,
        loads_request,
        unknown_evidence,
        validate_response,
    )


HEALTH_READONLY_PATH = "/usr/local/lib/warp-egress-gateway/health-readonly.sh"
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


class HealthReadonlyRunner:
    def run(self) -> CommandResult:
        return _bounded_process(
            (HEALTH_READONLY_PATH,),
            timeout=OBSERVATION_TIMEOUT_SECONDS,
            stdout_limit=OBSERVATION_STDOUT_LIMIT,
            stderr_limit=OBSERVATION_STDERR_LIMIT,
        )


class JournalAudit:
    """Emit fixed-field records without passing secrets or raw output."""

    _ALLOWED_STATES = frozenset({"requested", "started", "completed", "failed"})
    _RESULT_CODES = frozenset(
        {"pending", "ok", "evaluation_unhealthy", "mutation_lock_busy", "observation_unavailable", "operation_timeout"}
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
            or action not in {"status", "health", "invalid"}
            or type(state_name) is not str
            or state_name not in self._ALLOWED_STATES
            or type(result_code) is not str
            or result_code not in self._RESULT_CODES
            or type(duration_ms) is not int
            or not 0 <= duration_ms <= 3_600_000
        ):
            return
        message = (
            "WARP_ADMIN_HELPER protocol=1 "
            f"request_id={request_id} action={action} state={state_name} "
            f"duration_ms={duration_ms} result_code={result_code} changed=false"
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
    if values["EVALUATION"] != "completed" or values["HEALTH"] not in {"OK", "FAIL"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["wg"] not in {"up", "down"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["direct"] not in {"ok", "fail"} or values["warp"] not in {"on", "fail"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["nft"] not in {"ok", "fail"} or values["upstream"] not in {"ok", "fail", "skip"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["services"] not in {"ok", "fail"} or values["timers"] not in {"ok", "fail"}:
        raise HelperRuntimeError("observation_unavailable")
    if values["recovery"] != "none":
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
    route_state = "ok" if observation["route"] == "ok" else "failed"
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
        "warp": "on" if observation["warp"] == "on" else "failed",
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
            "result_code": "ok" if healthy else "evaluation_unhealthy",
            "changed": False,
            "state": "ok" if healthy else "failed",
            "evidence": evidence,
        }
    )


def _failure_response(request: dict[str, object], code: str, *, version: str) -> dict[str, object]:
    if code not in {"mutation_lock_busy", "observation_unavailable", "operation_timeout"}:
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
) -> dict[str, object]:
    request = loads_request(raw)
    runtime = runner or HealthReadonlyRunner()
    version = _read_version(version_path, require_root_metadata=require_root_metadata)
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
    response = handle_request(raw)
    duration = min(int((time.monotonic() - started) * 1000), 3_600_000)
    sink.emit(
        request_id=request_id,
        action=operation,
        state="completed" if response["ok"] else "failed",
        result_code=response["result_code"],
        duration_ms=duration,
    )
    sys.stdout.buffer.write(encode_response(response) + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
