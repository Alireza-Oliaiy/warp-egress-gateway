#!/usr/bin/python3 -I
"""Loopback-only, SSH-forwarded read-only Admin Console."""

from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from typing import Callable, Mapping, Protocol, Sequence
from urllib.parse import urlsplit
import uuid


INSTALLED_APP_DIR = Path("/opt/warp-egress-admin-console/app/admin")
INSTALLED_APPLICATION = INSTALLED_APP_DIR / "application.py"
INSTALLED_PROTOCOL = INSTALLED_APP_DIR / "protocol.py"


def validate_installed_application_metadata(
    application_path: Path = INSTALLED_APPLICATION,
    protocol_path: Path = INSTALLED_PROTOCOL,
    *,
    required_uid: int = 0,
    required_gid: int = 0,
    parents: Sequence[Path] | None = None,
) -> bool:
    """Validate the fixed isolated import chain before loading project code."""

    try:
        for path in (application_path, protocol_path):
            metadata = path.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_IMODE(metadata.st_mode) != 0o644
                or metadata.st_uid != required_uid
                or metadata.st_gid != required_gid
            ):
                return False
        checked_parents = parents or (
            application_path.parent,
            application_path.parent.parent,
            application_path.parent.parent.parent,
            application_path.parent.parent.parent.parent,
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


if __name__ == "__main__":
    if Path(__file__) != INSTALLED_APPLICATION or not validate_installed_application_metadata():
        raise SystemExit(78)
    sys.path.insert(0, str(INSTALLED_APP_DIR))

sys.dont_write_bytecode = True

try:  # Script deployment and package import deliberately share one source.
    from .protocol import (
        MAX_HELPER_OUTPUT_BYTES,
        MAX_HTTP_BODY_BYTES,
        ProtocolError,
        encode_request,
        loads_exact_json,
        loads_response,
    )
except ImportError:  # pragma: no cover - exercised by installed-script fixtures
    from protocol import (  # type: ignore[no-redef]
        MAX_HELPER_OUTPUT_BYTES,
        MAX_HTTP_BODY_BYTES,
        ProtocolError,
        encode_request,
        loads_exact_json,
        loads_response,
    )


BIND_ADDRESS = "127.0.0.1"
BIND_PORT = 8788
EXPECTED_HOST = "127.0.0.1:8788"
EXPECTED_ORIGIN = "http://127.0.0.1:8788"
HELPER_COMMAND = (
    "/usr/bin/sudo",
    "-n",
    "--",
    "/usr/local/libexec/warp-egress-gateway/warp-admin-helper",
)
HELPER_PATH = Path(HELPER_COMMAND[-1])
FIXED_ENVIRONMENT = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME": "/nonexistent",
    "LANG": "C",
    "LC_ALL": "C",
}
HELPER_TIMEOUT_SECONDS = 50.0
HELPER_STDERR_LIMIT = 4096
SESSION_COOKIE = "warp_admin_session"
SESSION_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
SESSION_INACTIVITY_SECONDS = 15 * 60
SESSION_ABSOLUTE_SECONDS = 8 * 60 * 60
MAX_SESSIONS = 1024
RATE_WINDOW_SECONDS = 60.0
PER_BINDING_LIMITS = {"status": 60, "health": 6}
GLOBAL_LIMITS = {"status": 120, "health": 12}
MAX_ASSET_BYTES = 256 * 1024
SOURCE_DIR = Path(__file__).resolve().parent
STATIC_DIR = SOURCE_DIR / "static"
LOGGER_PATH = "/usr/bin/logger"

CSP = (
    "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; "
    "img-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
)
PERMISSIONS_POLICY = (
    "accelerometer=(), autoplay=(), camera=(), geolocation=(), gyroscope=(), "
    "magnetometer=(), microphone=(), payment=(), usb=()"
)


