"""Owned, disposable PostgreSQL fixture. No existing database target is accepted.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import select
import signal
import socket
import subprocess
import tempfile
import time
from urllib.parse import quote, urlencode, urlunsplit


HERE = Path(__file__).resolve().parent
MIGRATION = HERE / "fixtures/0001_registry.sql"
MIGRATION_SHA384 = "e9fce69caa758cb9d15a700d92b76aba0fc3ca466a81624733124a742f2211aadae612ab877bd908a6e1d6ab5e803ef2"
POSTGRES_VERSION = "16.15"


def verify_migration(data):
    """Reject changed fixture bytes before any process or database is created."""
    if hashlib.sha384(data).hexdigest() != MIGRATION_SHA384:
        raise RuntimeError("The fixture migration digest changed. Review the schema and readiness guard.")
    if MIGRATION_SHA384 not in (HERE / "guard.sql").read_text():
        raise RuntimeError("The fixture migration and server readiness guard disagree.")


def verify_version(output):
    match = re.search(r"\(PostgreSQL\) (\d+\.\d+)(?:\s|$)", output)
    if match is None or match[1] != POSTGRES_VERSION:
        raise RuntimeError("Use the reviewed PostgreSQL 16.15 fixture binaries.")


def clean_environment():
    """Keep compiler/library paths, but exclude ambient PostgreSQL settings."""
    return {key: value for key, value in os.environ.items() if not key.startswith("PG")}


class Database:
    """Fixture administration with bounded nonblocking libpq socket waits."""
    def __init__(self, url, *, deadline=None):
        self.lib = ctypes.CDLL(os.environ["ASM_PROTO_LIBPQ"])
        self.lib.PQconnectStart.argtypes = [ctypes.c_char_p]
        self.lib.PQconnectStart.restype = ctypes.c_void_p
        for name in ("PQconnectPoll", "PQsocket", "PQflush", "PQconsumeInput", "PQisBusy"):
            getattr(self.lib, name).argtypes = [ctypes.c_void_p]
            getattr(self.lib, name).restype = ctypes.c_int
        self.lib.PQsetnonblocking.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.lib.PQsetnonblocking.restype = ctypes.c_int
        self.lib.PQsendQuery.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        self.lib.PQsendQuery.restype = ctypes.c_int
        self.lib.PQsendQueryParams.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int,
                                        ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p),
                                        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
        self.lib.PQsendQueryParams.restype = ctypes.c_int
        self.lib.PQgetResult.argtypes = [ctypes.c_void_p]
        self.lib.PQgetResult.restype = ctypes.c_void_p
        self.lib.PQresultStatus.argtypes = [ctypes.c_void_p]
        self.lib.PQresultStatus.restype = ctypes.c_int
        self.lib.PQgetvalue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        self.lib.PQgetvalue.restype = ctypes.c_char_p
        self.lib.PQntuples.argtypes = [ctypes.c_void_p]
        self.lib.PQntuples.restype = ctypes.c_int
        self.lib.PQnfields.argtypes = [ctypes.c_void_p]
        self.lib.PQnfields.restype = ctypes.c_int
        self.lib.PQclear.argtypes = [ctypes.c_void_p]
        self.lib.PQfinish.argtypes = [ctypes.c_void_p]
        self.lib.PQlibVersion.restype = ctypes.c_int
        if self.lib.PQlibVersion() != 160015:
            raise RuntimeError("Use the reviewed libpq 16.15 fixture library.")
        # Explicit URLs originate only in LocalPostgres.url. Clear all defaults
        # before calling libpq, including PGHOST, PGSERVICE, and PGOPTIONS.
        for key in tuple(os.environ):
            if key.startswith("PG"):
                del os.environ[key]
        self.conn = self.lib.PQconnectStart(url.encode())
        try:
            if not self.conn:
                raise RuntimeError("The owned PostgreSQL fixture is unavailable.")
            deadline = min(time.monotonic() + 2, deadline if deadline is not None else float("inf"))
            while True:
                if time.monotonic() >= deadline:
                    raise RuntimeError("The owned PostgreSQL fixture exceeded its connection deadline.")
                status = self.lib.PQconnectPoll(self.conn)
                if status == 3:
                    break
                if status not in (1, 2):
                    raise RuntimeError("The owned PostgreSQL fixture is unavailable.")
                self.wait(status == 2, deadline)
            if self.lib.PQsetnonblocking(self.conn, 1) != 0:
                raise RuntimeError("The owned PostgreSQL fixture cannot use nonblocking I/O.")
        except BaseException:
            self.close()
            raise

    def wait(self, writing, deadline):
        remaining = deadline - time.monotonic()
        descriptor = self.lib.PQsocket(self.conn)
        if remaining <= 0 or descriptor < 0:
            raise RuntimeError("The owned PostgreSQL fixture exceeded its socket deadline.")
        readers, writers, _ = select.select([] if writing else [descriptor],
                                            [descriptor] if writing else [], [], remaining)
        if not readers and not writers:
            raise RuntimeError("The owned PostgreSQL fixture exceeded its socket deadline.")

    def execute(self, sql, params=None, *, deadline=None):
        deadline = min(time.monotonic() + 5.5, deadline if deadline is not None else float("inf"))
        if params is None:
            sent = self.lib.PQsendQuery(self.conn, sql.encode())
        else:
            values = (ctypes.c_char_p * len(params))(
                *(None if value is None else str(value).encode() for value in params))
            sent = self.lib.PQsendQueryParams(self.conn, sql.encode(), len(params), None, values, None, None, 0)
        if sent != 1:
            raise RuntimeError("The owned PostgreSQL fixture could not send its query.")
        while True:
            flushing = self.lib.PQflush(self.conn)
            if flushing == 0:
                break
            if flushing != 1:
                raise RuntimeError("The owned PostgreSQL fixture could not flush its query.")
            self.wait(True, deadline)
        rows = []
        while True:
            if time.monotonic() >= deadline or self.lib.PQconsumeInput(self.conn) != 1:
                raise RuntimeError("The owned PostgreSQL fixture failed within its query deadline.")
            if self.lib.PQisBusy(self.conn):
                self.wait(False, deadline)
                continue
            result = self.lib.PQgetResult(self.conn)
            if not result:
                return rows
            try:
                status = self.lib.PQresultStatus(result)
                if status not in (1, 2):
                    # Never expose a server error that could contain role passwords.
                    raise AssertionError(f"Disposable fixture SQL failed with status {status}.")
                rows = [[self.lib.PQgetvalue(result, i, j).decode()
                         for j in range(self.lib.PQnfields(result))]
                        for i in range(self.lib.PQntuples(result))]
            finally:
                self.lib.PQclear(result)

    def close(self):
        if getattr(self, "conn", None):
            self.lib.PQfinish(self.conn)
            self.conn = None


class LocalPostgres:
    """Owns one new cluster, its process group, private files, and credentials."""
    def __init__(self, parent):
        self.parent = Path(parent)
        self.temp = None
        self.process = None
        self.log = None
        self.admin = None

    def url(self, *, database="postgres", role="asm_fixture_admin", password=None, port=None):
        # Names and secrets are generated by this fixture, never CLI inputs.
        if not re.fullmatch(r"[a-z0-9_]+", database + role):
            raise ValueError("Invalid internal fixture identifier.")
        secret = password if password is not None else self.password
        if not re.fullmatch(r"[0-9a-f]{48}", secret):
            raise ValueError("Invalid internal fixture credential.")
        query = urlencode({"hostaddr": "127.0.0.1", "sslmode": "disable", "gssencmode": "disable",
                           "connect_timeout": "2", "options": "-c statement_timeout=5000 -c lock_timeout=1000"},
                          quote_via=quote)
        return urlunsplit(("postgresql", f"{role}:{secret}@127.0.0.1:{port or self.port}", "/" + database, query, ""))

    def start(self):
        if os.geteuid() == 0:
            raise RuntimeError("Run the local PostgreSQL tests as a non-root user. Do not use sudo.")
        verify_migration(MIGRATION.read_bytes())
        bindir = Path(os.environ["ASM_PROTO_PG_BINDIR"]).resolve()
        env = dict(clean_environment(), LC_ALL="C", TZ="UTC")
        for name in ("initdb", "postgres"):
            result = subprocess.run([str(bindir / name), "--version"], env=env,
                                    capture_output=True, text=True, timeout=3, check=True)
            verify_version(result.stdout)
        self.temp = tempfile.TemporaryDirectory(prefix="asm-owned-pg-", dir=self.parent)
        self.base = Path(self.temp.name)
        self.data = self.base / "data"
        self.password = secrets.token_hex(24)
        password_file = self.base / "password"
        try:
            password_file.write_text(self.password + "\n")
            password_file.chmod(0o600)
            self._initialize(bindir, password_file, env)
            password_file.unlink()
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                self.port = reservation.getsockname()[1]
            self.log = (self.base / "postgres.log").open("wb")
            self.process = subprocess.Popen(
                [str(bindir / "postgres"), "-D", str(self.data), "-p", str(self.port),
                 "-c", "listen_addresses=127.0.0.1", "-c", "unix_socket_directories=",
                 "-c", "max_connections=32", "-c", "shared_buffers=16MB", "-c", "work_mem=1MB",
                 "-c", "max_worker_processes=0", "-c", "max_parallel_workers=0",
                 "-c", "temp_file_limit=32768", "-c", "log_statement=none",
                 "-c", "log_min_error_statement=panic"],
                env=env, stdout=self.log, stderr=self.log, start_new_session=True)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError("The owned PostgreSQL fixture stopped during startup.")
                try:
                    self.admin = Database(self.url(), deadline=deadline)
                    break
                except RuntimeError:
                    time.sleep(0.05)
            if self.admin is None:
                raise RuntimeError("The owned PostgreSQL fixture did not become ready within ten seconds.")
            # A bind race must never redirect DDL to an unrelated local server.
            actual = self.admin.execute("SHOW data_directory", deadline=deadline)[0][0]
            if Path(actual).resolve() != self.data.resolve() or self.process.poll() is not None:
                raise RuntimeError("The connected database is not this fixture's owned cluster.")
            return self
        except BaseException:
            self.close()
            raise

    def _initialize(self, bindir, password_file, env):
        process = subprocess.Popen(
            [str(bindir / "initdb"), "-D", str(self.data), "--username=asm_fixture_admin",
             "--auth-host=scram-sha-256", "--auth-local=scram-sha-256",
             "--pwfile=" + str(password_file), "--encoding=UTF8", "--locale=C", "--no-instructions"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=20)
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)
            raise
        (self.base / "initdb.log").write_bytes(output)
        if process.returncode != 0:
            raise RuntimeError("The owned PostgreSQL fixture could not initialize.")

    def close(self):
        if self.admin is not None:
            self.admin.close()
            self.admin = None
        if self.process is not None and self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
        if self.log is not None:
            self.log.close()
            self.log = None
        if self.temp is not None:
            self.temp.cleanup()
            self.temp = None

    def __enter__(self):
        return self.start()

    def __exit__(self, *_):
        self.close()


def create_catalog(migrator, operator, reader, operator_role):
    """Apply the exact migration and seed fixed records, without an importer."""
    for role in (reader, operator_role):
        if not re.fullmatch(r"asm_proto_[0-9a-f]{12}_[ro]", role):
            raise ValueError("Invalid internal fixture role.")
    data = MIGRATION.read_bytes()
    verify_migration(data)
    migrator.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
    try:
        migrator.execute(data.decode())
        migrator.execute("""CREATE TABLE public._sqlx_migrations (
            version bigint PRIMARY KEY, description text NOT NULL,
            installed_on timestamptz NOT NULL DEFAULT now(), success boolean NOT NULL,
            checksum bytea NOT NULL, execution_time bigint NOT NULL)""")
        migrator.execute("INSERT INTO public._sqlx_migrations (version, description, success, checksum, execution_time) VALUES (1, 'registry', true, decode($1, 'hex'), 0)", [MIGRATION_SHA384])
        migrator.execute(f'''GRANT USAGE ON SCHEMA asm TO "{reader}", "{operator_role}";
            GRANT SELECT ON public._sqlx_migrations TO "{reader}", "{operator_role}";
            GRANT SELECT ON asm.accounts, asm.namespaces, asm.packages, asm.releases, asm.artifacts,
                asm.publication_events, asm.download_observations TO "{reader}";
            GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA asm TO "{operator_role}";
            GRANT USAGE ON ALL SEQUENCES IN SCHEMA asm TO "{operator_role}";''')
        migrator.execute("COMMIT")
    except BaseException:
        migrator.execute("ROLLBACK")
        raise
    operator.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
    try:
        owner_id = operator.execute("INSERT INTO asm.accounts (github_id) VALUES ($1) RETURNING id", [12345])[0][0]
        operator.execute("INSERT INTO asm.namespaces (name, owner_id) VALUES ($1, $2)", ["fixture", owner_id])
        operator.execute("INSERT INTO asm.audit_events (action, subject, detail) VALUES ('namespace_bound', $1, $2::jsonb)", ["fixture", '{"github_id":12345}'])
        for i in range(23):
            name = f"p{i:02d}"
            summary = 'Text "quoted" <script>ignored</script> & data' if i == 0 else f"Assembly fixture {i:02d}"
            # Retain the reviewed reference's declared serialization order.
            # The golden p00.json fixture checks both this order and escaping.
            record = {"schema": 1, "name": f"fixture/{name}", "version": "0.2.0", "summary": summary,
                      "license": "MIT",
                      "source": {"repository": "https://github.com/stubbi/asm", "commit": "a" * 40, "path": "."},
                      "artifacts": [{"target": "x86_64-linux", "kind": "source", "sha256": "b" * 64,
                                     "url": f"https://github.com/stubbi/asm/releases/download/v0.2.0/{name}.tar.gz", "bytes": 512}],
                      "yanked": False}
            digest = hashlib.sha256(json.dumps(record, separators=(",", ":")).encode()).hexdigest()
            package = operator.execute("INSERT INTO asm.packages (namespace, name) VALUES ($1, $2) RETURNING id", ["fixture", name])[0][0]
            release = operator.execute("""INSERT INTO asm.releases
                (package_id, major, minor, patch, summary, license, source_repository, source_commit, source_path, record_digest)
                VALUES ($1, 0, 2, 0, $2, 'MIT', $3, $4, '.', $5) RETURNING id""",
                [package, summary, record["source"]["repository"], "a" * 40, digest])[0][0]
            operator.execute("INSERT INTO asm.artifacts (release_id, ordinal, target, kind, sha256, url, bytes) VALUES ($1, 0, 'x86_64-linux', 'source', $2, $3, 512)",
                             [release, "b" * 64, record["artifacts"][0]["url"]])
            operator.execute("INSERT INTO asm.publication_events (release_id, kind, acceptance_repository, acceptance_commit, yanked) VALUES ($1, 'operator_import', $2, $3, false)",
                             [release, "https://github.com/stubbi/asm", "c" * 40])
            operator.execute("INSERT INTO asm.audit_events (action, subject, detail) VALUES ('release_imported', $1, $2::jsonb)",
                             [record["name"] + "@0.2.0", json.dumps({"record_sha256": digest,
                              "acceptance_repository": "https://github.com/stubbi/asm", "acceptance_commit": "c" * 40})])
        operator.execute("COMMIT")
    except BaseException:
        operator.execute("ROLLBACK")
        raise
