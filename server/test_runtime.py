"""Exercise the assembly runtime against an owned TLS PostgreSQL fixture.

SPDX-License-Identifier: AGPL-3.0-or-later
Python runs tests only. It is not a registry application backend.
"""
import http.client
import concurrent.futures
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import secrets
import socket
import stat
import subprocess
import sys
import termios
import tempfile
import time
import unittest
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
REFERENCE = HERE.parent / "experiments/assembly-server"
sys.path.insert(0, str(REFERENCE))
from local_postgres import Database, LocalPostgres
sys.path.insert(0, str(HERE.parent / "tools"))
import registry
import registry_admin


def redact_diagnostic_text(text, secret=None):
    if isinstance(secret, str) and secret:
        text = text.replace(secret, "[redacted]")
    return re.sub(r"postgres(?:ql)?://[^\s\"']+", "[redacted]", text)


def diagnostic_file(path, limit, *, tail=False, secret=None):
    """Read only a bounded regular-file excerpt; never follow a log symlink."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                return {"unavailable": "not a regular file"}
            if tail:
                source.seek(max(0, metadata.st_size - limit))
            data = source.read(limit + 1)
        truncated = len(data) > limit or (tail and metadata.st_size > limit)
        if tail and truncated:
            # Discard a partial first line before redaction. A truncated URI or
            # password must not leave its trailing characters in the excerpt.
            data = data.partition(b"\n")[2]
        text = data[:limit].decode("utf-8", "replace")
        return {"text": redact_diagnostic_text(text, secret), "truncated": truncated}
    except OSError as error:
        return {"unavailable": type(error).__name__}


def cgroup_snapshot(root=Path("/sys/fs/cgroup")):
    try:
        return {name: diagnostic_file(root / name, 4096) for name in
                ("cpu.stat", "cpu.max", "memory.current", "memory.max", "memory.peak", "memory.events",
                 "pids.current", "pids.max", "pids.events")}
    except Exception as error:
        return {"unavailable": type(error).__name__}


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class TlsPostgres(LocalPostgres):
    """Add certificates only to the disposable cluster owned by LocalPostgres."""
    def openssl(self, *args):
        subprocess.run(["openssl", *args], cwd=self.base, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)

    def certificate(self, name, common_name, *, server=False):
        self.openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=" + common_name,
                     "-keyout", name + ".key", "-out", name + ".csr")
        extension = self.base / (name + ".ext")
        extension.write_text("subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n" if server
                             else "extendedKeyUsage=clientAuth\n")
        self.openssl("x509", "-req", "-in", name + ".csr", "-CA", "ca.crt", "-CAkey", "ca.key",
                     "-set_serial", str(secrets.randbits(96)), "-days", "1",
                     "-extfile", str(extension), "-out", name + ".crt")
        (self.base / (name + ".key")).chmod(0o600)

    def _initialize(self, bindir, env):
        super()._initialize(bindir, env)
        self.openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                     "-subj", "/CN=Asm runtime test CA", "-addext", "basicConstraints=critical,CA:TRUE",
                     "-keyout", "ca.key", "-out", "ca.crt")
        self.openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                     "-subj", "/CN=Unrelated test CA", "-addext", "basicConstraints=critical,CA:TRUE",
                     "-keyout", "unrelated.key", "-out", "unrelated.crt")
        self.certificate("server", "localhost", server=True)
        with (self.data / "postgresql.conf").open("a") as out:
            out.write("\nssl=on\n")
            for key, name in (("ssl_cert_file", "server.crt"), ("ssl_key_file", "server.key"),
                              ("ssl_ca_file", "ca.crt")):
                # The temporary path has no quote. PostgreSQL receives no user path here.
                out.write(f"{key}='{self.base / name}'\n")
        hba = self.data / "pg_hba.conf"
        hba.write_text("hostssl all all 127.0.0.1/32 cert\n" + hba.read_text())


class RuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        value = os.environ.get("ASM_SERVER_BINARY")
        if not value or not Path(value).is_file():
            raise AssertionError("ASM_SERVER_BINARY must identify a built assembly runtime; no runtime check ran.")
        cls.binary = Path(value).resolve()
        cls.revision = os.environ["ASM_SERVER_SOURCE_REVISION"]
        cls.temp = tempfile.TemporaryDirectory(prefix="asm-runtime-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.cluster = TlsPostgres(cls.base)
        cls.addClassCleanup(cls.cluster.close)
        cls.concurrent_wave = None
        cls.failure_diagnostics = None
        # Later server cleanups run first. Capture before cluster.close removes
        # the owned PostgreSQL log and before the outer temporary directory ends.
        cls.addClassCleanup(cls.retain_diagnostics)
        cls.cluster.start()
        cls.prefix = "asm_proto_" + secrets.token_hex(6)
        cls.dbname = cls.prefix
        cls.roles = {name: "asm_" + name for name in ("migrator", "reader", "operator")}
        for role in cls.roles.values():
            cls.cluster.admin.execute(f'CREATE ROLE "{role}" LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
        cls.cluster.admin.execute(f'CREATE DATABASE "{cls.dbname}" OWNER "{cls.roles["migrator"]}"')
        cls.admin = Database(cls.cluster.url(database=cls.dbname))
        cls.addClassCleanup(cls.admin.close)
        cls.configs = {}
        for label, role in cls.roles.items():
            cls.cluster.certificate(label, role)
            path = cls.base / (label + ".url")
            path.write_text(cls.url(role, label) + "\n")
            path.chmod(0o600)
            cls.configs[label] = path
        psql = Path(os.environ["ASM_PROTO_PG_BINDIR"]) / "psql"
        with registry_admin.Connection(cls.configs["migrator"], psql, cls.roles["migrator"]) as connection:
            registry_admin.migrate(connection)
        records = registry.read_records(HERE.parent / "registry")
        # Synthetic metadata distinguishes all six target vocabularies. These
        # test-only artifacts are neither downloaded nor executed.
        records.append({
            "schema": 1, "name": "fixture/all-targets", "version": "1.0.0", "license": "MIT",
            "summary": "Synthetic six-target HTTP metadata fixture.", "yanked": False,
            "source": {"repository": "https://github.com/stubbi/asm", "commit": cls.revision, "path": "fixtures"},
            "artifacts": [{"target": target, "kind": "source", "bytes": 1024, "sha256": "a" * 64,
                "url": "https://github.com/stubbi/asm/releases/download/runtime-fixture/all-targets-" + target + ".tar.gz"}
                for target in ("x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos",
                               "x86_64-windows", "aarch64-windows")],
        })
        full_tsv, index = registry.make_indexes(records)
        cls.exports = dict(zip(registry_admin.ROUTES, (
            registry.legacy_tsv(full_tsv).encode("ascii"), registry.macos_compat_tsv(full_tsv).encode("ascii"),
            full_tsv.encode("ascii"), registry.json_bytes(index)), strict=True))
        with registry_admin.Connection(cls.configs["operator"], psql, cls.roles["operator"]) as connection:
            for namespace in sorted({record["name"].split("/")[0] for record in records}):
                connection.execute("SELECT asm_catalog.bind_namespace(" + registry_admin.sql_text(namespace) +
                    ",12345," + registry_admin.sql_text(cls.revision) + ");")
            manifests = "ARRAY[" + ",".join(registry_admin.sql_text(registry.json_bytes(record).decode("ascii"))
                                            for record in records) + "]::text[]"
            connection.execute("SELECT asm_catalog.publish(" + registry_admin.sql_text(cls.revision) +
                ",0," + manifests + "," + ",".join(registry_admin.sql_text(body.decode("ascii"))
                                                   for body in cls.exports.values()) + ");")
        cls.port = free_port()
        cls.log = (cls.base / "server.log").open("wb")
        cls.addClassCleanup(cls.log.close)
        cls.server = subprocess.Popen([str(cls.binary), "serve"], env=cls.environment(),
                                      stdout=cls.log, stderr=cls.log)
        cls.addClassCleanup(cls.stop_server)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                raise AssertionError(f"Runtime exited during startup ({cls.server.returncode}); inspect its fixed error.")
            try:
                if cls.request("/health/live")[0] == 200:
                    return
            except OSError:
                time.sleep(0.02)
        raise AssertionError("Runtime did not become live within five seconds.")

    @classmethod
    def retain_diagnostics(cls):
        try:
            pg_base = getattr(cls.cluster, "base", None)
            secret = getattr(cls.cluster, "password", None)
            cls.failure_diagnostics = {
                "logs": {"server": diagnostic_file(cls.base / "server.log", 16384, tail=True, secret=secret),
                         "postgres": (diagnostic_file(pg_base / "postgres.log", 16384, tail=True, secret=secret)
                                      if pg_base else {"unavailable": "fixture did not initialize"})},
                "concurrent_wave": cls.concurrent_wave,
                "cgroup_before_cleanup": cgroup_snapshot(),
            }
        except Exception as error:
            # Diagnostic collection must not replace the original test outcome.
            cls.failure_diagnostics = {"unavailable": type(error).__name__}

    @classmethod
    def url(cls, role, label, *, host="localhost", extra="", hostaddr="127.0.0.1"):
        certs = cls.cluster.base
        params = "&".join(key + "=" + quote(str(certs / name), safe="/") for key, name in
                          (("sslrootcert", "ca.crt"), ("sslcert", label + ".crt"), ("sslkey", label + ".key")))
        return (f"postgresql://{role}@{host}:{cls.cluster.port}/{cls.dbname}?"
                f"sslmode=verify-full&{params}&hostaddr={hostaddr}{extra}")

    @classmethod
    def environment(cls, **changes):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
        env.update(ASM_BIND=f"127.0.0.1:{cls.port}", ASM_DATABASE_URL_FILE=str(cls.configs["reader"]))
        env.update(changes)
        return env

    @classmethod
    def raw_request(cls, path, method="GET", body=None):
        connection = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=3)
        try:
            connection.request(method, path, body=body)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    @classmethod
    def request(cls, path, method="GET", body=None):
        code, headers, body = cls.raw_request(path, method, body)
        return code, headers, json.loads(body)

    @classmethod
    def stop_server(cls):
        if getattr(cls, "server", None) and cls.server.poll() is None:
            cls.server.terminate()
            try:
                cls.server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                cls.server.kill()
                cls.server.wait(timeout=2)
                raise AssertionError("The runtime did not stop within three seconds.")

    def reject(self, *, config=None, bind=None, arguments=("serve",), content=None, expected=78, **env):
        if content is not None:
            config = self.base / ("rejected-" + secrets.token_hex(4) + ".url")
            config.write_text(content)
            config.chmod(0o600)
        if config is not None:
            env["ASM_DATABASE_URL_FILE"] = str(config)
        env["ASM_BIND"] = bind if bind is not None else f"127.0.0.1:{free_port()}"
        start = time.monotonic()
        result = subprocess.run([str(self.binary), *arguments], env=self.environment(**env),
                                capture_output=True, timeout=3)
        self.assertEqual(result.returncode, expected, result.stderr.decode("utf-8", "replace"))
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"postgresql://", result.stderr)
        self.assertLess(time.monotonic() - start, 2.8)
        return result

    def test_health_and_exact_source_identity(self):
        self.assertEqual(self.request("/health/live")[2], {"status": "alive"})
        self.assertEqual(self.request("/health/ready")[2], {"status": "ready"})
        code, headers, body = self.request("/api/v2/status")
        self.assertEqual(code, 200)
        self.assertEqual(body["source_revision"], self.revision)
        self.assertEqual(body["source_url"], "https://github.com/stubbi/asm/tree/" + self.revision)
        self.assertEqual(body["application_language"], "assembly")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")

    def test_canonical_exports_preserve_exact_current_bytes_and_media_types(self):
        self.assertGreater(len(self.exports["/registry/v1/index.json"]), 16384)
        for path, expected in self.exports.items():
            with self.subTest(path=path):
                code, headers, body = self.raw_request(path)
                self.assertEqual(code, 200)
                self.assertEqual(body, expected)
                self.assertEqual(headers["Content-Type"], "application/json" if path.endswith(".json")
                                 else "text/tab-separated-values; charset=utf-8")
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        vocabularies = {
            "/registry/v1/index.tsv": {"x86_64-linux", "aarch64-linux", "riscv64-linux"},
            "/registry/v1/index-macos.tsv": {"x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos"},
            "/registry/v1/index-all.tsv": {"x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos",
                                            "x86_64-windows", "aarch64-windows"},
        }
        for path, expected_targets in vocabularies.items():
            with self.subTest(vocabulary=path):
                code, _, body = self.raw_request(path)
                self.assertEqual(code, 200)
                rows = [line.split(b"\t") for line in body.splitlines() if not line.startswith(b"#")]
                self.assertEqual({row[2].decode("ascii") for row in rows}, expected_targets)
        code, _, body = self.raw_request("/registry/v1/index.json")
        self.assertEqual(code, 200)
        self.assertIn(b"x86_64-windows", body)
        self.assertIn(b"aarch64-windows", body)

    def test_unimplemented_write_routes_do_not_claim_success(self):
        self.assertEqual(self.request("/api/v2/packages")[0], 404)
        self.assertEqual(self.request("/health/live", method="POST")[0], 405)
        self.assertEqual(self.request("/health/live", body=b"x")[0], 400)
        self.assertEqual(self.request("/health/live?unknown=x")[0], 400)
        for path in self.exports:
            with self.subTest(path=path):
                self.assertEqual(self.request(path, method="POST")[0], 405)
                self.assertEqual(self.request(path, body=b"x")[0], 400)
                self.assertEqual(self.request(path + "?route=untrusted")[0], 400)
                self.assertEqual(self.request(path + "x")[0], 404)
                self.assertEqual(self.request(path + "/")[0], 404)
                self.assertEqual(self.request(path[:-1])[0], 404)

    def test_concurrent_exports_keep_independent_response_ownership(self):
        paths = list(self.exports) * 2
        wave = {"requests": [{"path": path, "unavailable": "request did not start"} for path in paths],
                "cgroup_before": cgroup_snapshot()}
        type(self).concurrent_wave = wave
        wave_started = time.monotonic()

        def measured_request(item):
            index, path = item
            started = time.monotonic()
            record = {"path": path, "started_seconds": round(started - wave_started, 6)}
            try:
                response = self.raw_request(path)
                record["status"] = response[0]
                return response
            except Exception as error:
                record["error"] = type(error).__name__
                raise
            finally:
                record["seconds"] = round(time.monotonic() - started, 6)
                wave["requests"][index] = record

        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as clients:
                responses = list(clients.map(measured_request, enumerate(paths)))
        finally:
            wave["cgroup_after"] = cgroup_snapshot()
        for path, (code, _, body) in zip(paths, responses):
            with self.subTest(path=path):
                self.assertEqual(code, 200)
                self.assertEqual(body, self.exports[path])

    @contextmanager
    def export_view(self, select):
        """Use trusted fixture administration to probe malformed database results."""
        original = self.admin.execute(
            "SELECT pg_catalog.pg_get_viewdef('asm_catalog.current_exports'::regclass,true)")[0][0]
        source = "(" + original.rstrip().removesuffix(";") + ") AS retained"
        self.admin.execute("CREATE OR REPLACE VIEW asm_catalog.current_exports AS " + select.format(source=source))
        try:
            yield
        finally:
            self.admin.execute("CREATE OR REPLACE VIEW asm_catalog.current_exports AS " + original)
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_exports_reject_missing_null_duplicate_and_unready_results(self):
        columns = "route,body,sha256,media_type,revision,acceptance_commit"
        variants = [
            ("SELECT " + columns + " FROM {source} UNION ALL SELECT " + columns + " FROM {source}", self.exports),
            ("SELECT " + columns + " FROM {source} WHERE false", self.exports),
        ]
        for path in self.exports:
            variants.extend((
                ("SELECT " + columns + " FROM {source} WHERE route <> '" + path + "'", self.exports),
                ("SELECT route,CASE WHEN route='" + path + "' THEN NULL::text ELSE body END AS body,"
                    "sha256,media_type,revision,acceptance_commit FROM {source}", (path,)),
            ))
        for select, paths in variants:
            with self.subTest(select=select), self.export_view(select):
                for path in paths:
                    code, _, body = self.request(path)
                    self.assertEqual(code, 503)
                    self.assertEqual(body["error"]["code"], "temporarily_unavailable")
                self.assertEqual(self.request("/health/live")[0], 200)
        original = self.admin.execute("SELECT sha384 FROM asm_catalog.schema_version")[0][0]
        for marker in ("0" * 96,
                       "259a54d22fcd1e53addf4f5f197d7ca0f7c5040e2492776fc60a30f59cd1428a6618f4ec39fa1f3df867d4b05ee2d9ae"):
            with self.subTest(marker=marker):
                self.admin.execute("UPDATE asm_catalog.schema_version SET sha384=$1", [marker])
                try:
                    self.assertEqual(self.request("/health/ready")[0], 503)
                    for path in self.exports:
                        self.assertEqual(self.request(path)[0], 503)
                    self.assertEqual(self.request("/health/live")[0], 200)
                finally:
                    self.admin.execute("UPDATE asm_catalog.schema_version SET sha384=$1", [original])
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_export_body_byte_limits_preserve_boundary_bytes(self):
        for path in self.exports:
            maximum = 4194304 if path.endswith(".json") else 1048576
            select = ("SELECT route,CASE WHEN route='" + path + "' THEN repeat('x'," + str(maximum) +
                      ") ELSE body END AS body,sha256,media_type,revision,acceptance_commit FROM {source}")
            with self.subTest(path=path), self.export_view(select):
                code, _, body = self.raw_request(path)
                self.assertEqual(code, 200)
                self.assertEqual(body, b"x" * maximum)
            with self.subTest(path=path, oversize=True), self.export_view(
                    select.replace(str(maximum), str(maximum + 1))):
                self.assertEqual(self.request(path)[0], 503)
                self.assertEqual(self.request("/health/live")[0], 200)

    def test_export_database_work_obeys_the_request_deadline(self):
        select = ("SELECT route,body,sha256,media_type,revision,acceptance_commit FROM {source} "
                  "CROSS JOIN (SELECT pg_catalog.pg_sleep(3)) AS stalled")
        with self.export_view(select):
            started = time.monotonic()
            self.assertEqual(self.request("/registry/v1/index.json")[0], 503)
            self.assertLess(time.monotonic() - started, 2.8)
            self.assertEqual(self.request("/health/live")[0], 200)

    def test_cli_and_bind_configuration_fail_closed(self):
        self.reject(arguments=(), expected=64)
        self.reject(arguments=("migrate",), expected=64)
        for bind in ("", "localhost:8080", "127.0.0.1:0", "127.0.0.1:80", "127.0.0.1:65536", "::1:8080", "0.0.0.0:8080junk"):
            with self.subTest(bind=bind):
                self.reject(bind=bind)

    def test_private_configuration_file_is_required(self):
        for content in ("", "x" * 4097, "postgresql://x\x00y", "postgresql://x\ny"):
            self.reject(content=content)
        path = self.base / "public.url"
        path.write_text(self.configs["reader"].read_text())
        path.chmod(0o644)
        self.reject(config=path)
        link = self.base / "linked.url"
        link.symlink_to(self.configs["reader"])
        self.reject(config=link)
        self.reject(config=self.base)

    def test_tls_policy_rejects_ambient_options_and_ambiguous_connections(self):
        raw = self.configs["reader"].read_text().strip()
        for value in (raw.replace("verify-full", "disable"), raw.replace("verify-full", "require"),
                      raw + "&sslmode=verify-full", raw + "&options=-c%20search_path=public",
                      raw.replace("&hostaddr=127.0.0.1", ""), raw.replace("127.0.0.1", "localhost"),
                      raw.replace("@localhost", ":secret@localhost")):
            with self.subTest(value=value.replace(raw, "valid-prefix")):
                self.reject(content=value, PGSSLMODE="disable", PGSERVICE="untrusted")

    def test_reader_rejects_migrator_operator_and_wrong_tls_identities(self):
        self.reject(config=self.configs["migrator"])
        self.reject(config=self.configs["operator"])
        self.reject(content=self.url(self.roles["reader"], "reader", host="wrong.invalid"))
        self.reject(content=self.url(self.roles["reader"], "operator"))
        raw = self.configs["reader"].read_text()
        self.reject(content=raw.replace("ca.crt", "unrelated.crt"))

    def test_readiness_checks_actual_permissions_after_start(self):
        role = self.roles["reader"]
        self.admin.execute(f'REVOKE SELECT ON asm_catalog.current_exports FROM "{role}"')
        try:
            code, _, _ = self.request("/health/ready")
            self.assertEqual(code, 503)
            self.assertEqual(self.request("/health/live")[0], 200)
            for path in self.exports:
                self.assertEqual(self.request(path)[0], 503)
        finally:
            self.admin.execute(f'GRANT SELECT ON asm_catalog.current_exports TO "{role}"')
        self.assertEqual(self.request("/health/ready")[0], 200)
        for schema in ("pgxtemp_", "pgxtempx", "pgxtoast_temp_", "pgxtoastxtempx"):
            with self.subTest(schema=schema):
                self.admin.execute(f'CREATE SCHEMA "{schema}"')
                try:
                    self.admin.execute(f'GRANT CREATE ON SCHEMA "{schema}" TO "{role}"')
                    self.assertEqual(self.request("/health/ready")[0], 503)
                    self.assertEqual(self.request("/registry/v1/index.json")[0], 503)
                    self.assertEqual(self.request("/health/live")[0], 200)
                finally:
                    self.admin.execute(f'DROP SCHEMA "{schema}"')
                self.assertEqual(self.request("/health/ready")[0], 200)

    def test_new_connections_load_replaced_certificate_files(self):
        cert = self.cluster.base / "reader.crt"
        key = self.cluster.base / "reader.key"
        old_cert, old_key = cert.read_bytes(), key.read_bytes()
        self.cluster.certificate("rotated", self.roles["reader"])
        try:
            cert.write_bytes((self.cluster.base / "rotated.crt").read_bytes())
            key.write_bytes((self.cluster.base / "rotated.key").read_bytes())
            self.assertNotEqual(cert.read_bytes(), old_cert)
            self.assertEqual(self.request("/health/ready")[0], 200)
            cert.write_bytes((self.cluster.base / "operator.crt").read_bytes())
            key.write_bytes((self.cluster.base / "operator.key").read_bytes())
            self.assertEqual(self.request("/health/ready")[0], 503)
            self.assertEqual(self.request("/health/live")[0], 200)
            for path in self.exports:
                self.assertEqual(self.request(path)[0], 503)
        finally:
            cert.write_bytes(old_cert)
            key.write_bytes(old_key)
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_stalled_database_handshake_has_a_deadline(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            raw = self.configs["reader"].read_text().replace(
                f":{self.cluster.port}/", f":{listener.getsockname()[1]}/")
            self.reject(content=raw)

    def test_encrypted_client_key_never_prompts_on_an_open_terminal(self):
        encrypted = self.cluster.base / "encrypted.key"
        subprocess.run(["openssl", "pkey", "-in", str(self.cluster.base / "reader.key"),
                        "-aes-256-cbc", "-passout", "stdin", "-out", str(encrypted)],
                       input=b"test-key-password\n", check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=10)
        encrypted.chmod(0o600)
        config = self.base / "encrypted.url"
        config.write_text(self.configs["reader"].read_text().replace("reader.key", "encrypted.key"))
        config.chmod(0o600)
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)

        def terminal_session():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        start = time.monotonic()
        process = subprocess.Popen([str(self.binary), "serve"], stdin=slave,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=self.environment(ASM_DATABASE_URL_FILE=str(config)),
                                   preexec_fn=terminal_session)
        try:
            stdout, stderr = process.communicate(timeout=3)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)
        self.assertEqual(process.returncode, 78)
        self.assertEqual(stdout, b"")
        self.assertNotIn(b"Enter PEM pass phrase", stderr)
        self.assertLess(time.monotonic() - start, 2.8)

    def test_z_sigterm_closes_the_listener_within_three_seconds(self):
        start = time.monotonic()
        self.server.terminate()
        self.assertEqual(self.server.wait(timeout=3), 0)
        self.assertLess(time.monotonic() - start, 3)
        with self.assertRaises(OSError):
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
