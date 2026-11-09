"""Owned native publication, signed distribution, mirror and installation flow.

SPDX-License-Identifier: AGPL-3.0-or-later
Python supplies test orchestration, TLS forwarding and static file serving only.
The checker callback is trusted fixture code; worker isolation has its own gate.
"""
from copy import deepcopy
import hashlib
import http.client
import http.server
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import publication_check
import publication_worker
import build_site
import registry
import registry_admin
import registry_distribution
import registry_log_import
from registry_storage import LocalBlobStore

spec = importlib.util.spec_from_file_location("full_flow_publisher_fixture", ROOT / "server/publisher/test_runtime.py")
runtime_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime_fixture)

PROGRAM = b""".global _start
.section .text
_start:
    mov $257, %eax
    mov $-100, %edi
    lea marker(%rip), %rsi
    mov $193, %edx
    mov $384, %r10d
    syscall
    test %rax, %rax
    js failed
    mov %rax, %rdi
    mov $1, %eax
    lea message(%rip), %rsi
    mov $message_len, %edx
    syscall
    mov $1, %eax
    mov $1, %edi
    lea message(%rip), %rsi
    mov $message_len, %edx
    syscall
    mov $60, %eax
    xor %edi, %edi
    syscall
failed:
    mov $60, %eax
    mov $1, %edi
    syscall
.section .rodata
marker: .asciz "executed.marker"
message: .ascii "Asm full-flow fixture.\\n"
.equ message_len, .-message
.section .note.GNU-stack,"",@progbits
"""


class _WebsitePage(HTMLParser):
    """Read displayed file commands and text, without running page scripts."""
    def __init__(self, raw):
        super().__init__(convert_charrefs=True)
        self.commands, self.text, self.links = [], [], []
        self.artifact = None
        self.command = None
        self.feed(raw.decode("utf-8"))
        self.close()

    def handle_starttag(self, tag, attributes):
        fields = dict(attributes)
        if tag == "a" and "href" in fields:
            self.links.append(fields["href"])
        if tag == "article" and "data-artifact-kind" in fields:
            self.artifact = {"kind": fields["data-artifact-kind"], "target": fields["data-artifact-target"],
                             "declared": fields.get("data-fetch-command")}
        if tag == "code" and self.artifact is not None and fields.get("id", "").startswith("fetch-"):
            self.command = self.artifact | {"text": ""}

    def handle_data(self, data):
        self.text.append(data)
        if self.command is not None:
            self.command["text"] += data

    def handle_endtag(self, tag):
        if tag == "code" and self.command is not None:
            self.commands.append(self.command)
            self.command = None
        if tag == "article":
            self.artifact = None


