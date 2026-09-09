#!/usr/bin/env python3
"""Linux TCP restart regressions using the shipped Admin server and handler."""

from contextlib import contextmanager
import errno
import io
import json
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from admin import application
from admin_console_test import FakeHelper
import admin_deploy_test


def new_server(address=("127.0.0.1", 0), server_type=application.AdminHTTPServer):
    return server_type(
        address, management_address="172.21.31.5", helper=FakeHelper(),
        sessions=application.SessionStore(), limiter=application.RateLimiter(),
        static_directory=ROOT / "admin/static", audit=application.NullAudit(),
    )


@contextmanager
def serving(server):
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        if thread.is_alive():
            raise AssertionError("test listener did not stop")


def server_closed_http(address):
    """Wait for server EOF BEFORE closing client: server owns TCP TIME_WAIT."""
    with socket.create_connection(address, timeout=3) as client:
        client.sendall(b"GET / HTTP/1.0\r\nHost: 172.21.31.5:8788\r\n\r\n")
        response = bytearray()
        while chunk := client.recv(8192):
            response.extend(chunk)
        if not response.startswith(b"HTTP/1.0 200 "):
            raise AssertionError("real Admin HTTP request failed")


def time_wait_present(address):
    encoded_ip = socket.inet_aton(address[0])[::-1].hex().upper()
    endpoint = f"{encoded_ip}:{address[1]:04X}"
    return any(fields[1] == endpoint and fields[3] == "06"
               for line in Path("/proc/net/tcp").read_text().splitlines()[1:]
               if len(fields := line.split()) >= 4)


class LegacyServer(application.AdminHTTPServer):
    allow_reuse_address = False
    allow_reuse_port = False


@unittest.skipUnless(sys.platform == "linux", "Linux TCP semantics required")
class ListenerRestartTests(unittest.TestCase):
    def test_legacy_server_reproduces_time_wait_bind_failure(self):
        with serving(new_server(server_type=LegacyServer)) as first:
            address = first.server_address
            server_closed_http(address)
        self.assertTrue(time_wait_present(address), "fixture must establish server-side TIME_WAIT")
        with self.assertRaises(OSError) as caught:
            with new_server(address, LegacyServer):
                self.fail("legacy listener unexpectedly rebound")
        self.assertEqual(caught.exception.errno, errno.EADDRINUSE)

    def test_immediate_restart_after_real_client_connection(self):
        with serving(new_server()) as first:
            address = first.server_address
            server_closed_http(address)
        self.assertTrue(time_wait_present(address))
        # No retries, bind fallback, or sleep for TIME_WAIT expiry.
        for _ in range(3):
            with serving(new_server(address)):
                server_closed_http(address)

    def test_concurrent_independent_listener_is_rejected(self):
        with serving(new_server()) as first:
            with self.assertRaises(OSError) as caught:
                with new_server(first.server_address):
                    self.fail("concurrent listener unexpectedly bound")
            self.assertEqual(caught.exception.errno, errno.EADDRINUSE)
            server_closed_http(first.server_address)

    def test_actual_socket_options_and_ipv4_family(self):
        with new_server() as server:
            self.assertEqual(server.socket.family, socket.AF_INET)
            self.assertEqual(server.socket.getsockname()[0], "127.0.0.1")
            self.assertEqual(server.socket.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR), 1)
            self.assertFalse(server.allow_reuse_port)
            self.assertEqual(server.socket.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT), 0)
            self.assertEqual(application.BIND_PORT, 8788)

    def test_reuse_cannot_retroactively_change_legacy_time_wait(self):
        with serving(new_server(server_type=LegacyServer)) as first:
            address = first.server_address
            server_closed_http(address)
        self.assertTrue(time_wait_present(address))
        with mock.patch.object(application.AdminHTTPServer, "allow_reuse_address", True):
            with self.assertRaises(OSError) as caught:
                with new_server(address):
                    self.fail("old non-reusable TIME_WAIT must not be hidden")
        self.assertEqual(caught.exception.errno, errno.EADDRINUSE)


# Only the privileged helper is replaced. Each child imports and serves the
# actual source/installed application, handler and static assets in a NEW process.
LISTENER_CHILD = r'''
import pathlib, sys
sys.path.insert(0, sys.argv[1])
from admin import application as app
from admin.protocol import unknown_evidence
class ReadOnlyHelper:
    def invoke(self, operation, request_id):
        return dict(protocol=1, request_id=request_id, operation=operation,
                    ok=True, result_code="ok", changed=False, state="ok",
                    evidence=unknown_evidence())
server = app.AdminHTTPServer(
    (sys.argv[2], 8788), management_address="172.21.31.5",
    helper=ReadOnlyHelper(), sessions=app.SessionStore(), limiter=app.RateLimiter(),
    static_directory=pathlib.Path(app.__file__).parent / "static", audit=app.NullAudit())
print("LISTENER_READY", flush=True)
server.serve_forever()
'''


