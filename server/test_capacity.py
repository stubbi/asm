"""Check native database admission through HTTP and an owned TCP fixture.

SPDX-License-Identifier: AGPL-3.0-or-later
Python supplies test orchestration only. TLS and PostgreSQL remain unchanged.
This candidate needs a built Linux runtime and the existing fixture tools.
"""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import os
from pathlib import Path
import select
import socket
import stat
import subprocess
import threading
import time
import unittest

import test_runtime as runtime


def null_connection_fixture():
    """Accept one precompiled fixture; its environment and parent paths are trusted."""
    value = os.environ.get("ASM_SERVER_CONNECT_NULL_FIXTURE")
    if not value:
        raise AssertionError("ASM_SERVER_CONNECT_NULL_FIXTURE must identify the precompiled read-only .so fixture.")
    path = Path(value)
    if not path.is_absolute() or path.suffix != ".so":
        raise AssertionError("ASM_SERVER_CONNECT_NULL_FIXTURE must be an absolute .so path.")
    if any(path.is_relative_to(Path(directory)) for directory in ("/tmp", "/var/tmp", "/private/tmp", "/private/var/tmp")):
        raise AssertionError("The precompiled null-connection fixture must be outside system temporary directories.")
    try:
        if path.resolve(strict=True) != path:
            raise AssertionError("The precompiled null-connection fixture path must contain no symbolic link.")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o222:
                raise AssertionError("The precompiled null-connection fixture must be a read-only regular file.")
            if metadata.st_uid not in (0, os.geteuid()):
                raise AssertionError("The precompiled null-connection fixture must belong to the current UID or root.")
        finally:
            os.close(descriptor)
    except (OSError, RuntimeError) as error:
        raise AssertionError("The precompiled null-connection fixture is unavailable or is a symbolic link.") from error
    return str(path)


class HandshakeGate:
    """Forward opaque bytes, or hold new connections before TLS negotiation."""

    def __init__(self, target_port):
        self.target_port = target_port
        self.hold_new = threading.Event()
        self.stopping = threading.Event()
        self.changed = threading.Condition()
        self.held = {}
        self.peer_closed = {}
        self.peak_held = {}
        self.generation = 0
        self.accepted = 0
        self.clients = set()
        self.workers = []
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(16)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stopping.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self.changed:
                self.accepted += 1
                self.clients.add(client)
                generation = self.generation if self.hold_new.is_set() else None
            worker = threading.Thread(target=self.connection,
                                      args=(client, generation), daemon=True)
            self.workers.append(worker)
            worker.start()

    def connection(self, client, generation):
        observed_close = False
        try:
            with client:
                if generation is not None:
                    # Observe protocol bytes before declaring the handshake held.
                    readable, _, _ = select.select([client], [], [], 1)
                    if not readable or not client.recv(1, socket.MSG_PEEK):
                        return
                    with self.changed:
                        self.held[client] = generation
                        current = sum(value == generation for value in self.held.values())
                        self.peak_held[generation] = max(current, self.peak_held.get(generation, 0))
                        self.changed.notify_all()
                    deadline = time.monotonic() + 3
                    while not self.stopping.is_set() and time.monotonic() < deadline:
                        readable, _, _ = select.select([client], [], [], 0.1)
                        if readable and not client.recv(65536):
                            observed_close = True
                            return
                    return
                with socket.create_connection(("127.0.0.1", self.target_port), timeout=1) as server:
                    client.settimeout(3)
                    server.settimeout(3)
                    while not self.stopping.is_set():
                        readable, _, _ = select.select([client, server], [], [], 0.1)
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                return
                            (server if source is client else client).sendall(data)
        except (OSError, ValueError):
            return
        finally:
            with self.changed:
                if observed_close:
                    self.peer_closed[generation] = self.peer_closed.get(generation, 0) + 1
                self.held.pop(client, None)
                self.clients.discard(client)
                self.changed.notify_all()

    def begin_hold(self):
        with self.changed:
            self.generation += 1
            self.hold_new.set()
            return self.generation, self.accepted

    def wait_for_held(self, count, timeout, generation):
        with self.changed:
            return self.changed.wait_for(
                lambda: sum(value == generation for value in self.held.values()) >= count, timeout)

    def wait_for_peer_close(self, count, timeout, generation):
        with self.changed:
            return self.changed.wait_for(lambda: self.peer_closed.get(generation, 0) >= count, timeout)

    def abort_held(self, generation, *, keep=(), limit=None):
        with self.changed:
            clients = [client for client, value in self.held.items() if value == generation and client not in keep]
            if limit is not None:
                clients = clients[:limit]
            for client in clients:
                try:
                    client.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                client.close()
                # Remove only after shutdown/close, before another worker records a new live socket.
                self.held.pop(client, None)
            self.changed.notify_all()
            return len(clients)

    def close(self):
        self.stopping.set()
        self.listener.close()
        with self.changed:
            clients = list(self.clients)
        for client in clients:
            client.close()
        deadline = time.monotonic() + 3
        self.thread.join(timeout=3)
        for worker in self.workers:
            worker.join(timeout=max(0, deadline - time.monotonic()))
        if self.thread.is_alive() or any(worker.is_alive() for worker in self.workers):
            raise AssertionError("The owned TCP fixture did not stop within three seconds.")