class _TlsTransport(http.server.BaseHTTPRequestHandler):
    """Forward API bytes unchanged; serve registry files without application policy."""
    def log_message(self, *_): pass

    def forward(self):
        fixture = self.server.fixture
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 <= length <= 1048576:
            self.send_error(413)
            return
        body = self.rfile.read(length) if length else None
        fixture.requests.append((self.command, self.path))
        if self.command == "POST":
            fixture.created_manifest = body
        connection = http.client.HTTPConnection("127.0.0.1", fixture.runtime.port, timeout=8)
        try:
            headers = {key: value for key, value in self.headers.items() if key.lower() in
                       {"authorization", "content-type", "content-length", "idempotency-key"}}
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            fixture.responses.append((self.command, self.path, response.status))
            raw = response.read(1048577)
            if len(raw) > 1048576:
                self.send_error(502)
                return
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() in {"content-type", "location", "cache-control", "www-authenticate", "retry-after"}:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        finally:
            connection.close()

    do_POST = forward
    do_PUT = forward

    def do_GET(self):
        if self.path.startswith("/api/"):
            self.forward()
            return
        self.server.reads.append(self.path)
        relative = self.path.split("?", 1)[0].removeprefix("/")
        if any(part in ("", ".", "..") for part in relative.split("/")) or "?" in relative or "#" in relative:
            self.send_error(404)
            return
        path = self.server.store.root / relative
        if not path.is_file() or path.is_symlink():
            self.send_error(404)
            return
        raw = path.read_bytes()
        if self.server.corrupt and relative.startswith("blobs/"):
            raw = b"!" * len(raw)
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class NativePublicationFullFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli_binary = Path(os.environ.get("ASM_REGISTRY_TEST_BINARY", ROOT / "build/asm-registry-v2")).resolve()
        cls.trust = Path(os.environ.get("ASM_REGISTRY_TRUST", ROOT / "build/asm-trust")).resolve()
        cls.nginx = os.environ.get("ASM_TEST_NGINX") or shutil.which("nginx")
        if not cls.nginx:
            raise AssertionError("Supply ASM_TEST_NGINX for the actual V2 download-log flow; no full-flow checks ran.")
        for path in (cls.cli_binary, cls.trust):
            if not path.is_file():
                raise AssertionError("Supply the built native V2 client and trust helper; no full-flow checks ran.")
        target = json.loads(subprocess.check_output([str(cls.cli_binary), "targets", "--json"], timeout=10))["host"]
        if target != "x86_64-linux":
            raise AssertionError("This full-flow executable fixture requires Linux x86-64.")

    def setUp(self):
        # Compose fixture lifecycle only. Do not inherit its sixteen test methods.
        self.runtime = runtime_fixture.PublisherRuntimeTests
        self.addCleanup(runtime_fixture.fixture_module.PublisherAuthorityTests.doClassCleanups)
        self.addCleanup(self.runtime.doClassCleanups)
        self.runtime.setUpClass()
        self.authority = self.runtime.authority
        self.work = self.authority.base / ("full-flow-" + secrets.token_hex(6))
        self.work.mkdir(mode=0o700)
        self.requests = []
        self.created_manifest = None
        self.project_mode = False
        self.responses = []
        self.registry_id = "d" * 32
        self.token = self.authority.token
        self.credential = self.work / "publisher.token"
        self.credential.write_text(self.token + "\n"); self.credential.chmod(0o600)
        self.objects = self.work / "objects"; self.objects.mkdir(mode=0o700)
        self.retained = LocalBlobStore(self.work / "retained")
        self.public = LocalBlobStore(self.work / "public")
        self.mirror = LocalBlobStore(self.work / "mirror")
        self.ca = self.work / "ca.pem"
        key = self.work / "tls.key"
        config = self.work / "tls.cnf"
        config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n"
                          "[ext]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n"
                          "keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\n")
        self.tool("/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                  "-out", self.ca, "-days", "1", "-config", config)
        key.chmod(0o600); self.ca.chmod(0o600)
        self.tls_key = key
        self.origin = self.serve(self.public)
        self.mirror_origin = self.serve(self.mirror)
        cluster = self.authority.cluster
        cluster.admin.execute("CREATE ROLE asm_distributor LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS")
        cluster.certificate("asm_distributor", "asm_distributor")
        cluster.admin.execute("ALTER ROLE asm_distributor SET log_parameter_max_length=0;ALTER ROLE asm_distributor SET log_parameter_max_length_on_error=0")
        migration = (ROOT / "server/publisher/distribution.sql").read_bytes()
        self.authority.run_role("asm_migrator", "BEGIN;" + migration.decode() +
            "INSERT INTO asm_publication.distribution_schema_version VALUES(2,'" + hashlib.sha384(migration).hexdigest() + "');COMMIT;")
        self.authority.run_role("asm_operator", "SELECT asm_publication.configure_distribution($1,$2,$3)",
            [self.registry_id, self.origin, "owned-native-full-flow"])
        self.authority.run_role("asm_operator", "SELECT asm_publication.set_check_policy($1,$2,$3)",
            ["7" * 40, publication_check.policy_digest(), "owned-native-full-flow"])
        self.distributor_file = self.work / "distributor.url"
        self.distributor_file.write_text(self.authority.connection_url("asm_distributor", operator=True) + "\n")
        self.distributor_file.chmod(0o600)
        self.keys = self.work / "keys"; self.keys.mkdir(mode=0o700)
        roles = ("root1", "root2", "root3", "targets", "snapshot", "timestamp")
        for role in roles:
            private = self.keys / (role + ".pem")
            self.tool("/usr/bin/openssl", "genpkey", "-algorithm", "ED25519", "-out", private)
            private.chmod(0o600)
            self.tool("/usr/bin/openssl", "pkey", "-in", private, "-pubout", "-out", self.keys / (role + ".pub"))
        self.anchor = self.work / "root.json"
        self.tool(self.trust, "prepare-root", self.work / "unsigned.json", *[self.keys / (role + ".pub") for role in roles])
        self.tool(self.trust, "sign-root", self.work / "unsigned.json", self.keys / "root1.pem", self.work / "first.json")
        self.tool(self.trust, "sign-root", self.work / "first.json", self.keys / "root2.pem", self.anchor)
        self.environment = dict(os.environ, HOME=str(self.work), GH_TOKEN="must-not-inherit",
                                CURL_CA_BUNDLE="must-not-inherit", PERL5OPT="must-not-inherit")
        self.state = self.work / "trust-state"
        self.destination = self.work / "installed-hello"
        self.marker = self.work / "executed.marker"
        self.website_root = self.work / "site-publications"
        self.website_root.mkdir(mode=0o700)
        self.prepare_package()

    def tool(self, *arguments):
        result = subprocess.run(list(map(str, arguments)), capture_output=True, timeout=30,
            env={"PATH": os.defpath, "HOME": "/nonexistent", "LC_ALL": "C", "OPENSSL_CONF": os.devnull})
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result

    def serve(self, store):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _TlsTransport)
        server.fixture, server.store, server.reads, server.corrupt = self, store, [], False
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.ca, self.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.shutdown)
        if store is self.public: self.primary_server = server
        if store is self.mirror: self.mirror_server = server
        return "https://127.0.0.1:" + str(server.server_port)

    def prepare_package(self):
        # An absolute marker detects accidental execution from any fixture cwd.
        program = PROGRAM.replace(b'"executed.marker"', json.dumps(str(self.marker)).encode("ascii"))
        source = self.work / "hello.s"; source.write_bytes(program)
        self.tool("/usr/bin/as", "--64", "-o", self.work / "hello.o", source)
        self.tool("/usr/bin/ld", "-z", "noexecstack", "--build-id=none", "-o", self.work / "hello", self.work / "hello.o")
        self.executable = (self.work / "hello").read_bytes()
        archive = registry.make_archive({"asm.toml": (b'[package]\nname = "hello"\nversion = "1.0.0"\n[target.x86_64-linux]\nsource = "src/main.s"\n', 0o644),
            "LICENSE": ((ROOT / "LICENSE").read_bytes(), 0o644), "README.md": (b"Explicit execution creates a marker.\n", 0o644),
            "src/main.s": (program, 0o644)})
        self.manifest = deepcopy(self.authority.manifest)
        self.manifest["license"] = "AGPL-3.0-or-later"
        self.manifest["source"]["archive"] = {"sha256": hashlib.sha256(archive).hexdigest(), "bytes": len(archive)}
        common = {"isa": "x86_64", "os": "linux", "abi": "sysv-amd64", "cpu_features": []}
        self.manifest["artifacts"] = [common | {"kind": kind, "format": form, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
            for kind, form, data in (("source", "tar.gz", archive), ("executable", "elf", self.executable))]
        for data in (archive, self.executable):
            path = self.objects / hashlib.sha256(data).hexdigest(); path.write_bytes(data); path.chmod(0o600)
        self.manifest_file = self.work / "publication.json"
        self.manifest_file.write_bytes(registry.json_bytes(self.manifest)); self.manifest_file.chmod(0o600)
        self.project = self.work / "project"
        created = subprocess.run([str(self.cli_binary), "new", "project"], cwd=self.work,
            env=self.environment, capture_output=True, timeout=10)
        self.assertEqual((created.returncode, created.stderr), (0, b""), (created.stdout, created.stderr))
        starter_files = ("asm.toml", "src/main.s", "tests/main.s")
        for name in starter_files:
            self.assertTrue((self.project / name).is_file(), name)
        self.project_files = {name: (self.project / name).read_bytes() for name in starter_files}
        self.project_files.update(registry.read_archive(archive))
        for name, data in self.project_files.items():
            (self.project / name).parent.mkdir(parents=True, exist_ok=True)
            (self.project / name).write_bytes(data)
        self.tool("/usr/bin/git", "-C", self.project, "init", "--initial-branch=main")
        self.tool("/usr/bin/git", "-C", self.project, "add", "--", *sorted(self.project_files))
        self.tool("/usr/bin/git", "-C", self.project, "-c", "user.name=Asm synthetic fixture",
                  "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
                  "commit", "--no-gpg-sign", "-m", "Create synthetic publication fixture")
        self.project_commit = self.tool("/usr/bin/git", "-C", self.project, "rev-parse", "HEAD").stdout.decode().strip()
        # These are deliberately absent from the committed archive.
        (self.project / "src/main.s").write_bytes(b"# Uncommitted replacement must not be published.\n")
        (self.project / ".env").write_bytes(b"ASM_TEST_UNTRACKED_SECRET=must-not-publish\n")

    def cli(self, *arguments, code=0):
        result = subprocess.run([str(self.cli_binary), "registry", *map(str, arguments)], cwd=self.work,
            env=self.environment, capture_output=True, timeout=30)
        self.assertLessEqual(len(result.stdout) + len(result.stderr), 131072)
        self.assertEqual(result.returncode, code, (result.stdout, result.stderr, self.responses[-8:]))
        if code != 0: self.assertEqual(result.stdout, b"")
        self.assertNotIn(self.token.encode(), result.stdout + result.stderr)
        self.assertEqual(list(self.work.glob(".asm-registry-*")), [])
        return result

    def publish(self, *, code=0):
        if self.project_mode:
            arguments = ["publish", "--project", self.project, "--name", self.manifest["name"],
                "--owner-id", self.manifest["owner_id"], "--summary", self.manifest["summary"],
                "--license", self.manifest["license"], "--source-target", "x86_64-linux",
                "--executable", "x86_64-linux", self.work / "hello", "--credential-file", self.credential,
                "--api", self.origin, "--idempotency-key", "1" * 32, "--ca", self.ca, "--json"]
            if "repository" in self.manifest["source"]:
                arguments.extend(("--repository", self.manifest["source"]["repository"]))
            return self.cli(*arguments, code=code)
        return self.cli("publish", "--manifest", self.manifest_file, "--objects-dir", self.objects,
            "--credential-file", self.credential, "--api", self.origin, "--idempotency-key", "1" * 32,
            "--ca", self.ca, "--json", code=code)

    def task(self, identity, *, code=0):
        return self.cli("task", identity, "--credential-file", self.credential, "--api", self.origin,
                        "--ca", self.ca, "--json", code=code)

    def receive(self, *, mirrors=None, destination=None, install=True, code=0):
        arguments = ["install" if install else "fetch", "fixture/hello@1.0.0", "--registry-id", self.registry_id,
            "--root", self.anchor, "--state", self.state, "--target", "x86_64-linux", "--kind", "executable",
            "--output", destination or self.destination, "--ca", self.ca]
        for origin in mirrors or [self.mirror_origin]: arguments.extend(("--mirror", origin))
        return self.cli(*arguments, code=code)

    def distribute(self, *, observe_task=None):
        with registry_admin.Connection(self.distributor_file, Path(os.environ["ASM_PROTO_PG_BINDIR"]) / "psql", "asm_distributor") as connection:
            fixture = self
            observed = []
            class ObservedConnection:
                def execute(self, statement):
                    raw = connection.execute(statement)
                    if observe_task is not None and statement.startswith("SELECT asm_publication.claim_distribution("):
                        fixture.assertIsNotNone(registry.strict_json(raw.encode("ascii")))
                        task = json.loads(fixture.task(observe_task).stdout)
                        fixture.assertEqual(task["state"], "distributing")
                        fixture.assertIsNone(task["release"])
                        observed.append(task["id"])
                    return raw
            result = registry_distribution.run_one(ObservedConnection(), self.retained, self.public, "f" * 32,
                self.anchor, self.keys, self.trust, self.work)
            if observe_task is not None: self.assertIn(observe_task, observed)
        self.assertIsNotNone(result)
        registry_distribution.sync(self.public, self.mirror, work_root=self.work)
        self.assertEqual(registry_distribution.load_current(self.public)[0], registry_distribution.load_current(self.mirror)[0])
        return result

    def publish_and_distribute(self, *, omit_repository=False):
        if omit_repository:
            del self.manifest["source"]["repository"]
            self.manifest_file.write_bytes(registry.json_bytes(self.manifest))
        self.assertFalse(self.marker.exists())
        initial = json.loads(self.publish().stdout)
        self.assertEqual(initial["state"], "checking")
        if self.project_mode:
            self.assertIsNotNone(self.created_manifest)
            self.assertEqual(self.created_manifest, registry.json_bytes(registry.strict_json(self.created_manifest)))
            generated = registry.strict_json(self.created_manifest)
            self.assertEqual(generated["source"]["commit"], {"algorithm": "git-sha1", "digest": self.project_commit})
            self.assertEqual(generated["version"], "1.0.0")
            self.assertEqual(generated["name"], self.manifest["name"])
            self.manifest = generated
            self.manifest_file.write_bytes(self.created_manifest)
        self.assertEqual([method for method, _ in self.requests], ["POST", "PUT", "PUT", "GET"])
        connection = self.authority.connection("asm_publication_worker")
        class Adapter:
            def execute(self, sql): return connection.execute(sql)[0][0]
        try:
            checked = publication_worker.run_one(Adapter(), self.retained, self.runtime.uploads, "2" * 32,
                lambda task, manifest, objects: publication_check.check(task, manifest, objects, "7" * 40), work_root=self.work)
        finally:
            connection.close()
        self.assertEqual(checked["state"], "committed")
        if self.project_mode:
            archive = self.manifest["source"]["archive"]
            self.assertEqual(registry.read_archive(self.retained.get_blob(archive["sha256"], archive["bytes"])), self.project_files)
        self.distribute(observe_task=initial["id"])
        published = json.loads(self.task(initial["id"]).stdout)
        self.assertEqual(published["state"], "published")
        self.assertEqual(published["id"], initial["id"])
        self.assertEqual(published["manifest_sha256"], hashlib.sha256(self.manifest_file.read_bytes()).hexdigest())
        self.assertTrue(published["release"]["manifest_url"].startswith(self.origin + "/targets/registries/"))
        self.assertFalse(self.marker.exists())
        return published

    def start_mirror_nginx(self):
        logs = self.work / "nginx-logs"
        logs.mkdir(mode=0o700)
        includes = self.work / "v2-locations.conf"
        includes.write_text((ROOT / "deploy/mirror/v2-locations.conf").read_text()
            .replace("/srv/asm/", str(self.mirror.root) + "/").replace("/var/log/asm", str(logs)))
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        configuration = (ROOT / "deploy/mirror/nginx.conf").read_text()
        configuration = configuration.replace("worker_processes auto", "worker_processes 1")
        configuration = configuration.replace("listen 8080;", "listen 127.0.0.1:" + str(port) + " ssl;\n"
            + "        ssl_certificate " + str(self.ca) + ";\n"
            + "        ssl_certificate_key " + str(self.tls_key) + ";\n"
            + "        ssl_protocols TLSv1.2 TLSv1.3;")
        configuration = configuration.replace("/tmp/asm-nginx.pid", str(self.work / "nginx.pid"))
        configuration = configuration.replace("/etc/nginx/asm/downloads.conf", str(includes))
        # Every website build is an immutable directory, separate from the
        # public mirror and the private observation ledger. No web application
        # or test-only package policy handles these requests.
        website = ("location /website/ {\n"
                   "            alias " + str(self.website_root) + "/;\n"
                   "            types { text/html html; text/css css; application/javascript js; application/json json; image/svg+xml svg; }\n"
                   "            default_type application/octet-stream;\n"
                   "        }\n\n        location / { return 404; }")
        self.assertEqual(configuration.count("location / { return 404; }"), 1)
        configuration = configuration.replace("location / { return 404; }", website)
        config = self.work / "nginx.conf"
        config.write_text(configuration)
        self.tool(self.nginx, "-p", str(self.work) + "/", "-c", config, "-t")
        process = subprocess.Popen([self.nginx, "-p", str(self.work) + "/", "-c", str(config)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                   env={"PATH": os.defpath, "TZ": "UTC"})
        def stop():
            process.terminate()
            _, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error.decode(errors="replace"))
        self.addCleanup(stop)
        deadline = time.monotonic() + 5
        while True:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1): break
            except OSError:
                self.assertLess(time.monotonic(), deadline, "nginx did not open its fixture listener")
                time.sleep(0.02)
        self.mirror_origin = "https://127.0.0.1:" + str(port)
        return logs / "downloads-v2.jsonl"

    def build_website(self, label, *, state=None):
        output = self.website_root / label
        build_site.build_site(ROOT, ROOT / "registry", output,
            v2_distribution_root=self.mirror.root, v2_registry_id=self.registry_id,
            v2_mirrors=(self.mirror_origin,), origin_log_state=state, origin_log_sources=("mirror",))
        self.assertFalse((output / "registry/v1/index.json").exists(), "V2 must not silently publish the legacy catalog.")
        self.assertNotIn("events.sqlite3", [path.name for path in output.rglob("*")])
        return output

    def website_get(self, label, relative):
        connection = http.client.HTTPSConnection("127.0.0.1", int(self.mirror_origin.rsplit(":", 1)[1]),
            context=ssl.create_default_context(cafile=str(self.ca)), timeout=5)
        try:
            connection.request("GET", "/website/" + label + "/" + relative)
            response = connection.getresponse()
            raw = response.read(4 * 1024 * 1024 + 1)
            self.assertEqual(response.status, 200, (relative, raw))
            self.assertLessEqual(len(raw), 4 * 1024 * 1024)
            self.assertNotIn(self.token.encode(), raw)
            self.assertNotIn(b"must-not-publish", raw)
            return raw
        finally:
            connection.close()

    def fetch_from_website(self, published):
        self.build_website("unknown")
        home = self.website_get("unknown", "index.html")
        self.assertIn(b'data-registry-version="2"', home)
        catalog = json.loads(self.website_get("unknown", "registry/v2/index.json"))
        self.assertEqual((catalog["schema"], catalog["registry_id"]), (2, self.registry_id))
        self.assertEqual([(item["name"], item["package_id"]) for item in catalog["packages"]],
                         [("fixture/hello", published["package_id"])])
        before = json.loads(self.website_get("unknown", "registry/v2/downloads.json"))
        self.assertEqual(before["counts"], {published["package_id"]: None})
        self.assertEqual(before["release_counts"], {published["id"]: None})
        page = _WebsitePage(self.website_get("unknown", "packages/fixture/hello/1.0.0/index.html"))
        matching = [item for item in page.commands if item["kind"] == "executable" and item["target"] == "x86_64-linux"]
        self.assertEqual(len(matching), 1, page.commands)
        selected = matching[0]
        self.assertEqual(selected["text"], selected["declared"], "Copy and visible commands must agree.")
        arguments = shlex.split(selected["text"])
        self.assertEqual(arguments[:4], ["asm", "registry", "fetch", "fixture/hello@1.0.0"])
        pairs = list(zip(arguments[4::2], arguments[5::2], strict=True))
        self.assertEqual(len(pairs), 7)
        options = dict(pairs)
        self.assertEqual(set(options), {"--registry-id", "--root", "--state", "--mirror", "--target", "--kind", "--output"})
        self.assertEqual(options["--registry-id"], self.registry_id)
        self.assertEqual(options["--root"], "/private/asm-trust/root.json")
        self.assertEqual(options["--state"], "/private/asm-trust/client-state")
        self.assertEqual(options["--mirror"], self.mirror_origin)
        self.assertEqual((options["--target"], options["--kind"]), ("x86_64-linux", "executable"))
        self.assertEqual(options["--output"], "/absolute/download/hello-1.0.0-x86_64-linux")
        # These documented host paths are the only copied arguments replaced
        # for this owned fixture. The command is never sent through a shell.
        destination = self.work / "website-fetched-hello"
        replacements = {"--root": str(self.anchor), "--state": str(self.work / "website-trust-state"),
                        "--output": str(destination)}
        native = arguments[2:4]
        for option, value in pairs:
            native.extend((option, replacements.get(option, value)))
        self.cli(*native, "--ca", self.ca)
        self.assertEqual(destination.read_bytes(), self.executable)
        self.assertFalse(self.marker.exists(), "Fetching the website command must not execute its bytes.")
        self.assertFalse((self.work / ".local/state/asm/installed.tsv").exists(), "Fetch must not create an installation receipt.")

    def check_website_counts(self, label, state, published, expected):
        self.build_website(label, state=state)
        snapshot = json.loads(self.website_get(label, "registry/v2/downloads.json"))
        self.assertEqual(snapshot["counts"], {published["package_id"]: expected})
        self.assertEqual(snapshot["release_counts"], {published["id"]: expected})
        self.assertEqual(snapshot["retained_counts"], snapshot["counts"])
        self.assertFalse(snapshot["complete"])
        page = _WebsitePage(self.website_get(label, "packages/fixture/hello/1.0.0/index.html"))
        visible = " ".join("".join(page.text).split())
        self.assertIn(str(expected) + " downloads", visible)
        self.assertIn("Coverage is incomplete", visible)
        stats = json.loads(self.website_get(label, "registry/v2/stats.json"))
        self.assertEqual((stats["schema"], stats["registry_id"]), (2, self.registry_id))
        self.assertEqual(stats["transfers"]["total"], expected)
        self.assertEqual(stats["activity"]["total"], expected)
        return snapshot

    def check_disabled_website_release(self, label, status):
        output = self.build_website(label)
        page = _WebsitePage((output / "packages/fixture/hello/1.0.0/index.html").read_bytes())
        self.assertIn(status, " ".join("".join(page.text).split()))
        self.assertEqual(page.commands, [], "Lifecycle-disabled releases must not provide new selection commands.")
        self.assertFalse(any(value.startswith(self.mirror_origin + "/blobs/") for value in page.links))
        catalog = json.loads((output / "registry/v2/index.json").read_bytes())
        self.assertIsNone(catalog["packages"][0]["latest"])

    def check_download_observations(self, published, log, *, expected=1):
        state = self.work / "statistics" / "events.sqlite3"
        store = registry_log_import.LogStore.from_distribution(state, self.mirror, self.registry_id, sources=("mirror",))
        self.assertTrue(all(value is None for value in store.snapshot()["counts"].values()))
        deadline = time.monotonic() + 3
        while not log.exists() or len(log.read_bytes().splitlines()) < expected:
            self.assertLess(time.monotonic(), deadline, "native download produced no normalized V2 log")
            time.sleep(0.02)
        raw = log.read_bytes()
        events = [registry.strict_json(line) for line in raw.splitlines()]
        self.assertEqual(len(events), expected, events)
        self.assertNotIn(self.token.encode(), raw)
        self.assertNotIn(b"?", raw)
        self.assertNotIn(b"must-not-publish", raw)
        stamps = [datetime.fromisoformat(event["time"]) for event in events]
        left, right = min(stamps) - timedelta(seconds=1), max(stamps)
        start, end = [value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") for value in (left, right)]
        first_log = self.work / "first-download.jsonl"
        first_log.write_bytes(raw)
        first_log.chmod(0o600)
        self.assertTrue(store.import_batch("mirror", "first-complete-download", start, end, first_log))
        first = store.snapshot(at=end)
        self.assertEqual(first["schema"], 2)
        self.assertEqual(first["registry_id"], self.registry_id)
        self.assertEqual(first["counts"], {published["package_id"]: expected})
        self.assertEqual(first["release_counts"], {published["id"]: expected})
        self.assertEqual(first["unattributed_requests"], 0)
        self.assertFalse(first["complete"])
        self.assertFalse(store.import_batch("mirror", "first-complete-download", start, end, first_log))
        self.assertEqual(store.snapshot(at=end), first)
        displayed = self.check_website_counts("observed", state, published, expected)
        # A public caller can supply a syntactically valid, false selection.
        # Its successful transfer must neither credit that package nor block
        # the genuine event when both occur in the next rotated batch.
        selector = ".".join((self.registry_id, "0" * 32, published["id"], "x86_64-linux", "executable"))
        route = "/blobs/sha256/" + hashlib.sha256(self.executable).hexdigest() + "?x-asm=" + selector
        connection = http.client.HTTPSConnection("127.0.0.1", int(self.mirror_origin.rsplit(":", 1)[1]),
            context=ssl.create_default_context(cafile=str(self.ca)), timeout=5)
        try:
            connection.request("GET", route)
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()), (200, self.executable))
        finally:
            connection.close()
        deadline = time.monotonic() + 3
        while len(log.read_bytes().splitlines()) != expected + 1:
            self.assertLess(time.monotonic(), deadline, "nginx did not record the second tagged request")
            time.sleep(0.02)
        second_log = self.work / "second-download-batch.jsonl"
        second_log.write_bytes(log.read_bytes())
        second_log.chmod(0o600)
        events = [registry.strict_json(line) for line in second_log.read_bytes().splitlines()]
        right = max(datetime.fromisoformat(event["time"]) for event in events)
        end = right.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertTrue(store.import_batch("mirror", "next-rotated-batch", start, end, second_log))
        result = store.snapshot(at=end)
        self.assertEqual(result["counts"], first["counts"])
        self.assertEqual(result["release_counts"], first["release_counts"])
        self.assertEqual(result["unattributed_requests"], 1)
        self.assertEqual(result["retained_unattributed_requests"], 1)
        self.assertFalse(store.import_batch("mirror", "next-rotated-batch", start, end, second_log))
        self.assertEqual(store.snapshot(at=end), result)
        replayed = self.check_website_counts("replayed", state, published, expected)
        self.assertEqual(replayed["counts"], displayed["counts"])
        self.assertEqual(replayed["release_counts"], displayed["release_counts"])
        self.assertEqual(replayed["unattributed_requests"], 1)

    def publish_dependency_project(self, name, version, source, dependencies=(), *, features=None):
        """Publish committed source through the actual native and authority paths."""
        project = self.work / (name.split("/")[-1] + "-" + version)
        (project / "src").mkdir(parents=True)
        manifest = (f'[package]\nname = "{name.split("/")[-1]}"\nversion = "{version}"\n'
                    '[target.x86_64-linux]\nsource = "src/main.s"\n')
        declared = ([dict(edge) for edge in dependencies] if dependencies and isinstance(dependencies[0], dict)
                    else [{"name": child, "requirement": requirement} for child, requirement in sorted(dependencies)])
        declared.sort(key=lambda edge: edge["name"])
        complex_profile = bool(features) or any(set(edge) != {"name", "requirement"} for edge in declared)
        if complex_profile:
            declared = [{"name": edge["name"], "requirement": edge["requirement"],
                         "optional": edge.get("optional", False), "default_features": edge.get("default_features", True),
                         "features": sorted(edge.get("features", []))} for edge in declared]
        if declared:
            manifest += "\n[dependencies]\n"
            for edge in declared:
                if not complex_profile:
                    manifest += f'"{edge["name"]}" = "{edge["requirement"]}"\n'
                else:
                    manifest += (f'"{edge["name"]}" = {{ version = "{edge["requirement"]}", '
                        f'optional = {json.dumps(edge["optional"])}, default-features = {json.dumps(edge["default_features"])}, '
                        f'features = {json.dumps(edge["features"])} }}\n')
        if features:
            manifest += "\n[features]\n" + "".join(
                f'{name} = {json.dumps(sorted(members))}\n' for name, members in sorted(features.items()))
        files = {"asm.toml": manifest.encode(), "src/main.s": source,
                 "LICENSE": (ROOT / "LICENSE").read_bytes(), "README.md": b"Synthetic dependency authority fixture.\n"}
        for relative, data in files.items():
            (project / relative).write_bytes(data)
        self.tool("/usr/bin/git", "-C", project, "init", "--initial-branch=main")
        self.tool("/usr/bin/git", "-C", project, "add", "--", *sorted(files))
        self.tool("/usr/bin/git", "-C", project, "-c", "user.name=Asm synthetic fixture",
                  "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
                  "commit", "--no-gpg-sign", "-m", "Create synthetic dependency package")
        commit = self.tool("/usr/bin/git", "-C", project, "rev-parse", "HEAD").stdout.decode().strip()
        key = hashlib.sha256((name + "@" + version).encode()).hexdigest()[:32]
        result = self.cli("publish", "--project", project, "--name", name, "--owner-id", self.authority.owner,
            "--summary", "Synthetic dependency authority fixture.", "--license", "AGPL-3.0-or-later",
            "--source-target", "x86_64-linux", "--credential-file", self.credential,
            "--api", self.origin, "--idempotency-key", key, "--ca", self.ca, "--json")
        initial = json.loads(result.stdout)
        self.assertEqual(initial["state"], "checking")
        generated = registry.strict_json(self.created_manifest)
        self.assertEqual(generated.get("dependencies", []), declared)
        self.assertEqual(generated.get("features", []), [
            {"name": name, "members": sorted(members)} for name, members in sorted((features or {}).items())])
        self.assertEqual(generated["source"]["commit"], {"algorithm": "git-sha1", "digest": commit})
        self.assertEqual(generated["name"], name)
        self.assertEqual(generated["version"], version)
        raw = self.created_manifest
        connection = self.authority.connection("asm_publication_worker")
        class Adapter:
            def execute(self, sql): return connection.execute(sql)[0][0]
        try:
            checked = publication_worker.run_one(Adapter(), self.retained, self.runtime.uploads, "2" * 32,
                lambda task, manifest, objects: publication_check.check(task, manifest, objects, "7" * 40), work_root=self.work)
        finally:
            connection.close()
        self.assertEqual(checked["state"], "committed")
        archive = generated["source"]["archive"]
        self.assertEqual(registry.read_archive(self.retained.get_blob(archive["sha256"], archive["bytes"])), files)
        self.distribute(observe_task=initial["id"])
        published = json.loads(self.task(initial["id"]).stdout)
        self.assertEqual(published["state"], "published")
        self.assertEqual(published["manifest_sha256"], hashlib.sha256(raw).hexdigest())
        envelope_key = published["release"]["manifest_url"].removeprefix(self.origin + "/")
        envelope = registry.strict_json((self.mirror.root / envelope_key).read_bytes())
        self.assertEqual(envelope["publication"], generated)
        self.assertEqual(envelope["publication"].get("dependencies", []), declared)
        self.assertFalse((project / "build").exists(), "Publication built the dependency package")
        return published, generated, envelope_key

    def dependency_command(self, operation, project, *options, code=0):
        return self.cli(operation, "--project", project, "--registry-id", self.registry_id,
            "--root", self.anchor, "--state", self.state, "--target", "x86_64-linux", "--ca", self.ca,
            "--mirror", self.mirror_origin, "--json", *options, code=code)

    def test_native_dependency_publication_complete_lock_sync_build_and_failures(self):
        # This credential is scoped to the two synthetic packages in this method.
        self.token = "asm_pub_v1_" + "e" * 64
        self.authority.issue("6" * 32, self.authority.owner, self.token, ["fixture/leaf", "fixture/middle"])
        self.credential.write_text(self.token + "\n")
        self.credential.chmod(0o600)
        leaf, leaf_manifest, leaf_envelope = self.publish_dependency_project("fixture/leaf", "1.0.0",
            b".text\n.global asm_leaf\nasm_leaf:\nmov $42, %eax\nret\n")
        self.publish_dependency_project("fixture/leaf", "2.0.0",
            b".text\n.global asm_leaf\nasm_leaf:\nmov $99, %eax\nret\n")
        middle, middle_manifest, middle_envelope = self.publish_dependency_project("fixture/middle", "1.0.0",
            b".text\n.global asm_middle\nasm_middle:\ncall asm_leaf\nret\n",
            [{"name": "fixture/leaf", "requirement": "^1.0.0", "optional": True}],
            features={"default": ["math"], "math": ["dep:fixture/leaf"]})
        consumer = self.work / "dependency consumer"
        (consumer / "src").mkdir(parents=True)
        consumer_manifest = (b'[package]\nname = "consumer"\nversion = "1.0.0"\n'
                             b'[target.x86_64-linux]\nsource = "src/main.s"\n'
                             b'[dependencies]\n"fixture/middle" = { version = "~1.0.0", default-features = false }\n'
                             b'[features]\ndefault = ["math"]\nmath = ["fixture/middle/math"]\n')
        (consumer / "asm.toml").write_bytes(consumer_manifest)
        marker = self.work / "dependency.executed.marker"
        source = PROGRAM.replace(b'"executed.marker"', json.dumps(str(marker)).encode("ascii"))
        source = source.replace(b"_start:\n", b"_start:\n    call asm_middle\n    cmp $42, %eax\n    jne failed\n")
        source = source.replace(b"Asm full-flow fixture.", b"Asm dependency graph.")
        (consumer / "src/main.s").write_bytes(
            b'.include "fixture/leaf/1.0.0/x86_64-linux/src/main.s"\n'
            b'.include "fixture/middle/1.0.0/x86_64-linux/src/main.s"\n' + source)
        self.mirror_server.reads.clear()
        resolved = json.loads(self.dependency_command("resolve", consumer).stdout)
        self.assertEqual(resolved, {"ok": True, "packages": 2, "resolved": True})
        self.assertFalse(any(path.startswith("/blobs/") for path in self.mirror_server.reads))
        lock = consumer / "asm.lock"
        original_lock = lock.read_bytes()
        lines = original_lock.decode().splitlines()
        self.assertEqual(lines[:6], ["# asm-lock-v4",
            "\t".join(("registry", self.registry_id, hashlib.sha256(self.anchor.read_bytes()).hexdigest(),
                        "x86_64-linux", hashlib.sha256(consumer_manifest).hexdigest())),
            "selection\t1\t-", "root-feature\tdefault", "root-feature\tmath",
            "root\tfixture/middle\t~1.0.0"])
        nodes = [line.split("\t") for line in lines if line.startswith("node\t")]
        self.assertEqual([(node[1], node[2]) for node in nodes], [("fixture/leaf", "1.0.0"), ("fixture/middle", "1.0.0")])
        self.assertEqual([line for line in lines if line.startswith("edge\t")], ["edge\tfixture/middle\tfixture/leaf\t^1.0.0"])
        for node, published, manifest, envelope_key in zip(nodes, (leaf, middle), (leaf_manifest, middle_manifest),
                                                         (leaf_envelope, middle_envelope), strict=True):
            envelope_bytes = (self.mirror.root / envelope_key).read_bytes()
            envelope = registry.strict_json(envelope_bytes)
            archive = manifest["source"]["archive"]
            self.assertEqual(node[3:], [envelope["package_id"], published["id"], hashlib.sha256(envelope_bytes).hexdigest(),
                published["manifest_sha256"], manifest["source"]["commit"]["digest"], str(archive["bytes"]), archive["sha256"]])
        self.assertFalse((consumer / "build").exists())
        self.assertFalse(marker.exists())
        # A corrupt transitive object must fail without replacing the complete lock.
        digest = leaf_manifest["source"]["archive"]["sha256"]
        blob = self.mirror.root / "blobs/sha256" / digest
        original_blob = blob.read_bytes()
        blob.write_bytes(b"!" * len(original_blob))
        self.dependency_command("sync", consumer, code=1)
        self.assertEqual(lock.read_bytes(), original_lock)
        self.assertFalse((consumer / "build").exists())
        blob.write_bytes(original_blob)
        synchronized = json.loads(self.dependency_command("sync", consumer).stdout)
        self.assertEqual(synchronized, {"ok": True, "packages": 2, "synchronized": True})
        self.assertEqual(lock.read_bytes(), original_lock)
        self.assertFalse(marker.exists(), "Resolution and synchronization executed a package")
        built = subprocess.run([str(self.cli_binary), "build", "--locked"], cwd=consumer, env=self.environment,
                               capture_output=True, timeout=30)
        self.assertEqual((built.returncode, built.stderr), (0, b""), built.stdout)
        executable = consumer / "build/app"
        original_executable = executable.read_bytes()
        self.assertFalse(marker.exists(), "A build executed the consumer")
        result = subprocess.run([str(executable)], cwd=consumer, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"Asm dependency graph.\n", b""))
        self.assertEqual(marker.read_bytes(), b"Asm dependency graph.\n")
        # Defaults off remove the optional transitive edge. Source imports are
        # explicit, so this selected project source deliberately has no imports.
        disabled_source = PROGRAM.replace(b'"executed.marker"', json.dumps(str(marker)).encode("ascii"))
        disabled_source = disabled_source.replace(b"Asm full-flow fixture.", b"Asm features disabled.")
        (consumer / "src/main.s").write_bytes(disabled_source)
        self.mirror_server.reads.clear()
        disabled = json.loads(self.dependency_command("resolve", consumer, "--no-default-features").stdout)
        self.assertEqual(disabled["packages"], 1)
        disabled_lock = lock.read_bytes()
        self.assertIn(b"selection\t0\t-\n", disabled_lock)
        self.assertNotIn(b"edge\t", disabled_lock)
        self.assertFalse(any("/fixture/leaf/" in path for path in self.mirror_server.reads))
        self.dependency_command("sync", consumer)
        built = subprocess.run([str(self.cli_binary), "build", "--locked"], cwd=consumer, env=self.environment,
                               capture_output=True, timeout=30)
        self.assertEqual((built.returncode, built.stderr), (0, b""), built.stdout)
        marker.unlink()
        result = subprocess.run([str(executable)], cwd=consumer, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"Asm features disabled.\n", b""))
        # An explicit request enables the same exact graph without implicit defaults.
        (consumer / "src/main.s").write_bytes(
            b'.include "fixture/leaf/1.0.0/x86_64-linux/src/main.s"\n'
            b'.include "fixture/middle/1.0.0/x86_64-linux/src/main.s"\n' + source)
        requested = json.loads(self.dependency_command("resolve", consumer, "--no-default-features", "--features", "math").stdout)
        self.assertEqual(requested["packages"], 2)
        self.assertIn(b"selection\t0\tmath\n", lock.read_bytes())
        self.dependency_command("sync", consumer)
        built = subprocess.run([str(self.cli_binary), "build", "--locked"], cwd=consumer, env=self.environment,
                               capture_output=True, timeout=30)
        self.assertEqual((built.returncode, built.stderr), (0, b""), built.stdout)
        self.assertEqual(executable.read_bytes(), original_executable)
        marker.unlink()
        result = subprocess.run([str(executable)], cwd=consumer, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"Asm dependency graph.\n", b""))
        # Restore the original selection before testing failure preservation.
        self.dependency_command("resolve", consumer)
        self.assertEqual(lock.read_bytes(), original_lock)
        # A direct request for leaf 2 conflicts with middle's authenticated range.
        (consumer / "asm.toml").write_bytes(consumer_manifest.replace(
            b"[features]", b'"fixture/leaf" = "^2.0.0"\n[features]'))
        conflict = self.dependency_command("resolve", consumer, code=1)
        self.assertIn(b"no compatible dependency graph", conflict.stderr.lower())
        self.assertEqual(lock.read_bytes(), original_lock)
        self.assertEqual(executable.read_bytes(), original_executable)
        (consumer / "asm.toml").write_bytes(consumer_manifest)
        self.authority.run_role("asm_operator", "SELECT asm_publication.set_lifecycle($1,'revoke',$2,0,$3)",
            [leaf["id"], "3" * 32, "owned-transitive-revocation-full-flow"])
        self.distribute()
        self.mirror_server.reads.clear()
        self.dependency_command("sync", consumer, code=1)
        self.assertFalse(any(path.startswith("/blobs/") for path in self.mirror_server.reads))
        self.assertEqual(lock.read_bytes(), original_lock)
        self.assertEqual(executable.read_bytes(), original_executable)
        print(json.dumps({"qualification": "synthetic-v2-dependency-full-flow",
            "registry_id": self.registry_id, "leaf_release_id": leaf["id"], "middle_release_id": middle["id"],
            "lock_sha256": hashlib.sha256(original_lock).hexdigest(),
            "consumer_sha256": hashlib.sha256(original_executable).hexdigest()}, sort_keys=True))

    def test_native_publish_signed_second_mirror_install_then_deliberate_execution(self):
        self.project_mode = True
        log = self.start_mirror_nginx()
        published = self.publish_and_distribute()
        self.fetch_from_website(published)
        self.receive(mirrors=[self.origin + "/missing", self.mirror_origin])
        self.assertTrue(self.primary_server.reads)
        self.assertEqual(self.destination.read_bytes(), self.executable)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o755)
        self.assertFalse(self.marker.exists(), "Publication and installation must never execute a package.")
        inventory = self.work / ".local/state/asm/installed.tsv"
        record = inventory.read_text().splitlines()[1].split("\t")
        envelope_key = published["release"]["manifest_url"].removeprefix(self.origin + "/")
        envelope = (self.mirror.root / envelope_key).read_bytes()
        package_id = registry.strict_json(envelope)["package_id"]
        binding = ":".join(("v2", self.registry_id, hashlib.sha256(self.anchor.read_bytes()).hexdigest(), package_id,
                            published["id"], hashlib.sha256(envelope).hexdigest()))
        self.assertEqual(record, ["fixture/hello", "1.0.0", "x86_64-linux", hashlib.sha256(self.executable).hexdigest(),
                                  str(len(self.executable)), str(self.destination), binding])
        before = inventory.read_bytes()
        self.receive()
        self.assertEqual(inventory.read_bytes(), before)
        self.assertFalse(self.marker.exists())
        before_replay = len(self.requests)
        self.assertEqual(json.loads(self.publish().stdout)["id"], published["id"])
        self.assertFalse(any(method == "PUT" for method, _ in self.requests[before_replay:]))
        self.check_download_observations(published, log, expected=2)
        # Deliberate execution is the sole operation authorized to run the package.
        result = subprocess.run([str(self.destination)], cwd=self.work, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"Asm full-flow fixture.\n", b""))
        self.assertEqual(self.marker.read_bytes(), b"Asm full-flow fixture.\n")
        # Retain public synthetic artifact identities before fixture cleanup.
        paths = ("index.html", "packages/fixture/hello/1.0.0/index.html", "stats/index.html",
                 "registry/v2/index.json", "registry/v2/downloads.json", "registry/v2/stats.json")
        artifacts = {label: {path: hashlib.sha256((self.website_root / label / path).read_bytes()).hexdigest()
                            for path in paths} for label in ("unknown", "observed", "replayed")}
        print(json.dumps({"qualification": "synthetic-v2-website-full-flow", "registry_id": self.registry_id,
            "package_id": package_id, "release_id": published["id"],
            "artifact_sha256": hashlib.sha256(self.executable).hexdigest(),
            "envelope_sha256": hashlib.sha256(envelope).hexdigest(), "website_artifacts": artifacts}, sort_keys=True))

    def test_replay_corruption_network_and_lifecycle_failures_preserve_files(self):
        published = self.publish_and_distribute(omit_repository=True)
        before_replay = len(self.requests)
        self.assertEqual(json.loads(self.publish().stdout)["id"], published["id"])
        self.assertFalse(any(method == "PUT" for method, _ in self.requests[before_replay:]),
                         "A durable received object must not be uploaded again.")
        self.assertEqual(self.authority.admin.execute("SELECT count(*) FROM asm_publication.tasks"), [["1"]])
        self.mirror_server.corrupt = True
        self.receive(code=1)
        self.assertFalse(self.destination.exists())
        self.mirror_server.corrupt = False
        self.receive()
        inventory = self.work / ".local/state/asm/installed.tsv"
        original_inventory = inventory.read_bytes()
        fresh = self.work / "refused-new-install"
        dead_port = runtime_fixture.reader_fixture.free_port()
        self.receive(mirrors=["https://127.0.0.1:" + str(dead_port)], destination=fresh, install=False, code=1)
        self.assertFalse(fresh.exists())
        stale = LocalBlobStore(self.work / "stale")
        registry_distribution.sync(self.public, stale, work_root=self.work)
        stale_origin = self.serve(stale)
        self.authority.run_role("asm_operator", "SELECT asm_publication.set_lifecycle($1,'yank',$2,0,$3)",
            [published["id"], "3" * 32, "owned-yank-full-flow"])
        self.distribute()
        self.check_disabled_website_release("yanked", "Yanked")
        self.receive(code=1)
        self.assertEqual(self.destination.read_bytes(), self.executable)
        self.assertEqual(inventory.read_bytes(), original_inventory)
        self.receive(destination=fresh, code=1)
        self.assertFalse(fresh.exists())
        self.receive(mirrors=[stale_origin], destination=fresh, code=1)
        self.assertFalse(fresh.exists())
        self.authority.run_role("asm_operator", "SELECT asm_publication.set_lifecycle($1,'revoke',$2,1,$3)",
            [published["id"], "4" * 32, "owned-revocation-full-flow"])
        self.authority.run_role("asm_operator", "SELECT asm_publication.set_lifecycle($1,'unyank',$2,2,$3)",
            [published["id"], "5" * 32, "revocation-survives-unyank"])
        self.assertEqual(self.authority.admin.execute("SELECT yanked,revoked FROM asm_publication.lifecycle_events ORDER BY policy_revision DESC LIMIT 1"), [["f", "t"]])
        self.distribute()
        self.check_disabled_website_release("revoked", "Revoked")
        self.receive(destination=fresh, code=1)
        self.assertFalse(fresh.exists())
        self.authority.run_role("asm_operator", "SELECT asm_publication.revoke_credential($1,$2)",
            [self.authority.credential, "owned-credential-revocation"])
        self.task(published["id"], code=1)
        self.assertEqual(self.destination.read_bytes(), self.executable)
        self.assertEqual(inventory.read_bytes(), original_inventory)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
