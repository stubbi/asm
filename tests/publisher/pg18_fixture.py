"""Explicit, owned PostgreSQL 18.6 server with unchanged 16.15 clients.

SPDX-License-Identifier: AGPL-3.0-or-later
No existing database, external endpoint, or production credential is accepted.
"""
import ctypes
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server"))
import test_runtime as reader_fixture
from local_postgres import LocalPostgres, clean_environment, verify_version


class Pg18TlsPostgres(reader_fixture.TlsPostgres):
    """Change only the owned server selection and its explicit TLS identity."""
    def server_binaries(self, env):
        value = os.environ.get("ASM_PROTO_PG18_BINDIR")
        if not value:
            raise RuntimeError("Supply ASM_PROTO_PG18_BINDIR for the owned PostgreSQL 18.6 server.")
        bindir = Path(value).resolve()
        for name in ("initdb", "postgres"):
            result = subprocess.run([str(bindir / name), "--version"], env=env,
                                    capture_output=True, text=True, timeout=3, check=True)
            if not re.search(r"\(PostgreSQL\) 18\.6(?:\s|$)", result.stdout):
                raise RuntimeError("Use the reviewed PostgreSQL 18.6 server fixture binaries.")
        return bindir

    def _initialize(self, bindir, env):
        super()._initialize(bindir, env)
        self.certificate("asm_fixture_admin", "asm_fixture_admin")

    def url(self, *, database="postgres", role="asm_fixture_admin", password=None, port=None):
        # The base validates identifiers and generated credentials. Keep its
        # fixed loopback address; no caller can select an existing database.
        parsed = urlsplit(super().url(database=database, role=role, password=password, port=port))
        query = dict(parse_qsl(parsed.query))
        query.update(sslmode="verify-full", sslrootcert=str(self.base / "ca.crt"),
                     sslcert=str(self.base / (role + ".crt")), sslkey=str(self.base / (role + ".key")))
        authority = parsed.netloc.replace("@127.0.0.1:", "@localhost:")
        return urlunsplit((parsed.scheme, authority, parsed.path, urlencode(query, quote_via=quote), ""))

    def start(self):
        try:
            super().start()
            # LocalPostgres has already checked the owned data directory and
            # live process. Verify the actual server and this TLS connection.
            actual = self.admin.execute("SELECT current_setting('server_version_num'), ssl "
                                        "FROM pg_stat_ssl WHERE pid=pg_backend_pid()")
            if actual != [["180006", "t"]]:
                raise RuntimeError("The owned PostgreSQL 18.6 fixture requires its actual version and verified TLS.")
            return self
        except BaseException:
            self.close()
            raise


def preflight():
    """Validate both distinct binary profiles without creating a database."""
    for name in ("ASM_PROTO_PG_BINDIR", "ASM_PROTO_LIBPQ", "ASM_PROTO_PG18_BINDIR"):
        if not os.environ.get(name):
            raise RuntimeError("Supply " + name + "; no PostgreSQL 18 qualification checks ran.")
    env = dict(clean_environment(), LC_ALL="C", TZ="UTC")
    psql = Path(os.environ["ASM_PROTO_PG_BINDIR"]).resolve() / "psql"
    result = subprocess.run([str(psql), "--version"], env=env,
                            capture_output=True, text=True, timeout=3, check=True)
    verify_version(result.stdout)
    library = ctypes.CDLL(os.environ["ASM_PROTO_LIBPQ"])
    library.PQlibVersion.restype = ctypes.c_int
    if library.PQlibVersion() != 160015:
        raise RuntimeError("Use the reviewed libpq 16.15 fixture library.")
    Pg18TlsPostgres(Path.cwd()).server_binaries(env)
