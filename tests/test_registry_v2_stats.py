"""Synthetic V2 sender observations: no people, installations, or trust claims.

SPDX-License-Identifier: AGPL-3.0-or-later
The selected local inventory is operator input, not verified TUF authority.
"""
from copy import deepcopy
from contextlib import closing
from datetime import datetime, timedelta, timezone
import hashlib
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import sqlite3
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import registry_distribution
import registry_log_import as logs
from registry_storage import LocalBlobStore


class RegistryV2StatsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-v2-stats-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / "state/events.sqlite3"
        self.log = self.root / "events.jsonl"
        self.registry_id = "1" * 32
        self.data = b"x" * 100
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.public = LocalBlobStore(self.root / "public")
        source = self.root / "object"; source.write_bytes(self.data)
        self.public.put_blob(source, self.digest, len(self.data))
        self.envelopes = [self.envelope("fixture/one", "2" * 32, "3" * 32),
                          self.envelope("fixture/two", "4" * 32, "5" * 32)]
        self.distribution(self.public, self.envelopes)

    def envelope(self, name, package, release, *, registry_id=None):
        publication = {"schema": 2, "owner_id": "a" * 32, "name": name, "version": "1.0.0",
            "summary": "Synthetic V2 observation fixture.", "license": "MIT",
            "source": {"commit": {"algorithm": "git-sha1", "digest": "b" * 40}, "path": ".",
                "archive": {"sha256": self.digest, "bytes": len(self.data)}},
            "artifacts": [{"kind": "source", "format": "tar.gz", "isa": "x86_64", "os": "linux",
                "abi": "sysv-amd64", "cpu_features": [], "sha256": self.digest, "bytes": len(self.data)}]}
        return {"schema": 2, "registry_id": registry_id or self.registry_id, "package_id": package,
            "release_id": release, "manifest_sha256": hashlib.sha256(registry.json_bytes(publication)).hexdigest(),
            "publication": publication}

    def distribution(self, store, envelopes, *, version=1, registry_id=None):
        identity = registry_id or self.registry_id
        objects = {f"metadata/{version}.{role}.json": registry.json_bytes({"signed": {"_type": role, "version": version}})
                   for role in ("root", "targets", "snapshot", "timestamp")}
        policy = f"# asm-registry-policy-v2\t{identity}\t{len(envelopes)}\t0\n"
        for envelope in envelopes:
            publication = envelope["publication"]
            raw = registry.json_bytes(envelope)
            sha = hashlib.sha256(raw).hexdigest()
            objects[f"targets/registries/{identity}/releases/{publication['name']}/{sha}.{publication['version']}.json"] = raw
            policy += f"{publication['name']}\t{publication['version']}\t{envelope['package_id']}\t{envelope['release_id']}\t0\t0\n"
        raw = policy.encode("ascii")
        objects[f"targets/registries/{identity}/{hashlib.sha256(raw).hexdigest()}.policy.tsv"] = raw
        files = []
        for key, data in sorted(objects.items()):
            store.create_object(key, data)
            files.append({"key": key, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        blobs = {}
        for envelope in envelopes:
            publication = envelope["publication"]
            for artifact in [publication["source"]["archive"], *publication["artifacts"]]:
                blobs[artifact["sha256"]] = artifact["bytes"]
        plan = {"schema": 2, "registry_id": identity, "batch_id": f"{version:032x}", "version": str(version),
            "publication_revision": str(len(envelopes)), "policy_revision": "0", "files": files,
            "blobs": [{"sha256": digest, "bytes": size} for digest, size in sorted(blobs.items())]}
        registry_distribution.validate_plan(plan)
        registry_distribution._store_plan(store, plan)
        prior = store.read_object(registry_distribution.HEAD_KEY, 4096)
        store.compare_and_swap(registry_distribution.HEAD_KEY, registry.json_bytes(registry_distribution._head_for(plan)),
                               prior[1] if prior else None)
        return plan

    def store(self, *, public=None, registry_id=None, state=None):
        return logs.LogStore.from_distribution(state or self.state, public or self.public,
                                               registry_id or self.registry_id, sources=("origin",))

    def route(self, envelope=None):
        envelope = envelope or self.envelopes[0]
        return "/downloads/v2/" + "/".join((envelope["registry_id"], envelope["package_id"], envelope["release_id"],
                                              "x86_64-linux", "source", self.digest))

    def event(self, identifier="request-1", **changes):
        value = {"time": "2026-01-02T12:00:00Z", "request_id": identifier, "method": "GET", "uri": self.route(),
                 "status": 200, "bytes": len(self.data), "complete": "OK", "traffic": "public"}
        value.update(changes)
        return value

    def batch(self, store, events, identity="batch-1"):
        self.log.write_bytes(b"".join(registry.json_bytes(event).replace(b"\n", b"") + b"\n" for event in events))
        return store.import_batch("origin", identity, "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z", self.log)

    def test_unknown_before_reporting_and_shared_bytes_do_not_merge_package_identities(self):
        with patch.object(self.public, "get_blob", side_effect=AssertionError("Statistics must not read artifact bytes.")):
            store = self.store()
        unknown = store.snapshot(at="2026-01-03T00:00:01Z")
        self.assertEqual(set(unknown), {"schema", "registry_id", "packages", "releases", "observed_at", "collection_started_at",
            "coverage_start", "coverage_end", "complete", "stale", "counts", "release_counts", "daily_counts", "coverage_intervals",
            "retained_counts", "retained_release_counts", "retained_coverage_start", "retained_complete", "sources", "reporting",
            "unattributed_requests", "retained_unattributed_requests"})
        self.assertEqual(unknown["schema"], 2)
        self.assertEqual(unknown["registry_id"], self.registry_id)
        self.assertEqual(unknown["counts"], {"2" * 32: None, "4" * 32: None})
        self.assertIsNone(unknown["unattributed_requests"])
        self.assertIsNone(unknown["retained_unattributed_requests"])
        self.assertFalse(self.state.exists())
        self.assertTrue(self.batch(store, [self.event()]))
        self.assertFalse(self.batch(store, [self.event()]))
        result = self.store().snapshot(at="2026-01-03T00:00:01Z")
        self.assertEqual(result["counts"], {"2" * 32: 1, "4" * 32: 0})
        self.assertEqual(result["release_counts"], {"3" * 32: 1, "5" * 32: 0})
        self.assertEqual(result["retained_counts"], result["counts"])
        self.assertFalse(result["complete"])
        self.assertEqual(result["packages"], {"2" * 32: "fixture/one", "4" * 32: "fixture/two"})

    def test_empty_report_is_zero_but_pins_even_an_empty_registry(self):
        empty = LocalBlobStore(self.root / "empty")
        self.distribution(empty, [])
        store = self.store(public=empty)
        self.assertTrue(self.batch(store, []))
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["counts"], {})
        other = LocalBlobStore(self.root / "other")
        self.distribution(other, [], registry_id="f" * 32)
        with self.assertRaises(registry.RegistryError):
            self.batch(self.store(public=other, registry_id="f" * 32), [], "other-registry")

    def test_changed_bindings_registry_or_v1_rows_preserve_the_existing_ledger(self):
        store = self.store(); self.batch(store, [self.event()])
        before = self.state.read_bytes()
        changed = deepcopy(self.envelopes)
        changed[0]["publication"]["summary"] = "Changed bytes under a retained release identity."
        changed[0]["manifest_sha256"] = hashlib.sha256(registry.json_bytes(changed[0]["publication"])).hexdigest()
        self.distribution(self.public, changed, version=2)
        with self.assertRaises(registry.RegistryError): self.batch(self.store(), [], "changed-binding")
        self.assertEqual(self.state.read_bytes(), before)
        v1 = {"schema": 1, "name": "fixture/old", "version": "1.0.0", "summary": "V1 fixture.", "license": "MIT", "yanked": False,
            "source": {"repository": "https://github.com/fixture/old", "commit": "b" * 40, "path": "."},
            "artifacts": [{"target": "x86_64-linux", "kind": "source", "sha256": self.digest, "bytes": len(self.data),
                "url": "https://github.com/fixture/old/releases/download/v1.0.0/source.tar.gz"}]}
        with self.assertRaises(registry.RegistryError): self.batch(logs.LogStore(self.state, [v1], sources=("origin",)), [], "v1-mix")
        self.assertEqual(self.state.read_bytes(), before)

    def test_reused_names_and_duplicated_release_identity_are_rejected(self):
        cases = []
        changed = deepcopy(self.envelopes); changed[1] = self.envelope("fixture/one", "4" * 32, "5" * 32); cases.append(changed)
        changed = deepcopy(self.envelopes); changed[1]["package_id"] = changed[0]["package_id"]; cases.append(changed)
        changed = deepcopy(self.envelopes); changed[1]["release_id"] = changed[0]["release_id"]; cases.append(changed)
        for index, envelopes in enumerate(cases, 2):
            self.distribution(self.public, envelopes, version=index)
            with self.subTest(case=index), self.assertRaises(registry.RegistryError): self.store()
        self.assertFalse(self.state.exists())

    def test_pin_rows_cannot_be_events_and_exclusions_keep_the_counted_policy(self):
        store = self.store()
        pin = next(iter(store.pins))
        for route in (pin, self.route() + "?private=secret", "/blobs/sha256/" + self.digest,
                      self.route().replace("x86_64-linux", "unsupported")):
            with self.subTest(route=route), self.assertRaises(registry.RegistryError): self.batch(store, [self.event(uri=route)])
        self.assertFalse(self.state.exists())
        excluded = [{"method": "HEAD", "bytes": 0}, {"status": 206, "bytes": 10}, {"status": 302},
                    {"status": 304, "bytes": 0}, {"complete": "", "bytes": 50}, {"traffic": "bot"}, {"traffic": "internal"}]
        self.batch(store, [self.event(str(index), **change) for index, change in enumerate(excluded)] + [self.event("counted")])
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["counts"]["2" * 32], 1)
        with closing(sqlite3.connect(self.state)) as connection, connection:
            self.assertEqual(dict(connection.execute("SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL")), logs.SCHEMA)
            # Even a trusted administrator's diagnostic row cannot turn a pin
            # into a counted artifact. Public import rejects it above.
            connection.execute("INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?)",
                ("origin", "internal-pin", "0" * 64, 1767355200000000, pin, "GET", 200, 0, 1, "public"))
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["counts"]["2" * 32], 1)

    def test_empty_v1_reporting_history_cannot_be_adopted_as_v2(self):
        prior = logs.LogStore(self.state, [], sources=("origin",))
        self.batch(prior, [])
        before = self.state.read_bytes()
        with self.assertRaises(registry.RegistryError): self.batch(self.store(), [], "v2-on-v1")
        self.assertEqual(self.state.read_bytes(), before)

    def test_forged_canonical_tags_are_unattributed_without_blocking_known_counts(self):
        store = self.store()
        routes = [self.route().replace(self.registry_id, "f" * 32, 1), self.route().replace("2" * 32, "4" * 32),
                  self.route().replace("3" * 32, "e" * 32), self.route().replace(self.digest, "0" * 64),
                  self.route().replace("source", "executable")]
        events = [self.event("known")] + [self.event("unattributed-" + str(index), uri=route) for index, route in enumerate(routes)]
        self.assertTrue(self.batch(store, events))
        self.assertFalse(self.batch(store, events))
        result = store.snapshot(at="2026-01-03T00:00:01Z")
        self.assertEqual(result["counts"], {"2" * 32: 1, "4" * 32: 0})
        self.assertEqual((result["unattributed_requests"], result["retained_unattributed_requests"]), (5, 5))
        with self.assertRaises(registry.RegistryError):
            self.batch(store, [self.event("unattributed-0", uri=routes[1])], "changed-request")
        self.assertEqual(store.snapshot(at="2026-01-03T00:00:01Z")["retained_unattributed_requests"], 5)

    def test_reporting_gaps_late_replay_and_thirty_day_totals_remain_explicit(self):
        store = self.store()
        forged = self.route().replace(self.registry_id, "f" * 32, 1)
        old = [self.event("old"), self.event("old-unknown", uri=forged)]
        self.batch(store, old)
        recent = [self.event("recent", time="2026-02-14T12:00:00Z", uri=self.route(self.envelopes[1])),
                  self.event("recent-unknown", time="2026-02-14T12:00:00Z", uri=forged)]
        self.log.write_bytes(b"".join(json.dumps(event).encode() + b"\n" for event in recent))
        store.import_batch("origin", "later", "2026-02-14T00:00:00Z", "2026-02-15T00:00:00Z", self.log)
        self.batch(store, old, "late-identical")
        result = store.snapshot(at="2026-02-16T00:00:01Z")
        self.assertEqual(result["counts"], {"2" * 32: 0, "4" * 32: 1})
        self.assertEqual(result["retained_counts"], {"2" * 32: 1, "4" * 32: 1})
        self.assertEqual((result["unattributed_requests"], result["retained_unattributed_requests"]), (1, 2))
        self.assertEqual(result["coverage_end"], "2026-02-15T00:00:00Z")
        self.assertEqual(result["coverage_intervals"], [])
        self.assertTrue(result["stale"])
        self.assertFalse(result["complete"])
        self.assertEqual(result["daily_counts"], [{"date": "2026-02-14", "package_id": "4" * 32, "release_id": "5" * 32, "count": 1}])

    def test_another_registry_with_identical_display_names_and_ids_cannot_merge(self):
        self.batch(self.store(), [self.event()])
        before = self.state.read_bytes()
        other = LocalBlobStore(self.root / "other")
        envelopes = [dict(envelope, registry_id="f" * 32) for envelope in self.envelopes]
        self.distribution(other, envelopes, registry_id="f" * 32)
        with self.assertRaises(registry.RegistryError):
            self.batch(self.store(public=other, registry_id="f" * 32), [], "other-registry")
        self.assertEqual(self.state.read_bytes(), before)

    def test_ledger_cannot_be_created_inside_public_storage_or_a_path_alias(self):
        alias = self.root / "public-alias"; alias.symlink_to(self.public.root, target_is_directory=True)
        paths = [self.public.root / "metadata/observations.sqlite3", self.public.root / "blobs/sha256/nested/events.sqlite3",
                 alias / "metadata/alias.sqlite3"]
        case_alias = self.public.root.with_name("PUBLIC")
        if case_alias.is_dir(): paths.append(case_alias / "metadata/case.sqlite3")
        for state in paths:
            with self.subTest(state=state), self.assertRaises(registry.RegistryError):
                self.batch(self.store(state=state), [])
            self.assertFalse(state.exists())

    def test_current_metadata_corruption_is_refused_without_reading_a_blob(self):
        key = next(key for key in (item["key"] for item in registry_distribution.load_current(self.public)[1]["files"]) if "/releases/" in key)
        (self.public.root / key).write_bytes(b"changed envelope")
        with self.assertRaises(registry.RegistryError): self.store()
        self.assertFalse(self.state.exists())

    def test_cli_selects_v2_without_creating_an_unknown_reporting_history(self):
        command = [sys.executable, str(ROOT / "tools/registry_log_import.py"), "--distribution-root", str(self.public.root),
                   "--registry-id", self.registry_id]
        result = subprocess.run(command + ["snapshot", "--state", str(self.state), "--source", "origin"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(registry.strict_json(result.stdout)["counts"], {"2" * 32: None, "4" * 32: None})
        self.assertFalse(self.state.exists())
        self.log.write_bytes(json.dumps(self.event()).encode() + b"\n")
        arguments = ["import", "--state", str(self.state), "--source", "origin", "--batch", "cli-batch",
                     "--start", "2026-01-02T00:00:00Z", "--end", "2026-01-03T00:00:00Z", "--log", str(self.log)]
        for _ in range(2):
            result = subprocess.run(command + arguments, capture_output=True, timeout=10)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        result = subprocess.run(command + ["snapshot", "--state", str(self.state), "--source", "origin"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(registry.strict_json(result.stdout)["retained_counts"], {"2" * 32: 1, "4" * 32: 0})

    @unittest.skipUnless(os.environ.get("ASM_TEST_NGINX"), "Set ASM_TEST_NGINX for the real static-origin gate")
    def test_actual_nginx_normalizes_only_exact_tags_and_imports_full_responses(self):
        large = self.envelope("fixture/large", "6" * 32, "7" * 32)
        data = b"z" * (256 * 1024)
        digest = hashlib.sha256(data).hexdigest()
        binding = {"sha256": digest, "bytes": len(data)}
        large["publication"]["source"]["archive"] = binding
        large["publication"]["artifacts"][0].update(binding)
        large["manifest_sha256"] = hashlib.sha256(registry.json_bytes(large["publication"])).hexdigest()
        path = self.root / "large"; path.write_bytes(data)
        self.public.put_blob(path, digest, len(data))
        self.distribution(self.public, self.envelopes + [large], version=2)
        log_dir = self.root / "logs"; log_dir.mkdir(mode=0o700)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0)); port = listener.getsockname()[1]
        include = self.root / "v2.conf"
        locations = (ROOT / "deploy/mirror/v2-locations.conf").read_text()
        locations = locations.replace("/srv/asm", str(self.public.root)).replace("/var/log/asm", str(log_dir))
        locations = locations.replace("alias " + str(self.public.root) + "/blobs/sha256/;", "limit_rate 16k;\n    alias " + str(self.public.root) + "/blobs/sha256/;")
        include.write_text(locations + "\n" + locations.replace("location /", "location /asm/v2/"))
        config = (ROOT / "deploy/mirror/nginx.conf").read_text()
        config = config.replace("listen 8080;", f"listen 127.0.0.1:{port};").replace("/tmp/asm-nginx.pid", str(self.root / "nginx.pid"))
        config = config.replace("/etc/nginx/asm/downloads.conf", str(include)).replace("/var/log/asm", str(log_dir))
        config_path = self.root / "nginx.conf"; config_path.write_text(config)
        command = [os.environ["ASM_TEST_NGINX"], "-p", str(self.root) + "/", "-c", str(config_path)]
        checked = subprocess.run(command + ["-t"], capture_output=True, timeout=10)
        self.assertEqual(checked.returncode, 0, checked.stderr.decode())
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env={**os.environ, "TZ": "UTC"})
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1): break
                except OSError:
                    self.assertLess(time.monotonic(), deadline, "nginx did not start")
                    time.sleep(0.02)
            def request(method, route, headers=None):
                connection = HTTPConnection("127.0.0.1", port, timeout=3)
                try:
                    connection.request(method, route, headers=headers or {})
                    response = connection.getresponse()
                    return response.status, response.read(), dict(response.getheaders())
                finally:
                    connection.close()
            blob = "/blobs/sha256/" + self.digest
            tags = [".".join((self.registry_id, envelope["package_id"], envelope["release_id"], "x86_64-linux", "source"))
                    for envelope in self.envelopes]
            first = blob + "?x-asm=" + tags[0]
            status, body, headers = request("GET", first)
            self.assertEqual((status, body), (200, self.data))
            self.assertEqual(request("GET", blob + "?x-asm=" + tags[1])[:2], (200, self.data))
            forged = tags[0].replace(self.registry_id, "f" * 32, 1)
            self.assertEqual(request("GET", blob + "?x-asm=" + forged)[:2], (200, self.data))
            self.assertEqual(request("GET", "/asm/v2" + first)[:2], (200, self.data))
            for prefix in ("/asm%2Fv2", "/asm/v2/../v2", "/asm/v2/.", "/asm//v2"):
                self.assertEqual(request("GET", prefix + first)[:2], (200, self.data))
            self.assertEqual(request("HEAD", first)[:2], (200, b""))
            self.assertEqual(request("GET", first, {"Range": "bytes=0-9"})[:2], (206, self.data[:10]))
            self.assertEqual(request("GET", first, {"If-None-Match": headers["ETag"]})[0], 304)
            for agent in ("SyntheticBot/1", "AsmValidation/1"):
                self.assertEqual(request("GET", first, {"User-Agent": agent})[0], 200)
            for query in ("", "?secret=private-value", "?x-asm=" + tags[0] + "&secret=private-value",
                          "?x-asm=" + tags[0] + "&x-asm=" + tags[1], "?x-asm=" + tags[0] + "&",
                          "?x-asm=" + tags[0].replace("x86_64", "%78%38%36%5f%36%34"), "?x-asm=" + tags[0] + "+"):
                self.assertEqual(request("GET", blob + query)[:2], (200, self.data))
            large_tag = ".".join((self.registry_id, large["package_id"], large["release_id"], "x86_64-linux", "source"))
            interrupted = socket.create_connection(("127.0.0.1", port), timeout=3)
            interrupted.sendall((f"GET /blobs/sha256/{digest}?x-asm={large_tag} HTTP/1.1\r\nHost: localhost\r\n\r\n").encode())
            interrupted.recv(4096)
            interrupted.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); interrupted.close()
            output = log_dir / "downloads-v2.jsonl"
            deadline = time.monotonic() + 3
            while not output.exists() or large["release_id"] not in output.read_text():
                self.assertLess(time.monotonic(), deadline, "nginx did not emit a normalized V2 observation")
                time.sleep(0.02)
        finally:
            process.terminate()
            _, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error.decode())
        raw = output.read_bytes()
        self.assertNotIn(b"private-value", raw); self.assertNotIn(b"x-asm", raw); self.assertNotIn(b"?", raw)
        events = [registry.strict_json(line) for line in raw.splitlines()]
        self.assertTrue(all(set(event) == logs.FIELDS and event["uri"].startswith("/downloads/v2/") for event in events))
        self.assertEqual(len(events), 10)
        now = datetime.now(timezone.utc)
        store = self.store()
        store.import_batch("origin", "actual-nginx", (now - timedelta(minutes=1)).isoformat(), now.isoformat(), output)
        result = store.snapshot()
        self.assertEqual(result["counts"], {"2" * 32: 2, "4" * 32: 1, "6" * 32: 0})
        self.assertEqual(result["release_counts"], {"3" * 32: 2, "5" * 32: 1, "7" * 32: 0})
        self.assertEqual((result["unattributed_requests"], result["retained_unattributed_requests"]), (1, 1))
        self.assertFalse(store.import_batch("origin", "actual-nginx", (now - timedelta(minutes=1)).isoformat(), now.isoformat(), output))


if __name__ == "__main__":
    unittest.main()
