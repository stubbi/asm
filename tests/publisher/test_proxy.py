"""Exercise the same-Pod publisher boundary through a real NGINX process.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "deploy/publisher/nginx.conf"
TASK = "/api/v2/publications/" + "a" * 32
ARTIFACT = TASK + "/artifacts/" + "b" * 64


class Backend(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.handle_request()

    do_POST = do_PUT = do_GET

    def handle_request(self):
        self.connection.settimeout(8)
        state = self.server.state
        headers = dict(self.headers.items())
        state["headers"].put((self.command, self.path, headers))
        if state["mode"] == "disconnect":
            self.close_connection = True
            return
        remaining = int(self.headers.get("Content-Length", "0"))
        digest = hashlib.sha256()
        received = 0
        try:
            while remaining:
                chunk = self.rfile.read1(min(16384, remaining))
                if not chunk:
                    state["aborted"].set()
                    return
                state["first_byte"].set()
                digest.update(chunk)
                received += len(chunk)
                remaining -= len(chunk)
            state["bodies"].put((received, digest.hexdigest()))
            if state["mode"] == "hold":
                state["release"].wait(8)
            duplicate = any(len(self.headers.get_all(field, [])) > 1 for field in
                            ("Authorization", "Idempotency-Key", "Content-Type"))
            status = 400 if duplicate else state["status"]
            payload = str(time.monotonic_ns()).encode("ascii")
            self.send_response(status)
            self.send_header("Content-Length", str(len(payload) if status != 204 else 0))
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            if status != 204:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            state["aborted"].set()
        finally:
            self.close_connection = True


class PublisherProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        selected = os.environ.get("ASM_TEST_NGINX")
        if not selected:
            raise unittest.SkipTest("Set ASM_TEST_NGINX to run the real publisher proxy checks.")
        cls.nginx = shutil.which(selected)
        if not cls.nginx:
            raise RuntimeError("ASM_TEST_NGINX must identify an executable NGINX binary.")
        if not CONFIG.is_file():
            raise AssertionError("The same-Pod publisher NGINX reference is missing.")
        cls.backend = ThreadingHTTPServer(("127.0.0.1", 8080), Backend)
        cls.backend.daemon_threads = True
        cls.addClassCleanup(cls.backend.server_close)
        cls.thread = threading.Thread(target=cls.backend.serve_forever, daemon=True)
        cls.thread.start()
        cls.addClassCleanup(cls.backend.shutdown)
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-publisher-proxy-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.prefix = Path(cls.temporary.name)
        cls.output = (cls.prefix / "process.log").open("w+b")
        cls.addClassCleanup(cls.output.close)
        # Make exports its NGINX selection. NGINX reserves that environment
        # variable for inherited socket descriptors during executable upgrades.
        environment = dict(os.environ)
        environment.pop("NGINX", None)
        cls.process = subprocess.Popen([cls.nginx, "-e", "/dev/null", "-p", str(cls.prefix) + "/",
                                        "-c", str(CONFIG)], stdout=cls.output, stderr=cls.output,
                                       env=environment)
        cls.addClassCleanup(cls.stop_proxy)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if cls.process.poll() is not None:
                cls.output.seek(0)
                raise AssertionError("NGINX startup failed: " + cls.output.read().decode())
            try:
                with socket.create_connection(("127.0.0.1", 8081), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.02)
        raise AssertionError("NGINX did not listen on port 8081 within five seconds.")

    @classmethod
    def stop_proxy(cls):
        cls.process.terminate()
        try:
            cls.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait(timeout=2)

    def setUp(self):
        self.state = {"headers": queue.Queue(), "bodies": queue.Queue(),
                      "first_byte": threading.Event(), "aborted": threading.Event(),
                      "release": threading.Event(), "mode": "normal", "status": 200}
        self.backend.state = self.state
        self.addCleanup(self.state["release"].set)

    def request(self, method, path, body=None, headers=None, *, port=8081):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def raw(self, data, *, port=8081):
        connection = socket.create_connection(("127.0.0.1", port), timeout=8)
        connection.sendall(data)
        return connection

    def test_exact_public_routes_preserve_selected_headers_and_response_status(self):
        for method, path, body, status in (("GET", "/api/v2/status", None, 200),
                                          ("POST", "/api/v2/publications", b"{}", 202),
                                          ("GET", TASK, None, 200),
                                          ("PUT", ARTIFACT, b"abc", 201),
                                          ("PUT", ARTIFACT, b"abc", 204)):
            with self.subTest(method=method, path=path, status=status):
                self.state["status"] = status
                headers = {"Authorization": "Bearer synthetic-publisher-token", "Idempotency-Key": "1" * 32,
                           "Content-Type": "application/octet-stream" if method == "PUT" else "application/json",
                           "X-Forwarded-For": "untrusted", "Cookie": "private"}
                actual, returned, _ = self.request(method, path, body, headers)
                self.assertEqual(actual, status)
                self.assertEqual(returned["Cache-Control"], "no-store")
                upstream_method, upstream_path, upstream_headers = self.state["headers"].get(timeout=2)
                self.assertEqual((upstream_method, upstream_path), (method, path))
                for field in ("Authorization", "Idempotency-Key", "Content-Type"):
                    self.assertEqual(upstream_headers[field], headers[field])
                if body is not None:
                    self.assertEqual(upstream_headers["Content-Length"], str(len(body)))
                self.assertNotIn("Cookie", upstream_headers)
                self.assertNotIn("X-Forwarded-For", upstream_headers)
                self.assertEqual(self.state["bodies"].get(timeout=2),
                                 (len(body or b""), hashlib.sha256(body or b"").hexdigest()))

    def test_private_routes_methods_queries_and_normalized_paths_never_reach_backend(self):
        cases = [("GET", path) for path in ("/", "/health/live", "/health/ready", "/metrics",
                 "/api/v1/packages", "/api/v2/publications", TASK + "/", TASK.upper(),
                 "/api/v2/status?secret=private-query", "/api/v2//status", "/api/v2/./status",
                 "/api/v2/private/../status", "/api/v2/%73tatus", "/api%2fv2/status",
                 "/api/v2/%2e/status", "/api/v2/status%3fprivate", "/api/v2/status/../status",
                 "/api/v2/status;private", TASK + "/artifacts/" + "b" * 63)]
        cases += [(method, path) for method, path in (("HEAD", "/api/v2/status"),
                  ("POST", TASK), ("GET", ARTIFACT), ("DELETE", TASK), ("PATCH", ARTIFACT),
                  ("OPTIONS", "/api/v2/status"), ("PUT", "/api/v2/publications"))]
        for method, path in cases:
            with self.subTest(method=method, path=path):
                self.assertIn(self.request(method, path)[0], (400, 404))
        self.assertTrue(self.state["headers"].empty())

    def test_private_probe_listener_forwards_only_exact_health_gets_and_backend_status(self):
        for path, status in (("/health/live", 200), ("/health/ready", 200), ("/health/ready", 503)):
            with self.subTest(path=path, status=status):
                self.state["status"] = status
                actual, headers, _ = self.request("GET", path, port=8082)
                self.assertEqual(actual, status)
                self.assertEqual(headers["Cache-Control"], "no-store")
                method, upstream_path, _ = self.state["headers"].get(timeout=2)
                self.assertEqual((method, upstream_path), ("GET", path))
                self.assertEqual(self.request("GET", path)[0], 404)
        denied = [("GET", path) for path in ("/", "/api/v2/status", "/api/v2/publications", TASK,
                  ARTIFACT, "/health/ready?private", "/health//ready", "/health/./ready",
                  "/health/%72eady", "/health/ready/", "/health/live/../ready")]
        denied += [(method, "/health/ready") for method in ("HEAD", "POST", "PUT", "DELETE", "OPTIONS")]
        for method, path in denied:
            with self.subTest(method=method, path=path):
                self.assertIn(self.request(method, path, port=8082)[0], (400, 404))
        self.assertTrue(self.state["headers"].empty())

    def test_private_probe_times_out_stalled_backend_without_retry(self):
        self.state["mode"] = "hold"
        started = time.monotonic()
        self.assertEqual(self.request("GET", "/health/ready", port=8082)[0], 504)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(self.state["headers"].qsize(), 1)

    def test_private_probe_rejects_bodies_and_writes_no_private_request_data(self):
        for headers in ("Content-Length: 1\r\n", "Transfer-Encoding: chunked\r\n",
                        "Authorization: " + "x" * 8192 + "\r\n"):
            with self.subTest(headers=headers[:32]), self.raw(
                    ("GET /health/ready HTTP/1.1\r\nHost: publisher\r\n" + headers + "\r\n").encode(),
                    port=8082) as connection:
                self.assertIn(b" 400 ", connection.recv(4096))
        self.assertTrue(self.state["headers"].empty())
        marker = "private-probe-log-marker"
        self.assertEqual(self.request("GET", "/health/ready?" + marker, port=8082)[0], 404)
        self.state["mode"] = "disconnect"
        self.assertEqual(self.request("GET", "/health/ready", headers={"Authorization": "Bearer " + marker},
                                      port=8082)[0], 502)
        _, _, forwarded = self.state["headers"].get(timeout=2)
        self.assertNotIn("Authorization", forwarded)
        self.output.flush()
        self.output.seek(0)
        self.assertEqual(self.output.read(), b"")

    def test_upload_reaches_backend_before_completion_and_disconnect_aborts_upstream(self):
        connection = self.raw((f"PUT {ARTIFACT} HTTP/1.1\r\nHost: publisher\r\n"
                               "Content-Length: 1048576\r\nContent-Type: application/octet-stream\r\n\r\n").encode()
                              + b"a" * 16384)
        try:
            self.assertTrue(self.state["first_byte"].wait(2), "NGINX buffered the unfinished upload.")
        finally:
            connection.close()
        self.assertTrue(self.state["aborted"].wait(2), "The disconnected upload remained open upstream.")
        self.assertTrue(self.state["bodies"].empty())
        self.assertEqual(list((self.prefix / "client_body").iterdir()), [])

    def test_body_limits_reject_oversized_declared_requests_before_forwarding(self):
        for path, length in (("/api/v2/publications", 65537), (ARTIFACT, 67108865)):
            with self.subTest(path=path), self.raw(
                    (f"{'POST' if length == 65537 else 'PUT'} {path} HTTP/1.1\r\n"
                     f"Host: publisher\r\nContent-Length: {length}\r\n\r\n").encode()) as connection:
                self.assertIn(b" 413 ", connection.recv(4096))
        self.assertTrue(self.state["headers"].empty())

    def test_duplicate_authority_headers_remain_visible_to_backend_admission(self):
        for field, value in (("Authorization", "Bearer synthetic-publisher-token"),
                             ("Idempotency-Key", "1" * 32), ("Content-Type", "application/json")):
            with self.subTest(field=field), self.raw(
                    ("POST /api/v2/publications HTTP/1.1\r\nHost: publisher\r\nContent-Length: 2\r\n"
                     f"{field}: {value}\r\n{field}: {value}\r\n\r\n{{}}").encode()) as connection:
                self.assertIn(b" 400 ", connection.recv(4096), "The proxy hid a duplicate authority header.")

    def test_exact_body_limits_stream_without_temporary_files(self):
        for path, length, method in (("/api/v2/publications", 65536, "POST"), (ARTIFACT, 67108864, "PUT")):
            with self.subTest(path=path), self.raw(
                    (f"{method} {path} HTTP/1.1\r\nHost: publisher\r\nContent-Length: {length}\r\n\r\n").encode()) as connection:
                block = b"a" * 16384
                for _ in range(length // len(block)):
                    connection.sendall(block)
                self.assertIn(b" 200 ", connection.recv(4096))
                self.assertEqual(self.state["bodies"].get(timeout=2)[0], length)
        self.assertEqual(list((self.prefix / "client_body").iterdir()), [])

    def test_ambiguous_framing_and_large_headers_never_reach_backend(self):
        for headers, status in (("Transfer-Encoding: chunked\r\n", 400),
                                ("Content-Length: 1\r\nContent-Length: 1\r\n", 400),
                                ("Authorization: " + "x" * 8192 + "\r\n", 400),
                                ("", 411)):
            with self.subTest(status=status), self.raw(
                    ("POST /api/v2/publications HTTP/1.1\r\nHost: publisher\r\n" + headers + "\r\n").encode()) as connection:
                self.assertIn(f" {status} ".encode(), connection.recv(4096))
        self.assertTrue(self.state["headers"].empty())

    def test_backend_failure_is_not_retried_and_responses_are_not_cached(self):
        first = self.request("GET", "/api/v2/status")
        second = self.request("GET", "/api/v2/status")
        self.assertEqual((first[0], second[0]), (200, 200))
        self.assertNotEqual(first[2], second[2])
        self.state["mode"] = "disconnect"
        self.assertEqual(self.request("POST", "/api/v2/publications", b"{}")[0], 502)
        self.assertEqual(self.state["headers"].qsize(), 3)

    def test_active_request_limit_refuses_seventeenth_request(self):
        self.state["mode"] = "hold"
        connections = []
        try:
            for _ in range(16):
                connections.append(self.raw(b"GET /api/v2/status HTTP/1.1\r\nHost: publisher\r\n\r\n"))
                self.state["headers"].get(timeout=2)
            self.assertEqual(self.request("GET", "/api/v2/status")[0], 429)
            self.assertTrue(self.state["headers"].empty())
        finally:
            self.state["release"].set()
            for connection in connections:
                try:
                    connection.recv(4096)
                finally:
                    connection.close()

    def test_partial_header_and_body_requests_have_idle_time_limits(self):
        started = time.monotonic()
        with self.raw(b"GET /api/v2/status HTTP/1.1\r\nHost:") as header, self.raw(
                (f"PUT {ARTIFACT} HTTP/1.1\r\nHost: publisher\r\nContent-Length: 1024\r\n\r\na").encode()) as body:
            for connection in (header, body):
                try:
                    response = connection.recv(4096)
                    self.assertTrue(not response or b" 408 " in response, response)
                except ConnectionResetError:
                    pass
        self.assertLess(time.monotonic() - started, 7)
        self.assertTrue(self.state["aborted"].wait(2))

    def test_request_secrets_and_paths_are_not_written_to_proxy_logs(self):
        marker = "private-proxy-log-marker"
        self.request("GET", "/api/v2/status?" + marker, headers={"Authorization": "Bearer " + marker})
        self.state["mode"] = "disconnect"
        self.request("POST", "/api/v2/publications", b"{}", {"Authorization": "Bearer " + marker})
        self.output.flush()
        self.output.seek(0)
        self.assertEqual(self.output.read(), b"")
        self.assertFalse((self.prefix / "logs/access.log").exists())
        self.assertFalse((self.prefix / "logs/error.log").exists())


if __name__ == "__main__":
    unittest.main()