class CapacityTests(unittest.TestCase):
    # Reuse the existing real canonical fixture without running or editing its tests.
    postgres_factory = staticmethod(runtime.TlsPostgres)
    setUpClass = runtime.RuntimeTests.__dict__["setUpClass"]
    url = runtime.RuntimeTests.__dict__["url"]
    raw_request = runtime.RuntimeTests.__dict__["raw_request"]
    request = runtime.RuntimeTests.__dict__["request"]
    stop_server = runtime.RuntimeTests.__dict__["stop_server"]
    export_view = runtime.RuntimeTests.__dict__["export_view"]

    @classmethod
    def environment(cls, **changes):
        env = runtime.RuntimeTests.environment.__func__(cls, **changes)
        if not hasattr(cls, "gate"):
            cls.gate = HandshakeGate(cls.cluster.port)
            cls.addClassCleanup(cls.gate.close)
            path = cls.base / "capacity-reader.url"
            path.write_text(cls.configs["reader"].read_text().replace(
                f":{cls.cluster.port}/", f":{cls.gate.port}/"))
            path.chmod(0o600)
            cls.gate_config = path
        env["ASM_DATABASE_URL_FILE"] = str(cls.gate_config)
        return env

    @classmethod
    def timed_request(cls, path):
        started = time.monotonic()
        response = cls.raw_request(path)
        return response, time.monotonic() - started

    def assert_unavailable(self, response):
        code, headers, body = response
        self.assertEqual(code, 503)
        self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(body, b'{"error":{"code":"temporarily_unavailable","message":'
                              b'"The database request could not finish. Try again shortly."}}\n')

    def assert_healthy(self):
        self.assertIsNone(self.server.poll())
        self.assertEqual(self.request("/health/ready")[0], 200)
        for _ in range(2):
            for path, expected in self.exports.items():
                code, _, body = self.raw_request(path)
                self.assertEqual(code, 200)
                self.assertEqual(body, expected)

    def assert_full_capacity_after_recovery(self):
        """A fresh full wave detects even one unreleased or double-released slot."""
        self.assert_healthy()
        pid = self.server.pid
        generation, before = self.gate.begin_hold()
        try:
            with ThreadPoolExecutor(max_workers=8) as clients:
                pending = [clients.submit(self.timed_request, "/health/ready") for _ in range(8)]
                self.assertTrue(self.gate.wait_for_held(8, 0.8, generation),
                                "Recovery did not restore all eight database slots.")
                self.assertTrue(all(not item.done() for item in pending))
                response, elapsed = self.timed_request("/health/ready")
                self.assert_unavailable(response)
                self.assertLess(elapsed, 0.5)
                for item in pending:
                    response, elapsed = item.result(timeout=3)
                    self.assert_unavailable(response)
                    self.assertLess(elapsed, 2.8)
                with self.gate.changed:
                    self.assertEqual(self.gate.accepted - before, 8,
                                     "Recovery admitted more than eight database connections.")
        finally:
            self.gate.hold_new.clear()
        self.assertEqual(self.server.pid, pid)
        self.assert_healthy()

    @contextmanager
    def separate_server(self, **changes):
        """Own a second runtime process for a test-only library failure fixture."""
        cls = type(self)
        original_port, original_server = cls.port, cls.server
        process = None
        try:
            cls.port = runtime.free_port()
            process = subprocess.Popen([str(self.binary), "serve"], env=cls.environment(**changes),
                                       stdout=self.log, stderr=self.log)
            cls.server = process
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                self.assertIsNone(process.poll(), "The isolated failure-fixture runtime stopped during startup.")
                try:
                    if self.request("/health/live")[0] == 200:
                        break
                except OSError:
                    time.sleep(0.02)
            else:
                self.fail("The isolated failure-fixture runtime did not become live within five seconds.")
            yield process
        finally:
            try:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        self.assertEqual(process.wait(timeout=3), 0)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)
                        self.fail("The isolated failure-fixture runtime exceeded its shutdown bound.")
            finally:
                cls.port, cls.server = original_port, original_server

    def test_successful_reads_release_admission_repeatedly(self):
        """Omitting the success-path release must exhaust the eight-slot budget."""
        for _ in range(3):
            self.assert_healthy()
        self.assert_full_capacity_after_recovery()

    def test_sixteen_contending_requests_never_hold_more_than_eight_connections(self):
        """Concurrent acquisitions must preserve the same eight-connection maximum."""
        generation, _ = self.gate.begin_hold()
        start = threading.Barrier(16, timeout=1)

        def contend():
            start.wait()
            return self.timed_request("/health/ready")

        try:
            # The existing HTTP connection bound is sixteen; add no seventeenth probe.
            with ThreadPoolExecutor(max_workers=16) as clients:
                pending = [clients.submit(contend) for _ in range(16)]
                deadline = time.monotonic() + 0.8
                while time.monotonic() < deadline:
                    with self.gate.changed:
                        held = sum(value == generation for value in self.gate.held.values())
                    if held + sum(item.done() for item in pending) == 16:
                        break
                    time.sleep(0.005)
                else:
                    self.fail("The contention requests were not admitted or refused before the unchanged handshake budget.")
                with self.gate.changed:
                    peak = self.gate.peak_held.get(generation, 0)
                    self.assertEqual(self.gate.peer_closed.get(generation, 0), 0,
                                     "A holder closed before the simultaneous-connection observation.")
                    self.assertGreater(peak, 0, "The contention fixture observed no admitted database work.")
                    self.assertLessEqual(peak, 8, "Concurrent admission exceeded eight reader connections.")
                for item in pending:
                    if item.done():
                        response, elapsed = item.result()
                        self.assert_unavailable(response)
                        self.assertLess(elapsed, 0.5)
                # Observe the peak before releasing sockets, so stale EOF observations cannot inflate it.
                self.gate.abort_held(generation)
                for item in pending:
                    response, elapsed = item.result(timeout=3)
                    self.assert_unavailable(response)
                    self.assertLess(elapsed, 2.8)
        finally:
            self.gate.hold_new.clear()
        self.assert_full_capacity_after_recovery()

    def test_replacement_acquisitions_overlap_individual_releases(self):
        """Four retained readers must stay bounded while six clients compete for released slots."""
        generation, _ = self.gate.begin_hold()
        stop = threading.Event()
        start = threading.Barrier(7, timeout=1)
        initial = []
        replacements = []

        def replace():
            start.wait()
            attempts = 0
            while not stop.is_set() and attempts < 32:
                response, elapsed = self.timed_request("/health/ready")
                self.assert_unavailable(response)
                self.assertLess(elapsed, 2.8)
                attempts += 1
                stop.wait(0.02)
            return attempts

        try:
            with ThreadPoolExecutor(max_workers=14) as clients:
                initial = [clients.submit(self.timed_request, "/health/ready") for _ in range(8)]
                self.assertTrue(self.gate.wait_for_held(8, 0.8, generation))
                with self.gate.changed:
                    original = {client for client, value in self.gate.held.items() if value == generation}
                    retained = set(list(original)[:4])
                replacements = [clients.submit(replace) for _ in range(6)]
                overlap_started = time.monotonic()
                cleanup_done = False
                try:
                    start.wait()
                    overlap_started = time.monotonic()
                    for expected in range(1, 5):
                        self.assertEqual(self.gate.abort_held(generation, keep=retained, limit=1), 1)
                        with self.gate.changed:
                            self.assertTrue(self.gate.changed.wait_for(
                                lambda: sum(value == generation and client not in original
                                            for client, value in self.gate.held.items()) >= expected,
                                max(0, overlap_started + 0.5 - time.monotonic())),
                                "A replacement did not acquire an individually released database slot.")
                            self.assertTrue(all(self.gate.held.get(client) == generation for client in retained),
                                            "A retained reader ended before the acquisition/release overlap check.")
                            self.assertLessEqual(self.gate.peak_held.get(generation, 0), 8,
                                                 "Overlapping acquisition and release exceeded eight reader connections.")
                    self.assertLess(time.monotonic() - overlap_started, 0.5)
                finally:
                    stop.set()
                    cleanup_deadline = time.monotonic() + 0.5
                    while time.monotonic() < cleanup_deadline:
                        self.gate.abort_held(generation)
                        if all(item.done() for item in initial + replacements):
                            cleanup_done = True
                            break
                        time.sleep(0.005)
                self.assertTrue(cleanup_done, "The bounded overlap fixture did not stop all admitted or refused work promptly.")
                for item in initial:
                    response, elapsed = item.result()
                    self.assert_unavailable(response)
                    self.assertLess(elapsed, 2.8)
                self.assertTrue(all(item.result() > 0 for item in replacements))
        finally:
            stop.set()
            self.gate.abort_held(generation)
            self.gate.hold_new.clear()
        self.assert_full_capacity_after_recovery()

    def test_tls_failures_release_admission_before_recovery(self):
        """TLS identity refusal must not consume slots across later requests."""
        cert, key = (self.cluster.base / name for name in ("reader.crt", "reader.key"))
        original_cert, original_key = cert.read_bytes(), key.read_bytes()
        try:
            cert.write_bytes((self.cluster.base / "operator.crt").read_bytes())
            key.write_bytes((self.cluster.base / "operator.key").read_bytes())
            for _ in range(9):
                self.assert_unavailable(self.raw_request("/health/ready"))
                self.assertEqual(self.request("/health/live")[0], 200)
        finally:
            cert.write_bytes(original_cert)
            key.write_bytes(original_key)
        self.assert_full_capacity_after_recovery()

    def test_guard_failures_release_admission_before_recovery(self):
        """A refused reader guard must release its connection and admission."""
        role = self.roles["reader"]
        self.admin.execute(f'REVOKE SELECT ON asm_catalog.current_exports FROM "{role}"')
        try:
            for _ in range(9):
                self.assert_unavailable(self.raw_request("/registry/v1/index.json"))
        finally:
            self.admin.execute(f'GRANT SELECT ON asm_catalog.current_exports TO "{role}"')
        self.assert_full_capacity_after_recovery()

    def test_invalid_results_release_admission_before_recovery(self):
        """Null, duplicate, and oversized database results must not leak slots."""
        columns = "route,body,sha256,media_type,revision,acceptance_commit"
        variants = {
            "null": ("SELECT route,CASE WHEN route='/registry/v1/index.json' THEN NULL::text ELSE body END AS body,"
                     "sha256,media_type,revision,acceptance_commit FROM {source}"),
            "duplicate": "SELECT " + columns + " FROM {source} UNION ALL SELECT " + columns + " FROM {source}",
            "oversized": ("SELECT route,CASE WHEN route='/registry/v1/index.json' THEN repeat('x',4194305) ELSE body END AS body,"
                          "sha256,media_type,revision,acceptance_commit FROM {source}"),
        }
        for label, select_sql in variants.items():
            with self.subTest(result=label):
                with self.export_view(select_sql):
                    for _ in range(9):
                        self.assert_unavailable(self.raw_request("/registry/v1/index.json"))
                self.assert_full_capacity_after_recovery()

    def test_statement_timeouts_release_admission_before_recovery(self):
        """The one-second SQL timeout must remain distinct from the outer deadline."""
        before = len(self.cluster.postgres_log_bytes())
        select_sql = ("SELECT route,body,sha256,media_type,revision,acceptance_commit FROM {source} "
                      "CROSS JOIN (SELECT pg_catalog.pg_sleep(3)) AS stalled")
        with self.export_view(select_sql):
            for _ in range(9):
                response, elapsed = self.timed_request("/registry/v1/index.json")
                self.assert_unavailable(response)
                self.assertGreater(elapsed, 0.7, "The request failed before reaching the stalled SQL statement.")
                self.assertLess(elapsed, 1.8, "The request waited for the two-second outer deadline.")
        messages = self.cluster.postgres_log_bytes()[before:]
        self.assertGreaterEqual(messages.count(b"canceling statement due to statement timeout"), 9,
                                "The owned database did not confirm all nine statement cancellations.")
        self.assert_full_capacity_after_recovery()

    def test_aborted_database_handshakes_release_admission(self):
        """Closing admitted database sockets must release every slot before retry."""
        generation, _ = self.gate.begin_hold()
        try:
            with ThreadPoolExecutor(max_workers=8) as clients:
                pending = [clients.submit(self.timed_request, "/health/ready") for _ in range(8)]
                self.assertTrue(self.gate.wait_for_held(8, 0.8, generation))
                started = time.monotonic()
                self.gate.abort_held(generation)
                for item in pending:
                    response, elapsed = item.result(timeout=3)
                    self.assert_unavailable(response)
                    self.assertLess(elapsed, 2.8)
                self.assertLess(time.monotonic() - started, 0.5)
        finally:
            self.gate.hold_new.clear()
        self.assert_full_capacity_after_recovery()

    def test_http_disconnects_release_admission_by_the_database_deadline(self):
        """Disconnects need eventual deadline cleanup, without immediate-cancel claims."""
        generation, _ = self.gate.begin_hold()
        clients = []
        started = time.monotonic()
        try:
            for _ in range(8):
                connection = socket.create_connection(("127.0.0.1", self.port), timeout=1)
                clients.append(connection)
                connection.sendall(b"GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            self.assertTrue(self.gate.wait_for_held(8, 0.8, generation))
            for connection in clients:
                connection.close()
            self.assertTrue(self.gate.wait_for_peer_close(8, max(0, started + 2.8 - time.monotonic()), generation),
                            "Disconnected HTTP clients retained database connections beyond the existing deadline.")
            # Socket EOF precedes PQfinish return and the final admission release.
            self.gate.hold_new.clear()
            attempts = 0
            while time.monotonic() < started + 2.8:
                attempts += 1
                response = self.raw_request("/health/ready")
                if response[0] == 200:
                    break
                self.assert_unavailable(response)
                time.sleep(0.01)
            else:
                self.fail(f"Readiness did not recover by the existing database deadline after {attempts} probes.")
            self.assertLess(time.monotonic() - started, 2.8)
        finally:
            for connection in clients:
                connection.close()
            self.gate.hold_new.clear()
        self.assert_full_capacity_after_recovery()

    def test_http_response_abort_preserves_database_capacity(self):
        """A partial maximum-size response must not retain database admission."""
        select_sql = ("SELECT route,CASE WHEN route='/registry/v1/index.json' THEN repeat('x',4194304) ELSE body END AS body,"
                      "sha256,media_type,revision,acceptance_commit FROM {source}")
        with self.export_view(select_sql):
            for _ in range(9):
                with socket.create_connection(("127.0.0.1", self.port), timeout=3) as connection:
                    connection.sendall(b"GET /registry/v1/index.json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    headers = bytearray()
                    while b"\r\n\r\n" not in headers:
                        part = connection.recv(4096)
                        self.assertTrue(part, "The response ended before its headers.")
                        headers.extend(part)
                        self.assertLessEqual(len(headers), 16384)
                    self.assertTrue(headers.startswith(b"HTTP/1.1 200 "), headers[:80])
        self.assert_full_capacity_after_recovery()

    def test_null_connection_creation_releases_admission(self):
        """A null PGconn after admission must not leak a slot or require restart."""
        library = null_connection_fixture()
        marker = self.base / "connect-null.marker"
        with self.separate_server(LD_PRELOAD=str(library), ASM_TEST_CONNECT_NULL_FILE=str(marker)) as process:
            self.assert_healthy()
            before = self.gate.accepted
            marker.touch(mode=0o600)
            try:
                for _ in range(9):
                    self.assert_unavailable(self.raw_request("/health/ready"))
                    self.assertEqual(self.request("/health/live")[0], 200)
                self.assertEqual(self.gate.accepted, before)
            finally:
                marker.unlink()
            self.assertEqual(self.server.pid, process.pid)
            self.assert_full_capacity_after_recovery()

    def test_eight_handshakes_refuse_ninth_and_recover_in_the_same_process(self):
        """Catch absent admission, leaked permits, and a database-dependent live probe."""
        pid = self.server.pid
        paths = ["/health/ready", *self.exports, "/health/ready",
                 "/registry/v1/index.tsv", "/registry/v1/index.json"]
        # A second full wave detects even a partial timeout-path permit leak.
        for wave in range(2):
            generation, before = self.gate.begin_hold()
            try:
                with ThreadPoolExecutor(max_workers=8) as clients:
                    pending = [clients.submit(self.timed_request, path) for path in paths]
                    self.assertTrue(self.gate.wait_for_held(8, 0.8, generation),
                                    f"Wave {wave}: could not establish eight stalled handshakes within the unchanged deadline.")
                    self.assertTrue(all(not item.done() for item in pending),
                                    "A holder completed before the saturation assertion.")
                    response, elapsed = self.timed_request("/health/ready")
                    self.assert_unavailable(response)
                    with self.gate.changed:
                        self.assertEqual(self.gate.accepted - before, 8,
                                         "The ninth request opened another database connection.")
                    self.assertLess(elapsed, 0.5, "Admission waited for a database timeout.")
                    for path in ("/health/live", "/api/v2/status"):
                        self.assertTrue(all(not item.done() for item in pending),
                                        "Database holders ended before the independent HTTP probe.")
                        response, elapsed = self.timed_request(path)
                        self.assertEqual(response[0], 200)
                        self.assertLess(elapsed, 0.5)
                        self.assertTrue(all(not item.done() for item in pending),
                                        "Database holders ended during the independent HTTP probe.")
                    for item in pending:
                        response, elapsed = item.result(timeout=3)
                        self.assert_unavailable(response)
                        self.assertLess(elapsed, 2.8)
                    with self.gate.changed:
                        self.assertEqual(self.gate.accepted - before, 8,
                                         "An excess database connection reached the fixture during the wave.")
            finally:
                self.gate.hold_new.clear()
            self.assertEqual(self.server.pid, pid)
            self.assertIsNone(self.server.poll())
            # Nine healthy calls also detect a success-path permit leak.
            self.assertEqual(self.request("/health/ready")[0], 200)
            for _ in range(2):
                for path, expected in self.exports.items():
                    code, _, body = self.raw_request(path)
                    self.assertEqual(code, 200)
                    self.assertEqual(body, expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
