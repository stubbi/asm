"""Owned PostgreSQL 18.6 test fixtures; never accept a database target.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import sys
import tempfile
import time
from urllib.parse import quote, urlencode

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry

INDEX = "sha256:39add80f5b1e573e2f6b641c66fd1a2f8dede67ca0330e870285bc1078551390"
PLATFORM = "sha256:9d1808e9b9c82fb1175ecc7aba615e88b16013e8f118c536a8b5a9aca017ec03"
CONFIG = "sha256:e81943bf2a7f93b868b0ce332642e9005ab3bc02d23f7effb505e5a19b7daa42"
DATABASE_IMAGE = "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@" + INDEX
DATA = "/run/asm-postgres18/data"
PREPARATION = Path(".postgres18-fixture")
FIXTURE = Path("/qualification/postgres18")
FILES = {"ca.crt", "ca.key", "server.crt", "unrelated.crt"}
LOG_PATH = "/run/asm-postgres18/postgres.log"
LOG_LIMIT = 1048576
IDENTITY_SQL = ("SELECT current_setting('server_version_num'),current_setting('data_directory'),"
    "current_setting('asm_fixture.nonce'),(SELECT system_identifier::text FROM pg_catalog.pg_control_system()),"
    "current_user,session_user,ssl,version FROM pg_catalog.pg_stat_ssl WHERE pid=pg_catalog.pg_backend_pid()")


def need(condition, message):
    if not condition:
        raise ValueError(message)


def declaration_contract(value, revision):
    need(isinstance(value, dict) and set(value) == {"schema", "source_revision", "nonce", "index_digest",
         "platform_digest", "server_version_num", "port", "data_directory", "files"}, "Unexpected fixture declaration.")
    need(type(value["schema"]) is int and value["schema"] == 1 and
         re.fullmatch(r"[0-9a-f]{40}", revision or "") and value["source_revision"] == revision,
         "The fixture source identity differs.")
    need(re.fullmatch(r"[0-9a-f]{64}", value.get("nonce", "")), "The fixture has no ownership nonce.")
    need(value["index_digest"] == INDEX and value["platform_digest"] == PLATFORM,
         "The fixture does not use the selected database image.")
    need(type(value["server_version_num"]) is int and value["server_version_num"] == 180006 and
         type(value["port"]) is int and value["port"] == 5432 and value["data_directory"] == DATA,
         "The fixture version or fixed endpoint differs.")
    need(isinstance(value["files"], dict) and set(value["files"]) == FILES and
         all(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) for digest in value["files"].values()),
         "The fixture file binding is incomplete.")
    return value


def private_read(path, limit=65536):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        need(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1 and
             not info.st_mode & 0o022 and 0 < info.st_size <= limit, "A fixture file has unsafe ownership or bounds.")
        need(Path(path).name != "ca.key" or not info.st_mode & 0o077, "The synthetic CA key is not private.")
        body = os.read(descriptor, limit + 1)
        need(len(body) == info.st_size, "A fixture file changed during its read.")
        return body
    finally:
        os.close(descriptor)


def read_declaration(directory, revision):
    value = declaration_contract(registry.strict_json(private_read(Path(directory) / "fixture.json", 8192)), revision)
    for name, digest in value["files"].items():
        need(hashlib.sha256(private_read(Path(directory) / name)).hexdigest() == digest,
             "A fixture certificate binding differs.")
    return value


def preparation_owner(directory):
    directory = Path(directory)
    info = directory.lstat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and info.st_mode & 0o777 == 0o700,
         "The preparation directory is not owned and private.")
    owner = registry.strict_json(private_read(directory / "owner.json", 1024))
    need(isinstance(owner, dict) and set(owner) == {"device", "inode", "nonce"} and
         type(owner["device"]) is type(owner["inode"]) is int and
         (owner["device"], owner["inode"]) == (info.st_dev, info.st_ino) and
         isinstance(owner["nonce"], str) and re.fullmatch(r"[0-9a-f]{64}", owner["nonce"]),
         "The preparation ownership marker differs.")
    return (info.st_dev, info.st_ino), owner["nonce"]


def server_contract(rows, declaration):
    need(isinstance(rows, list) and len(rows) == 1 and len(rows[0]) == 8, "The owned server identity is ambiguous.")
    version, data, nonce, identifier, user, session, tls, protocol = rows[0]
    need(version == "180006" and data == DATA and nonce == declaration["nonce"], "The connected server is not this fixture.")
    need(re.fullmatch(r"[1-9][0-9]{0,19}", identifier or "") and int(identifier) < 2 ** 64,
         "The fixture has no database system identifier.")
    need(user == session == "asm_fixture_admin" and tls == "t" and protocol in {"TLSv1.2", "TLSv1.3"},
         "The fixture administration connection lacks its exact TLS identity.")
    return {"server_version_num": 180006, "data_directory": data, "nonce": nonce,
            "system_identifier": identifier, "session_user": session, "tls_protocol": protocol}


def postgres_log_bytes(admin, declaration, identity):
    need(server_contract(admin.execute(IDENTITY_SQL), declaration) == identity,
         "The database log source changed its owned identity.")
    rows = admin.execute("SELECT pg_catalog.encode(pg_catalog.pg_read_binary_file('" + LOG_PATH +
                         "',0,1048577),'hex')")
    need(isinstance(rows, list) and len(rows) == 1 and len(rows[0]) == 1 and isinstance(rows[0][0], str) and
         len(rows[0][0]) <= LOG_LIMIT * 2 and re.fullmatch(r"(?:[0-9a-f]{2})+", rows[0][0]),
         "The owned database log is absent, malformed, or exceeds its bound.")
    body = bytes.fromhex(rows[0][0])
    body.decode("utf-8")
    return body


def postgres_factory(tls_type, database_type, declaration, identities):
    """Select this provider explicitly in image tests, leaving the 16.15 provider unchanged."""
    class OwnedPostgres18(tls_type):
        def start(self):
            self.temp = tempfile.TemporaryDirectory(prefix="asm-owned-pg18-", dir=self.parent)
            self.base = Path(self.temp.name)
            self.port = 5432
            try:
                for name in FILES:
                    body = private_read(FIXTURE / name)
                    need(hashlib.sha256(body).hexdigest() == declaration["files"][name], "The fixture CA or certificate changed.")
                    (self.base / name).write_bytes(body)
                    (self.base / name).chmod(0o600)
                self.certificate("asm_fixture_admin", "asm_fixture_admin")
                deadline = time.monotonic() + 10
                while True:
                    try:
                        self.admin = database_type(self.url(), deadline=deadline)
                        break
                    except RuntimeError:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(0.05)
                self.identity = server_contract(self.admin.execute(IDENTITY_SQL), declaration)
                identities.append(self.identity)
                return self
            except BaseException:
                self.close()
                raise

        def url(self, *, database="postgres", role="asm_fixture_admin", password=None, port=None):
            need(re.fullmatch(r"[a-z0-9_]+", database) and role == "asm_fixture_admin" and password is None and port is None,
                 "Only owned fixture administration can use this URL.")
            values = {"hostaddr": "127.0.0.1", "sslmode": "verify-full", "gssencmode": "disable", "connect_timeout": "2",
                      "options": "-c statement_timeout=5000 -c lock_timeout=1000"}
            values.update({key: str(self.base / name) for key, name in (("sslrootcert", "ca.crt"),
                           ("sslcert", "asm_fixture_admin.crt"), ("sslkey", "asm_fixture_admin.key"))})
            return "postgresql://asm_fixture_admin@localhost:5432/" + database + "?" + urlencode(values, quote_via=quote)

        def close(self):
            if self.admin is not None:
                self.admin.close()
                self.admin = None
            if self.temp is not None:
                self.temp.cleanup()
                self.temp = None

        def postgres_log_bytes(self):
            return postgres_log_bytes(self.admin, declaration, self.identity)

    return OwnedPostgres18


def prepare(directory, revision):
    directory = Path(directory).absolute()
    directory.mkdir(mode=0o700)
    original = directory.stat()
    nonce = secrets.token_hex(32)
    (directory / "owner.json").write_text(json.dumps({"nonce": nonce, "device": original.st_dev, "inode": original.st_ino}))
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
        from test_runtime import TlsPostgres
        app, server = directory / "app", directory / "server"
        app.mkdir(mode=0o700)
        server.mkdir(mode=0o700)
        tls = TlsPostgres(app)
        tls.base = app
        for name, common in (("ca", "Asm PostgreSQL 18 fixture CA"), ("unrelated", "Unrelated fixture CA")):
            tls.openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=" + common,
                        "-addext", "basicConstraints=critical,CA:TRUE", "-keyout", name + ".key", "-out", name + ".crt")
        tls.certificate("server", "localhost", server=True)
        for name in ("ca.crt", "server.crt", "server.key"):
            shutil.copyfile(app / name, server / name)
        (server / "nonce").write_text(nonce + "\n")
        for path in tuple(app.iterdir()):
            if path.name not in FILES:
                path.unlink()
        declaration = declaration_contract({"schema": 1, "source_revision": revision, "nonce": nonce,
            "index_digest": INDEX, "platform_digest": PLATFORM, "server_version_num": 180006, "port": 5432,
            "data_directory": DATA, "files": {name: hashlib.sha256((app / name).read_bytes()).hexdigest() for name in sorted(FILES)}}, revision)
        (app / "fixture.json").write_text(json.dumps(declaration, sort_keys=True) + "\n")
        for path in directory.rglob("*"):
            if path.is_file():
                path.chmod(0o600)
        return declaration
    except BaseException:
        remove_preparation(directory, (original.st_dev, original.st_ino), nonce)
        raise


def remove_preparation(directory, identity, nonce):
    directory = Path(directory)
    info = directory.lstat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and (info.st_dev, info.st_ino) == identity,
         "The private preparation directory was replaced; preserve it for inspection.")
    owner = registry.strict_json(private_read(directory / "owner.json", 1024))
    need(owner == {"nonce": nonce, "device": identity[0], "inode": identity[1]}, "The preparation ownership marker differs.")
    shutil.rmtree(directory)
