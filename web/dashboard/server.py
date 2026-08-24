#!/usr/bin/python3 -I
"""Loopback-only HTTP server for validated read-only dashboard snapshots."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import stat
from typing import Callable, Mapping, Protocol, Sequence
from urllib.parse import urlsplit

from web.dashboard.schema import (
    MAX_STATUS_BYTES,
    StatusValidationError,
    is_stale,
    loads_status,
    validate_status,
)


LISTEN_ADDRESS = "127.0.0.1"
DEFAULT_PORT = 8787
SNAPSHOT_PATH = Path("/run/warp-egress-dashboard/status.json")
PACKAGE_DIR = Path(__file__).resolve().parent
STATIC_DIR = PACKAGE_DIR / "static"
FIXTURE_DIR = PACKAGE_DIR / "fixtures"
MAX_ASSET_BYTES = 256 * 1024
FIXTURE_NAMES = {"healthy", "degraded", "failed"}
CSP = "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; base-uri 'none'; frame-ancestors 'none'"


class StatusUnavailable(RuntimeError):
    """The server cannot safely return the requested status snapshot."""


class StatusProvider(Protocol):
    def read(self) -> dict[str, object]:
        """Return one validated status document."""


class SnapshotProvider:
    def __init__(self, path: Path = SNAPSHOT_PATH) -> None:
        self.path = path

    def read(self) -> dict[str, object]:
        try:
            metadata = self.path.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0 or metadata.st_size > MAX_STATUS_BYTES:
                raise StatusUnavailable("snapshot metadata is unsafe")
            descriptor = os.open(self.path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                opened = os.fstat(descriptor)
                if not stat.S_ISREG(opened.st_mode) or opened.st_size != metadata.st_size:
                    raise StatusUnavailable("snapshot changed while opening")
                payload = os.read(descriptor, MAX_STATUS_BYTES + 1)
            finally:
                os.close(descriptor)
            if len(payload) != metadata.st_size:
                raise StatusUnavailable("snapshot changed while reading")
            return loads_status(payload)
        except (OSError, StatusValidationError, StatusUnavailable) as exc:
            raise StatusUnavailable("status snapshot is unavailable") from exc


class FixtureProvider:
    def __init__(
        self,
        name: str,
        *,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        if name not in FIXTURE_NAMES:
            raise ValueError("fixture must be healthy, degraded, or failed")
        self.name = name
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._fixture = loads_status((FIXTURE_DIR / f"{name}.json").read_bytes())

    def read(self) -> dict[str, object]:
        value = dict(self._fixture)
        value["generated_at"] = self._now().astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        return validate_status(value)


class DashboardHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple[str, int],
        provider: StatusProvider,
        static_directory: Path,
    ) -> None:
        self.provider = provider
        self.static_directory = static_directory
        super().__init__(server_address, DashboardHandler)


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "warp-dashboard"
    sys_version = ""

    def _write(
        self,
        status_code: int,
        content_type: str,
        payload: bytes,
        *,
        head_only: bool = False,
        extra_headers: Mapping[str, str] | None = None,
    ) -> None:
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        if not head_only:
            self.wfile.write(payload)

    def _asset(self, filename: str) -> bytes:
        path = self.server.static_directory / filename  # type: ignore[attr-defined]
        try:
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0 or metadata.st_size > MAX_ASSET_BYTES:
                raise OSError("unsafe asset")
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                payload = os.read(descriptor, MAX_ASSET_BYTES + 1)
            finally:
                os.close(descriptor)
            if len(payload) != metadata.st_size:
                raise OSError("asset changed")
            return payload
        except OSError as exc:
            raise StatusUnavailable("asset unavailable") from exc

    def _route(self, *, head_only: bool) -> None:
        path = urlsplit(self.path).path
        if path == "/api/status":
            try:
                value = self.server.provider.read()  # type: ignore[attr-defined]
                payload = json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode("ascii")
                stale = "true" if is_stale(value) else "false"
                self._write(200, "application/json; charset=utf-8", payload, head_only=head_only, extra_headers={"X-Warp-Status-Stale": stale})
            except (StatusUnavailable, StatusValidationError, OSError, TypeError, ValueError):
                payload = b'{"error":"status_unavailable"}'
                self._write(503, "application/json; charset=utf-8", payload, head_only=head_only)
            return
        if path == "/healthz":
            self._write(200, "application/json; charset=utf-8", b'{"ok":true}', head_only=head_only)
            return
        assets = {
            "/": ("index.html", "text/html; charset=utf-8"),
            "/assets/styles.css": ("styles.css", "text/css; charset=utf-8"),
            "/assets/app.js": ("app.js", "text/javascript; charset=utf-8"),
        }
        asset = assets.get(path)
        if asset is None:
            self._write(404, "application/json; charset=utf-8", b'{"error":"not_found"}', head_only=head_only)
            return
        try:
            self._write(200, asset[1], self._asset(asset[0]), head_only=head_only)
        except StatusUnavailable:
            self._write(503, "application/json; charset=utf-8", b'{"error":"asset_unavailable"}', head_only=head_only)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._route(head_only=False)

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._route(head_only=True)

    def log_message(self, format_string: str, *args: object) -> None:
        super().log_message(format_string, *args)


def create_server(
    listen: str,
    port: int,
    provider: StatusProvider,
    *,
    static_directory: Path = STATIC_DIR,
) -> DashboardHTTPServer:
    if listen != LISTEN_ADDRESS:
        raise ValueError("dashboard listener must be exactly 127.0.0.1")
    if type(port) is not int or not 0 <= port <= 65535:
        raise ValueError("port is invalid")
    return DashboardHTTPServer((LISTEN_ADDRESS, port), provider, static_directory)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="WARP Gateway read-only dashboard")
    parser.add_argument("--listen", default=LISTEN_ADDRESS)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--fixture", choices=sorted(FIXTURE_NAMES))
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    provider: StatusProvider = FixtureProvider(arguments.fixture) if arguments.fixture else SnapshotProvider()
    server = create_server(arguments.listen, arguments.port, provider)
    print(f"WARP dashboard listening on http://{LISTEN_ADDRESS}:{server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
