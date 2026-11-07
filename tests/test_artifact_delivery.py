"""First-party delivery verifies bytes and records complete responses only.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from copy import deepcopy
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import importlib
from pathlib import Path
import queue
import socket
import struct
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry
sys.path.insert(0, str(ROOT / "tests/registry"))
from test_registry import minimal_elf, release


class ArtifactReader:
    """Only upstream storage is replaced; validation and HTTP remain real."""

    def __init__(self, record, data):
        self.artifact = record["artifacts"][0]
        self.data = data
        self.calls = 0
        self.fail = False
        self.entered = threading.Event()
        self.proceed = None

    def __call__(self, url, limit, hosts, *, expected_size):
        if url != self.artifact["url"] or expected_size != self.artifact["bytes"] or limit < expected_size:
            raise AssertionError("Delivery requested undeclared storage or size.")
        self.calls += 1
        self.entered.set()
        if self.proceed is not None and not self.proceed.wait(3):
            raise TimeoutError("The fixture reader was not released.")
        if self.fail:
            raise OSError("Private upstream failure detail.")
        return self.data


class ArtifactDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / "tools/artifact_delivery.py").exists(), "Artifact delivery is not implemented.")
        self.module = importlib.import_module("artifact_delivery")
        self.ledger = importlib.import_module("download_data")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.record, self.data = release()
        self.reader = ArtifactReader(self.record, self.data)
        self.configure([self.record], self.reader)

    def configure(self, records, reader, *, name="main", session=None):
        self.store = self.ledger.Store(self.root / (name + ".sqlite"), records)
        self.session = self.store.begin()
        self.addCleanup(self.store.finish, self.session)
        self.cache = self.root / (name + "-cache")
        self.delivery = self.module.ArtifactDelivery(records, self.cache, self.store,
                                                    self.session if session is None else session, reader=reader)
        self.path = self.module.route(records[0], records[0]["artifacts"][0])
        finished = queue.Queue()
        delivery = self.delivery

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                try:
                    if not delivery.handle(self, self.path):
                        self.send_error(404)
                finally:
                    finished.put(self.path)

            def do_HEAD(self):
                try:
                    if not delivery.handle(self, self.path, head=True):
                        self.send_error(404)
                finally:
                    finished.put(self.path)

            def log_message(self, format, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        server.request_queue_size = 16
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.shutdown)
        self.port, self.finished = server.server_port, finished

    def request(self, *, path=None, method="GET", headers=None):
        connection = HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            connection.request(method, self.path if path is None else path, headers=headers or {})
            response = connection.getresponse()
            result = response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()
        self.finished.get(timeout=2)
        return result

    def count(self, name=None):
        self.store.heartbeat(self.session)
        return self.store.snapshot()["counts"][self.record["name"] if name is None else name]

    def test_full_download_verifies_bytes_and_cache_reuse_counts_each_response(self):
        for expected in (1, 2):
            status, headers, body = self.request()
            self.assertEqual(status, 200)
            self.assertEqual(body, self.data)
            self.assertEqual(int(headers["Content-Length"]), len(self.data))
            self.assertEqual(headers["Content-Type"], "application/octet-stream")
            self.assertTrue(headers["Content-Disposition"].startswith("attachment;"))
            self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
            self.assertNotIn("Set-Cookie", headers)
            self.assertEqual(self.count(), expected)
        self.assertEqual(self.reader.calls, 1)
        self.reader.fail = True
        self.assertEqual(self.request()[2], self.data, "Verified cached bytes survive an unavailable origin.")
        self.assertEqual(self.count(), 3)

    def test_head_and_conditional_responses_do_not_count_downloads(self):
        status, headers, body = self.request(method="HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(int(headers["Content-Length"]), len(self.data))
        for validator in (headers["ETag"], "W/" + headers["ETag"], "*"):
            status, _, body = self.request(headers={"If-None-Match": validator})
            self.assertEqual(status, 304)
            self.assertEqual(body, b"")
        self.assertEqual(self.count(), 0)

    def test_single_ranges_are_bounded_and_never_receive_full_download_credit(self):
        for value, start, end in (("bytes=0-7", 0, 7), ("bytes=-5", len(self.data)-5, len(self.data)-1),
                                   ("bytes=8-", 8, len(self.data)-1), ("bytes=0-999999", 0, len(self.data)-1)):
            status, headers, body = self.request(headers={"Range": value})
            self.assertEqual(status, 206)
            self.assertEqual(body, self.data[start:end+1])
            self.assertEqual(headers["Content-Range"], f"bytes {start}-{end}/{len(self.data)}")
        for value in ("bytes=999999-", "bytes=8-2", "bytes=0-1,3-4", "bytes=-0", "bytes=" + "9"*200 + "-"):
            self.assertEqual(self.request(headers={"Range": value})[0], 416)
        self.assertEqual(self.count(), 0)
        status, _, body = self.request(headers={"Range": "items=0-7"})
        self.assertEqual(status, 200)
        self.assertEqual(body, self.data)
        self.assertEqual(self.count(), 1)

    def test_if_range_mismatch_sends_a_complete_representation(self):
        status, _, body = self.request(headers={"Range": "bytes=0-7", "If-Range": '"another-version"'})
        self.assertEqual(status, 200)
        self.assertEqual(body, self.data)
        self.assertEqual(self.count(), 1)

    def test_internal_and_advisory_bot_classes_do_not_inflate_public_popularity(self):
        for agent in ("AsmValidation/1", "ExampleBot/2", "Example spider", "Example crawler"):
            self.assertEqual(self.request(headers={"User-Agent": agent})[0], 200)
        self.assertEqual(self.count(), 0)
        self.assertEqual(self.request(headers={"User-Agent": "Ordinary client"})[0], 200)
        self.assertEqual(self.count(), 1)

    def test_corrupt_or_structurally_invalid_upstream_bytes_are_not_exposed(self):
        self.reader.data = b"x" * len(self.data)
        status, _, body = self.request()
        self.assertEqual(status, 503)
        self.assertNotEqual(body, self.reader.data)
        self.assertEqual(self.count(), 0)
        self.assertFalse((self.cache / "sha256" / self.record["artifacts"][0]["sha256"]).exists())
        bad = deepcopy(self.record)
        data = b"not an archive"
        bad["artifacts"][0].update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        self.configure([bad], ArtifactReader(bad, data), name="bad-structure")
        self.assertEqual(self.request()[0], 503)
        self.assertEqual(self.count(), 0)

    def test_corrupt_cache_entry_is_preserved_and_not_delivered(self):
        self.request()
        path = self.cache / "sha256" / self.record["artifacts"][0]["sha256"]
        corrupt = b"x" * len(self.data)
        path.write_bytes(corrupt)
        self.assertEqual(self.request()[0], 503)
        self.assertEqual(path.read_bytes(), corrupt)
        self.assertEqual(self.reader.calls, 1)
        self.assertEqual(self.count(), 1)

    def test_symlink_cache_entries_and_cache_directories_are_rejected(self):
        secret = self.root / "private.txt"
        secret.write_bytes(b"Private unrelated bytes.")
        path = self.cache / "sha256" / self.record["artifacts"][0]["sha256"]
        path.symlink_to(secret)
        status, _, body = self.request()
        self.assertEqual(status, 503)
        self.assertNotIn(secret.read_bytes(), body)
        self.assertEqual(secret.read_bytes(), b"Private unrelated bytes.")
        alias = self.root / "alias"
        alias.symlink_to(self.cache, target_is_directory=True)
        with self.assertRaises(registry.RegistryError):
            self.module.ArtifactDelivery([self.record], alias, self.store, self.session, reader=self.reader)

    def test_user_controlled_cache_ancestor_symlinks_are_rejected_before_creation(self):
        directory = self.root / "elsewhere"
        directory.mkdir()
        alias = self.root / "cache-parent"
        alias.symlink_to(directory, target_is_directory=True)
        with self.assertRaises(registry.RegistryError):
            self.module.ArtifactDelivery([self.record], alias / "new-cache", self.store, self.session, reader=self.reader)
        self.assertFalse((directory / "new-cache").exists())

    def test_query_and_duplicate_range_fields_are_rejected_before_storage_or_events(self):
        self.assertEqual(self.request(path=self.path + "?ignored=1")[0], 400)
        connection = HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            connection.putrequest("GET", self.path)
            connection.putheader("Range", "bytes=0-1")
            connection.putheader("Range", "bytes=3-4")
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            response.read()
        finally:
            connection.close()
        self.finished.get(timeout=2)
        self.assertEqual(self.reader.calls, 0)
        self.assertEqual(self.count(), 0)

    def test_yanked_and_mismatched_selections_do_not_fetch_or_serve_cached_bytes(self):
        for path in (self.path + "/extra", self.path.replace("x86_64-linux", "aarch64-linux"),
                     self.path.replace("0.1.0", "0.2.0")):
            self.assertEqual(self.request(path=path)[0], 404)
        self.assertEqual(self.reader.calls, 0)
        yanked = deepcopy(self.record)
        yanked.update(yanked=True, yank_reason="Fixture withdrawal.")
        cached = self.cache / "sha256" / self.record["artifacts"][0]["sha256"]
        cached.write_bytes(self.data)
        # The handler closes over this instance; change its registered selection
        # by starting a separate endpoint, as a restarted registry process would.
        self.configure([yanked], self.reader, name="yanked")
        (self.cache / "sha256" / self.record["artifacts"][0]["sha256"]).write_bytes(self.data)
        self.assertEqual(self.request()[0], 410)
        self.assertEqual(self.reader.calls, 0)
        self.assertEqual(self.count(), 0)

    def test_identical_content_is_attributed_to_the_selected_package(self):
        data = minimal_elf()
        first = deepcopy(self.record)
        first["artifacts"][0].update(kind="executable", bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                                     url="https://github.com/stubbi/asm/releases/download/v0.1.0/hello")
        second = deepcopy(first)
        second["name"] = "stubbi/other"
        second["artifacts"][0]["url"] = "https://github.com/stubbi/asm/releases/download/v0.1.0/other"
        reader = lambda url, *args, **kwargs: data
        self.configure([first, second], reader, name="shared")
        path = self.module.route(second, second["artifacts"][0])
        self.assertEqual(self.request(path=path)[2], data)
        self.assertEqual(self.count(first["name"]), 0)
        self.assertEqual(self.count(second["name"]), 1)

    def test_client_abort_does_not_create_a_completed_event(self):
        data = minimal_elf() + b"\0" * (8 * 1024 * 1024)
        record = deepcopy(self.record)
        record["artifacts"][0].update(kind="executable", bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                                      url="https://github.com/stubbi/asm/releases/download/v0.1.0/large-hello")
        self.configure([record], ArtifactReader(record, data), name="abort")
        connection = socket.create_connection(("127.0.0.1", self.port), timeout=2)
        try:
            connection.sendall((f"GET {self.path} HTTP/1.0\r\nHost: 127.0.0.1:{self.port}\r\n\r\n").encode())
            received = b""
            while b"\r\n\r\n" not in received:
                received += connection.recv(4096)
            self.assertIn(b"200", received.split(b"\r\n", 1)[0])
            connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        finally:
            connection.close()
        self.finished.get(timeout=2)
        self.assertEqual(self.count(), 0)

    def test_ledger_failure_preserves_file_delivery_and_interrupts_coverage(self):
        self.store.heartbeat(self.session)
        with patch.object(self.store, "record", side_effect=OSError("Fixture ledger is unavailable.")):
            status, _, body = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(body, self.data)
        self.assertTrue(self.store.snapshot()["stale"])
        self.assertEqual(self.store.snapshot()["counts"][self.record["name"]], 0)

    def test_session_provider_is_resolved_when_recording_and_can_be_unavailable(self):
        session = [None]
        self.configure([self.record], self.reader, name="callable", session=lambda: session[0])
        self.assertEqual(self.request()[2], self.data)
        self.assertEqual(self.count(), 0)
        session[0] = self.session
        self.assertEqual(self.request()[2], self.data)
        self.assertEqual(self.count(), 1)

    def test_cache_budget_and_transfer_admission_fail_without_unbounded_work(self):
        with patch.object(self.module, "MAX_CACHE_BYTES", 16):
            self.assertEqual(self.request()[0], 503)
        self.assertEqual(self.reader.calls, 0)
        self.reader.proceed = threading.Event()
        self.addCleanup(self.reader.proceed.set)
        with ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(self.request) for _ in range(8)]
            try:
                self.assertTrue(self.reader.entered.wait(1))
                completed, _ = wait(futures, timeout=0.5, return_when=FIRST_COMPLETED)
                self.assertTrue(completed, "Overload must return without waiting for storage.")
                self.assertTrue(any(item.result()[0] == 503 for item in completed))
            finally:
                self.reader.proceed.set()
            self.assertTrue(all(item.result()[0] in (200, 503) for item in futures))

    def test_cache_file_admission_uses_the_current_release_artifact_bound(self):
        directory = self.cache / "sha256"
        maximum = registry.MAX_RELEASE_ARTIFACTS + self.module.MAX_TRANSFERS
        def cache_file(number):
            path = directory / f"{number:064x}"
            path.write_bytes(b"")
            path.chmod(0o600)
        with patch.object(registry, "MAX_ROWS", 1):
            for number in range(registry.MAX_RELEASE_ARTIFACTS): cache_file(number)
            self.assertEqual(self.request()[0], 200)
            self.assertEqual(self.count(), 1)
            (directory / self.record["artifacts"][0]["sha256"]).unlink()
            for number in range(registry.MAX_RELEASE_ARTIFACTS, maximum + 1): cache_file(number)
            self.assertEqual(self.request()[0], 503)
        self.assertEqual(self.reader.calls, 1, "An over-budget import must stop before storage reads.")
        self.assertEqual(self.count(), 1)


if __name__ == "__main__":
    unittest.main()
