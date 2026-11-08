"""Origin log fixtures are synthetic transfer observations, never user counts.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from contextlib import closing
import importlib
from datetime import datetime, timedelta, timezone
import errno
import hashlib
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import sqlite3
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import discovery
import registry


class RegistryLogImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.path = self.root / "state/events.sqlite3"
        self.log = self.root / "origin.jsonl"
        self.record = {"schema": 1, "name": "fixture/math", "version": "0.1.0", "summary": "Synthetic fixture.",
                       "license": "MIT", "yanked": False,
                       "source": {"repository": "https://github.com/fixture/math", "commit": "1" * 40, "path": "."},
                       "artifacts": [{"target": "x86_64-linux", "kind": "source", "sha256": "a" * 64,
                                      "bytes": 100, "url": "https://github.com/fixture/math/releases/download/v0.1.0/math.tar.gz"}]}
        self.uri = "/downloads/v1/fixture/math/0.1.0/x86_64-linux/source/" + "a" * 64

    def module(self):
        return importlib.import_module("registry_log_import")

    def store(self, **options):
        return self.module().LogStore(self.path, [self.record], **options)

    def event(self, request_id="request-1", **changes):
        result = {"time": "2026-01-02T12:00:00+00:00", "request_id": request_id, "method": "GET", "uri": self.uri,
                  "status": 200, "bytes": 100, "complete": "OK", "traffic": "public"}
        result.update(changes)
        return result

    def batch(self, store, events, batch_id="batch-1", source="asm-origin", start="2026-01-02T00:00:00Z", end="2026-01-03T00:00:00Z"):
        self.log.write_text("".join(json.dumps(event) + "\n" for event in events))
        return store.import_batch(source, batch_id, start, end, self.log)

    def test_out_of_order_batches_and_replay_produce_rebuildable_lower_bounds(self):
        store = self.store()
        self.assertTrue(self.batch(store, [self.event()]))
        self.assertFalse(self.batch(store, [self.event()]))
        self.batch(store, [self.event("request-old", time="2026-01-01T12:00:00Z")], "batch-old",
                   start="2026-01-01T00:00:00Z", end="2026-01-02T00:00:00Z")
        value = self.store().snapshot(at="2026-01-03T00:00:01Z")
        self.assertEqual(value["counts"], {"fixture/math": 2})
        self.assertEqual(value["retained_counts"], {"fixture/math": 2})
        self.assertEqual(value["coverage_end"], "2026-01-03T00:00:00Z")
        self.assertFalse(value["complete"])
        self.assertFalse(value["retained_complete"])
        self.assertEqual(value["coverage_intervals"], [])
        activity = discovery.delivery_activity([self.record], "fixture/math", value)
        self.assertEqual(activity["total"], 2)
        self.assertEqual(sum(day["count"] or 0 for day in activity["days"]), 2)
        self.assertTrue(any(day["coverage"] == "unavailable" and day["count"] is None for day in activity["days"]))
        self.assertEqual(discovery.retained_counts([self.record], value)["total"], 2)

    def test_batch_and_request_conflicts_abort_the_entire_import(self):
        store = self.store()
        self.batch(store, [self.event()])
        with self.assertRaises(registry.RegistryError):
            self.batch(store, [self.event("new"), self.event(traffic="bot")], "conflict")
        with self.assertRaises(registry.RegistryError):
            self.batch(store, [self.event("different")])
        value = store.snapshot(at="2026-01-03T00:00:01Z")
        self.assertEqual(value["counts"], {"fixture/math": 1})
        with closing(sqlite3.connect(self.path)) as connection, connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM batches").fetchone()[0], 1)

    def test_head_range_bot_internal_redirect_failure_and_conditional_are_excluded(self):
        changes = [{"method": "HEAD", "bytes": 0}, {"status": 206, "bytes": 50}, {"traffic": "bot"},
                   {"traffic": "internal"}, {"status": 302, "bytes": 0}, {"complete": "", "bytes": 40},
                   {"status": 304, "bytes": 0}, {"status": 500, "bytes": 146}]
        store = self.store()
        self.batch(store, [self.event(str(i), **change) for i, change in enumerate(changes)] + [self.event()])
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["counts"], {"fixture/math": 1})

    def test_missing_batches_differ_from_imported_empty_logs(self):
        store = self.store()
        self.assertIsNone(store.snapshot()["coverage_end"])
        self.batch(store, [])
        value = store.snapshot(at="2026-01-03T00:00:01Z")
        self.assertEqual(discovery.delivery_counts([self.record], value)["packages"]["fixture/math"]["total"], 0)
        self.assertFalse(value["complete"])

    def test_sources_have_separate_request_ids_and_unconfigured_sources_are_refused(self):
        store = self.store(sources=("origin-a", "origin-b"))
        self.batch(store, [self.event()], source="origin-a")
        self.batch(store, [self.event()], source="origin-b")
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["counts"]["fixture/math"], 2)
        selected = self.store(sources=("origin-b",)).snapshot(at="2026-01-03T00:00:01Z")
        self.assertEqual(selected["counts"]["fixture/math"], 1)
        with self.assertRaises(registry.RegistryError):
            self.batch(store, [], source="unknown")

    def test_yanked_historical_versions_remain_attributed(self):
        self.record.update(yanked=True, yank_reason="Synthetic withdrawal.")
        store = self.store()
        self.batch(store, [self.event()])
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["version_counts"], {"fixture/math@0.1.0": 1})

    def test_all_six_registry_targets_have_distinct_attributable_routes(self):
        targets = ("x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos", "x86_64-windows", "aarch64-windows")
        self.record["artifacts"] = [{**self.record["artifacts"][0], "target": target,
                                    "url": "https://github.com/fixture/math/releases/download/v0.1.0/" + target + ".tar.gz"}
                                   for target in targets]
        store = self.store()
        events = [self.event(target, uri="/downloads/v1/fixture/math/0.1.0/" + target + "/source/" + "a" * 64)
                  for target in targets]
        self.batch(store, events)
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["counts"], {"fixture/math": 6})
        locations = self.module().nginx_locations([self.record], "/srv/asm/blobs/sha256")
        for event in events:
            self.assertIn("location = " + event["uri"] + " {", locations)

    def test_privacy_fields_unknown_selections_duplicate_json_and_oversized_lines_fail_before_state(self):
        bad = [self.event(ip="192.0.2.1"), self.event(cookie="secret"), self.event(user_agent="secret"),
               self.event(uri=self.uri + "?secret=query"), self.event(uri="/blobs/sha256/" + "a" * 64),
               self.event(uri=self.uri.replace("fixture/math", "fixture/other")), self.event(bytes=True),
               self.event(time="2026-01-02T12:00:00+01:00")]
        for event in bad:
            with self.subTest(event=event), self.assertRaises(registry.RegistryError):
                self.batch(self.store(), [event])
        for data in ('{"time":"x","time":"y"}\n', 'x' * 4097 + '\n'):
            self.log.write_text(data)
            with self.assertRaises(registry.RegistryError):
                self.store().import_batch("asm-origin", "bad", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z", self.log)
        self.assertFalse(self.path.exists())

    def test_invalid_database_and_linked_private_paths_are_preserved(self):
        self.path.parent.mkdir(mode=0o700)
        self.path.write_bytes(b"broken")
        self.path.chmod(0o600)
        with self.assertRaises(registry.RegistryError):
            self.store().snapshot()
        self.assertEqual(self.path.read_bytes(), b"broken")
        self.path.unlink()
        self.path.symlink_to(self.log)
        with self.assertRaises(registry.RegistryError):
            self.batch(self.store(), [])

    def test_public_ancestor_is_refused_before_sqlite_reopens_the_path(self):
        ancestor = self.root / "shared"
        ancestor.mkdir(mode=0o777)
        ancestor.chmod(0o777)
        self.path = ancestor / "private/events.sqlite3"
        self.path.parent.mkdir(mode=0o700)
        with patch.object(self.module().sqlite3, "connect", wraps=sqlite3.connect) as connect:
            with self.assertRaises(registry.RegistryError):
                self.batch(self.store(), [])
            connect.assert_not_called()
        self.assertFalse(self.path.exists())

    def test_untrusted_ancestor_owner_is_refused_before_sqlite_connect(self):
        self.path.parent.mkdir(mode=0o700)
        identity = self.root.stat()
        original = os.fstat

        def changed_owner(descriptor):
            info = original(descriptor)
            if (info.st_dev, info.st_ino) == (identity.st_dev, identity.st_ino):
                fields = list(info)
                fields[4] = os.getuid() + 1
                return os.stat_result(fields)
            return info

        with patch.object(os, "fstat", side_effect=changed_owner), \
                patch.object(self.module().sqlite3, "connect", wraps=sqlite3.connect) as connect:
            with self.assertRaises(registry.RegistryError):
                with self.store()._database(create=True):
                    pass
            connect.assert_not_called()
        self.assertFalse(self.path.exists())

    def test_root_owned_sticky_ancestor_with_owned_child_remains_supported(self):
        ancestor = self.root / "sticky"
        ancestor.mkdir(mode=0o700)
        identity = ancestor.stat()
        self.path = ancestor / "private/events.sqlite3"
        original = os.fstat

        def sticky_root(descriptor):
            info = original(descriptor)
            if (info.st_dev, info.st_ino) == (identity.st_dev, identity.st_ino):
                fields = list(info)
                fields[0] = stat.S_IFDIR | stat.S_ISVTX | 0o777
                fields[4] = 0
                return os.stat_result(fields)
            return info

        with patch.object(os, "fstat", side_effect=sticky_root):
            self.assertTrue(self.batch(self.store(), []))
        self.assertIsNotNone(self.store().snapshot()["coverage_end"])

    def test_linked_sqlite_sidecars_are_refused_before_connection(self):
        self.batch(self.store(), [])
        sentinel = self.root / "sentinel"
        sentinel.write_bytes(b"keep")
        for suffix in ("-journal", "-wal", "-shm"):
            sidecar = Path(str(self.path) + suffix)
            sidecar.symlink_to(sentinel)
            try:
                with self.subTest(suffix=suffix), \
                        patch.object(self.module().sqlite3, "connect", wraps=sqlite3.connect) as connect:
                    with self.assertRaises(registry.RegistryError):
                        self.store().snapshot()
                    connect.assert_not_called()
                self.assertEqual(sentinel.read_bytes(), b"keep")
            finally:
                sidecar.unlink()

    @unittest.skipUnless(sys.platform == "darwin", "macOS descriptor ACL policy")
    def test_macos_deny_only_ancestor_acl_preserves_private_ledger_access(self):
        subprocess.run(["/bin/chmod", "+a", "everyone deny delete", str(self.root)], check=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-N", str(self.root)], check=True)
        self.assertTrue(self.batch(self.store(), []))
        self.assertIsNotNone(self.store().snapshot()["coverage_end"])

    @unittest.skipUnless(sys.platform == "darwin", "macOS descriptor ACL policy")
    def test_macos_ancestor_acl_allow_grant_is_refused_before_sqlite_connect(self):
        subprocess.run(["/bin/chmod", "+a", "everyone allow add_subdirectory", str(self.root)], check=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-N", str(self.root)], check=True)
        with patch.object(self.module().sqlite3, "connect", wraps=sqlite3.connect) as connect:
            with self.assertRaises(registry.RegistryError):
                self.batch(self.store(), [])
            connect.assert_not_called()
        self.assertFalse(self.path.exists())

    @unittest.skipUnless(sys.platform == "linux", "Linux descriptor ACL policy")
    def test_linux_extended_or_unavailable_acl_inspection_refuses_before_connection(self):
        for result in (b"extended ACL", OSError(errno.EACCES, "injected ACL inspection denial")):
            options = {"side_effect": result} if isinstance(result, OSError) else {"return_value": result}
            with self.subTest(unavailable=isinstance(result, OSError)), \
                    patch.object(os, "getxattr", **options), \
                    patch.object(self.module().sqlite3, "connect", wraps=sqlite3.connect) as connect:
                with self.assertRaises(registry.RegistryError):
                    with self.store()._database(create=True):
                        pass
                connect.assert_not_called()
        self.assertFalse(self.path.exists())

    def test_changed_sqlite_schema_is_refused_without_deleting_the_state(self):
        store = self.store()
        self.batch(store, [self.event()])
        with closing(sqlite3.connect(self.path)) as connection, connection:
            connection.execute("CREATE TABLE unexpected (payload TEXT)")
        with self.assertRaises(registry.RegistryError):
            store.snapshot()
        with closing(sqlite3.connect(self.path)) as connection, connection:
            self.assertIsNotNone(connection.execute("SELECT name FROM sqlite_master WHERE name='unexpected'").fetchone())

    def test_oversized_batch_and_event_count_fail_before_ledger_creation(self):
        with self.log.open("wb") as stream:
            stream.truncate(8 * 1024 * 1024 + 1)
        with self.assertRaises(registry.RegistryError):
            self.store().import_batch("asm-origin", "large", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z", self.log)
        self.log.write_bytes(b"\n" * 100001)
        with self.assertRaises(registry.RegistryError):
            self.store().import_batch("asm-origin", "many", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z", self.log)
        self.assertFalse(self.path.exists())

    def test_operator_log_from_a_public_writable_directory_is_refused(self):
        public = self.root / "public-logs"
        public.mkdir(mode=0o777)
        public.chmod(0o777)
        path = public / "origin.jsonl"
        path.write_text(json.dumps(self.event()) + "\n")
        with self.assertRaises(registry.RegistryError):
            self.store().import_batch("asm-origin", "untrusted", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z", path)
        self.assertFalse(self.path.exists())

    def test_nginx_routes_bind_exact_active_selections_and_never_expose_state(self):
        text = self.module().nginx_locations([self.record], "/srv/asm/blobs/sha256")
        self.assertIn("location = " + self.uri, text)
        self.assertIn("alias /srv/asm/blobs/sha256/" + "a" * 64 + ";", text)
        self.assertNotIn("sqlite", text)
        self.record.update(yanked=True, yank_reason="Synthetic withdrawal.")
        self.assertNotIn("location = ", self.module().nginx_locations([self.record], "/srv/asm/blobs/sha256"))
        with self.assertRaises(registry.RegistryError):
            self.module().nginx_locations([self.record], "/srv/asm; inject")

    def test_retention_failure_rolls_back_events_and_batch_marker(self):
        store = self.store()
        self.batch(store, [self.event()])
        with patch.object(self.module(), "MAX_EVENTS", 1), self.assertRaises(registry.RegistryError):
            self.batch(store, [self.event("new")], batch_id="too-many")
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["counts"]["fixture/math"], 1)
        with closing(sqlite3.connect(self.path)) as connection, connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM batches").fetchone()[0], 1)

    def test_first_batch_capacity_failure_keeps_a_valid_empty_store(self):
        store = self.store()
        with patch.object(self.module(), "MAX_EVENTS", 0), self.assertRaises(registry.RegistryError):
            self.batch(store, [self.event()])
        self.assertIsNone(store.snapshot()["coverage_end"])
        self.assertTrue(self.batch(store, [self.event()]))

    def test_log_cli_import_and_snapshot_keep_stdout_machine_readable(self):
        directory = self.root / "registry/packages/fixture/math"
        directory.mkdir(parents=True)
        (directory / "0.1.0.json").write_bytes(registry.json_bytes(self.record))
        self.log.write_text(json.dumps(self.event()) + "\n")
        command = [sys.executable, str(ROOT / "tools/registry_log_import.py"), "--registry", str(self.root / "registry")]
        result = subprocess.run(command + ["import", "--state", str(self.path), "--source", "asm-origin",
                                "--batch", "cli-batch", "--start", "2026-01-02T00:00:00Z", "--end",
                                "2026-01-03T00:00:00Z", "--log", str(self.log)], capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        result = subprocess.run(command + ["snapshot", "--state", str(self.path), "--source", "asm-origin"],
                                capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stderr), (0, b""))
        self.assertEqual(json.loads(result.stdout)["counts"], {"fixture/math": 1})

    def test_cli_routes_use_one_exact_mirror_snapshot_without_a_registry_checkout(self):
        snapshot = {"schema": 1, "source_commit": "b" * 40, "sequence": 1, "previous": None,
                    "records": [self.record], "objects": [{"name": "fixture/math", "version": "0.1.0",
                    "target": "x86_64-linux", "kind": "source", "sha256": "a" * 64, "bytes": 100,
                    "origin": "https://github.com/fixture/math/releases/download/v0.1.0/math.tar.gz"}]}
        digest = hashlib.sha256(registry.json_bytes(snapshot)).hexdigest()
        path = self.root / "snapshots" / digest / "manifest.json"
        path.parent.mkdir(mode=0o700, parents=True)
        path.write_bytes(registry.json_bytes(snapshot))
        command = [sys.executable, str(ROOT / "tools/registry_log_import.py"), "--snapshot-file", str(path)]
        result = subprocess.run(command + ["nginx", "--blob-root", "/srv/asm/blobs/sha256"],
                                capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stderr), (0, b""))
        self.assertIn(("location = " + self.uri).encode(), result.stdout)
        snapshot["records"][0]["summary"] = "Changed canonical metadata."
        path.write_bytes(registry.json_bytes(snapshot))
        result = subprocess.run(command + ["nginx", "--blob-root", "/srv/asm/blobs/sha256"],
                                capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout), (1, b""))
        path.write_bytes(b'{"schema":1,"schema":1}\n')
        result = subprocess.run(command + ["nginx", "--blob-root", "/srv/asm/blobs/sha256"],
                                capture_output=True, timeout=10)
        self.assertEqual((result.returncode, result.stdout), (1, b""))

    @unittest.skipUnless(os.environ.get("ASM_TEST_NGINX"), "set ASM_TEST_NGINX to test the actual nginx origin")
    def test_actual_nginx_transfers_emit_only_attributable_private_log_fields(self):
        data = b"x" * 100
        self.record["artifacts"][0]["sha256"] = hashlib.sha256(data).hexdigest()
        self.uri = "/downloads/v1/fixture/math/0.1.0/x86_64-linux/source/" + self.record["artifacts"][0]["sha256"]
        large = json.loads(json.dumps(self.record))
        large["version"] = "0.2.0"
        large["artifacts"][0].update(bytes=256 * 1024,
            sha256=hashlib.sha256(b"z" * (256 * 1024)).hexdigest(),
            url="https://github.com/fixture/math/releases/download/v0.2.0/math.tar.gz")
        records = [self.record, large]
        blobs = self.root / "blobs/sha256"
        blobs.mkdir(parents=True)
        (blobs / self.record["artifacts"][0]["sha256"]).write_bytes(data)
        (blobs / large["artifacts"][0]["sha256"]).write_bytes(b"z" * (256 * 1024))
        logs = self.root / "logs"
        logs.mkdir(mode=0o700)
        includes = self.root / "downloads.conf"
        locations = self.module().nginx_locations(records, str(blobs)).replace("/var/log/asm", str(logs))
        locations = locations.replace("alias " + str(blobs / large["artifacts"][0]["sha256"]),
                                      "limit_rate 16k;\n    alias " + str(blobs / large["artifacts"][0]["sha256"]))
        # Qualify the optional V2 serving include under a separate base. The
        # V1 origin must continue refusing raw digest paths at its own base.
        v2 = (ROOT / "deploy/mirror/v2-locations.conf").read_text()
        v2 = v2.replace("location /", "location /v2/").replace("/srv/asm/", str(self.root) + "/").replace("/var/log/asm", str(logs))
        metadata = self.root / "metadata"
        metadata.mkdir()
        (metadata / "timestamp.json").write_bytes(b'{"fixture":"timestamp"}\n')
        targets = self.root / "targets"
        targets.mkdir()
        (targets / "fixture.json").write_bytes(b'{"fixture":"target"}\n')
        (targets / "symlink.json").symlink_to(metadata / "timestamp.json")
        includes.write_text(locations + "\n" + v2)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        configuration = (ROOT / "deploy/mirror/nginx.conf").read_text()
        configuration = configuration.replace("worker_processes auto", "worker_processes 1")
        configuration = configuration.replace("listen 8080", f"listen 127.0.0.1:{port}")
        configuration = configuration.replace("/tmp/asm-nginx.pid", str(self.root / "nginx.pid"))
        configuration = configuration.replace("/etc/nginx/asm/downloads.conf", str(includes))
        path = self.root / "nginx.conf"
        path.write_text(configuration)
        command = [os.environ["ASM_TEST_NGINX"], "-p", str(self.root) + "/", "-c", str(path)]
        checked = subprocess.run(command + ["-t"], capture_output=True, timeout=10)
        self.assertEqual(checked.returncode, 0, checked.stderr.decode())
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env={**os.environ, "TZ": "UTC"})
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    self.assertLess(time.monotonic(), deadline, "nginx failed to open its test listener")
                    time.sleep(0.02)
            def request(method, route, headers=None):
                connection = HTTPConnection("127.0.0.1", port, timeout=3)
                connection.request(method, route, headers=headers or {})
                response = connection.getresponse()
                result = response.status, response.read(), dict(response.getheaders())
                connection.close()
                return result
            status, body, headers = request("GET", self.uri + "?private=secret")
            self.assertEqual((status, body), (200, data))
            self.assertEqual(headers["Content-Disposition"], "attachment")
            self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
            self.assertEqual(request("HEAD", self.uri)[:2], (200, b""))
            self.assertEqual(request("GET", self.uri, {"Range": "bytes=0-9"})[:2], (206, b"x" * 10))
            self.assertEqual(request("GET", self.uri, {"If-None-Match": headers["ETag"]})[0], 304)
            self.assertEqual(request("GET", self.uri, {"User-Agent": "SyntheticBot/1"})[0], 200)
            self.assertEqual(request("GET", self.uri, {"User-Agent": "AsmValidation/1"})[0], 200)
            self.assertEqual(request("POST", self.uri)[0], 405)
            for route in ("/unknown?private=secret", "/blobs/sha256/" + self.record["artifacts"][0]["sha256"], "/head.json"):
                self.assertEqual(request("GET", route)[0], 404)
            status, body, headers = request("GET", "/v2/metadata/timestamp.json")
            self.assertEqual((status, body), (200, b'{"fixture":"timestamp"}\n'))
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
            self.assertEqual(request("HEAD", "/v2/targets/fixture.json")[:2], (200, b""))
            status, body, headers = request("GET", "/v2/blobs/sha256/" + self.record["artifacts"][0]["sha256"], {"Range": "bytes=0-9"})
            self.assertEqual((status, body), (206, b"x" * 10))
            self.assertIn("immutable", headers["Cache-Control"])
            self.assertEqual(request("POST", "/v2/metadata/timestamp.json")[0], 405)
            for route in ("/v2/distribution/head.json", "/v2/work/private", "/v2/targets/symlink.json"):
                self.assertIn(request("GET", route)[0], (403, 404))
            interrupted = socket.create_connection(("127.0.0.1", port), timeout=3)
            large_uri = self.uri.replace("0.1.0", "0.2.0").rsplit("/", 1)[0] + "/" + large["artifacts"][0]["sha256"]
            interrupted.sendall((f"GET {large_uri} HTTP/1.1\r\nHost: localhost\r\n\r\n").encode())
            interrupted.recv(4096)
            interrupted.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            interrupted.close()
            deadline = time.monotonic() + 3
            while large_uri not in (logs / "downloads.jsonl").read_text():
                self.assertLess(time.monotonic(), deadline, "nginx did not finish logging the interrupted request")
                time.sleep(0.02)
        finally:
            process.terminate()
            _, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error.decode())
        raw = (logs / "downloads.jsonl").read_bytes()
        self.assertNotIn(b"secret", raw)
        events = [json.loads(line) for line in raw.splitlines()]
        self.assertTrue(events)
        self.assertTrue(all(set(event) == self.module().FIELDS for event in events))
        self.assertTrue(any(event["status"] == 206 for event in events))
        now = datetime.now(timezone.utc)
        store = self.module().LogStore(self.path, records)
        store.import_batch("asm-origin", "actual-nginx", (now - timedelta(minutes=1)).isoformat(), now.isoformat(), logs / "downloads.jsonl")
        observation = store.snapshot()
        self.assertEqual(observation["version_counts"], {"fixture/math@0.1.0": 1, "fixture/math@0.2.0": 0})


if __name__ == "__main__":
    unittest.main()
