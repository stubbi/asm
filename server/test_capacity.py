"""Check native database admission through HTTP and an owned TCP fixture.

SPDX-License-Identifier: AGPL-3.0-or-later
Python supplies test orchestration only. TLS and PostgreSQL remain unchanged.
This candidate needs a built Linux runtime and the existing fixture tools.
"""
from concurrent.futures import ThreadPoolExecutor
import select
import socket
import threading
import time
import unittest

import test_runtime as runtime


class HandshakeGate:
    """Forward opaque bytes, or hold new connections before TLS negotiation."""

    def __init__(self, target_port):
        self.target_port = target_port
        self.hold_new = threading.Event()
        self.stopping = threading.Event()
        self.changed = threading.Condition()
        self.held = {}
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
        try:
            with client:
                if generation is not None:
                    # Observe protocol bytes before declaring the handshake held.
                    readable, _, _ = select.select([client], [], [], 1)
                    if not readable or not client.recv(1, socket.MSG_PEEK):
                        return
                    with self.changed:
                        self.held[client] = generation
                        self.changed.notify_all()
                    self.stopping.wait(3)
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
    setUpClass = runtime.RuntimeTests.__dict__["setUpClass"]
    url = runtime.RuntimeTests.__dict__["url"]
    raw_request = runtime.RuntimeTests.__dict__["raw_request"]
    request = runtime.RuntimeTests.__dict__["request"]
    stop_server = runtime.RuntimeTests.__dict__["stop_server"]

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
