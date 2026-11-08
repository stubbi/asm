"""Keep the optional PostgreSQL 18 server separate from reviewed clients.

SPDX-License-Identifier: AGPL-3.0-or-later
These unit checks do not establish SQL or native runtime compatibility.
"""
import importlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "experiments/assembly-server"))
import local_postgres


class Pg18FixtureTests(unittest.TestCase):
    def module(self):
        self.assertTrue((Path(__file__).parent / "pg18_fixture.py").is_file(),
                        "The dedicated owned PostgreSQL 18.6 fixture is missing.")
        return importlib.import_module("pg18_fixture")

    def binaries(self, base, version, *, postgres_version=None):
        """Use harmless programs for version rejection, never a database server."""
        base.mkdir()
        for name in ("initdb", "postgres", "psql"):
            selected = postgres_version if name == "postgres" and postgres_version else version
            path = base / name
            path.write_text("#!/bin/sh\nprintf '%s\\n' '" + name + " (PostgreSQL) " + selected + "'\n")
            path.chmod(0o700)
        return base

    def test_default_server_still_accepts_only_16_15(self):
        self.assertTrue(hasattr(local_postgres.LocalPostgres, "server_binaries"),
                        "The default fixture needs a server-only binary selection seam.")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            default = self.binaries(base / "pg16", "16.15")
            alternate = self.binaries(base / "pg18", "18.6")
            cluster = local_postgres.LocalPostgres(base)
            env = local_postgres.clean_environment()
            with patch.dict(os.environ, {"ASM_PROTO_PG_BINDIR": str(default),
                                         "ASM_PROTO_PG18_BINDIR": str(alternate)}):
                self.assertEqual(cluster.server_binaries(env), default.resolve())
            with patch.dict(os.environ, {"ASM_PROTO_PG_BINDIR": str(alternate)}):
                with self.assertRaisesRegex(RuntimeError, "16.15"):
                    cluster.server_binaries(env)

    def test_18_server_requires_an_explicit_separate_binary_directory(self):
        fixture = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            default = self.binaries(base / "pg16", "16.15")
            cluster = fixture.Pg18TlsPostgres(base)
            with patch.dict(os.environ, {"ASM_PROTO_PG_BINDIR": str(default)}, clear=True):
                with self.assertRaisesRegex(RuntimeError, "ASM_PROTO_PG18_BINDIR"):
                    cluster.server_binaries(local_postgres.clean_environment())
            self.assertEqual(list(base.iterdir()), [default])

    def test_18_server_rejects_wrong_initdb_or_postgres_before_creating_files(self):
        fixture = self.module()
        for initdb, postgres in (("16.15", "18.6"), ("18.6", "18.5"), ("18.7", "18.6")):
            with self.subTest(initdb=initdb, postgres=postgres), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                selected = self.binaries(base / "binaries", initdb, postgres_version=postgres)
                with patch.dict(os.environ, {"ASM_PROTO_PG18_BINDIR": str(selected)}):
                    with self.assertRaisesRegex(RuntimeError, "18.6"):
                        fixture.Pg18TlsPostgres(base).server_binaries(local_postgres.clean_environment())
                self.assertEqual(list(base.iterdir()), [selected])

    def test_18_server_selects_only_the_explicit_server_directory(self):
        fixture = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            default = self.binaries(base / "pg16", "16.15")
            selected = self.binaries(base / "pg18", "18.6")
            with patch.dict(os.environ, {"ASM_PROTO_PG_BINDIR": str(default),
                                         "ASM_PROTO_PG18_BINDIR": str(selected),
                                         "PGHOST": "production.invalid"}):
                self.assertEqual(fixture.Pg18TlsPostgres(base).server_binaries(
                    local_postgres.clean_environment()), selected.resolve())
            self.assertCountEqual(base.iterdir(), [default, selected])

    def test_fixture_urls_keep_owned_loopback_and_verified_tls(self):
        fixture = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            cluster = fixture.Pg18TlsPostgres(temporary)
            cluster.base = Path(temporary) / "owned"
            cluster.port, cluster.password = 54321, "a" * 48
            parsed = urlsplit(cluster.url())
            query = parse_qs(parsed.query)
            self.assertEqual((parsed.hostname, parsed.port, parsed.path), ("localhost", 54321, "/postgres"))
            self.assertEqual(query["hostaddr"], ["127.0.0.1"])
            self.assertEqual(query["sslmode"], ["verify-full"])
            self.assertEqual(query["gssencmode"], ["disable"])
            for field, name in (("sslrootcert", "ca.crt"), ("sslcert", "asm_fixture_admin.crt"),
                                ("sslkey", "asm_fixture_admin.key")):
                self.assertEqual(query[field], [str(cluster.base / name)])
            with self.assertRaises(ValueError):
                cluster.url(database="postgres?host=production.invalid")
            with self.assertRaises(TypeError):
                fixture.Pg18TlsPostgres(temporary, url="postgresql://production.invalid/postgres")

    def test_actual_server_version_and_tls_are_required_after_owned_start(self):
        fixture = self.module()
        for rows, accepted in (([["180006", "t"]], True), ([["160015", "t"]], False),
                               ([["180006", "f"]], False), ([], False)):
            with self.subTest(rows=rows), tempfile.TemporaryDirectory() as temporary:
                cluster = fixture.Pg18TlsPostgres(temporary)
                cluster.admin = SimpleNamespace(execute=lambda _sql: rows, close=lambda: None)
                with patch.object(local_postgres.LocalPostgres, "start", return_value=cluster):
                    if accepted:
                        self.assertIs(cluster.start(), cluster)
                    else:
                        with self.assertRaisesRegex(RuntimeError, "18.6.*TLS"):
                            cluster.start()
                        self.assertIsNone(cluster.admin)

    def test_connected_data_directory_must_still_belong_to_the_started_process(self):
        fixture = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            cluster = fixture.Pg18TlsPostgres(base)
            process = SimpleNamespace(pid=123, poll=lambda: None, send_signal=lambda _signal: None,
                                      wait=lambda **_kw: 0)
            database = SimpleNamespace(execute=lambda *_args, **_kw: [[str(base / "unrelated")]],
                                       close=lambda: None)
            with patch.object(os, "geteuid", return_value=65532), \
                    patch.object(cluster, "server_binaries", return_value=base), \
                    patch.object(cluster, "_initialize"), \
                    patch.object(local_postgres.subprocess, "Popen", return_value=process), \
                    patch.object(local_postgres, "Database", return_value=database):
                with self.assertRaisesRegex(RuntimeError, "owned cluster"):
                    cluster.start()
            self.assertIsNone(cluster.temp)
            self.assertEqual(list(base.iterdir()), [])

    def test_launcher_fails_closed_when_the_separate_fixture_is_missing(self):
        self.assertTrue((Path(__file__).parent / "run_pg18.py").is_file(),
                        "The dedicated PostgreSQL 18 qualification launcher is missing.")
        result = subprocess.run([sys.executable, str(Path(__file__).parent / "run_pg18.py"), "--check-only"],
                                env={"PATH": os.environ["PATH"]}, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("ASM_PROTO_PG", result.stderr)
        self.assertNotIn("Ran ", result.stderr)

    def test_import_does_not_replace_the_default_fixture(self):
        self.module()
        result = subprocess.run([sys.executable, "-c", "import pg18_fixture; "
            "assert pg18_fixture.reader_fixture.TlsPostgres is not pg18_fixture.Pg18TlsPostgres; "
            "assert pg18_fixture.reader_fixture.TlsPostgres.__bases__ == (pg18_fixture.LocalPostgres,)"],
            cwd=Path(__file__).parent, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_preflight_retains_the_exact_16_15_client_profile(self):
        fixture = self.module()
        for client, library, accepted in (("16.15", 160015, True), ("18.6", 160015, False),
                                           ("16.15", 180006, False)):
            with self.subTest(client=client, library=library), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                client_bins = self.binaries(base / "client", client)
                server_bins = self.binaries(base / "server", "18.6")
                version = lambda: library
                with patch.dict(os.environ, {"ASM_PROTO_PG_BINDIR": str(client_bins),
                                             "ASM_PROTO_PG18_BINDIR": str(server_bins),
                                             "ASM_PROTO_LIBPQ": str(base / "libpq")}), \
                        patch.object(fixture.ctypes, "CDLL", return_value=SimpleNamespace(PQlibVersion=version)):
                    if accepted:
                        fixture.preflight()
                    else:
                        with self.assertRaisesRegex(RuntimeError, "16.15"):
                            fixture.preflight()
                self.assertCountEqual(base.iterdir(), [client_bins, server_bins])

    def test_launcher_selects_18_before_all_v2_fixture_imports(self):
        self.module()
        result = subprocess.run([sys.executable, "-c", "import run_pg18; import test_authority; "
            "original = run_pg18.reader_fixture.TlsPostgres; "
            "\ntry: run_pg18.load_suites(['authority'])\n"
            "except RuntimeError: pass\nelse: raise AssertionError('Late fixture selection succeeded')\n"
            "assert run_pg18.reader_fixture.TlsPostgres is original"],
            cwd=Path(__file__).parent, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

        result = subprocess.run([sys.executable, "-c", "import run_pg18; "
            "suite = run_pg18.load_suites(['authority','distribution','runtime','full-flow']); "
            "import test_authority; import test_full_flow; "
            "assert suite.countTestCases() > 0; "
            "assert test_authority.TlsPostgres is run_pg18.Pg18TlsPostgres; "
            "assert test_full_flow.runtime_fixture.fixture_module.TlsPostgres is run_pg18.Pg18TlsPostgres"],
            cwd=Path(__file__).parent, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_launcher_refuses_empty_or_skipped_suites(self):
        self.module()
        launcher = importlib.import_module("run_pg18")
        class SkippedCase(unittest.TestCase):
            @unittest.skip("This case cannot qualify the server.")
            def test_unavailable(self):
                pass
        for suite in (unittest.TestSuite(), unittest.defaultTestLoader.loadTestsFromTestCase(SkippedCase)):
            with self.subTest(cases=suite.countTestCases()), \
                    patch.object(launcher, "preflight"), patch.object(launcher, "load_suites", return_value=suite), \
                    patch.object(sys, "stderr", io.StringIO()):
                self.assertEqual(launcher.main(["authority"]), 1)


if __name__ == "__main__":
    unittest.main()
