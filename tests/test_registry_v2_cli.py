"""Observe the optional assembly V2 client; Python supplies transport fixtures only.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import http.server
import ssl
import shutil
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


class RegistryV2CliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        supplied = os.environ.get("ASM_REGISTRY_TEST_BINARY")
        if not supplied:
            raise unittest.SkipTest("Set ASM_REGISTRY_TEST_BINARY for the optional native V2 gate")
        cls.binary = Path(supplied).resolve()
        if not cls.binary.is_file():
            raise AssertionError("The selected V2 executable is missing")
        cls.native_target = json.loads(subprocess.check_output(
            [str(cls.binary), "targets", "--json"], timeout=10))["host"]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-v2-", dir=ROOT / "build")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.objects = self.work / "objects"
        self.objects.mkdir(mode=0o700)
        self.token = "asm_pub_v1_" + "a" * 64
        self.credential = self.work / "credential"
        self.credential.write_text(self.token + "\n")
        self.credential.chmod(0o600)
        self.environment = dict(os.environ, HOME=str(self.work), GH_TOKEN="must-not-inherit",
                                CURL_CA_BUNDLE="must-not-inherit", PERL5OPT="must-not-inherit",
                                SSL_CERT_FILE="must-not-inherit", SSL_CERT_DIR="must-not-inherit")

    def cli(self, *arguments, code=0):
        result = subprocess.run([str(self.binary), "registry", *map(str, arguments)],
                                cwd=self.work, env=self.environment, capture_output=True,
                                timeout=20)
        self.assertEqual(result.returncode, code, (result.stdout, result.stderr))
        self.assertNotIn(self.token.encode(), result.stdout + result.stderr)
        self.assertEqual(list(self.work.glob(".asm-registry-*")), [])
        return result

    def test_help_names_exact_commands_and_no_upload_claim(self):
        result = self.cli("--help")
        self.assertIn(b"registry publish", result.stdout)
        self.assertIn(b"registry task", result.stdout)
        self.assertIn(b"registry fetch", result.stdout)
        self.assertIn(b"registry install", result.stdout)

    def test_missing_duplicate_and_unknown_arguments_fail_before_network(self):
        cases = [("publish",), ("task", "b" * 32),
                 ("fetch", "owner/name"), ("install", "owner/name@1.0.0"),
                 ("task", "b" * 32, "--credential-file", self.credential,
                  "--api", "https://registry.example", "--api", "https://other.example"),
                 ("task", "b" * 32, "--token", self.token)]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.cli(*arguments, code=2)

    def test_credential_symlinks_shared_modes_and_invalid_token_fail(self):
        args = ("task", "b" * 32, "--credential-file", self.credential,
                "--api", "https://registry.example")
        self.credential.chmod(0o644)
        self.cli(*args, code=1)
        self.credential.chmod(0o600)
        self.credential.write_text(self.token + "\nInjected: value\n")
        self.cli(*args, code=1)
        self.credential.unlink()
        target = self.work / "actual"
        target.write_text(self.token)
        target.chmod(0o600)
        self.credential.symlink_to(target)
        self.cli(*args, code=1)

    def test_api_origin_refuses_credentials_queries_fragments_and_redirect_aliases(self):
        for origin in ("http://registry.example", "https://user@registry.example",
                       "https://registry.example?q=x", "https://registry.example#x",
                       "https://registry.example/%2e", "https://registry.example/../private"):
            with self.subTest(origin=origin):
                self.cli("task", "b" * 32, "--credential-file", self.credential,
                         "--api", origin, code=2)

    def test_receive_requires_explicit_clean_absolute_trust_paths(self):
        for field in ("root", "state", "ca"):
            with self.subTest(field=field):
                paths = {"root": self.work / "root", "state": self.work / "state", "ca": self.work / "ca"}
                paths[field] = "relative"
                self.cli("fetch", "owner/math@0.1.0", "--registry-id", "7" * 32,
                         "--root", paths["root"], "--state", paths["state"], "--ca", paths["ca"],
                         "--mirror", "https://registry.example", "--target", "x86_64-linux",
                         "--kind", "source", "--output", self.work / "output", code=2)


class _Publisher(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, status, body):
        encoded = json.dumps(body, sort_keys=True, indent=2).encode() + b"\n" if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(encoded)

    def task(self):
        fixture = self.server.fixture
        objects = {fixture.digest: fixture.source} | getattr(fixture, "additional_objects", {})
        received = lambda digest: fixture.received if digest == fixture.digest else digest in fixture.additional_received
        sizes = getattr(fixture, "project_sizes", {digest: len(data) for digest, data in objects.items()})
        return {"schema": 2, "id": "b" * 32, "package_id": "c" * 32,
                "manifest_sha256": hashlib.sha256(fixture.manifest.read_bytes()).hexdigest(),
                "state": getattr(fixture, "forced_state", None) or ("checking" if all(map(received, objects)) else "accepted"),
                "upload_expires_at": "2030-01-01T00:00:00Z", "failure": None,
                "release": getattr(fixture, "forced_release", None),
                "objects": [{"sha256": digest, "bytes": size, "received": received(digest)}
                            for digest, size in sorted(sizes.items())]}

    def authorized(self):
        fixture = self.server.fixture
        fixture.requests.append((self.command, self.path))
        if self.headers.get_all("Authorization") != ["Bearer " + fixture.token]:
            self.respond(401, {"error": "fixture authorization refused"})
            return False
        return True

    def do_POST(self):
        if not self.authorized():
            return
        fixture = self.server.fixture
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if getattr(fixture, "project_mode", False):
            try:
                from tools.publication_check import manifest
                value, declarations = manifest(data)
            except Exception:
                self.respond(400, {"error": "fixture canonical manifest refused"})
                return
            fixture.project_sizes = declarations
            fixture.digest = value["source"]["archive"]["sha256"]
            fixture.manifest.write_bytes(data)
        if self.path != "/api/v2/publications" or data != fixture.manifest.read_bytes():
            self.respond(400, {"error": "fixture manifest mismatch"})
            return
        fixture.key_headers = self.headers.get_all("Idempotency-Key")
        if fixture.response_mode == "redirect":
            self.send_response(307)
            self.send_header("Location", fixture.api + "/credential-leak")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        result = self.task()
        if fixture.response_mode == "wrong-id":
            result["id"] = "wrong"
        self.respond(200 if getattr(fixture, "forced_state", None) else 202, result)

    def do_PUT(self):
        if not self.authorized():
            return
        fixture = self.server.fixture
        if getattr(fixture, "forced_state", None) in ("committed", "distributing", "published"):
            self.respond(409, {"error": "completed tasks do not accept uploads"})
            return
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        objects = {fixture.digest: fixture.source} | fixture.additional_objects
        digest = self.path.rsplit("/", 1)[-1]
        expected = objects.get(digest)
        if getattr(fixture, "project_mode", False):
            expected = data if fixture.project_sizes.get(digest) == len(data) and hashlib.sha256(data).hexdigest() == digest else None
        if self.path != "/api/v2/publications/" + "b" * 32 + "/artifacts/" + digest or expected != data:
            self.respond(422, {"error": "fixture object mismatch"})
            return
        was_received = fixture.received if digest == fixture.digest else digest in fixture.additional_received
        status = 204 if was_received else 201
        if digest == fixture.digest:
            fixture.received = True
            if getattr(fixture, "project_mode", False):
                fixture.source = data
        else:
            fixture.additional_received.add(digest)
        self.respond(status, None if status == 204 else self.task())

    def do_GET(self):
        fixture = self.server.fixture
        if hasattr(fixture, "delivery") and not self.path.startswith("/api/"):
            fixture.requests.append((self.command, self.path))
            path = fixture.delivery / urlsplit(self.path).path.lstrip("/")
            if not path.is_file():
                self.respond(404, None)
                return
            data = path.read_bytes()
            callback = getattr(fixture, "after_blob_read", None)
            if callback is not None and self.path.startswith("/blobs/"):
                fixture.after_blob_read = None
                callback()
            if fixture.corrupt_blob and self.path.startswith("/blobs/"):
                data = b"x" * len(data)
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if not self.authorized():
            return
        self.respond(200, self.task())


class RegistryV2PublicationTests(unittest.TestCase):
    setUpClass = classmethod(RegistryV2CliTests.setUpClass.__func__)
    cli = RegistryV2CliTests.cli

    def setUp(self):
        RegistryV2CliTests.setUp(self)
        from test_publish_cli import registry, source_files
        self.source = registry.make_archive(source_files())
        self.digest = hashlib.sha256(self.source).hexdigest()
        (self.objects / self.digest).write_bytes(self.source)
        self.manifest = self.work / "publication.json"
        publication = {"schema": 2, "name": "owner/math", "version": "0.1.0",
                       "owner_id": "1" * 32, "summary": "Native publication fixture.", "license": "MIT",
                       "source": {"archive": {"sha256": self.digest, "bytes": len(self.source)},
                                  "commit": {"algorithm": "git-sha1", "digest": "a" * 40}, "path": "."},
                       "artifacts": [{"isa": "x86_64", "os": "linux", "abi": "sysv-amd64",
                                      "cpu_features": [], "kind": "source", "format": "tar.gz",
                                      "sha256": self.digest, "bytes": len(self.source)}]}
        self.manifest.write_text(json.dumps(publication, sort_keys=True, indent=2) + "\n")
        self.ca = self.work / "ca.pem"
        key = self.work / "key.pem"
        config = self.work / "tls.cnf"
        config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
                          "[dn]\nCN=localhost\n[ext]\nsubjectAltName=IP:127.0.0.1\n"
                          "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\n")
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(self.ca), "-days", "1", "-config", str(config)],
                       check=True, capture_output=True, timeout=20)
        self.ca.chmod(0o600)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Publisher)
        self.server.fixture = self
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.ca, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.api = "https://127.0.0.1:" + str(self.server.server_port)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.requests = []
        self.key_headers = None
        self.received = False
        self.response_mode = "normal"
        self.additional_objects = {}
        self.additional_received = set()

    def publish(self, code=0, key=None):
        return self.cli("publish", "--manifest", self.manifest, "--objects-dir", self.objects,
                        "--credential-file", self.credential, "--api", self.api,
                        "--idempotency-key", key or "d" * 32, "--ca", self.ca, "--json", code=code)

    def test_real_https_publication_upload_task_and_identical_replay(self):
        first = json.loads(self.publish().stdout)
        self.assertEqual(first["state"], "checking")
        self.assertEqual(self.key_headers, ["d" * 32])
        self.assertTrue(self.received)
        self.assertEqual([method for method, _ in self.requests], ["POST", "PUT", "GET"])
        self.assertEqual(json.loads(self.publish().stdout)["id"], first["id"])
        result = self.cli("task", "b" * 32, "--credential-file", self.credential,
                          "--api", self.api, "--ca", self.ca, "--json")
        self.assertEqual(json.loads(result.stdout)["id"], first["id"])

    def test_corrupt_local_object_fails_before_task_creation(self):
        (self.objects / self.digest).write_bytes(b"x" * len(self.source))
        self.publish(code=1)
        self.assertEqual(self.requests, [])

    def test_shared_writable_ca_is_refused_before_sending_a_credential(self):
        self.ca.chmod(0o666)
        self.publish(code=1)
        self.assertEqual(self.requests, [])

    def test_full_length_namespace_and_package_name_are_supported(self):
        from test_publish_cli import registry, source_files
        name = "n" * 64
        self.source = registry.make_archive(source_files(name=name))
        self.digest = hashlib.sha256(self.source).hexdigest()
        (self.objects / self.digest).write_bytes(self.source)
        publication = json.loads(self.manifest.read_bytes())
        publication["name"] = "o" * 39 + "/" + name
        binding = {"sha256": self.digest, "bytes": len(self.source)}
        publication["source"]["archive"] = binding
        publication["artifacts"][0].update(binding)
        self.manifest.write_text(json.dumps(publication, sort_keys=True, indent=2) + "\n")
        self.publish()
        self.assertTrue(self.received)

    def test_duplicate_and_unknown_fields_fail_before_task_creation(self):
        original = self.manifest.read_text()
        for content in ('{"schema":2,' + original[1:], original.replace('"schema": 2', '"unknown": 1, "schema": 2')):
            self.manifest.write_text(content)
            self.publish(code=1)
            self.assertEqual(self.requests, [])

    def test_authenticated_redirect_is_never_followed(self):
        self.response_mode = "redirect"
        self.publish(code=1)
        self.assertEqual(self.requests, [("POST", "/api/v2/publications")])

    def test_malformed_task_identity_cannot_choose_upload_path(self):
        self.response_mode = "wrong-id"
        self.publish(code=1)
        self.assertEqual(self.requests, [("POST", "/api/v2/publications")])

    def test_source_host_is_descriptive_and_never_fetched(self):
        original = json.loads(self.manifest.read_bytes())
        locators = [None, "https://github.com/example/math", "https://entire.com/et/example/math",
                    "https://gitlab.com/example/math", "https://codeberg.org/example/math"]
        for number, locator in enumerate(locators, 1):
            with self.subTest(locator=locator):
                publication = json.loads(json.dumps(original))
                if locator is not None:
                    publication["source"]["repository"] = locator
                raw = (json.dumps(publication, sort_keys=True, indent=2) + "\n").encode()
                self.manifest.write_bytes(raw)
                self.requests.clear()
                self.received = False
                key = f"{number:032x}"
                result = json.loads(self.publish(key=key).stdout)
                self.assertEqual(result["manifest_sha256"], hashlib.sha256(raw).hexdigest())
                self.assertEqual(self.key_headers, [key])
                self.assertEqual([method for method, _ in self.requests], ["POST", "PUT", "GET"])
                self.assertTrue(self.received)
                self.assertEqual(self.manifest.read_bytes(), raw)

    def test_committed_distributing_and_published_replay_uses_receipts_without_uploading(self):
        self.received = True
        for state in ("committed", "distributing", "published"):
            with self.subTest(state=state):
                self.forced_state = state
                self.requests.clear()
                result = json.loads(self.publish().stdout)
                self.assertEqual(result["state"], state)
                self.assertIsNone(result["release"])
                self.assertEqual([method for method, _ in self.requests], ["POST", "GET"])

    def test_release_links_require_published_task_state(self):
        self.received = True
        self.forced_release = {"manifest_url": self.api + "/release.json",
                               "metadata_url": self.api + "/metadata"}
        for state in ("accepted", "uploading", "checking", "committed", "distributing"):
            with self.subTest(state=state):
                self.forced_state = state
                self.requests.clear()
                self.publish(code=1)
                self.assertEqual([method for method, _ in self.requests], ["POST"])
        self.forced_state = "published"
        result = json.loads(self.publish().stdout)
        self.assertEqual(result["release"], self.forced_release)

    def test_partial_receipts_upload_only_the_missing_declared_object(self):
        from test_publish_cli import elf
        data = elf()
        digest = hashlib.sha256(data).hexdigest()
        self.additional_objects[digest] = data
        (self.objects / digest).write_bytes(data)
        publication = json.loads(self.manifest.read_bytes())
        publication["artifacts"].append({"isa": "x86_64", "os": "linux", "abi": "sysv-amd64",
                                          "cpu_features": [], "kind": "executable", "format": "elf",
                                          "sha256": digest, "bytes": len(data)})
        self.manifest.write_text(json.dumps(publication, sort_keys=True, indent=2) + "\n")
        self.received = True
        self.publish()
        self.assertEqual([method for method, _ in self.requests], ["POST", "PUT", "GET"])
        self.assertEqual(self.requests[1][1].rsplit("/", 1)[-1], digest)
        self.assertEqual(self.additional_received, {digest})


class RegistryV2DistributionTests(unittest.TestCase):
    setUpClass = classmethod(RegistryV2CliTests.setUpClass.__func__)
    cli = RegistryV2CliTests.cli

    def tool(self, *arguments):
        subprocess.run(list(map(str, arguments)), check=True, capture_output=True, timeout=30)

    def setUp(self):
        RegistryV2PublicationTests.setUp(self)
        self.trust = Path(os.environ.get("ASM_REGISTRY_TRUST", ROOT / "build/asm-trust"))
        self.assertTrue(self.trust.is_file(), "Build asm-trust before the native V2 gate")
        openssl = os.environ.get("ASM_REGISTRY_OPENSSL") or shutil.which("openssl")
        self.assertIsNotNone(openssl)
        self.keys = self.work / "keys"
        self.keys.mkdir(mode=0o700)
        roles = ("root1", "root2", "root3", "targets", "snapshot", "timestamp")
        for role in roles:
            key = self.keys / (role + ".pem")
            self.tool(openssl, "genpkey", "-algorithm", "ED25519", "-out", key)
            key.chmod(0o600)
            self.tool(openssl, "pkey", "-in", key, "-pubout", "-out", self.keys / (role + ".pub"))
        unsigned, first = self.work / "unsigned.json", self.work / "first.json"
        self.anchor = self.work / "root.json"
        self.tool(self.trust, "prepare-root", unsigned, *[self.keys / (role + ".pub") for role in roles])
        self.tool(self.trust, "sign-root", unsigned, self.keys / "root1.pem", first)
        self.tool(self.trust, "sign-root", first, self.keys / "root2.pem", self.anchor)
        self.registry_id, self.package_id, self.release_id = "7" * 32, "8" * 32, "9" * 32
        self.publication = json.loads(self.manifest.read_bytes())
        self.state = self.work / "trust-state"
        self.destination = self.work / "download.tar.gz"
        self.corrupt_blob = False
        self.sign(1)

    def sign(self, version, *, yanked=0, revoked=0, policy_package=None, publication=None, fresh=False):
        source = self.work / ("signed-input-" + str(version))
        source.mkdir(mode=0o700)
        publication = publication or self.publication
        envelope = {"schema": 2, "registry_id": self.registry_id, "package_id": self.package_id,
                    "release_id": self.release_id,
                    "manifest_sha256": hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
                    "publication": publication}
        record = source / "release.json"
        record.write_text(json.dumps(envelope, sort_keys=True, indent=2) + "\n")
        policy = source / "policy.tsv"
        policy.write_text(f"# asm-registry-policy-v2\t{self.registry_id}\t{version}\t0\n"
                          f"owner/math\t0.1.0\t{policy_package or self.package_id}\t{self.release_id}\t{yanked}\t{revoked}\n")
        target_map = source / "map.json"
        target_map.write_text(json.dumps({f"registries/{self.registry_id}/releases/owner/math/0.1.0.json": str(record),
                                         f"registries/{self.registry_id}/policy.tsv": str(policy)}))
        output = self.work / ("delivery-" + str(version))
        previous = self.delivery if hasattr(self, "delivery") and not fresh else "-"
        self.tool(self.trust, "publish-registry", self.anchor, self.keys, previous, target_map,
                  output, self.registry_id, version)
        self.delivery = output
        blobs = output / "blobs/sha256"
        blobs.mkdir(parents=True)
        (blobs / self.digest).write_bytes(self.source)
        return output

    def fetch(self, *, mirrors=None, destination=None, code=0, install=False, target="x86_64-linux", kind="source"):
        arguments = ["install" if install else "fetch", "owner/math@0.1.0", "--registry-id", self.registry_id,
                     "--root", self.anchor, "--state", self.state, "--target", target,
                     "--kind", kind, "--output", destination or self.destination, "--ca", self.ca]
        for mirror in mirrors or [self.api]:
            arguments.extend(["--mirror", mirror])
        return self.cli(*arguments, code=code)

    def test_real_tuf_source_fetch_and_ordered_mirror_failover(self):
        self.fetch(mirrors=[self.api + "/absent", self.api])
        self.assertEqual(self.destination.read_bytes(), self.source)
        self.assertEqual(self.destination.stat().st_mode & 0o111, 0)
        self.assertTrue(any(path.startswith("/absent/") for _, path in self.requests))
        expected = ("/blobs/sha256/" + self.digest + "?x-asm=" + ".".join([
            self.registry_id, self.package_id, self.release_id, "x86_64-linux", "source"]))
        self.assertTrue(any(path == expected for _, path in self.requests))

    def test_source_fetch_checks_signed_dependencies_against_archive_declarations(self):
        from test_publish_cli import registry, source_files
        files = source_files()
        data, mode = files["asm.toml"]
        files["asm.toml"] = (data + b'\n[dependencies]\n"other/math" = "^1.0.0"\n', mode)
        self.source = registry.make_archive(files)
        self.digest = hashlib.sha256(self.source).hexdigest()
        self.publication["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.source)}
        self.publication["artifacts"][0].update(sha256=self.digest, bytes=len(self.source))
        self.publication["dependencies"] = [{"name": "other/math", "requirement": "^1.0.0"}]
        self.manifest.write_bytes(registry.json_bytes(self.publication))
        self.sign(2, fresh=True)
        self.fetch()
        self.assertEqual(self.destination.read_bytes(), self.source)
        self.destination.unlink()
        self.publication["dependencies"][0]["requirement"] = "~1.0.0"
        self.manifest.write_bytes(registry.json_bytes(self.publication))
        self.sign(3, fresh=True)
        self.requests.clear()
        self.fetch(code=1)
        self.assertTrue(any(path.startswith("/blobs/") for _, path in self.requests))
        self.assertFalse(self.destination.exists())

    def test_corrupt_blob_and_existing_output_preserve_files(self):
        self.corrupt_blob = True
        self.fetch(code=1)
        self.assertFalse(self.destination.exists())
        self.corrupt_blob = False
        self.destination.write_bytes(b"keep")
        self.fetch(code=1)
        self.assertEqual(self.destination.read_bytes(), b"keep")

    def test_signed_yank_and_stale_metadata_refuse_installation(self):
        original = self.delivery
        self.fetch()
        self.destination.unlink()
        self.sign(2, yanked=1)
        self.fetch(code=1)
        self.assertFalse(self.destination.exists())
        self.delivery = original
        self.fetch(code=1)
        self.assertFalse(self.destination.exists())

    def test_policy_changed_during_blob_transfer_blocks_final_exposure(self):
        self.after_blob_read = lambda: self.sign(2, revoked=1)
        self.fetch(code=1)
        self.assertFalse(self.destination.exists())
        self.assertTrue(any(path.startswith("/blobs/") for _, path in self.requests))
        policy_reads = [index for index, (_, path) in enumerate(self.requests) if path.endswith(".policy.tsv")]
        self.assertGreaterEqual(len(policy_reads), 2)
        self.destination.write_bytes(b"keep existing destination")
        self.fetch(code=1)
        self.assertEqual(self.destination.read_bytes(), b"keep existing destination")

    def test_signed_policy_identity_mismatch_is_refused(self):
        self.sign(2, policy_package="a" * 32)
        self.fetch(code=1)
        self.assertFalse(self.destination.exists())

    def test_unsigned_target_corruption_and_cross_registry_state_are_refused(self):
        self.fetch()
        self.destination.unlink()
        for path in (self.delivery / "targets").rglob("*.json"):
            path.write_bytes(path.read_bytes() + b" ")
        self.fetch(code=1)
        self.assertFalse(self.destination.exists())
        self.registry_id = "f" * 32
        self.fetch(code=1)
        self.assertFalse(self.destination.exists())

    def test_signed_unsupported_cpu_features_fail_before_blob_transfer(self):
        changed = json.loads(json.dumps(self.publication))
        changed["artifacts"][0]["cpu_features"] = ["invented-feature"]
        # A first malicious signed view tests client schema rejection. Normal
        # publication refuses rewriting the already retained release bytes.
        self.sign(2, publication=changed, fresh=True)
        self.requests.clear()
        self.fetch(code=1)
        self.assertFalse(any(path.startswith("/blobs/") for _, path in self.requests))
        self.assertFalse(self.destination.exists())

    def test_native_executable_receipt_replay_and_v1_upgrade_refusal(self):
        target = self.native_target
        if target == "x86_64-macos":
            self.fetch(install=True, target=target, kind="executable", code=2)
            self.assertFalse(self.destination.exists())
            return
        from test_publish_cli import registry, source_files
        tuples = {"x86_64-linux": ("x86_64", "linux", "sysv-amd64", "elf"),
                  "aarch64-linux": ("aarch64", "linux", "aapcs64", "elf"),
                  "aarch64-macos": ("aarch64", "macos", "apple-arm64", "macho")}
        isa, system, abi, format_name = tuples[target]
        self.source = registry.make_archive(source_files(target=target))
        self.digest = hashlib.sha256(self.source).hexdigest()
        self.publication["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.source)}
        executable = self.binary.read_bytes()
        executable_sha = hashlib.sha256(executable).hexdigest()
        common = {"isa": isa, "os": system, "abi": abi, "cpu_features": []}
        self.publication["artifacts"] = [
            common | {"kind": "source", "format": "tar.gz", "sha256": self.digest, "bytes": len(self.source)},
            common | {"kind": "executable", "format": format_name, "sha256": executable_sha, "bytes": len(executable)}]
        self.manifest.write_text(json.dumps(self.publication, sort_keys=True, indent=2) + "\n")
        self.sign(2, fresh=True)
        (self.delivery / "blobs/sha256" / executable_sha).write_bytes(executable)
        self.fetch(install=True, target=target, kind="executable")
        self.assertEqual(self.destination.read_bytes(), executable)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o755)
        inventory = self.work / ".local/state/asm/installed.tsv"
        record = inventory.read_text().splitlines()[1].split("\t")
        envelope = self.work / "signed-input-2/release.json"
        expected = ":".join(["v2", self.registry_id, hashlib.sha256(self.anchor.read_bytes()).hexdigest(),
                             self.package_id, self.release_id, hashlib.sha256(envelope.read_bytes()).hexdigest()])
        self.assertEqual(record[-1], expected)
        before = inventory.read_bytes()
        self.fetch(install=True, target=target, kind="executable")
        self.assertEqual(inventory.read_bytes(), before)
        requests = len(self.requests)
        result = subprocess.run([str(self.binary), "upgrade", "owner/math"], cwd=self.work,
                                env=self.environment, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"registry V2", result.stderr)
        self.assertEqual(len(self.requests), requests)
        self.assertEqual(self.destination.read_bytes(), executable)
        self.destination.write_bytes(b"changed")
        self.fetch(install=True, target=target, kind="executable", code=1)
        self.assertEqual(self.destination.read_bytes(), b"changed")
        self.assertEqual(inventory.read_bytes(), before)