class AdminError(RuntimeError):
    """Stable application boundary failure."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class HelperClient(Protocol):
    def invoke(self, operation: str, request_id: str) -> dict[str, object]:
        """Invoke one fixed helper operation."""


class AuditSink(Protocol):
    def emit(self, **fields: object) -> None:
        """Write one sanitized event."""


class NullAudit:
    def emit(self, **_fields: object) -> None:
        return


class JournalAudit:
    _STATES = frozenset({"requested", "started", "completed", "failed"})
    _RESULT_CODES = frozenset(
        {
            "pending",
            "ok",
            "evaluation_unhealthy",
            "mutation_lock_busy",
            "observation_unavailable",
            "operation_timeout",
            "helper_protocol_error",
            "helper_unavailable",
            "privilege_denied",
        }
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
            or action not in {"status", "health"}
            or type(state_name) is not str
            or state_name not in self._STATES
            or type(result_code) is not str
            or result_code not in self._RESULT_CODES
            or type(duration_ms) is not int
            or not 0 <= duration_ms <= 3_600_000
        ):
            return
        message = (
            "WARP_ADMIN_APP protocol=1 "
            f"request_id={request_id} action={action} state={state_name} "
            f"duration_ms={duration_ms} result_code={result_code} changed=false"
        )
        try:
            subprocess.run(
                (LOGGER_PATH, "--tag", "warp-admin", "--", message),
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


def _kill_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except OSError:
            pass


def _invoke_bounded(payload: bytes) -> tuple[int, bytes]:
    try:
        process = subprocess.Popen(
            HELPER_COMMAND,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd="/",
            env=FIXED_ENVIRONMENT,
            close_fds=True,
            start_new_session=True,
        )
    except OSError as exc:
        raise AdminError("helper_unavailable") from exc

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

    readers = [
        threading.Thread(target=drain, args=("stdout", process.stdout, MAX_HELPER_OUTPUT_BYTES), daemon=True),
        threading.Thread(target=drain, args=("stderr", process.stderr, HELPER_STDERR_LIMIT), daemon=True),
    ]
    for reader in readers:
        reader.start()
    try:
        assert process.stdin is not None
        process.stdin.write(payload)
    except (BrokenPipeError, OSError):
        pass
    finally:
        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
    deadline = time.monotonic() + HELPER_TIMEOUT_SECONDS
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
    for reader in readers:
        reader.join(timeout=2)
    if process.stdout is not None:
        process.stdout.close()
    if process.stderr is not None:
        process.stderr.close()
    if timed_out:
        raise AdminError("operation_timeout")
    if overflow.is_set():
        raise AdminError("helper_protocol_error")
    return returncode, bytes(output["stdout"])


class SudoHelperClient:
    def invoke(self, operation: str, request_id: str) -> dict[str, object]:
        if not _helper_available():
            raise AdminError("helper_unavailable")
        payload = encode_request(operation, request_id)
        returncode, stdout = _invoke_bounded(payload)
        if returncode != 0:
            raise AdminError("privilege_denied")
        try:
            response = loads_response(stdout)
        except ProtocolError as exc:
            raise AdminError("helper_protocol_error") from exc
        if response["request_id"] != request_id or response["operation"] != operation:
            raise AdminError("helper_protocol_error")
        return response


def _helper_available(path: Path = HELPER_PATH, *, require_root: bool = True) -> bool:
    try:
        metadata = path.lstat()
        return (
            stat.S_ISREG(metadata.st_mode)
            and stat.S_IMODE(metadata.st_mode) == 0o755
            and (not require_root or (metadata.st_uid == 0 and metadata.st_gid == 0))
        )
    except OSError:
        return False


@dataclass
class Session:
    csrf: str
    created: float
    last_seen: float


def _opaque_token() -> str:
    token = secrets.token_urlsafe(32)
    if not SESSION_TOKEN_RE.fullmatch(token):  # defensive: 32 bytes is canonically 43 chars
        raise RuntimeError("CSPRNG token encoding is unexpected")
    return token


class SessionStore:
    def __init__(
        self,
        *,
        now: Callable[[], float] = time.monotonic,
        inactivity_seconds: int = SESSION_INACTIVITY_SECONDS,
        absolute_seconds: int = SESSION_ABSOLUTE_SECONDS,
        maximum: int = MAX_SESSIONS,
    ) -> None:
        self._now = now
        self._inactivity = inactivity_seconds
        self._absolute = absolute_seconds
        self._maximum = maximum
        self._sessions: dict[str, Session] = {}
        self._lock = threading.Lock()

    def _expired(self, session: Session, current: float) -> bool:
        return current - session.last_seen > self._inactivity or current - session.created > self._absolute

    def _prune(self, current: float) -> None:
        for key in [key for key, value in self._sessions.items() if self._expired(value, current)]:
            del self._sessions[key]
        while len(self._sessions) >= self._maximum:
            oldest = min(self._sessions, key=lambda key: self._sessions[key].last_seen)
            del self._sessions[oldest]

    def issue(self, *, replace: str | None = None) -> tuple[str, str]:
        current = self._now()
        binding, csrf = _opaque_token(), _opaque_token()
        with self._lock:
            self._prune(current)
            if replace is not None and SESSION_TOKEN_RE.fullmatch(replace):
                self._sessions.pop(replace, None)
            self._sessions[binding] = Session(csrf, current, current)
        return binding, csrf

    def validate(self, binding: str, *, csrf: str | None = None) -> bool:
        if not SESSION_TOKEN_RE.fullmatch(binding):
            return False
        current = self._now()
        with self._lock:
            session = self._sessions.get(binding)
            if session is None or self._expired(session, current):
                self._sessions.pop(binding, None)
                return False
            if csrf is not None and (
                not SESSION_TOKEN_RE.fullmatch(csrf) or not hmac.compare_digest(session.csrf, csrf)
            ):
                return False
            session.last_seen = current
            return True


class RateLimiter:
    def __init__(
        self,
        *,
        now: Callable[[], float] = time.monotonic,
        window: float = RATE_WINDOW_SECONDS,
        per_binding: Mapping[str, int] = PER_BINDING_LIMITS,
        global_limits: Mapping[str, int] = GLOBAL_LIMITS,
    ) -> None:
        self._now = now
        self._window = window
        self._per_binding = dict(per_binding)
        self._global_limits = dict(global_limits)
        self._bindings: dict[tuple[str, str], deque[float]] = defaultdict(deque)
        self._global: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, binding: str, operation: str) -> bool:
        current = self._now()
        cutoff = current - self._window
        with self._lock:
            per = self._bindings[(binding, operation)]
            global_window = self._global[operation]
            while per and per[0] <= cutoff:
                per.popleft()
            while global_window and global_window[0] <= cutoff:
                global_window.popleft()
            if len(per) >= self._per_binding[operation] or len(global_window) >= self._global_limits[operation]:
                return False
            per.append(current)
            global_window.append(current)
            return True


def _cookie_binding(headers: object) -> str | None:
    values = headers.get_all("Cookie", [])  # type: ignore[attr-defined]
    if len(values) != 1 or len(values[0]) > 1024 or any(ord(ch) < 32 or ord(ch) > 126 for ch in values[0]):
        return None
    found: str | None = None
    for item in values[0].split(";"):
        item = item.strip()
        if "=" not in item:
            return None
        name, value = item.split("=", 1)
        if name == SESSION_COOKIE:
            if found is not None or not SESSION_TOKEN_RE.fullmatch(value):
                return None
            found = value
    return found


def _valid_target(target: str) -> tuple[str, bool]:
    if type(target) is not str or not target.startswith("/") or target.startswith("//"):
        return "", False
    parsed = urlsplit(target)
    if parsed.scheme or parsed.netloc or parsed.fragment or parsed.query:
        return "", False
    return parsed.path, True


def _valid_host(headers: object) -> bool:
    hosts = headers.get_all("Host", [])  # type: ignore[attr-defined]
    if hosts != [EXPECTED_HOST]:
        return False
    for name in ("Forwarded", "X-Forwarded-Host"):
        if headers.get_all(name, []):  # type: ignore[attr-defined]
            return False
    return True


def _parse_empty_object(handler: BaseHTTPRequestHandler) -> None:
    headers = handler.headers
    content_types = headers.get_all("Content-Type", [])
    lengths = headers.get_all("Content-Length", [])
    if content_types != ["application/json"]:
        raise AdminError("unsupported_media_type")
    if headers.get_all("Transfer-Encoding", []) or headers.get_all("Content-Encoding", []):
        raise AdminError("bad_request")
    if len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdecimal():
        raise AdminError("bad_request")
    length = int(lengths[0], 10)
    if length > MAX_HTTP_BODY_BYTES:
        raise AdminError("payload_too_large")
    if length <= 0:
        raise AdminError("bad_request")
    raw = handler.rfile.read(length)
    if len(raw) != length:
        raise AdminError("bad_request")
    try:
        value = loads_exact_json(raw, maximum=MAX_HTTP_BODY_BYTES)
    except ProtocolError as exc:
        raise AdminError("bad_request") from exc
    if type(value) is not dict or value:
        raise AdminError("bad_request")


class AdminHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET
    daemon_threads = True
    allow_reuse_address = False

    def __init__(
        self,
        server_address: tuple[str, int],
        *,
        helper: HelperClient,
        sessions: SessionStore,
        limiter: RateLimiter,
        static_directory: Path,
        audit: AuditSink,
    ) -> None:
        self.helper = helper
        self.sessions = sessions
        self.limiter = limiter
        self.static_directory = static_directory
        self.audit = audit
        super().__init__(server_address, AdminHandler)


class AdminHandler(BaseHTTPRequestHandler):
    server_version = "warp-admin"
    sys_version = ""

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(5)

    def _write(
        self,
        status: int,
        content_type: str,
        payload: bytes,
        *,
        headers: Mapping[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Permissions-Policy", PERMISSIONS_POLICY)
        if headers:
            for name, value in headers.items():
                self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def _json_error(self, status: int, code: str) -> None:
        payload = json.dumps({"error": code}, separators=(",", ":")).encode("ascii")
        self._write(status, "application/json; charset=utf-8", payload)

    def _preflight(self) -> str | None:
        if not _valid_host(self.headers):
            self._json_error(403, "request_boundary_rejected")
            return None
        path, valid = _valid_target(self.path)
        if not valid:
            self._json_error(400, "bad_request")
            return None
        return path

    def _asset(self, filename: str) -> bytes:
        path = self.server.static_directory / filename  # type: ignore[attr-defined]
        try:
            metadata = path.lstat()
            if not path.is_file() or path.is_symlink() or metadata.st_size <= 0 or metadata.st_size > MAX_ASSET_BYTES:
                raise OSError("unsafe asset")
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                opened = os.fstat(descriptor)
                if opened.st_dev != metadata.st_dev or opened.st_ino != metadata.st_ino or opened.st_size != metadata.st_size:
                    raise OSError("asset changed")
                raw = os.read(descriptor, MAX_ASSET_BYTES + 1)
            finally:
                os.close(descriptor)
            if len(raw) != metadata.st_size:
                raise OSError("asset changed")
            return raw
        except OSError as exc:
            raise AdminError("asset_unavailable") from exc

    def _invoke(self, operation: str, binding: str) -> None:
        if not self.server.limiter.allow(binding, operation):  # type: ignore[attr-defined]
            self._json_error(429, "rate_limited")
            return
        request_id = str(uuid.uuid4())
        audit = self.server.audit  # type: ignore[attr-defined]
        started = time.monotonic()
        audit.emit(request_id=request_id, action=operation, state="requested", result_code="pending", duration_ms=0)
        audit.emit(request_id=request_id, action=operation, state="started", result_code="pending", duration_ms=0)
        try:
            response = self.server.helper.invoke(operation, request_id)  # type: ignore[attr-defined]
            duration = min(int((time.monotonic() - started) * 1000), 3_600_000)
            audit.emit(
                request_id=request_id,
                action=operation,
                state="completed" if response["ok"] else "failed",
                result_code=response["result_code"],
                duration_ms=duration,
            )
            code = 200
            if not response["ok"]:
                code = {
                    "mutation_lock_busy": 409,
                    "operation_timeout": 504,
                    "observation_unavailable": 503,
                    "helper_protocol_error": 502,
                }.get(str(response["result_code"]), 502)
            payload = json.dumps(response, allow_nan=False, ensure_ascii=True, separators=(",", ":")).encode("ascii")
            self._write(code, "application/json; charset=utf-8", payload)
        except AdminError as exc:
            duration = min(int((time.monotonic() - started) * 1000), 3_600_000)
            audit.emit(
                request_id=request_id,
                action=operation,
                state="failed",
                result_code=exc.code,
                duration_ms=duration,
            )
            status = {
                "helper_unavailable": 503,
                "privilege_denied": 503,
                "mutation_lock_busy": 409,
                "operation_timeout": 504,
                "helper_protocol_error": 502,
            }.get(exc.code, 502)
            self._json_error(status, exc.code)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = self._preflight()
        if path is None:
            return
        if path == "/":
            try:
                binding, csrf = self.server.sessions.issue(  # type: ignore[attr-defined]
                    replace=_cookie_binding(self.headers)
                )
                template = self._asset("index.html")
                if template.count(b"{{CSRF_TOKEN}}") != 1:
                    raise AdminError("asset_unavailable")
                payload = template.replace(b"{{CSRF_TOKEN}}", csrf.encode("ascii"))
                cookie = (
                    f"{SESSION_COOKIE}={binding}; HttpOnly; SameSite=Strict; Path=/; "
                    f"Max-Age={SESSION_ABSOLUTE_SECONDS}"
                )
                self._write(200, "text/html; charset=utf-8", payload, headers={"Set-Cookie": cookie})
            except AdminError:
                self._json_error(503, "asset_unavailable")
            return
        assets = {
            "/assets/admin.css": ("admin.css", "text/css; charset=utf-8"),
            "/assets/admin.js": ("admin.js", "text/javascript; charset=utf-8"),
        }
        if path in assets:
            try:
                filename, content_type = assets[path]
                self._write(200, content_type, self._asset(filename))
            except AdminError:
                self._json_error(503, "asset_unavailable")
            return
        if path == "/api/status":
            binding = _cookie_binding(self.headers)
            if binding is None or not self.server.sessions.validate(binding):  # type: ignore[attr-defined]
                self._json_error(403, "session_invalid")
                return
            self._invoke("status", binding)
            return
        self._json_error(404, "not_found")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = self._preflight()
        if path is None:
            return
        if path != "/api/actions/health":
            self._json_error(404, "not_found")
            return
        origins = self.headers.get_all("Origin", [])
        csrf_values = self.headers.get_all("X-CSRF-Token", [])
        binding = _cookie_binding(self.headers)
        if origins != [EXPECTED_ORIGIN] or len(csrf_values) != 1 or binding is None:
            self._json_error(403, "request_boundary_rejected")
            return
        if not self.server.sessions.validate(binding, csrf=csrf_values[0]):  # type: ignore[attr-defined]
            self._json_error(403, "request_boundary_rejected")
            return
        try:
            _parse_empty_object(self)
        except AdminError as exc:
            status = {"unsupported_media_type": 415, "payload_too_large": 413}.get(exc.code, 400)
            self._json_error(status, exc.code)
            return
        self._invoke("health", binding)

    def do_OPTIONS(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self._preflight() is not None:
            self._json_error(405, "method_not_allowed")

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self._preflight() is not None:
            self._json_error(405, "method_not_allowed")

    def do_PUT(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self._preflight() is not None:
            self._json_error(405, "method_not_allowed")

    def log_message(self, _format: str, *_args: object) -> None:
        return


def create_server() -> AdminHTTPServer:
    """Create the production listener; no caller or environment can override it."""

    return AdminHTTPServer(
        (BIND_ADDRESS, BIND_PORT),
        helper=SudoHelperClient(),
        sessions=SessionStore(),
        limiter=RateLimiter(),
        static_directory=STATIC_DIR,
        audit=JournalAudit(),
    )


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments:
        return 64
    server = create_server()
    print(f"WARP Admin Console listening on http://{BIND_ADDRESS}:{BIND_PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
