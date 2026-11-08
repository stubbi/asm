"""Offline source packaging behavior; all repositories are owned fixtures.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/operator_source.py"
sys.path.insert(0, str(ROOT / "tools"))
import operator_source
FILES = ("LICENSE", "README.md", "tools/registry.py", "tools/registry_admin.py", "tools/operator_entrypoint.py",
         "tools/prepare_operator.py", "tools/registry_mirror.py", "tools/registry_storage.py",
         "tools/image_source.py", "tools/prepare_signers.py", "tools/publisher_admin.py",
         "tools/publication_worker.py", "tools/kubernetes_checker.py", "tools/publication_check.py",
         "tools/checker_entrypoint.py", "tools/registry_distribution.py", "tools/verifier_notices.py",
         "requirements-storage.txt", "verifier/go.mod", "verifier/go.sum",
         "server/catalog/schema.sql", "server/catalog/reader-guard.sql",
         "server/catalog/read-exports.sql", "server/publisher/schema.sql", "server/publisher/distribution.sql")


class SourceBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-operator-source-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "source"
        self.repo.mkdir()
        self.git("init", "-q")
        for name in FILES:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("Fixture bytes for " + name + "\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Create source fixture")
        self.parent = self.git("rev-parse", "HEAD").decode().strip()
        (self.repo / "LICENSE").write_text("A second committed fixture\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Extend source fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.output = self.base / "bundle"

    def git(self, *args, repository=None):
        return subprocess.run(["git", "-C", str(repository or self.repo), "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false", "-c", "user.name=Operator fixture", "-c",
            "user.email=fixture@example.invalid", *args], capture_output=True, check=True, timeout=10).stdout

    def command(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True,
            timeout=25, env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})

    def create(self, revision=None):
        return self.command("create", "--repository", self.repo, "--revision", revision or self.commit,
                            "--output", self.output)

    def restore(self, destination, revision=None):
        return self.command("restore", "--bundle", self.output / "source.bundle", "--manifest",
            self.output / "source.json", "--revision", revision or self.commit, "--destination", destination)

    def test_complete_bundle_keeps_ancestors_exact_bytes_and_only_one_accepted_ref(self):
        unrelated = self.git("commit-tree", self.git("rev-parse", "HEAD^{tree}").decode().strip(),
                             "-m", "An unrelated orphan fixture").decode().strip()
        self.git("update-ref", "refs/heads/unrelated", unrelated)
        created = self.create()
        self.assertEqual(created.returncode, 0, created.stderr.decode())
        manifest = json.loads((self.output / "source.json").read_bytes())
        self.assertEqual(manifest["source_revision"], self.commit)
        self.assertEqual(manifest["bundle_sha256"], hashlib.sha256((self.output / "source.bundle").read_bytes()).hexdigest())
        self.assertEqual(set(manifest["files"]), set(FILES))
        for name in ("tools/registry_mirror.py", "tools/registry_storage.py", "tools/publication_check.py",
                     "tools/registry_distribution.py", "server/publisher/schema.sql", "verifier/go.sum"):
            self.assertEqual(manifest["files"][name], hashlib.sha256((self.repo / name).read_bytes()).hexdigest())
        destination = self.base / "accepted.git"
        restored = self.restore(destination)
        self.assertEqual(restored.returncode, 0, restored.stderr.decode())
        refs = self.git("for-each-ref", "--format=%(refname) %(objectname)", repository=destination).decode()
        self.assertEqual(refs, "refs/heads/accepted " + self.commit + "\n")
        self.assertEqual(self.git("rev-list", "--count", "refs/heads/accepted", repository=destination), b"2\n")
        self.assertEqual(self.git("show", self.commit + ":LICENSE", repository=destination), b"A second committed fixture\n")
        missing = subprocess.run(["git", "-C", str(destination), "cat-file", "-e", unrelated], capture_output=True, timeout=10)
        self.assertNotEqual(missing.returncode, 0)
        self.assertFalse((destination / "objects/info/alternates").exists())
        self.assertEqual(self.git("remote", repository=destination), b"")

    def test_missing_distribution_source_refuses_packaging(self):
        complete = self.commit
        for name in ("tools/registry_mirror.py", "tools/registry_storage.py", "tools/publication_check.py",
                     "tools/registry_distribution.py", "server/publisher/schema.sql", "verifier/go.sum"):
            with self.subTest(name=name):
                self.git("checkout", "-q", complete)
                self.output = self.base / (Path(name).stem + "-bundle")
                self.git("rm", name)
                self.git("commit", "-qm", "Remove required distribution source fixture")
                self.commit = self.git("rev-parse", "HEAD").decode().strip()
                refused = self.create()
                self.assertNotEqual(refused.returncode, 0)
                self.assertEqual(refused.stdout, b"")
                self.assertFalse(self.output.exists())

    def test_dirty_checkout_wrong_head_and_existing_output_are_refused(self):
        (self.repo / "LICENSE").write_text("Uncommitted bytes\n")
        self.assertNotEqual(self.create().returncode, 0)
        self.assertFalse(self.output.exists())
        self.git("checkout", "--", "LICENSE")
        self.assertNotEqual(self.create(self.parent).returncode, 0)
        self.output.mkdir()
        marker = self.output / "keep"
        marker.write_bytes(b"preserve")
        self.assertNotEqual(self.create().returncode, 0)
        self.assertEqual(marker.read_bytes(), b"preserve")

    def test_corrupt_bundle_wrong_revision_and_existing_destination_preserve_files(self):
        created = self.create()
        self.assertEqual(created.returncode, 0, created.stderr.decode())
        destination = self.base / "accepted.git"
        wrong = self.restore(destination, "1" * 40)
        self.assertNotEqual(wrong.returncode, 0)
        self.assertEqual(wrong.stdout, b"")
        self.assertFalse(destination.exists())
        bundle = self.output / "source.bundle"
        saved = bundle.read_bytes()
        bundle.write_bytes(saved[:-1] + bytes([saved[-1] ^ 1]))
        self.assertNotEqual(self.restore(destination).returncode, 0)
        self.assertFalse(destination.exists())
        bundle.write_bytes(saved)
        destination.mkdir()
        marker = destination / "keep"
        marker.write_bytes(b"preserve")
        self.assertNotEqual(self.restore(destination).returncode, 0)
        self.assertEqual(marker.read_bytes(), b"preserve")

    def test_replacing_the_verified_input_path_cannot_change_consumed_bytes_or_objects(self):
        self.assertEqual(self.create().returncode, 0)
        manifest = json.loads((self.output / "source.json").read_bytes())
        orphan = self.git("commit-tree", self.git("rev-parse", "HEAD^{tree}").decode().strip(),
                          "-m", "Unrelated replacement object").decode().strip()
        self.git("update-ref", "refs/heads/unrelated", orphan)
        replacement = self.git("bundle", "create", "--version=2", "-", "--all")
        bundle = self.output / "source.bundle"
        original_git = operator_source.git
        swapped = False
        consumed = []
        def swapping(repository, *arguments, **kwargs):
            nonlocal swapped
            if not swapped:
                swapped = True
                other = self.output / "replacement"
                other.write_bytes(replacement)
                other.chmod(0o600)
                other.replace(bundle)
            if arguments[:2] == ("bundle", "verify"):
                consumed.append(hashlib.sha256(Path(arguments[2]).read_bytes()).hexdigest())
            return original_git(repository, *arguments, **kwargs)
        destination = self.base / "accepted.git"
        with patch.object(operator_source, "git", side_effect=swapping):
            operator_source.restore(bundle, self.output / "source.json", self.commit, destination)
        with self.subTest(outcome="consumed verified bytes"):
            self.assertEqual(consumed, [manifest["bundle_sha256"]])
        found = subprocess.run(["git", "-C", str(destination), "cat-file", "-e", orphan], capture_output=True, timeout=10)
        with self.subTest(outcome="unrelated object excluded"):
            self.assertNotEqual(found.returncode, 0)

    def test_matching_manifest_and_head_header_cannot_hide_unrelated_packed_objects(self):
        self.assertEqual(self.create().returncode, 0)
        manifest_path = self.output / "source.json"
        manifest = json.loads(manifest_path.read_bytes())
        orphan = self.git("commit-tree", self.git("rev-parse", "HEAD^{tree}").decode().strip(),
                          "-m", "Hidden unrelated packed object").decode().strip()
        self.git("update-ref", "refs/heads/unrelated", orphan)
        all_objects = self.git("bundle", "create", "--version=2", "-", "--all")
        _, pack = all_objects.split(b"\n\n", 1)
        hidden = b"# v2 git bundle\n" + self.commit.encode() + b" HEAD\n\n" + pack
        (self.output / "source.bundle").write_bytes(hidden)
        manifest["bundle_sha256"] = hashlib.sha256(hidden).hexdigest()
        manifest["bundle_bytes"] = len(hidden)
        manifest_path.write_text(json.dumps(manifest))
        destination = self.base / "accepted.git"
        refused = self.restore(destination)
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(refused.stdout, b"")
        self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
