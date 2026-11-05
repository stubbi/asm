"""Real operator and immutable-export tests against an owned PostgreSQL 16.15 cluster.

SPDX-License-Identifier: AGPL-3.0-or-later
No existing database target or production credential is accepted.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "server"))
from test_runtime import TlsPostgres, Database
import registry
import registry_admin


class CatalogDatabaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.environ.get("ASM_PROTO_PG_BINDIR") or not os.environ.get("ASM_PROTO_LIBPQ"):
            raise AssertionError("Supply the reviewed PostgreSQL 16.15 fixture paths. No database tests ran.")
        cls.temp = tempfile.TemporaryDirectory(prefix="asm-catalog-owned-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.cluster = TlsPostgres(cls.base)
        cls.addClassCleanup(cls.cluster.close)
        cls.cluster.start()
        for role in ("asm_migrator", "asm_operator", "asm_reader"):
            cls.cluster.admin.execute(f'CREATE ROLE "{role}" LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
            cls.cluster.certificate(role, role)
        cls.psql = Path(os.environ["ASM_PROTO_PG_BINDIR"]) / "psql"

    def setUp(self):
        self.work = self.base / secrets.token_hex(6)
        self.work.mkdir(mode=0o700)
        self.dbname = "asm_catalog_" + secrets.token_hex(6)
        self.cluster.admin.execute(f'CREATE DATABASE "{self.dbname}" OWNER asm_migrator')
        self.admin = Database(self.cluster.url(database=self.dbname))
        self.addCleanup(self.admin.close)
        self.configs = {}
        for label in ("migrator", "operator", "reader"):
            path = self.work / (label + ".url")
            path.write_text(self.connection_url(label) + "\n")
            path.chmod(0o600)
            self.configs[label] = path
        self.repo = self.work / "source"
        self.repo.mkdir()
        records = registry.read_records(ROOT / "registry")
        self.records = records
        for record in records:
            path = self.repo / "registry/packages" / record["name"] / (record["version"] + ".json")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(registry.json_bytes(record))
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "Create an accepted catalog fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()

    def connection_url(self, label, **changes):
        query = {"hostaddr": "127.0.0.1", "sslmode": "verify-full", "gssencmode": "disable"}
        query.update({key: str(self.cluster.base / name) for key, name in (
            ("sslrootcert", "ca.crt"), ("sslcert", "asm_" + label + ".crt"),
            ("sslkey", "asm_" + label + ".key"))})
        query.update(changes)
        return (f"postgresql://asm_{label}@localhost:{self.cluster.port}/{self.dbname}?" +
                "&".join(key + "=" + quote(value, safe="/") for key, value in query.items()))

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false", "-c", "user.name=Catalog fixture", "-c",
            "user.email=fixture@example.invalid", *args], capture_output=True, check=True, timeout=10).stdout

    def command(self, label, *arguments, config=None):
        environment = {"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1",
                       "PGOPTIONS": "-c default_transaction_read_only=off",
                       "PGPASSWORD": "synthetic-ambient-secret-must-not-be-used",
                       "PGSERVICE": "untrusted-service"}
        return subprocess.run([sys.executable, str(ROOT / "tools/registry_admin.py"),
            "--connection-file", str(config or self.configs[label]), "--psql", str(self.psql),
            *arguments], capture_output=True, timeout=25, env=environment)

    def plan(self, revision=0):
        result = subprocess.run([sys.executable, str(ROOT / "tools/registry_admin.py"), "plan",
            "--repository", str(self.repo), "--commit", self.commit, "--expected-revision", str(revision)],
            capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout)

    def migrate(self):
        result = self.command("migrator", "migrate")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result

    def bind(self):
        result = self.command("operator", "bind-namespace", "--namespace", "stubbi", "--github-id", "12345",
                              "--acceptance-commit", self.commit)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def publish(self, revision=0):
        return self.command("operator", "import", "--repository", str(self.repo), "--commit", self.commit,
            "--expected-revision", str(revision), "--plan-sha256", self.plan(revision)["plan_sha256"])

    def import_first(self):
        self.migrate()
        self.bind()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)["revision"], 1)

    def test_migration_replay_and_role_grants_preserve_reader_denial(self):
        self.migrate()
        self.migrate()
        granted = self.command("migrator", "grant")
        self.assertEqual(granted.returncode, 0, granted.stderr.decode())
        reader = Database(self.connection_url("reader"))
        self.addCleanup(reader.close)
        self.assertEqual(reader.execute("SELECT count(*) FROM asm_catalog.current_exports"), [["0"]])
        for statement in ("UPDATE asm_catalog.head SET revision=0", "DELETE FROM asm_catalog.releases",
                          "SELECT asm_catalog.bind_namespace('wrong',42,repeat('a',40))"):
            refused = Database(self.connection_url("reader"))
            try:
                with self.subTest(statement=statement), self.assertRaises(AssertionError):
                    refused.execute(statement)
            finally:
                # The retained fixture stops on PG errors rather than draining an aborted result.
                refused.close()
        self.assertNotEqual(self.command("reader", "migrate").returncode, 0)
        self.assertNotEqual(self.command("migrator", "bind-namespace", "--namespace", "stubbi",
            "--github-id", "42", "--acceptance-commit", self.commit).returncode, 0)

    def test_roundtrip_complete_current_catalog_and_idempotent_import(self):
        self.import_first()
        tsv, index = registry.make_indexes(self.records)
        expected = {"/registry/v1/index.tsv": registry.legacy_tsv(tsv),
                    "/registry/v1/index-macos.tsv": tsv, "/registry/v1/index.json": registry.json_bytes(index).decode()}
        reader = Database(self.connection_url("reader"))
        self.addCleanup(reader.close)
        for route, body in expected.items():
            found = reader.execute("SELECT body,sha256 FROM asm_catalog.current_exports WHERE route=$1", [route])
            self.assertEqual(found, [[body, hashlib.sha256(body.encode()).hexdigest()]])
        self.assertIn("aarch64-macos", expected["/registry/v1/index-macos.tsv"])
        self.assertNotIn("aarch64-macos", expected["/registry/v1/index.tsv"])
        replay = self.publish()
        self.assertEqual(replay.returncode, 0, replay.stderr.decode())
        self.assertEqual(json.loads(replay.stdout)["revision"], 1)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.snapshots"), [["1"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.releases"), [[str(len(self.records))]])

    def test_conflicting_release_or_removed_history_rolls_back_the_entire_snapshot(self):
        self.import_first()
        path = self.repo / "registry/packages/stubbi/math/0.5.0.json"
        old = path.read_bytes()
        record = json.loads(old)
        record["summary"] = "A changed existing release must be refused"
        path.write_bytes(registry.json_bytes(record))
        self.git("add", ".")
        self.git("commit", "-qm", "Record a conflicting fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        result = self.publish(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(self.admin.execute("SELECT revision FROM asm_catalog.head"), [["1"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.snapshots"), [["1"]])
        path.write_bytes(old)
        (self.repo / "registry/packages/stubbi/hello/0.1.0.json").unlink()
        self.git("add", "-A")
        self.git("commit", "-qm", "Omit published history")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.assertNotEqual(self.publish(1).returncode, 0)
        self.assertEqual(self.admin.execute("SELECT revision FROM asm_catalog.head"), [["1"]])

    def test_namespace_assertion_conflict_and_stale_publication_do_not_change_head(self):
        self.import_first()
        result = self.command("operator", "bind-namespace", "--namespace", "stubbi", "--github-id", "54321",
                              "--acceptance-commit", self.commit)
        self.assertNotEqual(result.returncode, 0)
        self.git("commit", "--allow-empty", "-qm", "A later accepted commit")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.assertNotEqual(self.publish(0).returncode, 0)
        self.assertEqual(self.admin.execute("SELECT revision FROM asm_catalog.head"), [["1"]])

    def test_bad_tls_private_file_or_plan_cannot_reach_mutation(self):
        self.migrate()
        self.bind()
        original = self.configs["operator"]
        wrong = self.work / "wrong.url"
        wrong.write_text(self.connection_url("operator", sslmode="disable"))
        wrong.chmod(0o600)
        wrong_ca = self.work / "wrong-ca.url"
        wrong_ca.write_text(self.connection_url("operator", sslrootcert=str(self.cluster.base / "unrelated.crt")))
        wrong_ca.chmod(0o600)
        args = ("import", "--repository", str(self.repo), "--commit", self.commit,
                "--expected-revision", "0", "--plan-sha256", self.plan()["plan_sha256"])
        for case in (wrong, wrong_ca, self.work / "link.url"):
            if case.name == "link.url":
                case.symlink_to(original)
            with self.subTest(case=case.name):
                failed = self.command("operator", *args, config=case)
                self.assertNotEqual(failed.returncode, 0)
                self.assertEqual(failed.stdout, b"")
        original.chmod(0o644)
        self.assertNotEqual(self.command("operator", *args).returncode, 0)
        original.chmod(0o600)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.snapshots"), [["0"]])

    def test_direct_operator_cannot_publish_noncanonical_json_representations(self):
        self.migrate()
        self.bind()
        tsv, index = registry.make_indexes(self.records)
        canonical_records = [registry.json_bytes(record).decode() for record in self.records]
        canonical_index = registry.json_bytes(index).decode()
        variants = []
        compact = list(canonical_records)
        compact[0] = json.dumps(self.records[0], sort_keys=True) + "\n"
        variants.append((compact, canonical_index))
        variants.append((canonical_records, json.dumps(index, sort_keys=True) + "\n"))
        for records, index_body in variants:
            connection = Database(self.connection_url("operator"))
            try:
                connection.execute("BEGIN")
                with self.subTest(compact_manifest=records is compact), self.assertRaises(AssertionError):
                    connection.execute("SELECT asm_catalog.publish($1,0,ARRAY(SELECT value FROM json_array_elements_text($2::json)),$3,$4,$5)",
                        [self.commit, json.dumps(records), registry.legacy_tsv(tsv), tsv, index_body])
            finally:
                # Closing this owned transaction rolls back either branch independently.
                connection.close()
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.snapshots"), [["0"]])

    def test_direct_operator_rejects_hostile_metadata_and_forged_evidence_atomically(self):
        self.migrate()
        self.bind()
        tsv, index = registry.make_indexes(self.records)
        canonical = [registry.json_bytes(record).decode() for record in self.records]
        variants = []
        for field, value in (("schema", 2), ("version", "2147483648.0.0")):
            record = dict(self.records[0], **{field: value})
            variants.append(([registry.json_bytes(record).decode()] + canonical[1:], registry.json_bytes(index).decode()))
        record = json.loads(canonical[0])
        record["artifacts"][0]["target"] = "unsupported-target"
        variants.append(([registry.json_bytes(record).decode()] + canonical[1:], registry.json_bytes(index).decode()))
        duplicate = canonical[0].replace('  "schema": 1,', '  "schema": 1,\n  "schema": 1,')
        self.assertNotEqual(duplicate, canonical[0])
        variants.append(([duplicate] + canonical[1:], registry.json_bytes(index).decode()))
        index["packages"][0]["versions"][0]["evidence"]["formal"] = "verified"
        variants.append((canonical, registry.json_bytes(index).decode()))
        for records, body in variants:
            connection = Database(self.connection_url("operator"))
            try:
                connection.execute("BEGIN")
                with self.subTest(records=records[0][:30], forged=body == variants[-1][1]), self.assertRaises(AssertionError):
                    connection.execute("SELECT asm_catalog.publish($1,0,ARRAY(SELECT value FROM json_array_elements_text($2::json)),$3,$4,$5)",
                        [self.commit, json.dumps(records), registry.legacy_tsv(tsv), tsv, body])
            finally:
                connection.close()
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.releases"), [["0"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.snapshots"), [["0"]])

    def test_direct_operator_parser_settings_cannot_weaken_url_validation(self):
        self.migrate()
        self.bind()
        tsv, index = registry.make_indexes(self.records)
        records = [registry.json_bytes(record).decode().replace("github.com", "githubXcom") for record in self.records]
        connection = Database(self.connection_url("operator"))
        try:
            connection.execute("SET standard_conforming_strings=off")
            connection.execute("BEGIN")
            with self.assertRaises(AssertionError):
                connection.execute("SELECT asm_catalog.publish($1,0,ARRAY(SELECT value FROM json_array_elements_text($2::json)),$3,$4,$5)",
                    [self.commit, json.dumps(records), registry.legacy_tsv(tsv).replace("github.com", "githubXcom"),
                     tsv.replace("github.com", "githubXcom"), registry.json_bytes(index).decode().replace("github.com", "githubXcom")])
        finally:
            connection.close()
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.snapshots"), [["0"]])

    def test_operator_temporary_types_cannot_change_trusted_function_resolution(self):
        self.migrate()
        self.bind()
        tsv, index = registry.make_indexes(self.records)
        records = [registry.json_bytes(record).decode() for record in self.records]
        connection = Database(self.connection_url("operator"))
        try:
            connection.execute("CREATE TEMP TABLE jsonb (fake integer)")
            connection.execute("SET standard_conforming_strings=off")
            self.assertEqual(connection.execute("SELECT asm_catalog.publish($1,0,ARRAY(SELECT value FROM json_array_elements_text($2::json)),$3,$4,$5)",
                [self.commit, json.dumps(records), registry.legacy_tsv(tsv), tsv, registry.json_bytes(index).decode()]), [["1"]])
        finally:
            connection.close()

    def test_migration_removes_unexpected_default_write_and_function_grants(self):
        self.admin.execute("ALTER DEFAULT PRIVILEGES FOR ROLE asm_migrator GRANT ALL ON TABLES TO asm_operator,asm_reader")
        self.admin.execute("ALTER DEFAULT PRIVILEGES FOR ROLE asm_migrator GRANT ALL ON SEQUENCES TO asm_operator,asm_reader")
        self.admin.execute("ALTER DEFAULT PRIVILEGES FOR ROLE asm_migrator GRANT EXECUTE ON FUNCTIONS TO asm_reader")
        self.admin.execute("ALTER DEFAULT PRIVILEGES FOR ROLE asm_migrator GRANT ALL ON SCHEMAS TO asm_operator,asm_reader")
        self.migrate()
        rows = self.admin.execute("""SELECT
            has_table_privilege('asm_operator','asm_catalog.head','INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER'),
            has_table_privilege('asm_operator','asm_catalog.schema_version','INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER'),
            has_table_privilege('asm_reader','asm_catalog.releases','INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER'),
            has_function_privilege('asm_reader','asm_catalog.publish(text,bigint,text[],text,text,text)','EXECUTE'),
            has_schema_privilege('asm_reader','asm_catalog','CREATE'),
            has_sequence_privilege('asm_reader','asm_catalog.audit_id_seq','USAGE,UPDATE')""")
        self.assertEqual(rows, [["f"] * 6])

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL interface")
    def test_extended_acl_on_private_key_cannot_reach_mutation(self):
        self.migrate()
        self.bind()
        key = self.cluster.base / "asm_operator.key"
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,write", str(key)], check=True)
        try:
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            refused = self.publish()
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(refused.stdout, b"")
            self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_catalog.snapshots"), [["0"]])
        finally:
            subprocess.run(["/bin/chmod", "-N", str(key)], check=True)

    def guard(self, label="reader", readonly=True):
        connection = Database(self.connection_url(label))
        try:
            connection.execute("BEGIN READ ONLY" if readonly else "BEGIN READ WRITE")
            return connection.execute((ROOT / "server/catalog/reader-guard.sql").read_text())
        finally:
            connection.close()

    def test_reader_guard_binds_exact_migration_and_actual_readonly_snapshot(self):
        self.migrate()
        self.assertEqual(self.guard(), [["0"]])
        self.bind()
        self.assertEqual(self.publish().returncode, 0)
        self.assertEqual(self.guard(), [["1"]])
        self.assertEqual(self.guard(readonly=False), [["0"]])
        self.assertEqual(self.guard("operator"), [["0"]])
        digest = hashlib.sha384((ROOT / "server/catalog/schema.sql").read_bytes()).hexdigest()
        self.assertEqual(digest, registry_admin.MIGRATION_SHA384)
        self.assertIn("'" + digest + "'", (ROOT / "server/catalog/reader-guard.sql").read_text())
        self.admin.execute("UPDATE asm_catalog.schema_version SET sha384=repeat('0',96)")
        self.assertEqual(self.guard(), [["0"]])

    def test_reader_guard_refuses_function_authority_membership_and_write_drift(self):
        self.import_first()
        self.assertEqual(self.guard(), [["1"]])
        cases = [
            ("GRANT EXECUTE ON FUNCTION asm_catalog.publish(text,bigint,text[],text,text,text) TO asm_reader",
             "REVOKE EXECUTE ON FUNCTION asm_catalog.publish(text,bigint,text[],text,text,text) FROM asm_reader"),
            ("GRANT asm_operator TO asm_reader", "REVOKE asm_operator FROM asm_reader"),
            ("GRANT CREATE ON SCHEMA asm_catalog TO asm_reader", "REVOKE CREATE ON SCHEMA asm_catalog FROM asm_reader"),
            (f'GRANT CREATE ON DATABASE "{self.dbname}" TO asm_reader', f'REVOKE CREATE ON DATABASE "{self.dbname}" FROM asm_reader'),
            ("GRANT UPDATE(revision) ON asm_catalog.head TO asm_reader", "REVOKE UPDATE(revision) ON asm_catalog.head FROM asm_reader"),
            ("GRANT USAGE ON SEQUENCE asm_catalog.audit_id_seq TO asm_reader", "REVOKE USAGE ON SEQUENCE asm_catalog.audit_id_seq FROM asm_reader"),
            ("GRANT pg_read_all_data TO asm_reader", "REVOKE pg_read_all_data FROM asm_reader"),
        ]
        for grant, revoke in cases:
            with self.subTest(grant=grant):
                self.admin.execute(grant)
                try:
                    self.assertEqual(self.guard(), [["0"]])
                finally:
                    self.admin.execute(revoke)
                self.assertEqual(self.guard(), [["1"]])

    def test_reader_guard_checks_views_indirect_roles_foreign_definers_and_required_reads(self):
        self.import_first()
        self.admin.execute("CREATE VIEW asm_catalog.guard_view AS SELECT * FROM asm_catalog.head")
        self.admin.execute("ALTER VIEW asm_catalog.guard_view OWNER TO asm_migrator")
        role = "catalog_drift_" + secrets.token_hex(6)
        self.admin.execute(f'CREATE ROLE "{role}" NOLOGIN NOINHERIT')
        self.admin.execute(f'GRANT UPDATE ON asm_catalog.head TO "{role}"')
        self.admin.execute("CREATE FUNCTION public.guard_definer() RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS 'SELECT 1'")
        self.admin.execute("REVOKE ALL ON FUNCTION public.guard_definer() FROM PUBLIC")
        self.admin.execute("CREATE SCHEMA pgxtemp_evil")
        self.admin.execute("CREATE TABLE pgxtemp_evil.target(value integer)")
        self.admin.execute("CREATE SEQUENCE pgxtemp_evil.counter")
        self.admin.execute("CREATE FUNCTION pgxtemp_evil.definer() RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS 'SELECT 1'")
        self.admin.execute("REVOKE ALL ON FUNCTION pgxtemp_evil.definer() FROM PUBLIC")
        cases = [
            ("GRANT UPDATE ON asm_catalog.guard_view TO asm_reader", "REVOKE UPDATE ON asm_catalog.guard_view FROM asm_reader"),
            (f'GRANT "{role}" TO asm_reader WITH INHERIT FALSE', f'REVOKE "{role}" FROM asm_reader'),
            ("GRANT EXECUTE ON FUNCTION public.guard_definer() TO PUBLIC", "REVOKE EXECUTE ON FUNCTION public.guard_definer() FROM PUBLIC"),
            ("GRANT CREATE ON SCHEMA pgxtemp_evil TO asm_reader", "REVOKE CREATE ON SCHEMA pgxtemp_evil FROM asm_reader"),
            ("GRANT UPDATE ON pgxtemp_evil.target TO asm_reader", "REVOKE UPDATE ON pgxtemp_evil.target FROM asm_reader"),
            ("GRANT USAGE ON SEQUENCE pgxtemp_evil.counter TO asm_reader", "REVOKE USAGE ON SEQUENCE pgxtemp_evil.counter FROM asm_reader"),
            ("GRANT EXECUTE ON FUNCTION pgxtemp_evil.definer() TO asm_reader", "REVOKE EXECUTE ON FUNCTION pgxtemp_evil.definer() FROM asm_reader"),
        ]
        for grant, revoke in cases:
            self.admin.execute(grant)
            try:
                with self.subTest(grant=grant):
                    self.assertEqual(self.guard(), [["0"]])
            finally:
                self.admin.execute(revoke)
            self.assertEqual(self.guard(), [["1"]])
        self.admin.execute("REVOKE SELECT ON asm_catalog.current_exports FROM asm_reader")
        with self.assertRaises(AssertionError):
            self.guard()

    def test_concurrent_imports_fence_head_and_old_replay_cannot_roll_back_publication(self):
        self.import_first()
        original = self.commit
        commits = []
        for n in range(2):
            self.git("commit", "--allow-empty", "-qm", f"Concurrent accepted fixture {n}")
            commits.append(self.git("rev-parse", "HEAD").decode().strip())
        def attempt(commit):
            plan, _, _ = registry_admin.prepare_import(self.repo, commit, 1)
            return self.command("operator", "import", "--repository", str(self.repo), "--commit", commit,
                "--expected-revision", "1", "--plan-sha256", plan["plan_sha256"])
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, commits))
        self.assertEqual(sorted(result.returncode for result in results), [0, 1])
        self.assertEqual(self.admin.execute("SELECT count(*),max(revision) FROM asm_catalog.snapshots"), [["2", "2"]])
        self.assertEqual(self.admin.execute("SELECT count(*),min(revision),max(revision) FROM asm_catalog.current_exports"), [["3", "2", "2"]])
        self.commit = original
        replay = self.publish(0)
        self.assertEqual(replay.returncode, 0, replay.stderr.decode())
        self.assertEqual(json.loads(replay.stdout)["revision"], 1)
        self.assertEqual(self.admin.execute("SELECT revision FROM asm_catalog.head"), [["2"]])


if __name__ == "__main__":
    unittest.main()
