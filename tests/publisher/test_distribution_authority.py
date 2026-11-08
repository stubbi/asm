"""Distribution authority against an owned PostgreSQL 16.15 fixture.

SPDX-License-Identifier: AGPL-3.0-or-later
Synthetic bundle digests exercise SQL binding, not TUF or delivery verification.
"""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry
import registry_admin
import test_authority as fixtures


class DistributionAuthorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture_type = fixtures.PublisherAuthorityTests
        fixture_type.setUpClass()
        cls.fixture_type = fixture_type
        cls.addClassCleanup(fixture_type.doClassCleanups)
        fixture_type.cluster.admin.execute('CREATE ROLE asm_distributor LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
        fixture_type.cluster.certificate("asm_distributor", "asm_distributor")
        fixture_type.cluster.admin.execute("ALTER ROLE asm_distributor SET log_parameter_max_length=0;ALTER ROLE asm_distributor SET log_parameter_max_length_on_error=0")

    def setUp(self):
        self.fixture = self.fixture_type("test_role_isolation_and_pinned_readiness")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.admin = self.fixture.admin
        self.registry_id = "d" * 32
        self.origin = "https://registry.example/asm"
        self.worker = "f" * 32
        self.migration = ROOT / "server/publisher/distribution.sql"
        if self.migration.is_file():
            self.migration_sha = hashlib.sha384(self.migration.read_bytes()).hexdigest()
            self.fixture.run_role("asm_migrator", "BEGIN;" + self.migration.read_text() +
                f"INSERT INTO asm_publication.distribution_schema_version VALUES(2,'{self.migration_sha}');COMMIT;")

    def sql(self, role, operation, *values):
        fields = ",".join("$" + str(i + 1) for i in range(len(values)))
        rows = self.fixture.run_role(role, f"SELECT asm_publication.{operation}({fields})", values)
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(rows[0]), 1)
        return rows[0][0]

    def json(self, operation, *values, role="asm_distributor"):
        raw = self.sql(role, operation, *values)
        value = json.loads(raw)
        self.assertEqual(registry.json_bytes(value).decode(), raw)
        return value

    def configure(self):
        return self.json("configure_distribution", self.registry_id, self.origin, "owned-distribution-fixture", role="asm_operator")

    def commit(self, version="1.0.0"):
        manifest = deepcopy(self.fixture.manifest)
        manifest["version"] = version
        status, task, _ = self.fixture.create(key=secrets.token_hex(16), manifest=manifest)
        self.assertEqual(status, 202)
        objects = self.fixture.uploaded(task, manifest)
        lease = json.loads(self.fixture.claim()[0][0])
        self.assertEqual(lease["task_id"], task)
        result = self.fixture.run_role("asm_publication_worker", "SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
            [task, "2" * 32, lease["fence"], self.fixture.receipt(task, objects, manifest=manifest)])
        self.assertEqual(json.loads(result[0][0])["state"], "committed")
        return task, manifest

    def claim(self, worker=None, refresh=False):
        return self.json("claim_distribution", worker or self.worker, 60, refresh)

    def descriptor(self, batch):
        return {"schema": 2, "batch_id": batch["batch_id"], "source_sha256": batch["source_sha256"],
            "plan_sha256": "1" * 64, "bundle_sha256": "2" * 64, "timestamp_sha256": "3" * 64}

    def seal(self, batch, descriptor=None):
        return self.json("seal_distribution", batch["batch_id"], self.worker, batch["fence"], batch["source_sha256"],
                         registry.json_bytes(descriptor or self.descriptor(batch)).decode())

    def receipt(self, batch):
        return dict(self.descriptor(batch), **{key: batch["source"][key] for key in
                    ("version", "publication_revision", "policy_revision")})

    def finish(self, batch, receipt=None):
        return self.json("finish_distribution", batch["batch_id"], self.worker, batch["fence"],
                         registry.json_bytes(receipt or self.receipt(batch)).decode())

    def test_separate_migration_registry_identity_and_request_isolation(self):
        self.assertEqual(self.admin.execute("SELECT to_regclass('asm_publication.distribution_control') IS NOT NULL"), [["t"]])
        self.configure()
        self.configure()
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.schema_version"), [["1"]])
        self.assertEqual(self.sql("asm_distributor", "distribution_ready", self.migration_sha), "1")
        self.assertEqual(self.sql("asm_distributor", "distribution_ready", "0" * 96), "0")
        self.assertEqual(self.fixture.run_role("asm_publisher", "SELECT asm_publication.publisher_ready($1)", [self.fixture.migration_sha]), [["1"]])
        with self.assertRaises(AssertionError):
            self.json("configure_distribution", "e" * 32, self.origin, "changed-registry", role="asm_operator")
        for role, operation, values in (("asm_reader", "claim_distribution", [self.worker, 60]),
            ("asm_publication_worker", "claim_distribution", [self.worker, 60]),
            ("asm_publisher", "configure_distribution", [self.registry_id, self.origin, "wrong-role"]),
            ("asm_distributor", "set_lifecycle", ["0" * 32, "revoke", "0" * 32, 0, "wrong-role"])):
            with self.subTest(role=role), self.assertRaises(AssertionError):
                self.sql(role, operation, *values)

    def test_frozen_envelope_and_policy_have_exact_independent_identities(self):
        self.configure()
        task, manifest = self.commit()
        batch = self.claim()
        source = batch["source"]
        self.assertEqual(source["registry_id"], self.registry_id)
        self.assertEqual(source["origin"], self.origin)
        self.assertEqual(source["publication_revision"], "1")
        self.assertEqual(source["policy_revision"], "0")
        self.assertEqual(batch["source_sha256"], hashlib.sha256(registry.json_bytes(source)).hexdigest())
        target = f"registries/{self.registry_id}/releases/fixture/hello/1.0.0.json"
        envelope = json.loads(self.sql("asm_distributor", "distribution_release", batch["batch_id"], task))
        self.assertEqual(envelope, {"schema": 2, "registry_id": self.registry_id,
            "package_id": source["releases"][0]["package_id"], "release_id": task,
            "manifest_sha256": hashlib.sha256(registry.json_bytes(manifest)).hexdigest(), "publication": manifest})
        descriptor = source["releases"][0]
        self.assertEqual(descriptor["target"], target)
        self.assertEqual(descriptor["sha256"], hashlib.sha256(registry.json_bytes(envelope)).hexdigest())
        self.assertEqual(descriptor["bytes"], len(registry.json_bytes(envelope)))
        expected = (f"# asm-registry-policy-v2\t{self.registry_id}\t1\t0\nfixture/hello\t1.0.0\t"
                    + descriptor["package_id"] + "\t" + task + "\t0\t0\n")
        self.assertEqual(source["policy_tsv"], expected)
        self.assertEqual(self.fixture.call("read_publication", self.fixture.token, task)[2]["state"], "distributing")
        self.assertEqual(self.admin.execute("SELECT state FROM asm_publication.tasks WHERE id=$1", [task]), [["committed"]])

    def test_seal_recovery_uses_same_reserved_version_and_new_fence(self):
        self.configure(); task, _ = self.commit()
        batch = self.claim(); self.seal(batch)
        changed = self.descriptor(batch); changed["plan_sha256"] = "4" * 64
        with self.assertRaises(AssertionError):
            self.seal(batch, changed)
        self.admin.execute("UPDATE asm_publication.distribution_control SET lease_until=clock_timestamp()-interval '1 second'")
        recovered = self.claim()
        self.assertEqual(recovered["batch_id"], batch["batch_id"])
        self.assertEqual(recovered["source"], batch["source"])
        self.assertEqual(recovered["sealed"], self.descriptor(batch))
        self.assertGreater(recovered["fence"], batch["fence"])
        with self.assertRaises(AssertionError):
            self.finish(batch)
        self.json("renew_distribution", recovered["batch_id"], self.worker, recovered["fence"], recovered["source_sha256"], 60)
        self.json("authorize_distribution_head", recovered["batch_id"], self.worker, recovered["fence"], recovered["source_sha256"])
        head = self.finish(recovered)
        self.assertEqual(head["version"], batch["source"]["version"])
        self.assertEqual(self.finish(recovered), head)
        body = self.fixture.call("read_publication", self.fixture.token, task)[2]
        self.assertEqual(body["state"], "published")
        self.assertTrue(body["release"]["manifest_url"].startswith(self.origin + "/targets/"))
        self.assertEqual(body["release"]["metadata_url"], self.origin + "/metadata/timestamp.json")
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.outbox WHERE event='publication_published'"), [["1"]])
        self.assertIsNone(self.claim())
        refresh = self.claim(refresh=True)
        self.assertGreater(int(refresh["source"]["version"]), int(head["version"]))
        self.assertEqual(refresh["source"]["publication_revision"], "1")

    def test_abandoned_seal_is_retained_and_the_next_attempt_reserves_a_new_version(self):
        self.configure(); task, _ = self.commit()
        batch = self.claim(); self.seal(batch)
        values = (batch["batch_id"], self.worker, batch["fence"], batch["source_sha256"], "reconciled-expired-seal")
        with self.assertRaises(AssertionError):
            self.json("abandon_distribution", batch["batch_id"], self.worker, batch["fence"] + 1,
                      batch["source_sha256"], "stale-fence")
        result = self.json("abandon_distribution", *values)
        self.assertEqual(result, {"schema": 2, "batch_id": batch["batch_id"], "state": "abandoned", "version": batch["source"]["version"]})
        self.assertEqual(self.json("abandon_distribution", *values), result)
        with self.assertRaises(AssertionError):
            self.json("abandon_distribution", *values[:-1], "changed-reconciliation")
        with self.assertRaises(AssertionError):
            self.finish(batch)
        self.assertEqual(self.admin.execute("SELECT phase,sealed FROM asm_publication.distribution_batches WHERE id=$1", [batch["batch_id"]]),
                         [["abandoned", registry.json_bytes(self.descriptor(batch)).decode()]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.audit WHERE action='distribution_abandoned'"), [["1"]])
        following = self.claim()
        self.assertGreater(int(following["source"]["version"]), int(batch["source"]["version"]))
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_members"), [["1"]])
        self.assertEqual(self.fixture.call("read_publication", self.fixture.token, task)[2]["release"], None)

    def test_new_intent_waits_for_the_next_batch_without_starving_the_frozen_snapshot(self):
        self.configure(); first, _ = self.commit()
        old = self.claim(); self.seal(old)
        original = self.sql("asm_distributor", "distribution_release", old["batch_id"], first)
        self.commit("1.0.1")
        self.json("authorize_distribution_head", old["batch_id"], self.worker, old["fence"], old["source_sha256"])
        self.json("renew_distribution", old["batch_id"], self.worker, old["fence"], old["source_sha256"], 60)
        self.finish(old)
        new = self.claim()
        self.assertGreater(int(new["source"]["version"]), int(old["source"]["version"]))
        self.assertEqual(new["source"]["publication_revision"], "2")
        self.assertEqual(len(new["source"]["releases"]), 2)
        self.assertEqual(self.sql("asm_distributor", "distribution_release", old["batch_id"], first), original)
        self.assertEqual(self.admin.execute("SELECT phase FROM asm_publication.distribution_batches WHERE id=$1", [old["batch_id"]]), [["published"]])

    def test_unchanged_refresh_reuses_the_frozen_membership_and_policy(self):
        self.configure(); task, _ = self.commit()
        initial = self.claim(); self.seal(initial); self.finish(initial)
        def payload(batch):
            return {key: value for key, value in batch["source"].items() if key not in ("batch_id", "version")}
        for _ in range(3):
            refresh = self.claim(refresh=True)
            self.assertEqual(payload(refresh), payload(initial))
            self.seal(refresh); self.finish(refresh)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_members"), [["1"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_snapshots"), [["1"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_batches"), [["4"]])
        self.json("set_lifecycle", task, "yank", "4" * 32, 0, "refresh-policy-change", role="asm_operator")
        changed = self.claim(); self.seal(changed); self.finish(changed)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_snapshots"), [["2"]])
        self.commit("1.0.1")
        self.claim()
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_snapshots"), [["3"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_members"), [["4"]])

    def test_lifecycle_is_audited_idempotent_and_revocation_is_monotonic(self):
        self.configure(); task, _ = self.commit()
        first = self.claim(); self.seal(first); self.finish(first)
        original = self.sql("asm_distributor", "distribution_release", first["batch_id"], task)
        operation = "1" * 32
        result = self.json("set_lifecycle", task, "yank", operation, 0, "owned-yank", role="asm_operator")
        self.assertEqual(result["policy_revision"], "1")
        self.assertEqual(self.json("set_lifecycle", task, "yank", operation, 0, "owned-yank", role="asm_operator"), result)
        with self.assertRaises(AssertionError):
            self.json("set_lifecycle", task, "unyank", operation, 1, "changed-operation", role="asm_operator")
        pending = self.claim(); self.seal(pending)
        self.json("set_lifecycle", task, "revoke", "2" * 32, 1, "owned-revocation", role="asm_operator")
        with self.assertRaises(AssertionError):
            self.finish(pending)
        self.json("set_lifecycle", task, "unyank", "3" * 32, 2, "owned-unyank", role="asm_operator")
        with self.assertRaises(AssertionError):
            self.json("set_lifecycle", task, "unrevoke", "4" * 32, 3, "forbidden-reversal", role="asm_operator")
        final = self.claim()
        self.assertEqual(final["source"]["policy_revision"], "3")
        self.assertTrue(final["source"]["policy_tsv"].endswith("\t0\t1\n"))
        self.assertEqual(self.sql("asm_distributor", "distribution_release", final["batch_id"], task), original)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.lifecycle_events"), [["3"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.outbox WHERE event='lifecycle_changed'"), [["3"]])
        self.assertEqual(self.fixture.create(key="9" * 32)[0], 409)

    def test_invalid_receipts_cannot_mark_unexposed_tasks_published(self):
        self.configure(); task, _ = self.commit()
        batch = self.claim()
        with self.assertRaises(AssertionError):
            self.json("authorize_distribution_head", batch["batch_id"], self.worker, batch["fence"], batch["source_sha256"])
        self.seal(batch)
        changed = self.receipt(batch); changed["timestamp_sha256"] = "0" * 64
        with self.assertRaises(AssertionError):
            self.finish(batch, changed)
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.published_releases"), [["0"]])
        self.assertIsNone(self.fixture.call("read_publication", self.fixture.token, task)[2]["release"])
        self.assertEqual(self.admin.execute("SELECT state FROM asm_publication.tasks WHERE id=$1", [task]), [["committed"]])

    def test_flat_profile_overflow_preserves_the_completed_head(self):
        self.configure(); task, _ = self.commit()
        initial = self.claim(); self.seal(initial); self.finish(initial)
        # Trusted fixture inserts model the finite task ceiling. Overflow must
        # fail before export; these rows are not package-check evidence.
        self.admin.execute("""INSERT INTO asm_publication.tasks(id,owner_id,package_id,credential_id,idempotency_key,name,version,manifest,manifest_sha256,declared_bytes,state,upload_expires_at)
            SELECT lpad(to_hex(g),32,'0'),owner_id,package_id,credential_id,lpad(to_hex(g),32,'0'),name,'1.0.'||g,manifest,manifest_sha256,declared_bytes,state,upload_expires_at
            FROM asm_publication.tasks CROSS JOIN generate_series(1,4095) g WHERE id=$1""", [task])
        # Keep the real revision triggers and fixed five-second query deadline.
        # A single synthetic 4095-row transaction exceeded that deadline.
        for lower in range(1, 4096, 256):
            self.admin.execute("""INSERT INTO asm_publication.intents(task_id,package_id,name,version,manifest,manifest_sha256)
                SELECT id,package_id,name,version,manifest,manifest_sha256 FROM asm_publication.tasks WHERE id<>$1
                AND id>=lpad(to_hex($2::integer),32,'0') AND id<lpad(to_hex($3::integer),32,'0')""", [task, lower, lower + 256])
        with self.assertRaises(AssertionError):
            self.claim()
        self.assertEqual(self.admin.execute("SELECT public_version::text,active_batch FROM asm_publication.distribution_control"), [["1", ""]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_batches"), [["1"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.distribution_snapshots"), [["1"]])

    def test_distribution_readiness_refuses_extra_authority_and_parameter_logging(self):
        self.assertEqual(self.sql("asm_distributor", "distribution_ready", self.migration_sha), "1")
        self.admin.execute("CREATE SCHEMA accidental;CREATE TABLE accidental.mutable(value text);GRANT USAGE ON SCHEMA accidental TO asm_distributor;GRANT UPDATE ON accidental.mutable TO asm_distributor")
        self.assertEqual(self.sql("asm_distributor", "distribution_ready", self.migration_sha), "0")
        self.admin.execute("REVOKE UPDATE ON accidental.mutable FROM asm_distributor")
        self.assertEqual(self.sql("asm_distributor", "distribution_ready", self.migration_sha), "1")
        self.admin.execute("GRANT EXECUTE ON FUNCTION asm_publication.revoke_credential(text,text) TO asm_distributor")
        self.assertEqual(self.sql("asm_distributor", "distribution_ready", self.migration_sha), "0")
        self.admin.execute("REVOKE EXECUTE ON FUNCTION asm_publication.revoke_credential(text,text) FROM asm_distributor")
        self.admin.execute("ALTER ROLE asm_distributor SET log_parameter_max_length_on_error=64")
        try:
            self.assertEqual(self.sql("asm_distributor", "distribution_ready", self.migration_sha), "0")
        finally:
            self.admin.execute("ALTER ROLE asm_distributor SET log_parameter_max_length_on_error=0")

    def test_intent_revision_rolls_back_with_the_intent(self):
        self.configure()
        _, task, _ = self.fixture.create()
        objects = self.fixture.uploaded(task)
        lease = json.loads(self.fixture.claim()[0][0])
        connection = self.fixture.connection("asm_publication_worker")
        try:
            connection.execute("BEGIN")
            connection.execute("SELECT asm_publication.complete_check($1,$2,$3::bigint,$4)",
                [task, "2" * 32, lease["fence"], self.fixture.receipt(task, objects)])
            connection.execute("ROLLBACK")
        finally:
            connection.close()
        self.assertEqual(self.admin.execute("SELECT publication_revision FROM asm_publication.distribution_control"), [["0"]])
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.intents"), [["0"]])

    def test_real_checker_signed_distribution_and_mirror_bind_the_same_release(self):
        import publication_check
        import publication_worker
        import registry_distribution
        from registry_storage import LocalBlobStore
        self.configure()
        work = self.fixture.base / secrets.token_hex(6); work.mkdir(mode=0o700)
        data = registry.make_archive({"asm.toml": (b'[package]\nname = "hello"\nversion = "1.0.0"\n[target.x86_64-linux]\nsource = "src/main.s"\n', 0o644),
            "LICENSE": (b"Synthetic fixture under MIT.\n", 0o644), "README.md": (b"Synthetic fixture.\n", 0o644),
            "src/main.s": (b".global _start\n_start: nop\n", 0o644)})
        digest = hashlib.sha256(data).hexdigest()
        manifest = deepcopy(self.fixture.manifest)
        manifest["source"]["archive"] = {"sha256": digest, "bytes": len(data)}
        manifest["artifacts"][0].update(sha256=digest, bytes=len(data))
        self.assertIn("entire.com", manifest["source"]["repository"])
        status, task, _ = self.fixture.create(manifest=manifest)
        self.assertEqual(status, 202)
        path = work / (task + "-" + digest); path.write_bytes(data); path.chmod(0o600)
        self.fixture.uploaded(task, manifest)
        retained = LocalBlobStore(work / "retained")
        public = LocalBlobStore(work / "public")
        mirror = LocalBlobStore(work / "mirror")
        self.fixture.run_role("asm_operator", "SELECT asm_publication.set_check_policy($1,$2,$3)",
            ["7" * 40, publication_check.policy_digest(), "actual-checker-distribution-fixture"])
        connection = self.fixture.connection("asm_publication_worker")
        class Adapter:
            def execute(self, sql): return connection.execute(sql)[0][0]
        try:
            checked = publication_worker.run_one(Adapter(), retained, work, "2" * 32,
                lambda task_id, manifest_file, objects: publication_check.check(task_id, manifest_file, objects, "7" * 40), work_root=work)
        finally:
            connection.close()
        self.assertEqual(checked["state"], "committed")
        trust = Path(os.environ.get("ASM_REGISTRY_TRUST", ROOT / "build/asm-trust"))
        self.assertTrue(trust.is_file(), "Build the native trust helper for the signed distribution gate.")
        keys = work / "keys"; keys.mkdir(mode=0o700)
        def run(*arguments):
            result = subprocess.run([str(value) for value in arguments], capture_output=True, timeout=20,
                env={"PATH": os.defpath, "HOME": "/nonexistent", "LC_ALL": "C", "OPENSSL_CONF": os.devnull})
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        for role in ("root1", "root2", "root3", "targets", "snapshot", "timestamp"):
            run("/usr/bin/openssl", "genpkey", "-algorithm", "ED25519", "-out", keys / (role + ".pem"))
            (keys / (role + ".pem")).chmod(0o600)
            run("/usr/bin/openssl", "pkey", "-in", keys / (role + ".pem"), "-pubout", "-out", keys / (role + ".pub"))
        run(trust, "prepare-root", work / "unsigned.json", *[keys / (role + ".pub")
            for role in ("root1", "root2", "root3", "targets", "snapshot", "timestamp")])
        run(trust, "sign-root", work / "unsigned.json", keys / "root1.pem", work / "first.json")
        anchor = work / "root.json"
        run(trust, "sign-root", work / "first.json", keys / "root2.pem", anchor)
        credential = work / "distributor.url"
        credential.write_text(self.fixture.connection_url("asm_distributor", operator=True) + "\n"); credential.chmod(0o600)
        with registry_admin.Connection(credential, Path(os.environ["ASM_PROTO_PG_BINDIR"]) / "psql", "asm_distributor") as connection:
            self.assertEqual(connection.execute("SELECT asm_publication.distribution_ready(" + registry_admin.sql_text(self.migration_sha) + ");"), "1\n")
            completed = registry_distribution.run_one(connection, retained, public, self.worker, anchor, keys, trust, work)
            self.assertEqual(completed["published_count"], 1)
            self.assertIsNone(registry_distribution.run_one(connection, retained, public, self.worker, anchor, keys, trust, work))
        current = registry_distribution.load_current(public)
        registry_distribution.publish_plan(current[1], public, mirror, work_root=work)
        self.assertEqual(registry_distribution.load_current(mirror)[0], current[0])
        self.assertEqual(mirror.get_blob(digest, len(data)), data)
        body = self.fixture.call("read_publication", self.fixture.token, task)[2]
        self.assertEqual(body["state"], "published")
        key = body["release"]["manifest_url"].removeprefix(self.origin + "/")
        descriptor = next(item for item in current[1]["files"] if item["key"] == key)
        envelope = registry.strict_json(mirror.read_object(key, descriptor["bytes"])[0])
        self.assertEqual(envelope["release_id"], task)
        self.assertEqual(envelope["publication"], manifest)
        self.assertEqual(envelope["manifest_sha256"], hashlib.sha256(registry.json_bytes(manifest)).hexdigest())
        self.assertEqual(self.admin.execute("SELECT count(*) FROM asm_publication.outbox WHERE event='publication_published'"), [["1"]])

    def test_private_distribution_migration_replays_and_refuses_pin_drift(self):
        baseline = self.fixture_type("test_role_isolation_and_pinned_readiness")
        baseline.setUp(); self.addCleanup(baseline.doCleanups)
        work = self.fixture.base / secrets.token_hex(6); work.mkdir(mode=0o700)
        credential = work / "migrator.url"
        credential.write_text(baseline.connection_url("asm_migrator", operator=True) + "\n"); credential.chmod(0o600)
        command = [sys.executable, str(ROOT / "tools/publisher_admin.py"), "--connection-file", str(credential),
            "--psql", str(Path(os.environ["ASM_PROTO_PG_BINDIR"]) / "psql"), "migrate-distribution"]
        result = subprocess.run(command, capture_output=True, timeout=35, env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)["migration_sha384"], self.migration_sha)
        result = subprocess.run(command, capture_output=True, timeout=35, env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(baseline.admin.execute("SELECT sha384 FROM asm_publication.schema_version"), [[self.fixture.migration_sha]])
        baseline.admin.execute("UPDATE asm_publication.distribution_schema_version SET sha384=repeat('0',96)")
        result = subprocess.run(command, capture_output=True, timeout=35, env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(baseline.admin.execute("SELECT sha384 FROM asm_publication.distribution_schema_version"), [["0" * 96]])


if __name__ == "__main__":
    unittest.main()
