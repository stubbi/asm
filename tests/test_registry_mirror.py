"""Operator snapshot and mirror contracts; no network access is required.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib
import io
import inspect
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import weakref
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry


class MirrorTests(unittest.TestCase):
    def test_explicit_sync_audit_restores_only_missing_objects_at_the_same_head(self):
        module = self.module()
        self.assertIn("check_existing", inspect.signature(module.sync).parameters,
                      "unchanged mirrors have no explicit missing-object recovery path")
        primary, mirror = self.store(), self.store("mirror")
        digest = self.publish(primary, initialize=True)
        module.sync(primary, mirror, initialize=True)
        head = mirror.read_object("head.json", 1048576)
        artifact = self.record["artifacts"][0]
        (mirror.root / "blobs/sha256" / artifact["sha256"]).unlink()
        (mirror.root / f"snapshots/{digest}/registry/v1/index.tsv").unlink()
        with patch.object(primary, "get_blob", wraps=primary.get_blob) as fetched:
            self.assertEqual(module.sync(primary, mirror, check_existing=True), digest)
            self.assertEqual(fetched.call_count, 1)
        self.assertEqual(mirror.read_object("head.json", 1048576), head)
        self.assertEqual(module.verify(mirror), digest)
        (mirror.root / "blobs/sha256" / artifact["sha256"]).unlink()
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(module.main(["sync", "--source-store", "local", "--source-root", str(primary.root),
                "--store", "local", "--root", str(mirror.root), "--check-existing"]), 0)
        self.assertEqual(output.getvalue(), digest + "\n")
        bad = mirror.root / "blobs/sha256" / artifact["sha256"]
        bad.write_bytes(b"x" * len(self.data))
        with patch.object(primary, "get_blob", wraps=primary.get_blob) as fetched:
            with self.assertRaises(registry.RegistryError):
                module.sync(primary, mirror, check_existing=True)
            self.assertEqual(fetched.call_count, 0)
        self.assertEqual(mirror.read_object("head.json", 1048576), head)

    def test_excessive_json_nesting_is_a_controlled_no_write_failure(self):
        module = self.module()
        nested = b"[" * 10000 + b"0" + b"]" * 10000
        with self.assertRaises(registry.RegistryError):
            module.parse_snapshot(nested)
        store = self.store()
        store.create_object("head.json", nested)
        error = io.StringIO()
        with redirect_stderr(error):
            self.assertEqual(module.main(["verify", "--store", "local", "--root", str(store.root)]), 1)
        self.assertNotIn("Traceback", error.getvalue())
        self.assertEqual(store.read_object("head.json", 1048576)[0], nested)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.record, self.data = self.release("0.1.0")
        self.commit = self.save([self.record])

    def git(self, *args):
        return subprocess.check_output(["git", "--no-replace-objects", "-C", str(self.repository),
                                        *args], stderr=subprocess.PIPE).decode().strip()

    def release(self, version, target="x86_64-linux"):
        files = {"asm.toml": (f'[package]\nname = "hello"\nversion = "{version}"\n'
                              f'[build]\nsource = "src/main.s"\ntarget = "{target}"\n'.encode(), 0o644),
                 "README.md": (b"Synthetic registry test source.\n", 0o644),
                 "LICENSE": (b"Synthetic fixture under MIT.\n", 0o644),
                 "src/main.s": (b".global _start\n_start: nop\n", 0o644)}
        data = registry.make_archive(files)
        asset = f"hello-{version}.tar.gz"
        (self.artifacts / asset).write_bytes(data)
        return {"schema": 1, "name": "fixture/hello", "version": version,
                "summary": "Synthetic assembly fixture.", "license": "MIT", "yanked": False,
                "source": {"repository": "https://github.com/fixture/hello", "commit": "a" * 40, "path": "."},
                "artifacts": [{"target": target, "kind": "source", "bytes": len(data),
                               "sha256": hashlib.sha256(data).hexdigest(),
                               "url": f"https://github.com/fixture/hello/releases/download/v{version}/{asset}"}]}, data

    def save(self, records):
        directory = self.repository / "registry/packages/fixture/hello"
        directory.mkdir(parents=True, exist_ok=True)
        for path in directory.glob("*.json"):
            path.unlink()
        for record in records:
            (directory / (record["version"] + ".json")).write_bytes(registry.json_bytes(record))
        if not records:
            (self.repository / "registry/packages/.gitkeep").touch()
        self.git("add", "registry")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Record synthetic fixture")
        return self.git("rev-parse", "HEAD")

    def module(self):
        self.assertTrue((ROOT / "tools/registry_mirror.py").is_file(), "Operator mirror is not implemented")
        return importlib.import_module("registry_mirror")

    def store(self, name="primary"):
        return importlib.import_module("registry_storage").LocalBlobStore(self.root / name)

    def publish(self, store, commit=None, initialize=False):
        return self.module().publish(store, self.repository, commit or self.commit, self.artifacts,
                                     initialize=initialize)

    def test_publish_and_second_mirror_preserve_reviewed_records_and_origin_urls(self):
        module = self.module()
        primary, mirror = self.store(), self.store("mirror")
        digest = self.publish(primary, initialize=True)
        self.assertEqual(module.sync(primary, mirror, initialize=True), digest)
        manifest = json.loads(mirror.read_object(f"snapshots/{digest}/manifest.json", 1048576)[0])
        self.assertEqual(manifest["source_commit"], self.commit)
        self.assertEqual(manifest["records"], [self.record])
        self.assertEqual(manifest["objects"][0]["origin"], self.record["artifacts"][0]["url"])
        self.assertEqual(mirror.get_blob(self.record["artifacts"][0]["sha256"], len(self.data)), self.data)
        tsv = mirror.read_object(f"snapshots/{digest}/registry/v1/index.tsv", 1048576)[0]
        self.assertIn(self.record["artifacts"][0]["url"].encode(), tsv)
        self.assertEqual(mirror.read_object(f"snapshots/{digest}/registry/v1/index-all.tsv",1048576)[0],tsv)
        self.assertEqual(mirror.read_object(f"snapshots/{digest}/registry/v1/index-macos.tsv",1048576)[0],tsv)
        index = json.loads(mirror.read_object(f"snapshots/{digest}/registry/v1/index.json",1048576)[0])
        self.assertEqual(index["packages"][0]["versions"][0]["artifacts"],self.record["artifacts"])
        self.assertEqual(module.sync(primary, mirror), digest)

    def test_unchanged_sync_uses_metadata_without_reading_or_writing_artifacts(self):
        module = self.module()
        primary,mirror = self.store(),self.store("mirror")
        digest = self.publish(primary,initialize=True)
        module.sync(primary,mirror,initialize=True)
        with patch.object(primary,"get_blob",side_effect=AssertionError("source artifact read")), \
             patch.object(mirror,"get_blob",side_effect=AssertionError("destination artifact read")), \
             patch.object(mirror,"put_blob",side_effect=AssertionError("artifact write")), \
             patch.object(mirror,"create_object",side_effect=AssertionError("metadata write")), \
             patch.object(mirror,"compare_and_swap",side_effect=AssertionError("head write")):
            self.assertEqual(module.sync(primary,mirror),digest)

    def test_explicit_verify_detects_corruption_that_unchanged_sync_does_not_audit(self):
        module = self.module()
        primary,mirror = self.store(),self.store("mirror")
        digest = self.publish(primary,initialize=True)
        module.sync(primary,mirror,initialize=True)
        self.assertEqual(module.verify(mirror),digest)
        blob = self.root/"mirror/blobs/sha256"/self.record["artifacts"][0]["sha256"]
        blob.write_bytes(b"x"*len(self.data))
        before = mirror.read_object("head.json",1048576)
        self.assertEqual(module.sync(primary,mirror),digest)
        with self.assertRaises(registry.RegistryError):
            module.verify(mirror)
        self.assertEqual(blob.read_bytes(),b"x"*len(self.data))
        self.assertEqual(mirror.read_object("head.json",1048576),before)

    def test_incremental_sync_downloads_and_puts_only_the_missing_artifact(self):
        module = self.module()
        primary,mirror = self.store(),self.store("mirror")
        self.publish(primary,initialize=True)
        module.sync(primary,mirror,initialize=True)
        second,_ = self.release("0.2.0")
        expected = self.publish(primary,self.save([self.record,second]))
        source_get,destination_put = primary.get_blob,mirror.put_blob
        downloaded,uploaded = [],[]

        def download(digest,size):
            downloaded.append((digest,size))
            return source_get(digest,size)

        def upload(path,digest,size):
            uploaded.append((digest,size))
            return destination_put(path,digest,size)

        with patch.object(primary,"get_blob",side_effect=download), patch.object(mirror,"put_blob",side_effect=upload):
            self.assertEqual(module.sync(primary,mirror),expected)
        artifact = second["artifacts"][0]
        self.assertEqual(downloaded,[(artifact["sha256"],artifact["bytes"])])
        self.assertEqual(uploaded,downloaded)

    def test_destination_failure_never_becomes_a_missing_blob_or_falls_back(self):
        module = self.module()
        primary,mirror = self.store(),self.store("mirror")
        self.publish(primary,initialize=True)
        module.sync(primary,mirror,initialize=True)
        second,_ = self.release("0.2.0")
        self.publish(primary,self.save([self.record,second]))
        before = mirror.read_object("head.json",1048576)
        with patch.object(mirror,"get_blob",side_effect=registry.RegistryError("destination unavailable")), \
             patch.object(primary,"get_blob",side_effect=AssertionError("failure became a source download")), \
             patch.object(mirror,"put_blob",side_effect=AssertionError("failure became an upload")):
            with self.assertRaisesRegex(registry.RegistryError,"unavailable"):
                module.sync(primary,mirror)
        self.assertEqual(mirror.read_object("head.json",1048576),before)

    def test_changed_head_refuses_corrupt_destination_bytes_without_a_source_download(self):
        module = self.module()
        primary,mirror = self.store(),self.store("mirror")
        self.publish(primary,initialize=True)
        module.sync(primary,mirror,initialize=True)
        second,_ = self.release("0.2.0")
        self.publish(primary,self.save([self.record,second]))
        blob = self.root/"mirror/blobs/sha256"/self.record["artifacts"][0]["sha256"]
        blob.write_bytes(b"x"*len(self.data))
        before = mirror.read_object("head.json",1048576)
        with patch.object(primary,"get_blob",side_effect=AssertionError("corruption became a download")), \
             patch.object(mirror,"put_blob",side_effect=AssertionError("corruption became an upload")):
            with self.assertRaises(registry.RegistryError):
                module.sync(primary,mirror)
        self.assertEqual(blob.read_bytes(),b"x"*len(self.data))
        self.assertEqual(mirror.read_object("head.json",1048576),before)

    def test_missing_artifact_with_corrupt_source_cannot_advance_destination(self):
        module = self.module()
        primary,mirror = self.store(),self.store("mirror")
        self.publish(primary,initialize=True)
        module.sync(primary,mirror,initialize=True)
        second,data = self.release("0.2.0")
        self.publish(primary,self.save([self.record,second]))
        digest = second["artifacts"][0]["sha256"]
        (self.root/"primary/blobs/sha256"/digest).write_bytes(b"x"*len(data))
        before = mirror.read_object("head.json",1048576)
        with self.assertRaises(registry.RegistryError):
            module.sync(primary,mirror)
        self.assertEqual(mirror.read_object("head.json",1048576),before)
        self.assertFalse((self.root/"mirror/blobs/sha256"/digest).exists())

    def test_verify_rejects_missing_or_changed_current_exports(self):
        module = self.module()
        primary = self.store()
        digest = self.publish(primary,initialize=True)
        path = self.root/f"primary/snapshots/{digest}/registry/v1/index.tsv"
        original = path.read_bytes()
        path.write_bytes(b"x"*len(original))
        with self.assertRaises(registry.RegistryError):
            module.verify(primary)
        path.unlink()
        with self.assertRaises(registry.RegistryError):
            module.verify(primary)

    def test_all_six_targets_match_the_existing_operators_four_exact_exports(self):
        self.module()
        import registry_admin
        targets = ("x86_64-linux","aarch64-linux","riscv64-linux","aarch64-macos",
                   "x86_64-windows","aarch64-windows")
        records = [self.release(f"0.{number}.0",target)[0] for number,target in enumerate(targets,1)]
        commit = self.save(records)
        plan,_,exports = registry_admin.prepare_import(self.repository,commit,0)
        primary = self.store()
        digest = self.publish(primary,commit,initialize=True)
        for route,expected in zip(registry_admin.ROUTES,exports):
            with self.subTest(route=route):
                actual = primary.read_object(f"snapshots/{digest}"+route,1048576)[0]
                self.assertEqual(actual,expected.encode("ascii"))
                self.assertEqual(hashlib.sha256(actual).hexdigest(),plan["exports"][route]["sha256"])
        linux = primary.read_object(f"snapshots/{digest}/registry/v1/index.tsv",1048576)[0]
        macos = primary.read_object(f"snapshots/{digest}/registry/v1/index-macos.tsv",1048576)[0]
        full = primary.read_object(f"snapshots/{digest}/registry/v1/index-all.tsv",1048576)[0]
        self.assertNotIn(b"aarch64-macos",linux)
        self.assertIn(b"aarch64-macos",macos)
        for target in (b"x86_64-windows",b"aarch64-windows"):
            self.assertNotIn(target,linux)
            self.assertNotIn(target,macos)
            self.assertIn(target,full)

    def test_corrupt_git_blob_cannot_change_the_record_under_its_accepted_commit(self):
        self.module()
        oid = self.git("rev-parse",self.commit+":registry/packages/fixture/hello/0.1.0.json")
        path = self.repository/".git/objects"/oid[:2]/oid[2:]
        changed = registry.json_bytes(dict(self.record,summary="Altered bytes under the accepted Git object name"))
        path.chmod(0o600)
        path.write_bytes(zlib.compress(b"blob "+str(len(changed)).encode()+b"\0"+changed))
        primary = self.store()
        with self.assertRaises(registry.RegistryError):
            self.publish(primary,initialize=True)
        self.assertIsNone(primary.read_object("head.json",1048576))

    def test_bootstrap_is_explicit_and_must_not_replace_existing_head(self):
        self.module()
        primary = self.store()
        with self.assertRaisesRegex(registry.RegistryError, "initializ"):
            self.publish(primary)
        self.publish(primary, initialize=True)
        before = primary.read_object("head.json", 1048576)
        with self.assertRaisesRegex(registry.RegistryError, "initializ"):
            self.publish(primary, initialize=True)
        self.assertEqual(primary.read_object("head.json", 1048576), before)

    def test_dirty_records_are_ignored_and_full_real_commit_is_required(self):
        self.module()
        changed = copy.deepcopy(self.record)
        changed["summary"] = "Uncommitted content must not be published."
        (self.repository / "registry/packages/fixture/hello/0.1.0.json").write_bytes(registry.json_bytes(changed))
        primary = self.store()
        digest = self.publish(primary, initialize=True)
        manifest = json.loads(primary.read_object(f"snapshots/{digest}/manifest.json", 1048576)[0])
        self.assertEqual(manifest["records"][0]["summary"], "Synthetic assembly fixture.")
        for commit in ("HEAD", self.commit[:12], "0" * 40, "b" * 40):
            with self.subTest(commit=commit), self.assertRaises(registry.RegistryError):
                self.publish(self.store(commit), commit, initialize=True)

    def test_yank_retains_historical_blobs_and_sync_copies_full_chain(self):
        module = self.module()
        primary = self.store()
        first = self.publish(primary, initialize=True)
        yanked = dict(self.record, yanked=True, yank_reason="Synthetic test withdrawal")
        second_record, _ = self.release("0.2.0")
        commit = self.save([yanked, second_record])
        second = self.publish(primary, commit)
        mirror = self.store("mirror")
        module.sync(primary, mirror, initialize=True)
        self.assertIsNotNone(mirror.read_object(f"snapshots/{first}/manifest.json", 1048576))
        self.assertEqual(mirror.get_blob(self.record["artifacts"][0]["sha256"], len(self.data)), self.data)
        tsv = mirror.read_object(f"snapshots/{second}/registry/v1/index.tsv", 1048576)[0]
        self.assertNotIn(b"\t0.1.0\t", tsv)
        self.assertIn(b"\t0.2.0\t", tsv)

    def test_rewrite_delete_and_git_rollback_leave_head_unchanged(self):
        self.module()
        primary = self.store()
        self.publish(primary, initialize=True)
        original = primary.read_object("head.json", 1048576)
        changed = dict(self.record, summary="Changed published summary")
        rewrite = self.save([changed])
        with self.assertRaisesRegex(registry.RegistryError, "immutable"):
            self.publish(primary, rewrite)
        deletion = self.save([])
        with self.assertRaisesRegex(registry.RegistryError, "deleted"):
            self.publish(primary, deletion)
        self.assertEqual(primary.read_object("head.json", 1048576), original)
        self.git("checkout", "-q", self.commit)
        second_record, _ = self.release("0.2.0")
        newer = self.save([self.record, second_record])
        self.publish(primary, newer)
        with self.assertRaisesRegex(registry.RegistryError, "descend|rollback"):
            self.publish(primary, self.commit)

    def test_corrupt_artifact_fails_before_head_or_snapshot_creation(self):
        self.module()
        (self.artifacts / "hello-0.1.0.tar.gz").write_bytes(b"corrupt")
        primary = self.store()
        with self.assertRaises(registry.RegistryError):
            self.publish(primary, initialize=True)
        self.assertIsNone(primary.read_object("head.json", 1048576))
        self.assertFalse((self.root / "primary/snapshots").exists())

    def test_corrupt_manifest_and_unrelated_or_old_source_cannot_move_mirror_head(self):
        module = self.module()
        primary, mirror = self.store(), self.store("mirror")
        first = self.publish(primary, initialize=True)
        module.sync(primary, mirror, initialize=True)
        old = self.store("old")
        module.sync(primary, old, initialize=True)
        second_record, _ = self.release("0.2.0")
        self.publish(primary, self.save([self.record, second_record]))
        module.sync(primary, mirror)
        current = mirror.read_object("head.json", 1048576)
        with self.assertRaisesRegex(registry.RegistryError, "rollback|older|history"):
            module.sync(old, mirror)
        self.assertEqual(mirror.read_object("head.json", 1048576), current)
        with patch.object(primary, "read_object", return_value=(b'{}', "opaque")):
            with self.assertRaises(registry.RegistryError):
                module.sync(primary, mirror)
        self.assertEqual(mirror.read_object("head.json", 1048576), current)

    def test_storage_failure_and_concurrent_head_change_do_not_expose_candidate(self):
        self.module()
        primary = self.store()
        self.publish(primary, initialize=True)
        original = primary.read_object("head.json", 1048576)
        second_record, _ = self.release("0.2.0")
        newer = self.save([self.record, second_record])
        with patch.object(primary, "put_blob", side_effect=registry.RegistryError("store unavailable")):
            with self.assertRaisesRegex(registry.RegistryError, "unavailable"):
                self.publish(primary, newer)
        self.assertEqual(primary.read_object("head.json", 1048576), original)
        with patch.object(primary, "compare_and_swap", side_effect=registry.RegistryError("stale head")):
            with self.assertRaisesRegex(registry.RegistryError, "stale"):
                self.publish(primary, newer)
        self.assertEqual(primary.read_object("head.json", 1048576), original)

    def test_duplicate_noncanonical_or_oversized_snapshot_is_rejected(self):
        module = self.module()
        primary = self.store()
        digest = self.publish(primary, initialize=True)
        raw = primary.read_object(f"snapshots/{digest}/manifest.json", 1048576)[0]
        for candidate in (b'{"schema":1,"schema":1}', raw.rstrip(), b" " * 1048577):
            with self.subTest(size=len(candidate)), self.assertRaises(registry.RegistryError):
                module.parse_snapshot(candidate)

    def test_s3_adapter_roundtrip_preserves_bytes_and_head_binding(self):
        module = self.module()
        from registry_storage import S3BlobStore
        from test_registry_storage import FakeS3
        remote = S3BlobStore("asm-fixture", client=FakeS3(), prefix="operator")
        digest = self.publish(remote, initialize=True)
        mirror = self.store("mirror")
        self.assertEqual(module.sync(remote, mirror, initialize=True), digest)
        head, manifest, token = module.load_current(mirror)
        self.assertEqual(head["snapshot"], digest)
        self.assertEqual(manifest["source_commit"], self.commit)
        self.assertIsInstance(token, str)
        self.assertEqual(mirror.get_blob(self.record["artifacts"][0]["sha256"], len(self.data)), self.data)

    def test_corrupt_existing_blob_or_snapshot_is_never_replaced(self):
        module = self.module()
        primary = self.store()
        digest = self.publish(primary, initialize=True)
        blob = self.root / "primary/blobs/sha256" / self.record["artifacts"][0]["sha256"]
        blob.write_bytes(b"x" * len(self.data))
        before = primary.read_object("head.json", 1048576)
        with self.assertRaises(registry.RegistryError):
            self.publish(primary)
        self.assertEqual(blob.read_bytes(), b"x" * len(self.data))
        self.assertEqual(primary.read_object("head.json", 1048576), before)
        candidate = self.store("candidate")
        key = f"snapshots/{digest}/manifest.json"
        candidate.create_object(key, b"corrupt")
        with self.assertRaises(registry.RegistryError):
            self.publish(candidate, initialize=True)
        self.assertEqual(candidate.read_object(key, 1048576)[0], b"corrupt")
        self.assertIsNone(module.load_current(candidate))

    def test_artifacts_can_use_digest_names_when_origin_basenames_collide(self):
        self.module()
        second_record, second_data = self.release("0.2.0")
        for record, data in ((self.record, self.data), (second_record, second_data)):
            record["artifacts"][0]["url"] = record["artifacts"][0]["url"].rsplit("/", 1)[0] + "/source.tar.gz"
            (self.artifacts / record["artifacts"][0]["sha256"]).write_bytes(data)
        commit = self.save([self.record, second_record])
        primary = self.store()
        self.publish(primary, commit, initialize=True)
        self.assertEqual(primary.get_blob(second_record["artifacts"][0]["sha256"], len(second_data)), second_data)

    def test_concurrent_publisher_preserves_the_winning_head(self):
        self.module()
        primary = self.store()
        self.publish(primary, initialize=True)
        second_record, _ = self.release("0.2.0")
        second_commit = self.save([self.record, second_record])
        third_record, _ = self.release("0.3.0")
        third_commit = self.save([self.record, second_record, third_record])
        original_cas = primary.compare_and_swap
        winner = []

        def interleave(key, data, expected):
            with patch.object(primary, "compare_and_swap", side_effect=original_cas):
                winner.append(self.publish(primary, third_commit))
            return original_cas(key, data, expected)

        with patch.object(primary, "compare_and_swap", side_effect=interleave):
            with self.assertRaises(registry.RegistryError):
                self.publish(primary, second_commit)
        self.assertEqual(self.module().load_current(primary)[0]["snapshot"], winner[0])

    def test_missing_registry_and_unsafe_artifact_fail_without_a_head(self):
        self.module()
        asset = self.artifacts / "hello-0.1.0.tar.gz"
        original = self.artifacts / "original"
        asset.rename(original)
        asset.symlink_to(original)
        primary = self.store()
        with self.assertRaises(registry.RegistryError):
            self.publish(primary, initialize=True)
        self.assertIsNone(primary.read_object("head.json", 1048576))
        asset.unlink()
        original.rename(asset)
        self.git("rm", "-qr", "registry")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Remove registry fixture")
        with self.assertRaises(registry.RegistryError):
            self.publish(primary, self.git("rev-parse", "HEAD"), initialize=True)
        self.assertIsNone(primary.read_object("head.json", 1048576))

    def test_unrelated_history_and_bounded_chain_leave_destination_unpublished(self):
        module = self.module()
        primary = self.store()
        self.publish(primary, initialize=True)
        second_record, _ = self.release("0.2.0")
        second_commit = self.save([self.record, second_record])
        self.publish(primary, second_commit)
        mirror = self.store("mirror")
        with patch.object(module, "MAX_HISTORY", 1), self.assertRaises(registry.RegistryError):
            module.sync(primary, mirror, initialize=True)
        self.assertIsNone(mirror.read_object("head.json", 1048576))
        unrelated = self.store("unrelated")
        self.publish(unrelated, second_commit, initialize=True)
        yanked = dict(second_record, yanked=True, yank_reason="Synthetic test withdrawal")
        third_commit = self.save([self.record, yanked])
        self.publish(unrelated, third_commit)
        old = self.store("old")
        self.publish(old, self.commit, initialize=True)
        before = old.read_object("head.json", 1048576)
        with self.assertRaisesRegex(registry.RegistryError, "history"):
            module.sync(unrelated, old)
        self.assertEqual(old.read_object("head.json", 1048576), before)

    def test_sync_retains_only_a_bounded_number_of_parsed_history_manifests(self):
        module = self.module()
        source = self.store()
        previous = None
        for number in range(1,11):
            snapshot = {"schema":1,"source_commit":f"{number:040x}","sequence":number,
                        "previous":previous,"records":[],"objects":[]}
            raw = registry.json_bytes(snapshot)
            previous = hashlib.sha256(raw).hexdigest()
            source.create_object(f"snapshots/{previous}/manifest.json",raw)
        source.compare_and_swap("head.json",registry.json_bytes({"schema":1,"snapshot":previous,
                                "sequence":10,"source_commit":f"{10:040x}"}),None)
        counts = [0,0]

        class TrackedSnapshot(dict):
            pass

        def released():
            counts[0] -= 1

        original_parse = module.parse_snapshot

        def tracked_parse(raw):
            value = TrackedSnapshot(original_parse(raw))
            counts[0] += 1
            counts[1] = max(counts)
            weakref.finalize(value,released)
            return value

        with patch.object(module,"parse_snapshot",side_effect=tracked_parse):
            module.sync(source,self.store("mirror"),initialize=True)
        self.assertLessEqual(counts[1],4,"history sync retained every parsed snapshot in memory")

    def test_missing_s3_profile_returns_a_controlled_error_without_provider_details(self):
        module = self.module()

        def failed_session(**kwargs):
            raise RuntimeError("private provider detail")

        output,error = io.StringIO(),io.StringIO()
        with patch.dict(sys.modules,{"boto3":SimpleNamespace(Session=failed_session)}), redirect_stdout(output), redirect_stderr(error):
            result = module.main(["sync","--source-store","local","--source-root",str(self.root/"missing"),
                                  "--store","s3","--bucket","asm-fixture","--profile","missing"])
        self.assertEqual(result,1)
        self.assertEqual(output.getvalue(),"")
        self.assertNotIn("private provider detail",error.getvalue())

    def test_cli_publishes_and_syncs_with_stable_digest_output(self):
        self.module()
        tool = [sys.executable, str(ROOT / "tools/registry_mirror.py")]
        published = subprocess.run(tool + ["publish", "--repository", str(self.repository), "--commit", self.commit,
                                  "--artifacts-dir", str(self.artifacts), "--store", "local", "--root", str(self.root / "a"),
                                  "--initialize"], capture_output=True, text=True, timeout=10)
        self.assertEqual(published.returncode, 0, published.stderr)
        self.assertRegex(published.stdout, r"^[0-9a-f]{64}\n$")
        synced = subprocess.run(tool + ["sync", "--source-store", "local", "--source-root", str(self.root / "a"),
                               "--store", "local", "--root", str(self.root / "b"), "--initialize"],
                               capture_output=True, text=True, timeout=10)
        self.assertEqual(synced.returncode, 0, synced.stderr)
        self.assertEqual(synced.stdout, published.stdout)
        verified = subprocess.run(tool+["verify","--store","local","--root",str(self.root/"b")],
                                  capture_output=True,text=True,timeout=10)
        self.assertEqual(verified.returncode,0,verified.stderr)
        self.assertEqual(verified.stdout,published.stdout)
        blob = self.root/"b/blobs/sha256"/self.record["artifacts"][0]["sha256"]
        blob.write_bytes(b"x"*len(self.data))
        repeat = subprocess.run(tool+["sync","--source-store","local","--source-root",str(self.root/"a"),
                                      "--store","local","--root",str(self.root/"b")],
                                capture_output=True,text=True,timeout=10)
        self.assertEqual(repeat.returncode,0,repeat.stderr)
        audited = subprocess.run(tool+["verify","--store","local","--root",str(self.root/"b")],
                                 capture_output=True,text=True,timeout=10)
        self.assertEqual(audited.returncode,1)
        self.assertEqual(audited.stdout,"")
        self.assertNotEqual(audited.stderr,"")
        failed = subprocess.run(tool + ["sync", "--source-store", "local", "--source-root", str(self.root / "absent"),
                               "--store", "local", "--root", str(self.root / "b")], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(failed.stdout, "")
        self.assertIn("head", failed.stderr)


if __name__ == "__main__":
    unittest.main()