class ListenerController:
    """Private test service manager: controls only children it created, no sudo."""

    def __init__(self, area):
        self.area = area
        # An exact local-only address, port 8788. No interface/route changes.
        # Separate addresses prevent unrelated concurrent fixtures sharing a port.
        unique = time.monotonic_ns() & 0xFFFFFF
        self.address = (f"127.{unique >> 16}.{(unique >> 8) & 255}.{unique & 255}", 8788)
        self.process = None
        self.started = 0
        self.launches = 0
        self.prior_time_wait = False
        self.rpc = None
        self.thread = None
        self.start(ROOT)
        self.old_pid = self.process.pid
        server_closed_http(self.address)
        controller = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                command = self.rfile.readline(64).decode().strip()
                try:
                    if command == "restart":
                        controller.stop_child()
                        controller.prior_time_wait = time_wait_present(controller.address)
                        controller.start(area / "rootfs/opt/warp-egress-admin-console/app")
                    elif command != "snapshot":
                        raise AssertionError("unexpected fixture command")
                    response = controller.snapshot()
                except Exception:
                    response = {"fixture_error": True}
                self.wfile.write(json.dumps(response).encode() + b"\n")

        self.rpc = socketserver.UnixStreamServer(str(area / "listener-control.sock"), Handler)
        self.thread = threading.Thread(target=self.rpc.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()

    def start(self, app_root):
        self.started = time.monotonic_ns() // 1000
        self.launches += 1
        self.process = subprocess.Popen(
            [sys.executable, "-B", "-c", LISTENER_CHILD, str(app_root), self.address[0]],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        if not select.select([self.process.stdout], [], [], 3)[0] \
                or self.process.stdout.readline() != b"LISTENER_READY\n":
            self.stop_child()
            raise AssertionError("test child could not bind on its single startup attempt")

    def snapshot(self):
        alive = self.process is not None and self.process.poll() is None
        endpoint = f"{socket.inet_aton(self.address[0])[::-1].hex().upper()}:2254"
        listening = any(fields[1] == endpoint and fields[3] == "0A"
                        for line in Path("/proc/net/tcp").read_text().splitlines()[1:]
                        if len(fields := line.split()) >= 4)
        return dict(active="active" if alive else "failed", sub="running" if alive else "dead",
                    pid=self.process.pid if alive else 0, started=self.started, restarts=0,
                    # Translate only the isolated socket address observation;
                    # the production exact-management/8788 gate is not bypassed.
                    listeners=["172.21.31.5:8788"] if alive and listening else [])

    def stop_child(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
            try:
                self.process.wait(timeout=3)
            finally:
                if self.process.poll() is None:
                    self.process.kill()
                    self.process.wait(timeout=3)
                self.process.stdout.close()

    def close(self):
        if self.rpc is not None:
            self.rpc.shutdown()
            self.rpc.server_close()
            self.thread.join(timeout=2)
        self.stop_child()


@unittest.skipUnless(sys.platform == "linux", "Linux TCP/installer fixture required")
class InstallerSocketRestartTests(unittest.TestCase):
    run_migration = admin_deploy_test.AdminInstallerMigrationTests.run_migration

    def test_active_client_used_listener_restarts_and_passes_real_http_gate(self):
        controllers = []

        def transform(source, area):
            controller = ListenerController.__new__(ListenerController)
            # Register cleanup before starting any test-owned child.
            controller.process = controller.rpc = controller.thread = None
            controllers.append(controller)
            controller.__init__(area)
            double = area / "service_double.py"
            text = double.read_text()
            rpc = f'''
def live_snapshot(command):
    import socket
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(5)
        channel.connect({str(area / "listener-control.sock")!r})
        channel.sendall(command.encode() + b"\\n")
        with channel.makefile("rb") as stream:
            result = json.loads(stream.readline(4096))
    assert "fixture_error" not in result, "real listener restart failed"
    return result
'''
            text = text.replace('kind, *args = sys.argv[1:]', 'kind, *args = sys.argv[1:]\n' + rpc)
            text = text.replace('            scenario = state["scenario"]',
                                '            state.update(live_snapshot("restart"))\n            scenario = state["scenario"]')
            text = text.replace('        state["shows"] += 1',
                                '        state.update(live_snapshot("snapshot"))\n        state["shows"] += 1')
            text = text.replace('elif kind == "ss":',
                                'elif kind == "ss":\n    state.update(live_snapshot("snapshot"))')
            double.write_text(text)
            # Restore the REAL installed HTTP smoke block bypassed by the
            # old metadata-only fixture; substitute only TCP destination.
            source = source.replace("if true; then\n  printf 'http GET",
                                    "if [[ ${TEST_MODE} == true ]]; then\n  printf 'http GET")
            source = source.replace('http.client.HTTPConnection(address, 8788, timeout=60)',
                                    f'http.client.HTTPConnection({controller.address[0]!r}, 8788, timeout=60)')
            return source

        try:
            def inspect(_rootfs, result, _state):
                if result.returncode == 0:
                    server_closed_http(controllers[0].address)

            result, state = self.run_migration(transform=transform, inspect=inspect)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            controller = controllers[0]
            self.assertTrue(controller.prior_time_wait, "restart must cross real prior-client TIME_WAIT")
            self.assertEqual(controller.launches, 2, "old process + one replacement; no retries")
            self.assertNotEqual(state["pid"], controller.old_pid)
            self.assertEqual(state["pid"], controller.process.pid)
            self.assertIsNone(controller.process.poll())
            self.assertEqual(state["restarts"], 0)
            self.assertGreaterEqual(state["shows"], 3)
            self.assertEqual(state["listeners"], ["172.21.31.5:8788"])
            self.assertIn("ADMIN_INSTALL_OK", result.stdout)
        finally:
            for controller in controllers:
                controller.close()


class StartupDiagnosticTests(unittest.TestCase):
    def test_network_and_socket_failures_are_distinct_and_sanitized(self):
        for exception, expected in (
            (application.NetworkConfigError("untrusted detail"), "ADMIN_NETWORK_INVALID: trusted management listener unavailable\n"),
            (OSError(errno.EADDRINUSE, "untrusted detail"), "ADMIN_LISTENER_UNAVAILABLE: management socket unavailable\n"),
        ):
            with self.subTest(kind=type(exception).__name__), \
                    mock.patch.object(application, "create_server", side_effect=exception), \
                    mock.patch("sys.stderr", new_callable=io.StringIO) as error:
                self.assertEqual(application.main([]), 78)
                self.assertEqual(error.getvalue(), expected)


if __name__ == "__main__":
    unittest.main()
