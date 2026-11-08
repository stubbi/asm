"""Bounded distribution placement and mirror recovery, using real local stores.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import hashlib
import importlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import registry
from registry_storage import LocalBlobStore, StorageConflict
import registry_admin


class DistributionPlacementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-distribution-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = LocalBlobStore(self.root / "private")
        self.public = LocalBlobStore(self.root / "public")
        self.module = importlib.import_module("registry_distribution")
        self.registry_id = "1" * 32
        self.blob = b"Synthetic retained package bytes.\n"
        self.digest = hashlib.sha256(self.blob).hexdigest()
        fixture = self.root / "object"
        fixture.write_bytes(self.blob)
        self.source.put_blob(fixture, self.digest, len(self.blob))
        self.plan = self.bundle(1)

    def bundle(self, version):
        # Deliberately unsigned metadata exercises placement only. Separate
        # verifier and full-flow tests establish the cryptographic boundary.
        objects = {
            f"metadata/{version}.targets.json": b'{"synthetic":"targets"}\n',
            f"metadata/{version}.snapshot.json": b'{"synthetic":"snapshot"}\n',
            f"metadata/{version}.timestamp.json": registry.json_bytes(
                {"signed": {"_type": "timestamp", "version": version}}),
        }
        files = []
        for key, data in sorted(objects.items()):
            digest = hashlib.sha256(data).hexdigest()
            self.source.create_object("distribution/files/" + digest, data)
            files.append({"key": key, "bytes": len(data), "sha256": digest})
        return {"schema": 2, "registry_id": self.registry_id, "batch_id": f"{version:032x}",
            "version": str(version), "publication_revision": str(version), "policy_revision": "0",
            "files": files, "blobs": [{"sha256": self.digest, "bytes": len(self.blob)}]}

    def place(self, plan=None, authorize=None):
        return self.module.publish_plan(plan or self.plan, self.source, self.public,
            sealed=True, authorize=authorize, work_root=self.root)

    def test_checked_immutable_bytes_precede_both_heads(self):
        def authorize():
            self.assertEqual(self.public.get_blob(self.digest, len(self.blob)), self.blob)
            self.assertIsNone(self.public.read_object("metadata/timestamp.json", 16384))
        result = self.place(authorize=authorize)
        self.assertEqual(result["version"], "1")
        timestamp = self.public.read_object("metadata/timestamp.json", 16384)[0]
        self.assertEqual(registry.strict_json(timestamp)["signed"]["version"], 1)
        self.assertEqual(self.public.get_blob(self.digest, len(self.blob)), self.blob)

    def test_lost_authority_retains_bytes_without_exposing_a_head(self):
        def authorize():
            raise registry.RegistryError("lease lost")
        with self.assertRaises(registry.RegistryError):
            self.place(authorize=authorize)
        self.assertIsNone(self.public.read_object("distribution/head.json", 4096))
        self.assertIsNone(self.public.read_object("metadata/timestamp.json", 16384))
        self.assertEqual(self.public.get_blob(self.digest, len(self.blob)), self.blob)

    def test_unchanged_replay_performs_no_artifact_reads(self):
        first = self.place()
        with patch.object(self.source, "get_blob", side_effect=AssertionError("unneeded artifact read")), \
             patch.object(self.public, "get_blob", side_effect=AssertionError("unneeded artifact audit")):
            self.assertEqual(self.place(), first)

    def test_corrupt_source_preserves_the_previous_timestamp(self):
        self.place()
        before = self.public.read_object("metadata/timestamp.json", 16384)[0]
        newer = self.bundle(2)
        digest = newer["files"][0]["sha256"]
        (self.source.root / "distribution/files" / digest).write_bytes(b"changed")
        with self.assertRaises(registry.RegistryError):
            self.place(newer)
        self.assertEqual(self.public.read_object("metadata/timestamp.json", 16384)[0], before)

    def test_partial_timestamp_write_resumes_without_replacing_signed_bytes(self):
        original = self.public.compare_and_swap
        def fail_timestamp(key, *arguments):
            if key == "metadata/timestamp.json":
                raise registry.RegistryError("uncertain transfer")
            return original(key, *arguments)
        with patch.object(self.public, "compare_and_swap", side_effect=fail_timestamp):
            with self.assertRaises(registry.RegistryError):
                self.place()
        self.assertIsNotNone(self.public.read_object("distribution/head.json", 4096))
        self.assertIsNone(self.public.read_object("metadata/timestamp.json", 16384))
        self.place()
        self.assertEqual(registry.strict_json(self.public.read_object("metadata/timestamp.json", 16384)[0])
                         ["signed"]["version"], 1)

    def test_an_older_worker_cannot_replace_a_newer_head_or_policy(self):
        self.place()
        newer = self.bundle(3)
        newer["policy_revision"] = "2"
        self.place(newer)
        before = self.public.read_object("metadata/timestamp.json", 16384)[0]
        with self.assertRaises(StorageConflict):
            self.place(self.bundle(2))
        self.assertEqual(self.public.read_object("metadata/timestamp.json", 16384)[0], before)
        with self.assertRaises(StorageConflict):
            self.place(self.bundle(4))
        self.assertEqual(self.public.read_object("metadata/timestamp.json", 16384)[0], before)

    def test_independent_byte_mirror_needs_no_database_or_signer(self):
        self.place()
        mirror = LocalBlobStore(self.root / "mirror")
        result = self.module.sync(self.public, mirror, work_root=self.root)
        self.assertEqual(result["version"], "1")
        self.assertEqual(mirror.get_blob(self.digest, len(self.blob)), self.blob)
        self.assertEqual(mirror.read_object("metadata/timestamp.json", 16384)[0],
                         self.public.read_object("metadata/timestamp.json", 16384)[0])
        with patch.object(self.public, "get_blob", side_effect=AssertionError("unchanged sync read")):
            self.module.sync(self.public, mirror, work_root=self.root)

    def test_reversed_worker_completion_cannot_replace_a_newer_timestamp(self):
        self.place()
        older, newer = self.bundle(2), self.bundle(3)
        calls = 0
        def authorize():
            nonlocal calls
            calls += 1
            if calls == 2:
                self.place(newer)
        with self.assertRaises(StorageConflict):
            self.place(older, authorize=authorize)
        self.assertEqual(registry.strict_json(self.public.read_object("metadata/timestamp.json", 16384)[0])
                         ["signed"]["version"], 3)
        self.assertEqual(self.module.load_current(self.public)[0]["version"], "3")

    def test_unsafe_or_ambiguous_inventory_never_creates_a_head(self):
        variants = []
        for key, value in (("schema", True), ("version", "01"), ("registry_id", "../escape")):
            bad = copy.deepcopy(self.plan); bad[key] = value; variants.append(bad)
        bad = copy.deepcopy(self.plan); bad["files"][0]["key"] = "../escape"; variants.append(bad)
        bad = copy.deepcopy(self.plan); bad["files"].append(bad["files"][0]); variants.append(bad)
        bad = copy.deepcopy(self.plan); bad["blobs"][0]["bytes"] = 67108865; variants.append(bad)
        for plan in variants:
            with self.subTest(plan=plan), self.assertRaises(registry.RegistryError):
                self.place(plan)
            self.assertIsNone(self.public.read_object("distribution/head.json", 4096))

    def test_timestamp_renewal_reuses_existing_targets_snapshot_and_artifacts(self):
        self.place()
        newer = self.bundle(2)
        newer["publication_revision"] = "1"
        newer["files"] = sorted([item for item in self.plan["files"] if not item["key"].endswith(".timestamp.json")] +
            [item for item in newer["files"] if item["key"].endswith(".timestamp.json")], key=lambda item: item["key"])
        with patch.object(self.source, "get_blob", side_effect=AssertionError("renewal read an unchanged artifact")):
            self.place(newer)
        current = self.module.load_current(self.public)
        self.assertEqual(current[0]["version"], "2")
        self.assertEqual([item["key"] for item in current[1]["files"]],
            ["metadata/1.snapshot.json", "metadata/1.targets.json", "metadata/2.timestamp.json"])

    def test_routine_renewals_retain_one_inventory_and_small_plans(self):
        self.place()
        for version in (2, 3, 4):
            newer = self.bundle(version)
            newer["publication_revision"] = "1"
            newer["files"] = sorted([item for item in self.plan["files"] if not item["key"].endswith(".timestamp.json")] +
                [item for item in newer["files"] if item["key"].endswith(".timestamp.json")], key=lambda item: item["key"])
            self.place(newer)
        inventories = list((self.public.root / "distribution/inventories").glob("*.json"))
        self.assertEqual(len(inventories), 1)
        plans = list((self.public.root / "distribution/plans").glob("*.json"))
        self.assertEqual(len(plans), 4)
        pointers = []
        for filename in plans:
            self.assertLess(filename.stat().st_size, 2048)
            value = registry.strict_json(filename.read_bytes())
            self.assertNotIn("files", value)
            self.assertNotIn("blobs", value)
            pointers.append(value["inventory_sha256"])
        self.assertEqual(len(set(pointers)), 1)

    def test_mirror_command_reports_its_retained_state_and_audits_corruption(self):
        self.place()
        mirror = self.root / "command-mirror"
        command = [sys.executable, str(ROOT / "tools/registry_distribution.py")]
        result = subprocess.run(command + ["sync", "--source-store", "local", "--source-root", str(self.public.root),
            "--store", "local", "--root", str(mirror), "--work-root", str(self.root)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(registry.strict_json(result.stdout)["version"], "1")
        audit = command + ["verify", "--store", "local", "--root", str(mirror)]
        result = subprocess.run(audit, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(registry.strict_json(result.stdout)["blobs_checked"], 1)
        object_path = mirror / "blobs/sha256" / self.digest
        object_path.write_bytes(b"x" * len(self.blob))
        result = subprocess.run(audit, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(object_path.read_bytes(), b"x" * len(self.blob))

    def test_overlapping_store_configuration_is_refused_before_claiming_work(self):
        from registry_storage import S3BlobStore
        class UnusedDatabase:
            def execute(self, *_):
                raise AssertionError("unsafe store configuration reached the database")
        parent = LocalBlobStore(self.root / "overlap")
        child = LocalBlobStore(parent.root / "retained")
        client = SimpleNamespace(meta=SimpleNamespace(endpoint_url="https://s3.example"))
        pairs = [(parent, child), (child, parent), (parent, parent)]
        for first, second in (("", "retained"), ("public", "public/retained"), ("a", "a")):
            source = S3BlobStore("asm-test", prefix=first, client=client)
            destination = S3BlobStore("asm-test", prefix=second, client=client)
            pairs.extend([(source, destination), (destination, source)])
        for source, destination in pairs:
            with self.subTest(source=source, destination=destination), self.assertRaises(registry.RegistryError):
                self.module.run_one(UnusedDatabase(), source, destination, "2" * 32, Path("unused"), Path("unused"), Path("unused"), self.root)
        # Similar spelling is not ancestry, and separate buckets are separate
        # configured namespaces. Their actual access policy needs qualification.
        for source, destination in ((LocalBlobStore(self.root / "a"), LocalBlobStore(self.root / "ab")),
            (S3BlobStore("asm-test", prefix="a", client=client), S3BlobStore("asm-test", prefix="ab", client=client)),
            (S3BlobStore("asm-one", client=client), S3BlobStore("asm-two", client=client))):
            self.module._separate_stores(source, destination)


class SignedDistributionTests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(Path(__file__).parent))
        import test_checker
        self.fixture = test_checker.PublicationCheckerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.trust = Path(os.environ.get("ASM_REGISTRY_TRUST", ROOT / "build/asm-trust"))
        if not self.trust.is_file():
            self.skipTest("Build asm-trust before the signed operator gate.")
        self.openssl = os.environ.get("ASM_REGISTRY_OPENSSL") or shutil.which("openssl")
        self.module = importlib.import_module("registry_distribution")
        self.private = LocalBlobStore(self.root / "retained")
        self.public = LocalBlobStore(self.root / "public")
        self.private.put_blob(self.fixture.object_file, self.fixture.digest, len(self.fixture.data))
        self.keys = self.root / "keys"
        self.keys.mkdir(mode=0o700)
        for role in ("root1", "root2", "root3", "targets", "snapshot", "timestamp"):
            self.run_tool(self.openssl, "genpkey", "-algorithm", "ED25519", "-out", self.keys / (role + ".pem"))
            (self.keys / (role + ".pem")).chmod(0o600)
            self.run_tool(self.openssl, "pkey", "-in", self.keys / (role + ".pem"), "-pubout", "-out", self.keys / (role + ".pub"))
        self.run_tool(self.trust, "prepare-root", self.root / "unsigned.json", *[
            self.keys / (role + ".pub") for role in ("root1", "root2", "root3", "targets", "snapshot", "timestamp")])
        self.run_tool(self.trust, "sign-root", self.root / "unsigned.json", self.keys / "root1.pem", self.root / "first.json")
        self.anchor = self.root / "root.json"
        self.run_tool(self.trust, "sign-root", self.root / "first.json", self.keys / "root2.pem", self.anchor)
        self.id = "7" * 32
        self.package = "8" * 32
        envelope = {"schema": 2, "registry_id": self.id, "package_id": self.package,
            "release_id": self.fixture.task, "manifest_sha256": hashlib.sha256(self.fixture.manifest_file.read_bytes()).hexdigest(),
            "publication": self.fixture.manifest}
        self.envelope = registry.json_bytes(envelope)
        self.source = {"schema": 2, "batch_id": "9" * 32, "registry_id": self.id,
            "origin": "https://distribution.invalid", "version": "1", "publication_revision": "1", "policy_revision": "0",
            "policy_tsv": f"# asm-registry-policy-v2\t{self.id}\t1\t0\nexample/hello\t1.0.0\t{self.package}\t{self.fixture.task}\t0\t0\n",
            "releases": [{"name": "example/hello", "version": "1.0.0", "package_id": self.package,
                "release_id": self.fixture.task, "target": f"registries/{self.id}/releases/example/hello/1.0.0.json",
                "sha256": hashlib.sha256(self.envelope).hexdigest(), "bytes": len(self.envelope)}]}
        self.lease = {"schema": 2, "batch_id": self.source["batch_id"], "fence": 1,
            "source_sha256": hashlib.sha256(registry.json_bytes(self.source)).hexdigest(), "source": self.source, "sealed": None}
        self.fail_finish = False
        self.abandoned = []
        outer = self
        class Connection:
            def execute(self, sql):
                if "distribution_ready(" in sql:
                    return "1\n"
                if "distribution_release(" in sql:
                    # Unaligned psql adds one record LF to this text scalar.
                    return outer.envelope.decode("ascii") + "\n"
                if "abandon_distribution(" in sql:
                    old = copy.deepcopy(outer.lease)
                    outer.abandoned.append(old)
                    outer.source = copy.deepcopy(outer.source)
                    outer.source.update(batch_id="4" * 32, version=str(int(old["source"]["version"]) + 1))
                    outer.lease = {"schema": 2, "batch_id": outer.source["batch_id"], "fence": old["fence"] + 1,
                        "source_sha256": hashlib.sha256(registry.json_bytes(outer.source)).hexdigest(),
                        "source": outer.source, "sealed": None}
                    return registry.json_bytes({"schema": 2, "batch_id": old["batch_id"], "state": "abandoned",
                        "version": old["source"]["version"]}).decode("ascii")
                if "seal_distribution(" in sql:
                    # Decode the last protected SQL text parameter. Production
                    # PostgreSQL validates the same statement in its own suite.
                    encoded = re.findall(r"decode\('([0-9a-f]+)'", sql)[-1]
                    outer.lease["sealed"] = registry.strict_json(bytes.fromhex(encoded))
                elif "finish_distribution(" in sql:
                    if outer.fail_finish:
                        outer.fail_finish = False
                        raise registry_admin.AdminError("unknown final acknowledgment")
                    return '{"schema":2,"state":"published"}\n'
                elif not any(name in sql for name in ("claim_distribution(", "authorize_distribution_head(", "renew_distribution(")):
                    raise AssertionError("unexpected distribution SQL")
                return registry.json_bytes(outer.lease).decode("ascii")
        self.connection = Connection()

    def run_tool(self, *arguments):
        result = subprocess.run([str(value) for value in arguments], capture_output=True, timeout=15,
            env={"PATH": os.defpath, "HOME": "/nonexistent", "LC_ALL": "C", "OPENSSL_CONF": os.devnull})
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))

    def run_one(self, *, refresh=False):
        return self.module.run_one(self.connection, self.private, self.public, "3" * 32,
            self.anchor, self.keys, self.trust, self.root, refresh=refresh)

    def test_real_signed_bundle_and_exact_release_are_retained_before_publication(self):
        self.assertEqual(self.run_one()["state"], "published")
        current = self.module.load_current(self.public)
        self.assertEqual(current[0]["version"], "1")
        key = next(item for item in current[1]["files"] if item["key"].endswith("1.0.0.json"))
        self.assertEqual(self.public.read_object(key["key"], key["bytes"])[0], self.envelope)
        self.assertEqual(self.public.get_blob(self.fixture.digest, len(self.fixture.data)), self.fixture.data)

    def test_uncertain_finalization_reuses_sealed_bytes_without_signing_again(self):
        self.fail_finish = True
        with self.assertRaises(registry_admin.AdminError):
            self.run_one()
        timestamp = self.public.read_object("metadata/timestamp.json", 16384)[0]
        descriptor = copy.deepcopy(self.lease["sealed"])
        self.assertIsNotNone(descriptor)
        with patch.object(self.module, "prepare_bundle", side_effect=AssertionError("must not sign a sealed version again")):
            self.assertEqual(self.run_one()["state"], "published")
        self.assertEqual(self.lease["sealed"], descriptor)
        self.assertEqual(self.public.read_object("metadata/timestamp.json", 16384)[0], timestamp)

    def test_payload_transfer_completes_before_the_checkpoint_is_signed(self):
        original = registry_admin.run_bounded
        def run(arguments, **keywords):
            if len(arguments) > 1 and arguments[1] == "publish-registry":
                self.assertEqual(self.public.get_blob(self.fixture.digest, len(self.fixture.data)), self.fixture.data)
                release = self.source["releases"][0]
                target = release["target"]
                directory, basename = target.rsplit("/", 1)
                key = "targets/" + directory + "/" + release["sha256"] + "." + basename
                self.assertEqual(self.public.read_object(key, release["bytes"])[0], self.envelope)
                self.assertIsNone(self.public.read_object("metadata/timestamp.json", 16384))
            return original(arguments, **keywords)
        with patch.object(registry_admin, "run_bounded", side_effect=run):
            self.run_one()

    def test_unready_distributor_changes_no_public_state(self):
        original = self.connection.execute
        def execute(sql):
            return "0\n" if "distribution_ready(" in sql else original(sql)
        with patch.object(self.connection, "execute", side_effect=execute), self.assertRaises(registry.RegistryError):
            self.run_one()
        self.assertIsNone(self.public.read_object("distribution/head.json", 4096))

    def test_timestamp_only_renewal_does_not_need_targets_or_snapshot_private_keys(self):
        self.run_one()
        old = self.module.load_current(self.public)[1]
        for role in ("targets", "snapshot"):
            (self.keys / (role + ".pem")).rename(self.keys / (role + ".offline"))
        self.source = copy.deepcopy(self.source)
        self.source.update(batch_id="5" * 32, version="2")
        self.lease = {"schema": 2, "batch_id": self.source["batch_id"], "fence": 2,
            "source_sha256": hashlib.sha256(registry.json_bytes(self.source)).hexdigest(), "source": self.source, "sealed": None}
        self.run_one(refresh=True)
        latest = self.module.load_current(self.public)[1]
        self.assertEqual([item for item in old["files"] if not item["key"].endswith(".timestamp.json")],
                         [item for item in latest["files"] if not item["key"].endswith(".timestamp.json")])
        self.assertEqual(len(list((self.public.root / "distribution/inventories").glob("*.json"))), 1)

    def test_expired_seal_is_retained_and_recovery_reserves_a_new_version(self):
        from datetime import datetime, timedelta, timezone
        self.fail_finish = True
        with self.assertRaises(registry_admin.AdminError):
            self.run_one()
        old_descriptor = copy.deepcopy(self.lease["sealed"])
        real_now = datetime.now(timezone.utc)
        def now():
            return real_now if self.abandoned else real_now + timedelta(minutes=6)
        with patch.object(self.module, "_now", side_effect=now):
            self.run_one()
        self.assertEqual(len(self.abandoned), 1)
        self.assertEqual(self.abandoned[0]["sealed"], old_descriptor)
        self.assertEqual(self.module.load_current(self.public)[0]["version"], "2")
        self.assertIsNotNone(self.public.read_object("metadata/1.timestamp.json", 16384))


if __name__ == "__main__":
    unittest.main()
