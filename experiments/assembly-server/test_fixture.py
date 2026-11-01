"""Tests for the new disposable fixture boundary.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import socket
import unittest
from unittest.mock import patch

from local_postgres import Database, LocalPostgres, MIGRATION, verify_migration, verify_version


ROOT = Path(__file__).resolve().parents[2]


class FixtureTests(unittest.TestCase):
    def test_changed_schema_and_unsupported_version_fail_before_startup(self):
        verify_migration(MIGRATION.read_bytes())
        with self.assertRaisesRegex(RuntimeError, "digest changed"):
            verify_migration(MIGRATION.read_bytes() + b"\n")
        for value in ("postgres (PostgreSQL) 16.14", "initdb (PostgreSQL) 17.0", "unknown"):
            with self.subTest(version=value), self.assertRaisesRegex(RuntimeError, "16.15"):
                verify_version(value)

    def test_identity_failure_during_start_removes_owned_process_listener_and_directory(self):
        fixture = LocalPostgres(ROOT / "build/assembly-server")
        # Start a real server, then force the ownership read to disagree.
        # This exercises cleanup inside start(), before __enter__ can succeed.
        with patch.object(Database, "execute", return_value=[["/not-the-owned-data-directory"]]):
            with self.assertRaisesRegex(RuntimeError, "not this fixture's owned cluster"):
                fixture.start()
        process, directory, port = fixture.process, fixture.base, fixture.port
        self.assertIsNotNone(process.poll())
        self.assertFalse(directory.exists())
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=0.2)
        fixture.close()  # Repeated cleanup must be harmless.
