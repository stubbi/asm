"""Private operator coordination tests; HTTP application logic stays assembly.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import importlib
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry
import publication_check
import test_checker as checker_fixtures


class PublicationWorkerTests(unittest.TestCase):
    def setUp(self):
        self.fixture = checker_fixtures.PublicationCheckerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.module = importlib.import_module("publication_worker")
        self.worker = "3" * 32
        self.lease = {"task_id": self.fixture.task, "fence": 1,
            "manifest": self.fixture.manifest_file.read_text(),
            "manifest_sha256": hashlib.sha256(self.fixture.manifest_file.read_bytes()).hexdigest(),
            "objects": [{"sha256": self.fixture.digest, "bytes": len(self.fixture.data)}]}
        self.commands = []
        self.retained = []

    def connection(self):
        outer = self
        class Connection:
            def execute(self, sql):
                outer.commands.append(sql)
                if "claim_check(" in sql:
                    return registry.json_bytes(outer.lease).decode() + "\n"
                if "complete_check(" in sql:
                    return registry.json_bytes({"schema": 2, "id": outer.fixture.task, "state": "committed"}).decode() + "\n"
                raise AssertionError("unexpected SQL")
        return Connection()

    def store(self):
        outer = self
        class Store:
            def put_blob(self, path, digest, size):
                outer.retained.append((digest, size, Path(path).read_bytes()))
            def create_object(self, key, data):
                outer.retained.append((key, data))
        return Store()

    def checker(self, task, manifest, objects):
        self.assertFalse(any("complete_check(" in sql for sql in self.commands))
        return publication_check.check(task, manifest, objects, self.fixture.revision)

    def run_one(self, checker=None, store=None):
        return self.module.run_one(self.connection(), store or self.store(), self.fixture.objects,
            self.worker, checker or self.checker)

    def test_retained_objects_and_manifest_precede_the_immutable_intent(self):
        result = self.run_one()
        self.assertEqual(result["state"], "committed")
        self.assertEqual(self.retained[0], (self.fixture.digest, len(self.fixture.data), self.fixture.data))
        self.assertEqual(self.retained[1], ("publications/v2/intents/" + self.lease["manifest_sha256"] + ".json",
                                           self.fixture.manifest_file.read_bytes()))
        self.assertIn("complete_check(", self.commands[-1])
        self.assertEqual(self.fixture.object_file.read_bytes(), self.fixture.data)

    def test_no_pending_work_is_quiet_and_touches_no_files(self):
        self.lease = None
        self.assertIsNone(self.run_one())
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.retained, [])

    def test_checker_receives_only_private_copies_of_the_leased_task(self):
        unrelated = self.fixture.objects / ("9" * 32 + "-" + "f" * 64)
        unrelated.write_bytes(b"Private bytes from another owner's unfinished task.")
        unrelated.chmod(0o600)
        def checker(task, manifest, objects):
            self.assertNotEqual(objects, self.fixture.objects)
            self.assertEqual([path.name for path in objects.iterdir()], [self.fixture.object_file.name])
            self.assertEqual(objects.stat().st_mode & 0o777, 0o700)
            self.assertEqual((objects / self.fixture.object_file.name).stat().st_nlink, 1)
            return self.checker(task, manifest, objects)
        self.run_one(checker=checker)
        self.assertEqual(unrelated.read_bytes(), b"Private bytes from another owner's unfinished task.")

    def test_store_failure_never_commits_and_preserves_staged_bytes(self):
        store = self.store()
        with patch.object(store, "put_blob", side_effect=registry.RegistryError("storage failure")):
            with self.assertRaises(registry.RegistryError):
                self.run_one(store=store)
        self.assertFalse(any("complete_check(" in sql for sql in self.commands))
        self.assertEqual(self.fixture.object_file.read_bytes(), self.fixture.data)

    def test_failed_or_unavailable_check_records_no_retained_release(self):
        for outcome in ("fail", "error"):
            self.commands.clear()
            def checker(*args):
                receipt = self.checker(*args)
                receipt["outcome"] = receipt["objects"][0]["outcome"] = outcome
                return receipt
            self.run_one(checker=checker)
            self.assertEqual(self.retained, [])
            self.assertIn("complete_check(", self.commands[-1])

    def test_substituted_lease_or_receipt_never_reaches_storage_or_commit(self):
        self.lease["manifest_sha256"] = "0" * 64
        with self.assertRaises(registry.RegistryError):
            self.run_one()
        self.assertEqual(self.retained, [])
        self.assertEqual(len(self.commands), 1)

    def test_isolated_checker_uses_fixed_readonly_mounts_and_no_network_or_credentials(self):
        image = "asm-checker@sha256:" + "a" * 64
        view = self.fixture.manifest_file.parent / "objects"
        args = self.module.container_arguments("/usr/bin/docker", "/private/docker.sock", image,
            "asm-check-" + "b" * 32, Path("/private/empty-config"),
            self.fixture.task, self.fixture.manifest_file, view, self.fixture.revision)
        self.assertIn("--network=none", args)
        self.assertIn("--read-only", args)
        self.assertIn("--cap-drop=ALL", args)
        self.assertIn("--security-opt=no-new-privileges", args)
        self.assertIn("--pull=never", args)
        mounts = [args[i + 1] for i, value in enumerate(args[:-1]) if value == "--mount"]
        self.assertEqual(len(mounts), 4)
        self.assertTrue(all(value.endswith(",readonly") for value in mounts))
        self.assertFalse(any("credentials" in value or "docker.sock" in value for value in mounts))
        self.assertEqual(args[-2:], ["--checker-revision", self.fixture.revision])
        offline = self.module.container_arguments("/usr/bin/docker", "/private/docker.sock", "sha256:" + "a" * 64,
            "asm-check-" + "b" * 32, Path("/private/empty-config"), self.fixture.task,
            self.fixture.manifest_file, view, self.fixture.revision)
        self.assertIn("sha256:" + "a" * 64, offline)
        with self.assertRaises(registry.RegistryError):
            self.module.container_arguments("/usr/bin/docker", "/private/docker.sock", "asm-checker:latest",
                "asm-check-" + "b" * 32, Path("/private/empty-config"), self.fixture.task,
                self.fixture.manifest_file, view, self.fixture.revision)

    def test_image_declared_writable_volumes_are_refused_before_a_job_runs(self):
        checker = self.module.isolated_checker("/usr/bin/docker", "/private/docker.sock",
            "sha256:" + "a" * 64, self.fixture.revision)
        with patch.object(self.module.registry_admin, "run_bounded", return_value=b'{"/unbounded":{}}\n') as run:
            with self.assertRaises(registry.RegistryError):
                checker(self.fixture.task, self.fixture.manifest_file, self.fixture.root / "objects")
        self.assertFalse(any("run" in call.args[0][5:6] for call in run.call_args_list))


if __name__ == "__main__":
    unittest.main()
