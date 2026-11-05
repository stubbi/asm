"""Reject unowned or substituted PostgreSQL qualification fixtures.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import postgres18_fixture as fixture


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "prepared"

    def declaration(self):
        return {"schema": 1, "source_revision": "a" * 40, "nonce": "b" * 64,
                "index_digest": "sha256:39add80f5b1e573e2f6b641c66fd1a2f8dede67ca0330e870285bc1078551390",
                "platform_digest": "sha256:9d1808e9b9c82fb1175ecc7aba615e88b16013e8f118c536a8b5a9aca017ec03",
                "server_version_num": 180006, "port": 5432,
                "data_directory": "/run/asm-postgres18/data",
                "files": {"ca.crt": "c" * 64, "ca.key": "d" * 64,
                          "server.crt": "e" * 64, "unrelated.crt": "f" * 64}}

    def test_wrong_image_version_nonce_target_or_schema_cannot_select_a_fixture(self):
        accepted = self.declaration()
        self.assertEqual(fixture.declaration_contract(accepted, "a" * 40)["port"], 5432)
        for key, value in (("schema", True), ("server_version_num", 160015), ("port", 5433),
                           ("nonce", ""), ("nonce", "g" * 64), ("index_digest", "sha256:" + "0" * 64),
                           ("platform_digest", "sha256:" + "1" * 64), ("source_revision", "c" * 40),
                           ("data_directory", "/var/lib/postgresql/data")):
            changed = dict(accepted, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                fixture.declaration_contract(changed, "a" * 40)
        changed = dict(accepted, target_url="postgresql://production.invalid/asm")
        with self.assertRaises(ValueError):
            fixture.declaration_contract(changed, "a" * 40)

    def test_running_database_identity_requires_the_owned_nonce_tls_and_version(self):
        row = ["180006", "/run/asm-postgres18/data", "b" * 64,
               "7452238960987612345", "asm_fixture_admin", "asm_fixture_admin", "t", "TLSv1.3"]
        self.assertEqual(fixture.server_contract([row], self.declaration())["system_identifier"], row[3])
        for position, value in ((0, "180005"), (1, "/unowned"), (2, "c" * 64), (3, "0"),
                                (4, "postgres"), (5, "postgres"), (6, "f"), (7, "TLSv1.1")):
            changed = list(row)
            changed[position] = value
            with self.subTest(position=position), self.assertRaises(ValueError):
                fixture.server_contract([changed], self.declaration())
        with self.assertRaises(ValueError):
            fixture.server_contract([row, row], self.declaration())

    def test_preparation_preserves_an_existing_destination(self):
        self.directory.mkdir()
        retained = self.directory / "retained"
        retained.write_bytes(b"existing user bytes")
        with self.assertRaises(FileExistsError):
            fixture.prepare(self.directory, "a" * 40)
        self.assertEqual(retained.read_bytes(), b"existing user bytes")

    def test_prepared_certificates_bind_the_nonce_and_cleanup_owns_the_complete_directory(self):
        declaration = fixture.prepare(self.directory, "a" * 40)
        self.assertEqual(fixture.read_declaration(self.directory / "app", "a" * 40), declaration)
        identity, nonce = fixture.preparation_owner(self.directory)
        self.assertEqual(nonce, declaration["nonce"])
        (self.directory / "app/ca.key").chmod(0o644)
        with self.assertRaises(ValueError):
            fixture.read_declaration(self.directory / "app", "a" * 40)
        fixture.remove_preparation(self.directory, identity, nonce)
        self.assertFalse(self.directory.exists())

    def test_preparation_marker_and_parent_links_cannot_authorize_foreign_cleanup(self):
        self.directory.mkdir(mode=0o700)
        info = self.directory.stat()
        (self.directory / "owner.json").write_text(json.dumps({"device": info.st_dev, "inode": info.st_ino + 1, "nonce": "b" * 64}))
        with self.assertRaises(ValueError):
            fixture.preparation_owner(self.directory)
        link = self.directory.with_name("link")
        link.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            fixture.preparation_owner(link)

    def test_cleanup_refuses_a_replaced_directory_and_preserves_its_files(self):
        self.directory.mkdir(mode=0o700)
        original = self.directory.stat()
        moved = self.directory.with_name("retained-original")
        self.directory.rename(moved)
        self.directory.mkdir(mode=0o700)
        retained = self.directory / "retained"
        retained.write_bytes(b"do not delete")
        with self.assertRaises(ValueError):
            fixture.remove_preparation(self.directory, (original.st_dev, original.st_ino), "b" * 64)
        self.assertEqual(retained.read_bytes(), b"do not delete")

    def test_duplicate_json_and_symlink_files_are_rejected_before_certificate_use(self):
        self.directory.mkdir(mode=0o700)
        declaration = self.directory / "fixture.json"
        declaration.write_text(json.dumps(self.declaration()).replace('"schema": 1', '"schema": 1, "schema": 1'))
        with self.assertRaises(ValueError):
            fixture.read_declaration(self.directory, "a" * 40)
        declaration.unlink()
        elsewhere = self.directory.with_name("elsewhere")
        elsewhere.write_text(json.dumps(self.declaration()))
        declaration.symlink_to(elsewhere)
        with self.assertRaises((ValueError, OSError)):
            fixture.read_declaration(self.directory, "a" * 40)


if __name__ == "__main__":
    unittest.main()
