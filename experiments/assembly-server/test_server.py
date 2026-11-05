"""Real HTTP and PostgreSQL checks for the assembly experiment.

SPDX-License-Identifier: AGPL-3.0-or-later

Python supplies test orchestration only. The served application is the native
assembly executable. The fixture owns a fresh local PostgreSQL cluster and
creates its test records without an external service or reference executable.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import os
from pathlib import Path
import select
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import urlencode
import uuid

from local_postgres import Database, LocalPostgres, MIGRATION_SHA384, create_catalog


BUILD = Path(os.environ.get("ASM_PROTO_BUILD_DIR", Path(__file__).resolve().parent / "build"))
BINARY = Path(os.environ["ASM_PROTO_BINARY"])


class GateProxy:
    """A local TCP fixture. Closed gate accepts but forwards no protocol bytes."""
    def __init__(self, target_port):
        self.target_port = target_port
        self.closed_gate = threading.Event()
        self.stopping = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(32)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.workers = []
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
            worker = threading.Thread(target=self.connection, args=(client,), daemon=True)
            self.workers.append(worker)
            worker.start()

    def connection(self, client):
        with client:
            if self.closed_gate.is_set():
                self.stopping.wait(4)
                return
            with socket.create_connection(("127.0.0.1", self.target_port), timeout=2) as server:
                client.settimeout(2)
                server.settimeout(2)
                while not self.stopping.is_set():
                    readable, _, _ = select.select([client, server], [], [], 0.1)
                    for source in readable:
                        try:
                            data = source.recv(65536)
                            if not data:
                                return
                            (server if source is client else client).sendall(data)
                        except OSError:
                            return

    def close(self):
        self.stopping.set()
        self.listener.close()
        deadline = time.monotonic() + 3
        self.thread.join(timeout=3)
        for worker in self.workers:
            worker.join(timeout=max(0, deadline - time.monotonic()))
        if self.thread.is_alive() or any(worker.is_alive() for worker in self.workers):
            raise RuntimeError("The local proxy did not stop within its cleanup deadline.")


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="asm-server-test-", dir=BUILD)
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.cluster = LocalPostgres(cls.base)
        cls.addClassCleanup(cls.cluster.close)
        cls.cluster.start()
        cls.names = "asm_proto_" + uuid.uuid4().hex[:12]
        cls.dbname = cls.names
        cls.migrator = cls.names + "_m"
        cls.reader = cls.names + "_r"
        cls.operator = cls.names + "_o"
        cls.password = secrets.token_hex(24)
        cls.admin = cls.cluster.admin
        cls.proxy = GateProxy(cls.cluster.port)
        cls.addClassCleanup(cls.proxy.close)
        for role in (cls.migrator, cls.reader, cls.operator):
            cls.admin.execute(f'CREATE ROLE "{role}" LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD \'{cls.password}\'')
            cls.addClassCleanup(cls.admin.execute, f'DROP ROLE "{role}"')
        cls.admin.execute(f'CREATE DATABASE "{cls.dbname}" OWNER "{cls.migrator}"')
        cls.addClassCleanup(cls.admin.execute, f'DROP DATABASE "{cls.dbname}" WITH (FORCE)')
        cls.fixture_admin = Database(cls.cluster.url(database=cls.dbname))
        cls.addClassCleanup(cls.fixture_admin.close)
        cls.url_files = {}
        for label, role in (("migrator", cls.migrator), ("reader", cls.reader), ("operator", cls.operator)):
            path = cls.base / (label + ".url")
            path.write_text(cls.cluster.url(database=cls.dbname, role=role, password=cls.password) + "\n")
            path.chmod(0o600)
            cls.url_files[label] = path
        cls.proxy_file = cls.base / "proxy.url"
        cls.proxy_file.write_text(cls.cluster.url(database=cls.dbname, role=cls.reader, password=cls.password, port=cls.proxy.port) + "\n")
        cls.proxy_file.chmod(0o600)
        migrator = Database(cls.url_files["migrator"].read_text().strip())
        try:
            operator = Database(cls.url_files["operator"].read_text().strip())
            try:
                create_catalog(migrator, operator, cls.reader, cls.operator)
            finally:
                operator.close()
        finally:
            migrator.close()
        cls.expected_names = [f"fixture/p{i:02d}" for i in range(23)]
        cls.log = (cls.base / "server.log").open("wb")
        cls.addClassCleanup(cls.log.close)
        cls.port = cls.unused_port()
        cls.server = subprocess.Popen([str(BINARY), str(cls.port), str(cls.proxy_file)], stdout=cls.log, stderr=cls.log)
        cls.addClassCleanup(cls.stop_server)
        cls.wait_server(cls.server, cls.port)
        cls.evidence = {"binary_sha256": hashlib.sha256(BINARY.read_bytes()).hexdigest(),
                        "libpq_version": cls.admin.lib.PQlibVersion(), "database_version": cls.fixture_admin.execute("SHOW server_version")[0][0],
                        "schema_sha384": MIGRATION_SHA384, "fixture": "owned-local-cluster", "measurements": {}}

    @staticmethod
    def unused_port():
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]

    @classmethod
    def wait_server(cls, proc, port):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise AssertionError(f"Assembly server stopped during startup: {proc.returncode}")
            try:
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.2)
                connection.request("GET", "/health/live")
                response = connection.getresponse()
                response.read()
                connection.close()
                if response.status == 200:
                    return
            except OSError:
                time.sleep(0.02)
        raise AssertionError("Assembly server did not become live.")

    @classmethod
    def stop_server(cls):
        if getattr(cls, "server", None) and cls.server.poll() is None:
            cls.server.terminate()
            try:
                cls.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.server.kill()
                cls.server.wait(timeout=2)
                raise

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()
        cls.log.flush()
        evidence = BUILD / "evidence.json"
        evidence.write_text(json.dumps(cls.evidence, indent=2) + "\n")
        saved_log = BUILD / "server-test.log"
        saved_log.write_bytes((cls.base / "server.log").read_bytes())

    def request(self, path, *, method="GET", body=None, headers=None, timeout=4):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), json.loads(data)
        finally:
            connection.close()

    def test_health_and_declared_dependency_boundary(self):
        self.assertEqual(self.request("/health/live")[2], {"status": "alive"})
        self.assertEqual(self.request("/health/ready")[2], {"status": "ready"})
        code, headers, data = self.request("/")
        self.assertEqual(code, 200)
        self.assertTrue(data["experimental"])
        self.assertEqual(data["application_language"], "assembly")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["Connection"], "close")

    def test_fixture_retains_reference_records_and_query_limits(self):
        canonical = (Path(__file__).parent / "fixtures/p00.json").read_bytes().rstrip(b"\n")
        expected = hashlib.sha256(canonical).hexdigest()
        digest = self.fixture_admin.execute("SELECT r.record_digest FROM asm.releases r JOIN asm.packages p ON p.id = r.package_id WHERE p.full_name = 'fixture/p00'")[0][0]
        detail = self.fixture_admin.execute("SELECT detail::text FROM asm.audit_events WHERE action = 'release_imported' AND subject = 'fixture/p00@0.2.0'")[0][0]
        self.assertEqual(digest, expected)
        self.assertEqual(json.loads(detail), {"record_sha256": expected,
                         "acceptance_repository": "https://github.com/stubbi/asm", "acceptance_commit": "c" * 40})
        self.assertEqual(self.fixture_admin.execute("SHOW statement_timeout"), [["5s"]])
        self.assertEqual(self.fixture_admin.execute("SHOW lock_timeout"), [["1s"]])

    def test_real_pagination_does_not_drop_or_repeat_packages(self):
        code, _, first = self.request("/prototype/packages")
        self.assertEqual(code, 200)
        self.assertEqual(len(first["packages"]), 20)
        code, _, second = self.request("/prototype/packages?" + urlencode({"after": first["next_after"]}))
        self.assertEqual(code, 200)
        names = [p["name"] for p in first["packages"] + second["packages"]]
        self.assertEqual(names, self.expected_names)
        self.assertIsNone(second["next_after"])
        self.assertEqual(first["packages"][0]["summary"], 'Text "quoted" <script>ignored</script> & data')
        self.assertEqual(first["packages"][0]["owner_github_id"], 12345)

    def test_search_uses_parameters_and_literal_matching(self):
        for query, expected in (("fixture 22", ["fixture/p22"]), ("FIXTURE 22", ["fixture/p22"]),
                                ("' OR 1=1 --", []), ("%", []), ("quoted", ["fixture/p00"])):
            with self.subTest(query=query):
                code, _, data = self.request("/prototype/packages?" + urlencode({"q": query}))
                self.assertEqual(code, 200)
                self.assertEqual([p["name"] for p in data["packages"]], expected)

    def test_query_rejects_duplicates_unknown_fields_controls_and_oversize(self):
        for query in ("q=a&q=b", "after=a&after=b", "unknown=1", "q=%00", "q=a%00b", "q=%0a",
                      "q=" + "a" * 161, "after=" + "a" * 105, "q=%c3%a9"):
            with self.subTest(query=query[:50]):
                self.assertEqual(self.request("/prototype/packages?" + query)[0], 400)

    def test_unknown_route_method_and_body_fail_without_database_writes(self):
        self.assertEqual(self.request("/missing")[0], 404)
        self.assertEqual(self.request("/prototype/packages", method="POST", body="ignored")[0], 405)
        self.assertEqual(self.request("/prototype/packages", body="ignored")[0], 400)
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_uri_and_header_limits(self):
        self.assertEqual(self.request("/" + "x" * 2048)[0], 414)
        headers = {f"X-Field-{i}": "x" for i in range(65)}
        self.assertEqual(self.request("/health/live", headers=headers)[0], 431)

    def test_readiness_loses_permissions_and_recovers(self):
        self.fixture_admin.execute(f'REVOKE SELECT ON asm.artifacts FROM "{self.reader}"')
        try:
            self.assertEqual(self.request("/health/ready")[0], 503)
            self.assertEqual(self.request("/health/live")[0], 200)
        finally:
            self.fixture_admin.execute(f'GRANT SELECT ON asm.artifacts TO "{self.reader}"')
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_startup_rejects_migrator_and_missing_grants(self):
        result = subprocess.run([str(BINARY), str(self.unused_port()), str(self.url_files["migrator"])],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 78)
        self.assertNotIn(self.url_files["migrator"].read_bytes().strip(), result.stderr)
        self.fixture_admin.execute(f'REVOKE SELECT ON asm.packages FROM "{self.reader}"')
        try:
            result = subprocess.run([str(BINARY), str(self.unused_port()), str(self.url_files["reader"])],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 78)
        finally:
            self.fixture_admin.execute(f'GRANT SELECT ON asm.packages TO "{self.reader}"')

    def test_configuration_rejects_nonregular_public_and_malformed_files(self):
        cases = []
        for name, data, mode in (("empty", b"", 0o600), ("oversize", b"a" * 4097, 0o600),
                                 ("nul", b"dbname=a\x00ignore", 0o600),
                                 ("public", self.url_files["reader"].read_bytes(), 0o644)):
            path = self.base / ("bad-" + name)
            path.write_bytes(data)
            path.chmod(mode)
            cases.append(path)
        link = self.base / "config-link"
        link.symlink_to(self.url_files["reader"])
        cases.append(link)
        fifo = self.base / "config-fifo"
        os.mkfifo(fifo, 0o600)
        cases.append(fifo)
        for path in cases:
            with self.subTest(file=path.name):
                result = subprocess.run([str(BINARY), str(self.unused_port()), str(path)], capture_output=True, timeout=1)
                self.assertEqual(result.returncode, 78)
                self.assertNotIn(self.password.encode(), result.stderr)

    def test_connection_cap_bounds_http_threads_and_recovers(self):
        held = []
        recovery_start = None
        try:
            for _ in range(16):
                client = socket.create_connection(("127.0.0.1", self.port), timeout=1)
                client.sendall(b"GET /health/live HTTP/1.1\r\nHost: localhost\r\nX-Pending: ")
                held.append(client)
            def threads():
                rows = Path(f"/proc/{self.server.pid}/status").read_text().splitlines()
                return int(next(row.split()[1] for row in rows if row.startswith("Threads:")))
            deadline = time.monotonic() + 1
            while threads() < 18 and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(threads(), 18)  # main + listener + 16 connections
            with socket.create_connection(("127.0.0.1", self.port), timeout=1) as extra:
                extra.settimeout(0.15)
                extra.sendall(b"GET /health/live HTTP/1.1\r\nHost: localhost\r\n\r\n")
                try:
                    data = extra.recv(1)
                    self.assertEqual(data, b"")
                except (socket.timeout, ConnectionResetError):
                    pass
                self.assertLessEqual(threads(), 18)
            self.evidence["measurements"]["threads_at_connection_cap"] = 18
        finally:
            recovery_start = time.monotonic()
            for client in held:
                client.close()
        # Closing the client sockets starts asynchronous library cleanup.
        # ITC wakes listener cleanup. Worker exit alone did not prove that the
        # admission slots were released when that wake channel was disabled.
        deadline = time.monotonic() + 1
        while threads() > 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(threads(), 2)
        self.assertEqual(self.request("/health/live")[0], 200)
        self.evidence["measurements"]["connection_cap_recovery_seconds"] = time.monotonic() - recovery_start

    def test_a_stalled_database_does_not_stall_liveness(self):
        self.proxy.closed_gate.set()
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                start = time.monotonic()
                blocked = pool.submit(self.request, "/health/ready")
                time.sleep(0.05)
                live_start = time.monotonic()
                self.assertEqual(self.request("/health/live")[0], 200)
                live_elapsed = time.monotonic() - live_start
                self.assertLess(live_elapsed, 0.75)
                self.assertEqual(blocked.result(timeout=3)[0], 503)
                elapsed = time.monotonic() - start
                self.assertGreater(elapsed, 1.5)
                self.assertLess(elapsed, 2.75)
                self.evidence["measurements"]["stalled_database_seconds"] = elapsed
                self.evidence["measurements"]["liveness_during_stall_seconds"] = live_elapsed
        finally:
            self.proxy.closed_gate.clear()
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_simultaneous_searches_keep_request_data_separate(self):
        def one(i):
            query = f"fixture {i:02d}"
            code, _, data = self.request("/prototype/packages?" + urlencode({"q": query}))
            return code, [p["name"] for p in data["packages"]]
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(one, range(1, 17)))
        self.assertEqual(results, [(200, [f"fixture/p{i:02d}"]) for i in range(1, 17)])

    def test_shutdown_is_bounded_with_a_stalled_database(self):
        port = self.unused_port()
        proc = subprocess.Popen([str(BINARY), str(port), str(self.proxy_file)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            self.wait_server(proc, port)
            self.proxy.closed_gate.set()
            with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
                client.sendall(b"GET /health/ready HTTP/1.1\r\nHost: localhost\r\n\r\n")
                time.sleep(0.05)
                start = time.monotonic()
                proc.terminate()
                self.assertEqual(proc.wait(timeout=3), 0)
                self.evidence["measurements"]["shutdown_during_stall_seconds"] = time.monotonic() - start
        finally:
            self.proxy.closed_gate.clear()
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=2)
            proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
