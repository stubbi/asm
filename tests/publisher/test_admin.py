"""Private publisher enrollment file and credential boundaries.

SPDX-License-Identifier: AGPL-3.0-or-later
Database authority behavior is exercised separately against PostgreSQL.
"""
from contextlib import redirect_stderr
import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import publisher_admin as publisher


class PublisherAdminTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-publisher-admin-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def test_token_is_complete_private_and_never_replaces_a_destination(self):
        path = self.base / "token"
        token = publisher.token_file(path)
        self.assertRegex(token, r"^asm_pub_v1_[0-9a-f]{64}$")
        self.assertEqual(path.read_text(), token + "\n")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.stat().st_nlink, 1)
        self.assertEqual(publisher.token_file(path, reuse=True), token)
        with self.assertRaises(publisher.registry.RegistryError):
            publisher.token_file(path)
        self.assertEqual(path.read_text(), token + "\n")
        self.assertEqual(list(self.base.glob(".asm-publisher-*")), [])

    def test_links_unprotected_parents_and_invalid_saved_tokens_fail(self):
        target = self.base / "target"
        target.write_text("keep\n"); target.chmod(0o600)
        link = self.base / "link"; link.symlink_to(target)
        with self.assertRaises(publisher.registry.RegistryError):
            publisher.token_file(link)
        with self.assertRaises(publisher.registry.RegistryError):
            publisher.token_file(link, reuse=True)
        with self.assertRaises(publisher.admin.AdminError):
            publisher.token_file(target, reuse=True)
        self.assertEqual(target.read_text(), "keep\n")
        unprotected = self.base / "unprotected"; unprotected.mkdir(mode=0o755)
        with self.assertRaises(publisher.registry.RegistryError):
            publisher.token_file(unprotected / "token")

    def test_interrupted_private_write_has_no_partial_final_file(self):
        path = self.base / "token"
        with patch.object(publisher.os, "write", side_effect=OSError("synthetic write failure")):
            with self.assertRaises(publisher.registry.RegistryError):
                publisher.token_file(path)
        self.assertFalse(path.exists())
        self.assertEqual(list(self.base.iterdir()), [])

    def command(self, *extra, failure=False):
        statements = []
        class Connection:
            def __init__(self, *_): pass
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def execute(self, statement):
                statements.append(statement)
                if failure: raise publisher.admin.AdminError("synthetic unavailable authority")
                return ""
        output, errors = io.BytesIO(), io.StringIO()
        args = ["--connection-file", str(self.base / "operator.url"), "--psql", "/fixed/psql", *extra]
        with patch.object(publisher.admin, "Connection", Connection), patch.object(sys, "stdout", SimpleNamespace(buffer=output)), redirect_stderr(errors):
            status = publisher.main(args)
        return status, output.getvalue(), errors.getvalue(), statements

    def issue_args(self, path):
        return ("issue", "--owner-id", "a" * 32, "--credential-id", "b" * 32, "--package", "fixture/hello",
                "--operation", "task-read", "--reference", "private-enrollment", "--token-file", str(path))

    def test_issuance_sends_only_hash_and_saves_replay_material_on_unknown_result(self):
        path = self.base / "token"
        status, output, errors, statements = self.command(*self.issue_args(path), failure=True)
        self.assertEqual(status, 1)
        self.assertEqual(output, b"")
        token = path.read_text().strip()
        self.assertNotIn(token, errors)
        self.assertNotIn(token, statements[0])
        self.assertNotIn(token.encode().hex(), statements[0])
        self.assertIn(hashlib.sha256(token.encode()).hexdigest().encode().hex(), statements[0])
        self.assertIn("task-read".encode().hex(), statements[0])
        status, output, errors, statements = self.command(*self.issue_args(path), "--reuse-token-file")
        self.assertEqual(status, 0)
        self.assertNotIn(token.encode(), output)
        self.assertEqual(errors, "")
        self.assertIn(hashlib.sha256(token.encode()).hexdigest().encode().hex(), statements[0])
        self.assertEqual(path.read_text().strip(), token)

    def test_invalid_scope_or_lifetime_creates_no_file_or_database_call(self):
        path = self.base / "token"
        status, output, _, statements = self.command(*self.issue_args(path), "--ttl-seconds", "86401")
        self.assertEqual(status, 1)
        self.assertEqual(output, b"")
        self.assertEqual(statements, [])
        self.assertFalse(path.exists())

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL interface")
    def test_inherited_parent_acl_refuses_issuance_without_files_or_database_effects(self):
        parent = self.base.resolve() / "inherited"
        parent.mkdir(mode=0o700)
        sentinel = parent / "existing"
        sentinel.write_bytes(b"preserve existing bytes\n"); sentinel.chmod(0o600)
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,execute,file_inherit,directory_inherit", str(parent)],
                       check=True, capture_output=True, timeout=5)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-N", str(parent)], check=True, capture_output=True, timeout=5)
        self.assertEqual(parent.stat().st_mode & 0o777, 0o700)
        path = parent / "publisher.token"
        status, output, _, statements = self.command(*self.issue_args(path))
        self.assertEqual(status, 1)
        self.assertEqual(output, b"")
        self.assertEqual(statements, [])
        self.assertFalse(path.exists())
        self.assertEqual(list(parent.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"preserve existing bytes\n")
        descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            with self.assertRaises(publisher.admin.AdminError):
                publisher.admin.reject_extended_acl(descriptor)
        finally:
            os.close(descriptor)

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL interface")
    def test_staged_descriptor_acl_is_refused_before_secret_bytes_are_written(self):
        path = self.base.resolve() / "publisher.token"
        real_open = publisher.os.open
        inspected = []
        def open_with_acl(name, flags, *args, **kwargs):
            descriptor = real_open(name, flags, *args, **kwargs)
            if isinstance(name, str) and name.startswith(".asm-publisher-token-") and flags & os.O_CREAT:
                inspected.append(os.dup(descriptor))
                subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(self.base.resolve() / name)],
                               check=True, capture_output=True, timeout=5)
            return descriptor
        try:
            with patch.object(publisher.os, "open", open_with_acl):
                with self.assertRaises(publisher.admin.AdminError):
                    publisher.token_file(path)
            self.assertEqual(len(inspected), 1)
            self.assertEqual(os.fstat(inspected[0]).st_size, 0)
            self.assertFalse(path.exists())
            self.assertEqual(list(self.base.iterdir()), [])
        finally:
            for descriptor in inspected:
                os.close(descriptor)

    def test_migration_file_matches_reviewed_digest(self):
        self.assertEqual(hashlib.sha384((ROOT / "server/publisher/schema.sql").read_bytes()).hexdigest(), publisher.MIGRATION_SHA384)

    def test_distribution_migration_is_separately_pinned_and_replay_checked(self):
        status, output, errors, statements = self.command("migrate-distribution")
        self.assertEqual(status, 0)
        self.assertEqual(errors, "")
        self.assertIn(b'"schema": 2', output)
        self.assertEqual(hashlib.sha384((ROOT / "server/publisher/distribution.sql").read_bytes()).hexdigest(),
                         publisher.DISTRIBUTION_MIGRATION_SHA384)
        self.assertIn("distribution_schema_version", statements[0])
        self.assertIn(publisher.DISTRIBUTION_MIGRATION_SHA384, statements[0])
        self.assertIn(publisher.MIGRATION_SHA384, statements[0])

    def test_distribution_identity_and_lifecycle_use_only_fixed_operator_calls(self):
        status, _, errors, statements = self.command("configure-distribution", "--registry-id", "d" * 32,
            "--origin", "https://registry.example/asm", "--reference", "owned-registry")
        self.assertEqual((status, errors), (0, ""))
        self.assertTrue(statements[0].startswith("SELECT asm_publication.configure_distribution("))
        status, _, errors, statements = self.command("lifecycle", "--release-id", "e" * 32,
            "--action", "revoke", "--operation-id", "f" * 32, "--expected-policy-revision", "17", "--reference", "owned-revocation")
        self.assertEqual((status, errors), (0, ""))
        self.assertTrue(statements[0].startswith("SELECT asm_publication.set_lifecycle("))
        self.assertIn(",17,", statements[0])


if __name__ == "__main__":
    unittest.main()
