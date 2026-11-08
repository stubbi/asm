"""Direct publisher authority tests against an owned PostgreSQL 16.15 cluster.

SPDX-License-Identifier: AGPL-3.0-or-later
No existing database or production credential is accepted.
"""
import concurrent.futures
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import re
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


class PublisherAuthorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.environ.get("ASM_PROTO_PG_BINDIR") or not os.environ.get("ASM_PROTO_LIBPQ"):
            raise AssertionError("Supply PostgreSQL 16.15 fixture paths; no publisher database tests ran.")
        cls.temp = tempfile.TemporaryDirectory(prefix="asm-publisher-owned-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.cluster = TlsPostgres(cls.base)
        cls.addClassCleanup(cls.cluster.close)
        cls.cluster.start()
        for role in ("asm_migrator", "asm_operator", "asm_reader", "asm_publisher", "asm_publication_worker"):
            cls.cluster.admin.execute(f'CREATE ROLE "{role}" LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
            cls.cluster.certificate(role, role)
        cls.cluster.admin.execute("ALTER ROLE asm_publisher SET log_parameter_max_length=0")
        cls.cluster.admin.execute("ALTER ROLE asm_publisher SET log_parameter_max_length_on_error=0")
        cls.migration = (ROOT / "server/publisher/schema.sql").read_bytes()
        cls.migration_sha = hashlib.sha384(cls.migration).hexdigest()

    def connection_url(self, role, *, operator=False):
        query = {"hostaddr": "127.0.0.1", "sslmode": "verify-full", "gssencmode": "disable"}
        query.update({key: str(self.cluster.base / name) for key, name in (
            ("sslrootcert", "ca.crt"), ("sslcert", role + ".crt"), ("sslkey", role + ".key"))})
        if not operator:
            query["options"] = "-c statement_timeout=5000 -c lock_timeout=1000"
        url = (f"postgresql://{role}@localhost:{self.cluster.port}/{self.dbname}?" +
               "&".join(key + "=" + quote(value, safe="/") for key, value in query.items()))
        return url

    def connection(self, role):
        return Database(self.connection_url(role))

    def setUp(self):
        self.dbname = "asm_publication_" + secrets.token_hex(6)
        self.cluster.admin.execute(f'CREATE DATABASE "{self.dbname}" OWNER asm_migrator')
        self.admin = Database(self.cluster.url(database=self.dbname))
        self.addCleanup(self.admin.close)
        migrator = self.connection("asm_migrator")
        try:
            migrator.execute("BEGIN;" + (ROOT / "server/catalog/schema.sql").read_text() +
                f"INSERT INTO asm_catalog.schema_version VALUES(1,'{registry_admin.MIGRATION_SHA384}');COMMIT;")
            try:
                migrator.execute("BEGIN;" + self.migration.decode() +
                    f"INSERT INTO asm_publication.schema_version VALUES(1,'{self.migration_sha}');COMMIT;")
            except AssertionError:
                # At this point only public migration SQL has run. No publisher
                # token, operator assertion, or package data entered this database.
                log = (self.cluster.base / "postgres.log").read_bytes()[-524288:].decode("utf-8", "replace")
                errors = [line for line in log.splitlines() if "ERROR:" in line or "HINT:" in line]
                print("Publication migration diagnostic:", "\n".join(errors[-3:]), file=sys.stderr)
                raise
        finally:
            migrator.close()
        self.owner = "a" * 32
        self.token = "asm_pub_v1_" + "b" * 64
        self.credential = "c" * 32
        self.enroll(self.owner, "fixture")
        self.issue(self.credential, self.owner, self.token, ["fixture/hello"])
        self.run_role("asm_operator", "SELECT asm_publication.set_check_policy($1,$2,$3)", ["7" * 40, "8" * 64, "fixture-policy"])
        self.manifest = {"schema": 2, "owner_id": self.owner, "name": "fixture/hello", "version": "1.0.0",
            "summary": "Owned publisher fixture.", "license": "MIT", "source": {
                "repository": "https://entire.com/et/fixture/hello", "path": ".",
                "commit": {"algorithm": "git-sha1", "digest": "d" * 40},
                "archive": {"sha256": "e" * 64, "bytes": 128}},
            "artifacts": [{"kind": "source", "format": "tar.gz", "isa": "x86_64", "os": "linux",
                "abi": "sysv-amd64", "cpu_features": [], "sha256": "e" * 64, "bytes": 128}]}

    def run_role(self, role, sql, params=()):
        connection = self.connection(role)
        try:
            return connection.execute(sql, params or None)
        except AssertionError:
            log = (self.cluster.base / "postgres.log").read_bytes()[-524288:].decode("utf-8", "replace")
            errors = [line for line in log.splitlines() if "ERROR:" in line]
            # Preserve bounded failure evidence without raw publisher credentials.
            diagnostic = re.sub(r"asm_pub_v1_[0-9a-f]{64}", "[redacted]", "\n".join(errors[-2:]))
            print("Publication SQL diagnostic:", diagnostic[:2048], file=sys.stderr)
            raise
        finally:
            connection.close()

    def enroll(self, owner, namespace):
        return self.run_role("asm_operator", "SELECT asm_publication.enroll_owner($1,$2,$3)",
                             [owner, namespace, "fixture-enrollment"])

    def issue(self, credential, owner, token, packages):
        return self.run_role("asm_operator", "SELECT asm_publication.issue_credential($1,$2,$3,$4::text[],'1 hour',$5)",
            [credential, owner, hashlib.sha256(token.encode()).hexdigest(), "{" + ",".join(packages) + "}", "fixture-issue"])

    def call(self, operation, *params, role="asm_publisher"):
        placeholders = ",".join(f"${i + 1}" for i in range(len(params)))
        rows = self.run_role(role, f"SELECT * FROM asm_publication.{operation}({placeholders})", params)
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual(len(rows[0]), 3, rows)
        status, task, body = rows[0]
        self.assertRegex(status, r"^[1-5][0-9]{2}$")
        self.assertTrue(task == "" or len(task) == 32)
        self.assertLessEqual(len(body.encode()), 65536)
        value = json.loads(body) if body else None
        if body:
            self.assertEqual(registry.json_bytes(value).decode(), body)
        return int(status), task, value

    def create(self, *, token=None, key=None, manifest=None, raw=None):
        return self.call("create_publication", token or self.token, key or "1" * 32,
                         raw if raw is not None else registry.json_bytes(manifest or self.manifest).decode())

    def uploaded(self, task, manifest=None):
        manifest = manifest or self.manifest
        objects = {manifest["source"]["archive"]["sha256"]: manifest["source"]["archive"]["bytes"]}
        objects.update({a["sha256"]: a["bytes"] for a in manifest["artifacts"]})
        for digest, size in objects.items():
            self.assertEqual(self.call("authorize_upload", self.token, task, digest, size)[0], 204)
            self.assertEqual(self.call("receipt_upload", self.token, task, digest, size)[0], 201)
        return objects

    def claim(self, worker="2" * 32):
        return self.run_role("asm_publication_worker", "SELECT asm_publication.claim_check($1,30)", [worker])

    def receipt(self, task, objects, *, outcome="pass", manifest=None):
        return registry.json_bytes({"schema": 1, "task_id": task,
            "manifest_sha256": hashlib.sha256(registry.json_bytes(manifest or self.manifest)).hexdigest(),
            "checker_revision": "7" * 40, "policy_sha256": "8" * 64, "outcome": outcome,
            "objects": [{"sha256": digest, "bytes": size, "outcome": outcome}
                        for digest, size in sorted(objects.items())]}).decode()

    def test_role_isolation_and_pinned_readiness(self):
        self.assertEqual(self.run_role("asm_publisher", "SELECT asm_publication.publisher_ready($1)", [self.migration_sha]), [["1"]])
        self.assertEqual(self.run_role("asm_publisher", "SELECT asm_publication.publisher_ready($1)", ["0" * 96]), [["0"]])
        for role, statement in (("asm_reader", "SELECT * FROM asm_publication.tasks"),
            ("asm_publisher", "UPDATE asm_publication.tasks SET state='published'"),
            ("asm_publisher", "SELECT asm_publication.enroll_owner(repeat('f',32),'wrong','wrong')"),
            ("asm_publication_worker", "SELECT * FROM asm_publication.credentials")):
            with self.subTest(role=role, statement=statement), self.assertRaises(AssertionError):
                self.run_role(role, statement)
        self.admin.execute("GRANT asm_operator TO asm_publisher")
        try:
            self.assertEqual(self.run_role("asm_publisher", "SELECT asm_publication.publisher_ready($1)", [self.migration_sha]), [["0"]])
        finally:
            self.admin.execute("REVOKE asm_operator FROM asm_publisher")

    def test_owner_binding_and_credential_hash_only(self):
        self.enroll(self.owner, "fixture")
        with self.assertRaises(AssertionError):
            self.enroll("f" * 32, "fixture")
        retained = self.admin.execute("SELECT to_jsonb(c)::text FROM asm_publication.credentials c")[0][0]
        self.assertNotIn(self.token, retained)
        self.assertIn(hashlib.sha256(self.token.encode()).hexdigest(), retained)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.audit WHERE action='owner_enrolled'"), [["1"]])
        for role in ("asm_reader", "asm_publisher", "asm_publication_worker"):
            with self.subTest(role=role), self.assertRaises(AssertionError):
                self.run_role(role, "SELECT asm_publication.revoke_credential($1,'wrong')", [self.credential])

    def test_dependency_declarations_are_retained_with_the_canonical_intent(self):
        manifest = deepcopy(self.manifest)
        manifest["dependencies"] = [{"name": "other/math", "requirement": ">=1.2.0,<2.0.0"}]
        status, task, _ = self.create(manifest=manifest)
        self.assertEqual(status, 202)
        self.assertEqual(self.admin.execute("SELECT manifest FROM asm_publication.tasks WHERE id=$1", [task]),
                         [[registry.json_bytes(manifest).decode()]])

    def test_invalid_dependency_declarations_create_no_task(self):
        cases = [
            [{"name": "other/math", "requirement": ">=1.0.0,invalid"}],
            [{"name": "other/math", "requirement": ">=1.0.0, <2.0.0"}],
            [{"name": "other/math", "requirement": "2147483648.0.0"}],
            [{"name": "other/math", "requirement": "*", "optional": True}],
            [{"name": "other/math", "requirement": "1.0.0"}] * 2,
            [{"name": "z/math", "requirement": "1.0.0"}, {"name": "a/math", "requirement": "*"}],
        ]
        for dependencies in cases:
            with self.subTest(dependencies=dependencies):
                manifest = deepcopy(self.manifest)
                manifest["dependencies"] = dependencies
                self.assertEqual(self.create(manifest=manifest)[0], 400)
                self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.tasks"), [["0"]])

    def test_forge_independent_manifest_and_all_six_target_tuples(self):
        tuples = [("x86_64", "linux", "sysv-amd64"), ("aarch64", "linux", "aapcs64"),
            ("riscv64", "linux", "lp64d"), ("aarch64", "macos", "apple-arm64"),
            ("x86_64", "windows", "windows-x64"), ("aarch64", "windows", "windows-arm64")]
        manifest = deepcopy(self.manifest)
        manifest["source"]["commit"] = {"algorithm": "git-sha256", "digest": "d" * 64}
        manifest["artifacts"] = [dict(self.manifest["artifacts"][0], isa=isa, os=system, abi=abi)
                                 for isa, system, abi in tuples]
        status, task, body = self.create(manifest=manifest)
        self.assertEqual(status, 202)
        self.assertEqual(body["state"], "accepted")
        self.assertIsNone(body["release"])
        self.assertEqual(body["objects"], [{"sha256": "e" * 64, "bytes": 128, "received": False}])
        self.assertEqual(self.call("read_publication", self.token, task)[0], 200)
        manifest["version"] = "1.0.1"
        del manifest["source"]["repository"]
        self.assertEqual(self.create(key="3" * 32, manifest=manifest)[0], 202)

    def test_manifest_refusals_have_no_partial_tasks(self):
        cases = []
        for field, value in (("schema", 1), ("owner_id", "x" * 32), ("artifacts", []), ("summary", "bad\nsummary")):
            item = deepcopy(self.manifest); item[field] = value; cases.append(registry.json_bytes(item).decode())
        item = deepcopy(self.manifest); item["artifacts"][0]["abi"] = "windows-x64"; cases.append(registry.json_bytes(item).decode())
        item = deepcopy(self.manifest); item["artifacts"][0]["cpu_features"] = ["avx2"]; cases.append(registry.json_bytes(item).decode())
        item = deepcopy(self.manifest); item["source"]["archive"]["bytes"] = 67108865; cases.append(registry.json_bytes(item).decode())
        item = deepcopy(self.manifest); item["artifacts"][0]["url"] = "https://github.com/fixture/asset"; cases.append(registry.json_bytes(item).decode())
        cases.extend((registry.json_bytes(self.manifest).decode().replace('"schema": 2', '"schema": 2, "schema": 2'),
            json.dumps(self.manifest), "[" * 1000 + "]" * 1000, " " * 65537))
        for raw in cases:
            with self.subTest(raw=raw[:64]):
                self.assertEqual(self.create(raw=raw)[0], 400)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.tasks"), [["0"]])

    def test_authorization_idempotency_and_version_reservation(self):
        self.assertEqual(self.create(token="asm_pub_v1_" + "0" * 64)[0], 401)
        self.assertEqual(self.create(key="bad")[0], 400)
        status, task, _ = self.create()
        self.assertEqual(status, 202)
        self.assertEqual(self.create()[0:2], (200, task))
        changed = deepcopy(self.manifest); changed["summary"] = "Changed manifest."
        self.assertEqual(self.create(manifest=changed)[0], 409)
        self.assertEqual(self.create(key="4" * 32)[0], 409)
        self.enroll("f" * 32, "other")
        other = "asm_pub_v1_" + "9" * 64
        self.issue("d" * 32, "f" * 32, other, ["other/hello"])
        self.assertEqual(self.create(token=other)[0], 403)
        self.assertEqual(self.call("read_publication", other, task)[0], 404)
        self.assertEqual(self.call("read_publication", self.token, "f" * 32)[0], 404)

    def test_upload_receipts_are_declared_idempotent_and_checking_is_not_published(self):
        _, task, _ = self.create()
        self.assertEqual(self.call("authorize_upload", self.token, task, "f" * 64, 128)[0], 404)
        self.assertEqual(self.call("authorize_upload", self.token, task, "e" * 64, 129)[0], 409)
        self.uploaded(task)
        self.assertEqual(self.call("receipt_upload", self.token, task, "e" * 64, 128)[0], 204)
        _, _, body = self.call("read_publication", self.token, task)
        self.assertEqual(body["state"], "checking")
        self.assertIsNone(body["release"])
        self.assertTrue(body["objects"][0]["received"])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.intents"), [["0"]])

    def test_revocation_blocks_replay_upload_and_final_commit(self):
        _, task, _ = self.create()
        objects = self.uploaded(task)
        claim = json.loads(self.claim()[0][0])
        self.run_role("asm_operator", "SELECT asm_publication.revoke_credential($1,$2)", [self.credential, "fixture-revocation"])
        self.assertEqual(self.create()[0], 401)
        self.assertEqual(self.call("authorize_upload", self.token, task, "e" * 64, 128)[0], 401)
        result = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
                              [task, "2" * 32, claim["fence"], self.receipt(task, objects)])
        self.assertEqual(json.loads(result[0][0])["error"]["code"], "authorization_changed")
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.intents"), [["0"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.checks"), [["1"]])

    def test_check_fencing_exact_binding_and_atomic_outbox(self):
        _, task, _ = self.create()
        objects = self.uploaded(task)
        claim = json.loads(self.claim()[0][0])
        self.assertEqual(json.loads(self.claim("3" * 32)[0][0]), None)
        self.admin.execute("UPDATE asm_publication.tasks SET lease_until=clock_timestamp()-interval '1 second'")
        second = json.loads(self.claim("3" * 32)[0][0])
        self.assertGreater(second["fence"], claim["fence"])
        stale = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "2" * 32, claim["fence"], self.receipt(task, objects)])
        self.assertEqual(json.loads(stale[0][0])["error"]["code"], "lease_lost")
        wrong = json.loads(self.receipt(task, objects)); wrong["manifest_sha256"] = "0" * 64
        refused = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "3" * 32, second["fence"], registry.json_bytes(wrong).decode()])
        self.assertEqual(json.loads(refused[0][0])["error"]["code"], "invalid_receipt")
        accepted = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "3" * 32, second["fence"], self.receipt(task, objects)])
        self.assertEqual(json.loads(accepted[0][0])["state"], "committed")
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.intents"), [["1"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.outbox"), [["1"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.pending_events"), [["1"]])
        replay = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "3" * 32, second["fence"], self.receipt(task, objects)])
        self.assertEqual(json.loads(replay[0][0])["state"], "committed")
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.outbox"), [["1"]])

    def test_concurrent_creation_converges_without_replacing_bytes(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda _: self.create(), range(2)))
        self.assertEqual(sorted(r[0] for r in results), [200, 202])
        self.assertEqual(results[0][1], results[1][1])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.tasks"), [["1"]])

    def test_operation_scopes_logging_and_foreign_write_authority_are_enforced(self):
        _, task, _ = self.create()
        read_token = "asm_pub_v1_" + "1" * 64
        self.run_role("asm_operator", "SELECT asm_publication.issue_credential($1,$2,$3,$4::text[],'1 hour',$5,$6::text[])",
            ["1" * 32, self.owner, hashlib.sha256(read_token.encode()).hexdigest(), "{fixture/hello}", "read-only-fixture", "{task-read}"])
        self.assertEqual(self.call("read_publication", read_token, task)[0], 200)
        self.assertEqual(self.create(token=read_token)[0], 403)
        self.assertEqual(self.call("authorize_upload", read_token, task, "e" * 64, 128)[0], 403)
        self.admin.execute("CREATE SCHEMA unexpected;CREATE TABLE unexpected.writable(value text);GRANT USAGE ON SCHEMA unexpected TO asm_publisher;GRANT UPDATE(value) ON unexpected.writable TO asm_publisher")
        self.assertEqual(self.run_role("asm_publisher", "SELECT asm_publication.publisher_ready($1)", [self.migration_sha]), [["0"]])
        self.admin.execute("REVOKE UPDATE(value) ON unexpected.writable FROM asm_publisher")
        self.assertEqual(self.run_role("asm_publisher", "SELECT asm_publication.publisher_ready($1)", [self.migration_sha]), [["1"]])
        self.admin.execute("ALTER ROLE asm_publisher SET log_parameter_max_length=-1")
        try:
            self.assertEqual(self.run_role("asm_publisher", "SELECT asm_publication.publisher_ready($1)", [self.migration_sha]), [["0"]])
        finally:
            self.admin.execute("ALTER ROLE asm_publisher SET log_parameter_max_length=0")
        connection = self.connection("asm_publisher")
        try:
            connection.execute("BEGIN ISOLATION LEVEL REPEATABLE READ")
            rows = connection.execute("SELECT * FROM asm_publication.create_publication($1,$2,$3)",
                [self.token, "2" * 32, registry.json_bytes(self.manifest).decode()])
            self.assertEqual(rows[0][0], "503")
        finally:
            connection.close()

    def test_expiry_fences_workers_and_releases_only_uncommitted_version_reservations(self):
        _, task, _ = self.create()
        objects = self.uploaded(task)
        claim = json.loads(self.claim()[0][0])
        self.admin.execute("UPDATE asm_publication.credentials SET issued_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE id=$1", [self.credential])
        expired = self.run_role("asm_publication_worker", "SELECT asm_publication.expire_tasks(1)")
        self.assertEqual(json.loads(expired[0][0]), [{"task_id": task, "objects": [{"sha256": "e" * 64, "bytes": 128}]}])
        self.assertEqual(json.loads(self.run_role("asm_publication_worker", "SELECT asm_publication.expire_tasks(1)")[0][0]), [])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.reservations"), [["0"]])
        stale = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "2" * 32, claim["fence"], self.receipt(task, objects)])
        self.assertEqual(json.loads(stale[0][0])["error"]["code"], "lease_lost")
        fresh_token = "asm_pub_v1_" + "4" * 64
        self.issue("4" * 32, self.owner, fresh_token, ["fixture/hello"])
        status, replacement, _ = self.create(token=fresh_token, key="5" * 32)
        self.assertEqual(status, 202)
        self.assertNotEqual(replacement, task)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.tasks"), [["2"]])

    def test_current_replacement_grant_cannot_renew_an_expired_upload_reservation(self):
        _, task, _ = self.create()
        fresh = "asm_pub_v1_" + "6" * 64
        self.issue("6" * 32, self.owner, fresh, ["fixture/hello"])
        self.admin.execute("UPDATE asm_publication.tasks SET upload_expires_at=clock_timestamp()-interval '1 second' WHERE id=$1", [task])
        for operation in ("authorize_upload", "receipt_upload"):
            with self.subTest(operation=operation):
                status, _, body = self.call(operation, fresh, task, "e" * 64, 128)
                self.assertEqual(status, 410)
                self.assertEqual(body["error"]["code"], "upload_expired")
        self.assertEqual(self.admin.execute("SELECT received_at IS NULL FROM asm_publication.objects WHERE task_id=$1", [task]), [["t"]])
        self.admin.execute("UPDATE asm_publication.credentials SET issued_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE id=$1", [self.credential])
        self.assertEqual(self.call("authorize_upload", self.token, task, "e" * 64, 128)[0], 401)
        self.assertEqual(self.call("authorize_upload", fresh, task, "e" * 64, 128)[0], 410)

    def test_checker_error_retries_preserve_evidence_and_bad_policy_cannot_commit(self):
        _, task, _ = self.create()
        objects = self.uploaded(task)
        claim = json.loads(self.claim()[0][0])
        error = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "2" * 32, claim["fence"], self.receipt(task, objects, outcome="error")])
        self.assertEqual(json.loads(error[0][0])["error"]["code"], "check_unavailable")
        retry = json.loads(self.claim("3" * 32)[0][0])
        wrong = json.loads(self.receipt(task, objects)); wrong["policy_sha256"] = "0" * 64
        bad = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "3" * 32, retry["fence"], registry.json_bytes(wrong).decode()])
        self.assertEqual(json.loads(bad[0][0])["error"]["code"], "invalid_receipt")
        accepted = self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "3" * 32, retry["fence"], self.receipt(task, objects)])
        self.assertEqual(json.loads(accepted[0][0])["state"], "committed")
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.checks"), [["2"]])

    def test_pending_outbox_does_not_skip_an_earlier_allocated_late_commit(self):
        _, first, _ = self.create()
        first_objects = self.uploaded(first)
        second_manifest = deepcopy(self.manifest); second_manifest["version"] = "1.0.1"
        _, second, _ = self.create(key="2" * 32, manifest=second_manifest)
        second_objects = self.uploaded(second, second_manifest)
        first_claim = json.loads(self.claim()[0][0])
        self.assertEqual(first_claim["task_id"], first)
        held = self.connection("asm_publication_worker")
        try:
            held.execute("BEGIN")
            held.execute("SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
                [first, "2" * 32, first_claim["fence"], self.receipt(first, first_objects)])
            second_claim = json.loads(self.claim("3" * 32)[0][0])
            self.assertEqual(second_claim["task_id"], second)
            self.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
                [second, "3" * 32, second_claim["fence"], self.receipt(second, second_objects, manifest=second_manifest)])
            newer = json.loads(self.run_role("asm_publication_worker", "SELECT asm_publication.claim_event($1,30)", ["4" * 32])[0][0])
            self.assertEqual(newer["task_id"], second)
            self.assertEqual(self.run_role("asm_publication_worker", "SELECT asm_publication.acknowledge_event($1::bigint,$2,$3::bigint)",
                [newer["id"], "4" * 32, newer["fence"]]), [["t"]])
            held.execute("COMMIT")
        finally:
            held.close()
        older = json.loads(self.run_role("asm_publication_worker", "SELECT asm_publication.claim_event($1,30)", ["5" * 32])[0][0])
        self.assertEqual(older["task_id"], first)
        self.assertLess(older["id"], newer["id"])
        self.assertEqual(self.run_role("asm_publication_worker", "SELECT asm_publication.acknowledge_event($1::bigint,$2,$3::bigint)",
            [older["id"], "4" * 32, older["fence"]]), [["f"]])

    def test_real_credential_free_checker_receipt_binds_retained_archive_before_commit(self):
        import publication_check
        import publication_worker
        from registry_storage import LocalBlobStore
        data = registry.make_archive({"asm.toml": (b'[package]\nname = "hello"\nversion = "1.0.0"\n[target.x86_64-linux]\nsource = "src/main.s"\n', 0o644),
            "LICENSE": (b"Synthetic fixture under MIT.\n", 0o644), "README.md": (b"Synthetic fixture.\n", 0o644),
            "src/main.s": (b".global _start\n_start: nop\n", 0o644)})
        digest = hashlib.sha256(data).hexdigest()
        self.manifest["source"]["archive"] = {"sha256": digest, "bytes": len(data)}
        self.manifest["artifacts"][0].update(sha256=digest, bytes=len(data))
        _, task, _ = self.create()
        work = self.base / secrets.token_hex(6); work.mkdir(mode=0o700)
        manifest_file = work / "manifest.json"; manifest_file.write_bytes(registry.json_bytes(self.manifest)); manifest_file.chmod(0o600)
        path = work / (task + "-" + digest); path.write_bytes(data); path.chmod(0o600)
        self.uploaded(task)
        retained = LocalBlobStore(work / "retained")
        self.run_role("asm_operator", "SELECT asm_publication.set_check_policy($1,$2,$3)",
            ["7" * 40, publication_check.policy_digest(), "actual-checker-fixture"])
        connection = self.connection("asm_publication_worker")
        class Adapter:
            def execute(self, sql):
                return connection.execute(sql)[0][0]
        try:
            result = publication_worker.run_one(Adapter(), retained, work, "2" * 32,
                lambda task_id, manifest, objects: publication_check.check(task_id, manifest, objects, "7" * 40), work_root=work)
        finally:
            connection.close()
        self.assertEqual(result["state"], "committed")
        self.assertEqual(retained.get_blob(digest, len(data)), data)
        self.assertEqual(retained.read_object("publications/v2/intents/" + result["manifest_sha256"] + ".json", 65536)[0], registry.json_bytes(self.manifest))

    def test_failed_attempt_storage_charge_and_global_attempt_limit_remain_conservative(self):
        _, task, _ = self.create()
        self.admin.execute("UPDATE asm_publication.tasks SET failure=jsonb_build_object('code','artifact_invalid','detail','fixture','retryable',false),accepted_at=clock_timestamp()-interval '2 days'")
        self.admin.execute("DELETE FROM asm_publication.reservations")
        # Trusted fixture administration lowers the operator-owned budget. This
        # does not grant the public publisher a table mutation capability.
        self.admin.execute("ALTER TABLE asm_publication.owners DISABLE TRIGGER USER;UPDATE asm_publication.owners SET max_reserved_bytes=128;ALTER TABLE asm_publication.owners ENABLE TRIGGER USER")
        changed = deepcopy(self.manifest); changed["version"] = "1.0.1"
        self.assertEqual(self.create(key="6" * 32, manifest=changed)[2]["error"]["code"], "owner_quota_exceeded")
        self.admin.execute("ALTER TABLE asm_publication.owners DISABLE TRIGGER USER;UPDATE asm_publication.owners SET max_reserved_bytes=1073741824;ALTER TABLE asm_publication.owners ENABLE TRIGGER USER")
        self.admin.execute("""INSERT INTO asm_publication.tasks(id,owner_id,package_id,credential_id,idempotency_key,name,version,manifest,manifest_sha256,declared_bytes,state,upload_expires_at,accepted_at,failure)
            SELECT lpad(to_hex(g),32,'0'),owner_id,package_id,credential_id,lpad(to_hex(g),32,'0'),name,version,manifest,manifest_sha256,declared_bytes,state,
                upload_expires_at,accepted_at,failure FROM asm_publication.tasks CROSS JOIN generate_series(1,4095) g WHERE id=$1""", [task])
        self.assertEqual(self.create(key="6" * 32, manifest=changed)[2]["error"]["code"], "registry_quota_exceeded")
        self.assertEqual(self.create()[0:2], (200, task))

    def test_private_operator_cli_replays_without_renewing_or_printing_credentials(self):
        work = self.base / secrets.token_hex(6); work.mkdir(mode=0o700)
        files = {}
        for role in ("asm_migrator", "asm_operator"):
            path = work / (role + ".url")
            path.write_text(self.connection_url(role, operator=True) + "\n"); path.chmod(0o600)
            files[role] = path
        def command(role, *args):
            return subprocess.run([sys.executable, str(ROOT / "tools/publisher_admin.py"),
                "--connection-file", str(files[role]), "--psql", str(Path(os.environ["ASM_PROTO_PG_BINDIR"]) / "psql"), *args],
                capture_output=True, timeout=35, env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})
        migrated = command("asm_migrator", "migrate")
        self.assertEqual(migrated.returncode, 0, migrated.stderr.decode())
        self.assertEqual(json.loads(migrated.stdout)["migration_sha384"], self.migration_sha)
        owner, credential = "9" * 32, "8" * 32
        enrolled = command("asm_operator", "enroll", "--owner-id", owner, "--namespace", "operations", "--reference", "private-operator-fixture")
        self.assertEqual(enrolled.returncode, 0, enrolled.stderr.decode())
        token_file = work / "publish.token"
        arguments = ["issue", "--owner-id", owner, "--credential-id", credential, "--package", "operations/hello",
            "--operation", "task-read", "--token-file", str(token_file), "--ttl-seconds", "60", "--reference", "private-operator-fixture"]
        issued = command("asm_operator", *arguments)
        self.assertEqual(issued.returncode, 0, issued.stderr.decode())
        token = token_file.read_text().strip()
        self.assertNotIn(token.encode(), issued.stdout + issued.stderr)
        expires = self.admin.execute("SELECT expires_at::text FROM asm_publication.credentials WHERE id=$1", [credential])
        replay = command("asm_operator", *arguments, "--reuse-token-file")
        self.assertEqual(replay.returncode, 0, replay.stderr.decode())
        self.assertNotIn("expires_in_seconds", json.loads(replay.stdout))
        self.assertEqual(self.admin.execute("SELECT expires_at::text FROM asm_publication.credentials WHERE id=$1", [credential]), expires)
        changed = list(arguments); changed[changed.index("60")] = "61"
        refused = command("asm_operator", *changed, "--reuse-token-file")
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(refused.stdout, b"")
        self.assertNotIn(token.encode(), refused.stderr)
        self.assertEqual(token_file.read_text().strip(), token)
        revoked = command("asm_operator", "revoke", "--credential-id", credential, "--reference", "private-operator-fixture")
        self.assertEqual(revoked.returncode, 0, revoked.stderr.decode())
        self.assertEqual(self.admin.execute("SELECT revoked_at IS NOT NULL FROM asm_publication.credentials WHERE id=$1", [credential]), [["t"]])

    def test_prepared_parameter_logs_do_not_retain_bearer_credentials(self):
        self.admin.execute("ALTER ROLE asm_publisher SET log_statement='all';ALTER ROLE asm_publisher SET log_min_duration_statement=0")
        try:
            self.assertEqual(self.create()[0], 202)
            self.assertEqual(self.create(raw='{"schema":2,"schema":2}')[0], 400)
            log = (self.cluster.base / "postgres.log").read_bytes()
            self.assertIn(b"create_publication", log)
            self.assertNotIn(self.token.encode(), log)
        finally:
            self.admin.execute("ALTER ROLE asm_publisher RESET log_statement;ALTER ROLE asm_publisher RESET log_min_duration_statement")


if __name__ == "__main__":
    unittest.main()
