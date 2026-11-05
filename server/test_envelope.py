"""Explicit fixed-envelope cases; ordinary admission discovery does not select these.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import socket
import threading
import time
import unittest

import deployment_envelope as evidence
import test_capacity as capacity
import test_runtime as runtime


class EnvelopeTests(unittest.TestCase):
    postgres_factory = None
    url = runtime.RuntimeTests.__dict__["url"]
    raw_request = runtime.RuntimeTests.__dict__["raw_request"]
    request = runtime.RuntimeTests.__dict__["request"]
    stop_server = runtime.RuntimeTests.__dict__["stop_server"]
    export_view = runtime.RuntimeTests.__dict__["export_view"]
    environment = capacity.CapacityTests.__dict__["environment"]
    separate_server = capacity.CapacityTests.separate_server

    @classmethod
    def setUpClass(cls):
        if not callable(cls.postgres_factory):
            raise AssertionError("The envelope requires an explicitly selected owned PostgreSQL 18 provider.")
        runtime.RuntimeTests.setUpClass.__func__(cls)

    def slow_export(self, path, maximum, ready=None, release=None):
        record = {"path": path, "valid_request": True, "status": None, "body_bytes": 0, "outcome": "truncated"}
        started = time.monotonic_ns()
        deadline = time.monotonic() + 14
        try:
            with socket.socket() as connection:
                connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                connection.settimeout(3)
                connection.connect(("127.0.0.1", self.port))
                connection.sendall(("GET " + path + " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").encode())
                head = bytearray()
                while b"\r\n\r\n" not in head:
                    self.assertLess(time.monotonic(), deadline, "The slow reader exceeded its total deadline.")
                    connection.settimeout(min(3, max(0.001, deadline - time.monotonic())))
                    chunk = connection.recv(4096)
                    self.assertTrue(chunk, "The maximum export ended before its headers.")
                    head.extend(chunk)
                    self.assertLessEqual(len(head), 16384)
                headers, body = bytes(head).split(b"\r\n\r\n", 1)
                status = headers.split(b"\r\n", 1)[0].split(b" ", 2)
                self.assertTrue(len(status) == 3 and status[0] == b"HTTP/1.1" and status[1].isdigit(), headers[:80])
                record["status"] = int(status[1])
                if record["status"] != 200:
                    record["outcome"] = "refused"
                self.assertEqual(record["status"], 200)
                lengths = [line.split(b":", 1)[1].strip() for line in headers.split(b"\r\n")[1:]
                           if line.lower().startswith(b"content-length:")]
                self.assertEqual(lengths, [str(maximum).encode()], "The maximum export changed its declared byte length.")
                if ready is not None:
                    ready.wait(timeout=3)
                    self.assertTrue(release.wait(timeout=3), "The bounded response holder was not released.")
                # A small receive buffer and a fixed pause exercise response ownership under backpressure.
                time.sleep(0.25)
                connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
                digest = hashlib.sha256(body)
                record["body_bytes"] = len(body)
                while True:
                    self.assertLess(time.monotonic(), deadline, "The slow reader exceeded its total deadline.")
                    connection.settimeout(min(3, max(0.001, deadline - time.monotonic())))
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    record["body_bytes"] += len(chunk)
                    self.assertLessEqual(record["body_bytes"], maximum)
                    digest.update(chunk)
                self.assertEqual(record["body_bytes"], maximum)
                self.assertEqual(digest.digest(), hashlib.sha256(b"x" * maximum).digest())
                record["outcome"] = "complete"
        except (TimeoutError, socket.timeout):
            record["outcome"] = "timeout"
            raise
        except OSError as error:
            record.update(outcome="reset", error=type(error).__name__)
            raise
        finally:
            record["elapsed_ns"] = time.monotonic_ns() - started
            evidence.append_request(self.request_records, record)

    def test_eight_slow_maximum_exports_preserve_bytes_and_recover(self):
        for path, maximum in (("/registry/v1/index.json", 4194304), ("/registry/v1/index.tsv", 1048576)):
            select = ("SELECT route,CASE WHEN route='" + path + "' THEN repeat('x'," + str(maximum) +
                      ") ELSE body END AS body,sha256,media_type,revision,acceptance_commit FROM {source}")
            with self.subTest(path=path), self.export_view(select):
                ready, release = threading.Barrier(9), threading.Event()
                with ThreadPoolExecutor(max_workers=8) as clients:
                    pending = [clients.submit(self.slow_export, path, maximum, ready, release) for _ in range(8)]
                    try:
                        ready.wait(timeout=3)
                        # Observed response holders leave eight HTTP connections available.
                        for path_probe in ("/health/live", "/api/v2/status"):
                            started = time.monotonic()
                            self.assertEqual(self.request(path_probe)[0], 200)
                            self.assertLess(time.monotonic() - started, 0.5)
                    finally:
                        release.set()
                    for result in pending:
                        result.result(timeout=15)
            self.assertEqual(self.request("/health/ready")[0], 200)

    def test_incomplete_headers_release_connections_after_inactivity(self):
        connections = []
        try:
            for _ in range(8):
                connection = socket.create_connection(("127.0.0.1", self.port), timeout=1)
                connection.settimeout(3)
                connection.sendall(b"GET /health/live HTTP/1.1\r\nHost: localhost\r\nX-Incomplete: ")
                connections.append(connection)
            for _ in range(3):
                for connection in connections:
                    connection.sendall(b"x")
                time.sleep(0.1)
            self.assertEqual(self.request("/health/live")[0], 200)
            self.assertEqual(self.request("/api/v2/status")[0], 200)
            for connection in connections:
                record = {"path": "/health/live", "valid_request": False, "status": None,
                          "body_bytes": 0, "outcome": "closed"}
                started = time.monotonic_ns()
                try:
                    body = connection.recv(16385)
                    record["body_bytes"] = len(body)
                    if body:
                        record["outcome"] = "truncated"
                    self.assertEqual(body, b"", "An incomplete header remained admitted after inactivity.")
                except socket.timeout:
                    record["outcome"] = "timeout"
                    raise
                except ConnectionResetError:
                    record["outcome"] = "reset"
                finally:
                    record["elapsed_ns"] = time.monotonic_ns() - started
                    evidence.append_request(self.request_records, record)
        finally:
            for connection in connections:
                connection.close()
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_sigterm_bounds_exit_during_observed_inflight_work(self):
        with self.separate_server() as process:
            generation, _ = self.gate.begin_hold()
            try:
                with ThreadPoolExecutor(max_workers=1) as clients:
                    pending = clients.submit(self.raw_request, "/health/ready")
                    self.assertTrue(self.gate.wait_for_held(1, 0.8, generation), "No in-flight database handshake was observed.")
                    started = time.monotonic()
                    process.terminate()
                    self.assertEqual(process.wait(timeout=3), 0)
                    self.assertLess(time.monotonic() - started, 3)
                    try:
                        pending.result(timeout=3)
                    except (OSError, http.client.HTTPException):
                        # The observer retains the actual response or transport failure.
                        pass
                    with self.assertRaises(OSError):
                        with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                            pass
            finally:
                self.gate.abort_held(generation)
                self.gate.hold_new.clear()
        self.assertEqual(self.request("/health/ready")[0], 200)
