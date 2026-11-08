"""Owned HTTP/TLS publisher fixtures; Python is test orchestration only.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import secrets
import select
import socket
import subprocess
import sys
import time
import unittest
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server"))
sys.path.insert(0, str(ROOT / "tools"))
import registry
import test_runtime as reader_fixture
spec = importlib.util.spec_from_file_location("publisher_authority_fixture", ROOT / "tests/publisher/test_authority.py")
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)


class PublisherRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        value = os.environ.get("ASM_PUBLISHER_BINARY")
        if not value or not Path(value).is_file():
            raise AssertionError("ASM_PUBLISHER_BINARY must identify a built publisher; no HTTP checks ran.")
        cls.binary = Path(value).resolve()
        cls.revision = os.environ["ASM_SERVER_SOURCE_REVISION"]
        fixture_type = fixture_module.PublisherAuthorityTests
        fixture_type.setUpClass()
        cls.addClassCleanup(fixture_type.doClassCleanups)
        cls.authority = fixture_type("test_role_isolation_and_pinned_readiness")
        cls.authority.setUp()
        cls.addClassCleanup(cls.authority.doCleanups)
        cls.base = cls.authority.base
        cls.uploads = cls.base / "http-uploads"
        cls.uploads.mkdir(mode=0o700)
        cls.port = reader_fixture.free_port()
        cls.connection_file = cls.base / "publisher.url"
        certs = cls.authority.cluster.base
        params = "&".join(key + "=" + quote(str(certs / name), safe="/") for key, name in (
            ("sslrootcert", "ca.crt"), ("sslcert", "asm_publisher.crt"), ("sslkey", "asm_publisher.key")))
        cls.connection_file.write_text(f"postgresql://asm_publisher@localhost:{cls.authority.cluster.port}/"
            f"{cls.authority.dbname}?sslmode=verify-full&{params}&hostaddr=127.0.0.1\n")
        cls.connection_file.chmod(0o600)
        cls.log = (cls.base / "publisher.log").open("wb")
        cls.addClassCleanup(cls.log.close)
        cls.addClassCleanup(cls.stop_server)
        cls.start_server()
        cls.version = 0

    @classmethod
    def environment(cls, **changes):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
        env.update(ASM_BIND=f"127.0.0.1:{cls.port}", ASM_DATABASE_URL_FILE=str(cls.connection_file),
                   ASM_UPLOAD_ROOT=str(cls.uploads))
        env.update(changes)
        return env

    @classmethod
    def start_server(cls):
        cls.server = subprocess.Popen([str(cls.binary), "serve"], env=cls.environment(), stdout=cls.log, stderr=cls.log)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                raise AssertionError(f"Publisher startup failed ({cls.server.returncode}); inspect fixed diagnostics.")
            try:
                if cls.request("GET", "/health/live")[0] == 200:
                    return
            except OSError:
                time.sleep(0.02)
        raise AssertionError("Publisher did not become live within five seconds.")

    stop_server = reader_fixture.RuntimeTests.__dict__["stop_server"]

    @classmethod
    def request(cls, method, path, body=None, headers=()):
        connection = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=5)
        try:
            connection.putrequest(method, path)
            for name, value in headers:
                connection.putheader(name, value)
            if body is not None and not any(key.lower() == "content-length" for key, _ in headers):
                connection.putheader("Content-Length", str(len(body)))
            connection.endheaders(body)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def headers(self, media=None):
        result = [("Authorization", "Bearer " + self.authority.token)]
        return result + ([("Content-Type", media)] if media else [])

    def problem(self, response, status, code):
        actual, headers, raw = response
        self.assertEqual(actual, status, raw)
        value = json.loads(raw)
        self.assertEqual(set(value), {"type", "title", "status", "detail", "code", "retryable"})
        self.assertEqual(value["type"], "urn:asm:publication:error:" + code)
        self.assertEqual(value["status"], status)
        self.assertEqual(value["code"], code)
        self.assertIs(value["retryable"], status in (429, 503))
        self.assertEqual(headers["Content-Type"], "application/problem+json")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertTrue(value["detail"])
        if status == 401:
            self.assertEqual(headers["WWW-Authenticate"], 'Bearer realm="Asm publication"')
        if status in (429, 503):
            self.assertEqual(headers["Retry-After"], "1")
        return raw

    def create(self, data=None):
        type(self).version += 1
        version = "1.0." + str(self.version)
        project = f'[package]\nname = "hello"\nversion = "{version}"\n\n[target.x86_64-linux]\nsource = "src/main.s"\n'
        data = data if data is not None else registry.make_archive({"asm.toml": (project.encode(), 0o644),
            "LICENSE": (b"Synthetic MIT fixture.\n", 0o644), "README.md": (b"Owned HTTP fixture.\n", 0o644),
            "src/main.s": (b".global _start\n_start: nop\n", 0o644)})
        digest = hashlib.sha256(data).hexdigest()
        manifest = deepcopy(self.authority.manifest)
        manifest["version"] = version
        manifest["source"]["archive"] = {"sha256": digest, "bytes": len(data)}
        manifest["artifacts"][0].update(sha256=digest, bytes=len(data))
        body, key = registry.json_bytes(manifest), secrets.token_hex(16)
        code, headers, raw = self.request("POST", "/api/v2/publications", body,
            self.headers("application/json") + [("Idempotency-Key", key)])
        self.assertEqual(code, 202, raw)
        task = json.loads(raw)
        self.assertEqual(headers["Location"], "/api/v2/publications/" + task["id"])
        self.assertEqual(task["manifest_sha256"], hashlib.sha256(body).hexdigest())
        return task, body, key, data

    def put(self, task, data, *, digest=None):
        path = "/api/v2/publications/" + task["id"] + "/artifacts/" + (digest or hashlib.sha256(data).hexdigest())
        return self.request("PUT", path, data, self.headers("application/octet-stream"))

    def test_routes_require_current_direct_credentials(self):
        for method, path, body in (("POST", "/api/v2/publications", b"{}\n"),
            ("GET", "/api/v2/publications/" + "1" * 32, None),
            ("PUT", "/api/v2/publications/" + "1" * 32 + "/artifacts/" + "a" * 64, b"x")):
            with self.subTest(method=method):
                code, headers, raw = self.request(method, path, body)
                self.assertEqual(code, 401, raw)
                self.assertEqual(json.loads(raw)["code"], "invalid_credential")
                self.assertEqual(headers["Content-Type"], "application/problem+json")
                self.assertEqual(headers["Cache-Control"], "no-store")

    def test_all_credential_refusals_use_the_same_problem_and_bearer_challenge(self):
        path = "/api/v2/publications/" + "0" * 32
        missing = self.request("GET", path)
        self.assertEqual(missing[0], 401)
        baseline = missing[2]
        revoked, expired = ("asm_pub_v1_" + secrets.token_hex(32) for _ in range(2))
        credential = secrets.token_hex(16)
        self.authority.issue(credential, self.authority.owner, revoked, ["fixture/hello"])
        self.authority.run_role("asm_operator", "SELECT asm_publication.revoke_credential($1,$2)",
            [credential, "owned-http-revocation"])
        self.authority.run_role("asm_operator", "SELECT asm_publication.issue_credential($1,$2,$3,$4::text[],'1 second',$5)",
            [secrets.token_hex(16), self.authority.owner, hashlib.sha256(expired.encode()).hexdigest(),
             "{fixture/hello}", "owned-http-expiry"])
        time.sleep(1.1)
        for token in ("asm_pub_v1_" + "f" * 64, revoked, expired, "malformed"):
            headers = [("Authorization", "Bearer " + token)]
            for method, selected, body, extra in (("GET", path, None, []),
                ("POST", "/api/v2/publications", registry.json_bytes(self.authority.manifest),
                 [("Content-Type", "application/json"), ("Idempotency-Key", secrets.token_hex(16))]),
                ("PUT", path + "/artifacts/" + "e" * 64, b"x", [("Content-Type", "application/octet-stream")])):
                with self.subTest(credential_class=("malformed" if token == "malformed" else "unavailable"), method=method):
                    raw = self.problem(self.request(method, selected, body, headers + extra), 401, "invalid_credential")
                    self.assertEqual(raw, baseline)
        self.problem(missing, 401, "invalid_credential")

    def test_sql_refusals_use_fixed_public_problem_codes(self):
        base = deepcopy(self.authority.manifest)
        standard = self.headers("application/json")
        request = lambda raw, key: self.request("POST", "/api/v2/publications", raw,
            standard + [("Idempotency-Key", key)])
        self.problem(request(b"{}\n", secrets.token_hex(16)), 400, "invalid_request")
        base["name"] = "outside/hello"
        self.problem(request(registry.json_bytes(base), secrets.token_hex(16)), 403, "not_authorized")
        task, raw, key, data = self.create()
        changed = json.loads(raw); changed["summary"] = "A changed request under the same key."
        self.problem(request(registry.json_bytes(changed), key), 409, "publication_conflict")
        replacement = "asm_pub_v1_" + secrets.token_hex(32)
        self.authority.issue(secrets.token_hex(16), self.authority.owner, replacement, ["fixture/hello"])
        self.authority.admin.execute("UPDATE asm_publication.tasks SET upload_expires_at=clock_timestamp()-interval '1 second' WHERE id=$1", [task["id"]])
        before = set(self.uploads.iterdir())
        expired_path = "/api/v2/publications/" + task["id"] + "/artifacts/" + hashlib.sha256(data).hexdigest()
        self.problem(self.request("PUT", expired_path, data, [("Authorization", "Bearer " + replacement),
            ("Content-Type", "application/octet-stream")]), 410, "upload_expired")
        self.assertEqual(set(self.uploads.iterdir()), before)
        self.problem(self.request("GET", "/api/v2/publications/" + "0" * 32, headers=self.headers()), 404, "task_not_found")
        owner, token = secrets.token_hex(16), "asm_pub_v1_" + secrets.token_hex(32)
        self.authority.enroll(owner, "httpquota")
        self.authority.issue(secrets.token_hex(16), owner, token, ["httpquota/hello"])
        base = deepcopy(self.authority.manifest)
        base.update(owner_id=owner, name="httpquota/hello")
        quota_headers = [("Authorization", "Bearer " + token), ("Content-Type", "application/json")]
        for attempt in range(10):
            base["version"] = "1.0." + str(attempt)
            response = self.request("POST", "/api/v2/publications", registry.json_bytes(base),
                quota_headers + [("Idempotency-Key", secrets.token_hex(16))])
            if response[0] == 429:
                self.problem(response, 429, "admission_limited")
                break
            self.assertEqual(response[0], 202, response[2])
        else:
            self.fail("The bounded initial owner admission limit was not enforced.")

    def test_validated_database_statuses_never_expose_private_error_payloads(self):
        # Trusted fixture administration substitutes only the bounded database
        # result. This probes transport handling, not publisher authorization.
        admin = self.authority.admin
        original = admin.execute("SELECT pg_get_functiondef('asm_publication.read_publication(text,text)'::regprocedure)")[0][0]
        cases = {400: "invalid_request", 401: "invalid_credential", 403: "not_authorized", 404: "task_not_found",
            409: "publication_conflict", 410: "upload_expired", 413: "limit_exceeded", 415: "unsupported_media_type",
            422: "artifact_invalid", 429: "admission_limited", 503: "temporarily_unavailable"}
        try:
            for status in (*cases, 418, 500):
                admin.execute("CREATE OR REPLACE FUNCTION asm_publication.read_publication(token text,p_task text) "
                    "RETURNS TABLE(status text,task_id text,body text) LANGUAGE sql SECURITY DEFINER "
                    "SET search_path=pg_catalog,pg_temp AS $fixture$ "
                    f"SELECT '{status}'::text,''::text,'{{\"error\":{{\"code\":\"private-fixture-marker\"}}}}'::text $fixture$")
                selected = status if status in cases else 503
                with self.subTest(database_status=status):
                    raw = self.problem(self.request("GET", "/api/v2/publications/" + "0" * 32,
                        headers=self.headers()), selected, cases[selected])
                    self.assertNotIn(b"private-fixture-marker", raw)
        finally:
            admin.execute(original)

    def test_status_labels_operator_declared_source_as_a_source_build(self):
        code, headers, raw = self.request("GET", "/api/v2/status")
        self.assertEqual(code, 200, raw)
        value = json.loads(raw)
        self.assertEqual(value, {"service": "asm-publisher", "status": "source-build-only",
            "application_language": "assembly", "declared_source_revision": self.revision,
            "declared_source_url": "https://github.com/stubbi/asm/tree/" + self.revision})
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_http_upload_reaches_retained_intent_through_the_real_coordinator(self):
        import publication_check
        import publication_worker
        from registry_storage import LocalBlobStore
        task, manifest, _, data = self.create()
        self.assertEqual(self.put(task, data)[0], 201)
        self.authority.run_role("asm_operator", "SELECT asm_publication.set_check_policy($1,$2,$3)",
            [self.revision, publication_check.policy_digest(), "owned-http-check-policy"])
        authority = self.authority
        class WorkerConnection:
            def execute(self, sql):
                rows = authority.run_role("asm_publication_worker", sql)
                self_outer.assertEqual(len(rows), 1)
                return rows[0][0] + "\n"
        self_outer = self
        store = LocalBlobStore(self.base / "retained")
        checker = lambda identity, selected, objects: publication_check.check(identity, selected, objects, self.revision)
        for _ in range(16):
            result = publication_worker.run_one(WorkerConnection(), store, self.uploads, secrets.token_hex(16), checker)
            self.assertIsNotNone(result)
            if result["id"] == task["id"]:
                break
        else:
            self.fail("The owned task was not checked within the bounded fixture work queue.")
        self.assertEqual(result["state"], "committed")
        self.assertEqual(store.get_blob(hashlib.sha256(data).hexdigest(), len(data)), data)
        key = "publications/v2/intents/" + hashlib.sha256(manifest).hexdigest() + ".json"
        self.assertEqual(store.read_object(key, 65536)[0], manifest)
        self.assertIsNone(result["release"])
        # This exercises coordination with a trusted in-process checker fixture.
        # Separate container tests qualify isolation; no native V2 install occurs.

    def test_entire_create_retry_upload_restart_and_exact_bytes(self):
        task, body, key, data = self.create()
        code, _, raw = self.request("POST", "/api/v2/publications", body,
            self.headers("application/json") + [("Idempotency-Key", key)])
        self.assertEqual(code, 200, raw)
        self.assertEqual(json.loads(raw)["id"], task["id"])
        code, _, raw = self.put(task, data)
        self.assertEqual(code, 201, raw)
        self.assertEqual(json.loads(raw)["state"], "checking")
        path = self.uploads / (task["id"] + "-" + hashlib.sha256(data).hexdigest())
        self.assertEqual(path.read_bytes(), data)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.uploads.glob(".upload-*")))
        self.stop_server(); self.start_server()
        self.assertEqual(self.put(task, data)[0], 204)
        code, _, raw = self.request("GET", "/api/v2/publications/" + task["id"], headers=self.headers())
        self.assertEqual(code, 200, raw)
        self.assertTrue(json.loads(raw)["objects"][0]["received"])
        self.assertIsNone(json.loads(raw)["release"])

    def test_duplicate_headers_queries_and_encoded_paths_create_no_files(self):
        before = set(self.uploads.iterdir())
        headers = self.headers("application/json") + [("Idempotency-Key", "1" * 32)]
        for field, value in (("Authorization", "Bearer " + self.authority.token),
            ("Content-Length", "3"), ("Content-Type", "application/json"), ("Idempotency-Key", "1" * 32)):
            with self.subTest(field=field):
                code, _, _ = self.request("POST", "/api/v2/publications", b"{}\n",
                    headers + [("Content-Length", "3"), (field, value)])
                self.assertIn(code, (400, 431))
        for path in ("/api/v2/publications?", "/api/v2/publications?x=1", "/api/v2/%70ublications"):
            self.assertEqual(self.request("POST", path, b"{}\n", headers)[0], 400)
        self.assertEqual(set(self.uploads.iterdir()), before)

    def test_interrupted_and_wrong_digest_uploads_preserve_receipts(self):
        task, _, _, data = self.create(secrets.token_bytes(131072))
        digest = hashlib.sha256(data).hexdigest()
        path = "/api/v2/publications/" + task["id"] + "/artifacts/" + digest
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as sock:
            head = (f"PUT {path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {self.authority.token}\r\n"
                    f"Content-Type: application/octet-stream\r\nContent-Length: {len(data)}\r\n\r\n")
            sock.sendall(head.encode() + data[:4096])
        time.sleep(0.1)
        deadline = time.monotonic() + 3
        while list(self.uploads.glob(".upload-*")) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(list(self.uploads.glob(".upload-*")))
        wrong = bytes([data[0] ^ 1]) + data[1:]
        code, _, raw = self.put(task, wrong, digest=digest)
        self.assertEqual(code, 422, raw)
        self.assertFalse((self.uploads / (task["id"] + "-" + digest)).exists())
        code, _, raw = self.request("GET", "/api/v2/publications/" + task["id"], headers=self.headers())
        self.assertEqual(code, 200, raw)
        self.assertFalse(json.loads(raw)["objects"][0]["received"])
        self.assertEqual(self.put(task, data)[0], 201)

    def test_corrupt_existing_file_is_never_replaced(self):
        task, _, _, data = self.create()
        path = self.uploads / (task["id"] + "-" + hashlib.sha256(data).hexdigest())
        path.write_bytes(b"!" + data[1:]); path.chmod(0o600)
        code, _, raw = self.put(task, data)
        self.assertEqual(code, 503, raw)
        self.assertEqual(path.read_bytes(), b"!" + data[1:])

    def test_database_receipt_failure_preserves_complete_file_for_retry(self):
        task, _, _, data = self.create()
        admin = self.authority.admin
        admin.execute("CREATE FUNCTION public.asm_fail_receipt() RETURNS trigger LANGUAGE plpgsql AS $$"
                      "BEGIN RAISE EXCEPTION 'synthetic receipt dependency failure'; END $$")
        admin.execute("CREATE TRIGGER asm_fail_receipt BEFORE UPDATE OF received_at ON asm_publication.objects "
                      "FOR EACH ROW EXECUTE FUNCTION public.asm_fail_receipt()")
        try:
            code, headers, raw = self.put(task, data)
            self.assertEqual(code, 503, raw)
            self.assertEqual(headers["Retry-After"], "1")
            self.assertNotIn(b"synthetic receipt dependency failure", raw)
            path = self.uploads / (task["id"] + "-" + hashlib.sha256(data).hexdigest())
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(admin.execute("SELECT received_at IS NULL FROM asm_publication.objects WHERE task_id=$1", [task["id"]]), [["t"]])
        finally:
            admin.execute("DROP TRIGGER asm_fail_receipt ON asm_publication.objects")
            admin.execute("DROP FUNCTION public.asm_fail_receipt()")
        self.assertEqual(self.put(task, data)[0], 201)

    def test_hardlinked_or_symlinked_destination_is_never_replaced(self):
        victim = self.base / "unrelated-file"
        victim.write_bytes(b"Unrelated private content."); victim.chmod(0o600)
        for linked in (False, True):
            task, _, _, data = self.create()
            path = self.uploads / (task["id"] + "-" + hashlib.sha256(data).hexdigest())
            if linked:
                os.link(victim, path)
            else:
                path.symlink_to(victim)
            self.assertEqual(self.put(task, data)[0], 503)
            self.assertEqual(victim.read_bytes(), b"Unrelated private content.")

    def test_privileged_or_reader_database_identity_is_refused(self):
        for role in ("asm_reader", "asm_operator"):
            config = self.base / (role + ".url")
            config.write_text(self.connection_file.read_text().replace("asm_publisher", role))
            config.chmod(0o600)
            result = subprocess.run([str(self.binary), "serve"], env=self.environment(ASM_DATABASE_URL_FILE=str(config)),
                                    capture_output=True, timeout=4)
            self.assertEqual(result.returncode, 78)
            self.assertNotIn(b"postgresql://", result.stderr)

    def test_invalid_schema_and_targets_reserve_no_task_or_file(self):
        before = self.authority.admin.execute("SELECT count(*) FROM asm_publication.tasks")
        original = deepcopy(self.authority.manifest)
        for number, raw in enumerate((b'{"schema":2,"schema":2}\n', b"[" * 20 + b"]" * 20,
                    b"{}\0\n", b"\xff", '"é"'.encode(), registry.json_bytes(dict(original, schema=1)))):
            with self.subTest(case=number):
                code, _, body = self.request("POST", "/api/v2/publications", raw,
                    self.headers("application/json") + [("Idempotency-Key", secrets.token_hex(16))])
                self.assertEqual(code, 400, body)
        original["artifacts"][0]["isa"] = "unsupported"
        code, _, body = self.request("POST", "/api/v2/publications", registry.json_bytes(original),
            self.headers("application/json") + [("Idempotency-Key", secrets.token_hex(16))])
        self.assertEqual(code, 400, body)
        self.assertEqual(self.authority.admin.execute("SELECT count(*) FROM asm_publication.tasks"), before)

    def test_nonloopback_and_linked_upload_roots_fail_before_listening(self):
        linked = self.base / "linked-uploads"
        linked.symlink_to(self.uploads, target_is_directory=True)
        (self.uploads / "nested").mkdir(mode=0o700)
        for changes in ({"ASM_BIND": "0.0.0.0:" + str(reader_fixture.free_port())},
                        {"ASM_UPLOAD_ROOT": str(linked)}, {"ASM_UPLOAD_ROOT": str(linked / "nested")}):
            with self.subTest(changes=tuple(changes)):
                result = subprocess.run([str(self.binary), "serve"], env=self.environment(**changes), capture_output=True, timeout=4)
                self.assertEqual(result.returncode, 78)
                self.assertNotIn(self.authority.token.encode(), result.stderr)
                self.assertNotIn(b"postgresql://", result.stderr)

    def test_slow_upload_hits_the_actual_postheader_deadline_and_removes_partial_bytes(self):
        task, _, _, data = self.create(secrets.token_bytes(131072))
        path = "/api/v2/publications/" + task["id"] + "/artifacts/" + hashlib.sha256(data).hexdigest()
        closed = False
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as sock:
            head = (f"PUT {path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {self.authority.token}\r\n"
                    f"Content-Type: application/octet-stream\r\nContent-Length: {len(data)}\r\n\r\n")
            started = time.monotonic()
            sock.sendall(head.encode())
            while time.monotonic() - started < 65:
                if select.select([sock], [], [], 0.5)[0]:
                    self.assertEqual(sock.recv(4096), b"", "The deadline must close this incomplete request.")
                    closed = True
                    break
                try:
                    sock.sendall(b"x")
                except (BrokenPipeError, ConnectionResetError):
                    closed = True
                    break
            elapsed = time.monotonic() - started
        self.assertTrue(closed, "The actual 60-second deadline did not close the incomplete upload.")
        self.assertGreaterEqual(elapsed, 58)
        self.assertLess(elapsed, 64)
        deadline = time.monotonic() + 3
        while list(self.uploads.glob(".upload-*")) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(list(self.uploads.glob(".upload-*")))
        code, _, raw = self.request("GET", "/api/v2/publications/" + task["id"], headers=self.headers())
        self.assertEqual(code, 200, raw)
        self.assertFalse(json.loads(raw)["objects"][0]["received"])


if __name__ == "__main__":
    unittest.main()
