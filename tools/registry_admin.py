#!/usr/bin/env python3
"""Explicit operator tooling for the hosted canonical catalog.

SPDX-License-Identifier: AGPL-3.0-or-later
The native CLI and registry HTTP application remain assembly.
"""
from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import ipaddress
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import subprocess
import sys
import time
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit

import registry

ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE_REPOSITORY = "https://github.com/stubbi/asm"
MAX_RECORD_BYTES = 65536
MAX_RECORDS_BYTES = 16 * 1024 * 1024
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_OUTPUT_BYTES = 9 * 1024 * 1024
ROUTES = ("/registry/v1/index.tsv", "/registry/v1/index-macos.tsv", "/registry/v1/index.json")
MIGRATION_SHA384 = "259a54d22fcd1e53addf4f5f197d7ca0f7c5040e2492776fc60a30f59cd1428a6618f4ec39fa1f3df867d4b05ee2d9ae"


class AdminError(ValueError):
    """A bounded operator operation failed without exposing provider details."""


def require(condition, message):
    if not condition:
        raise AdminError(message)


def run_bounded(arguments, *, data=b"", environment=None, output_limit=MAX_OUTPUT_BYTES,
                timeout=20, pass_fds=()):
    """Bound child time and both output streams before parsing any result.

    Arguments are an array for one fixed executable. No shell interprets data.
    A failed mutation can have an unknown remote result; callers must replay its identity.
    """
    process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=environment, pass_fds=pass_fds, start_new_session=True)
    output, errors = bytearray(), bytearray()
    selector = selectors.DefaultSelector()
    pending = memoryview(data)
    deadline = time.monotonic() + timeout
    try:
        for stream in (process.stdout, process.stderr, process.stdin):
            os.set_blocking(stream.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ, output)
        selector.register(process.stderr, selectors.EVENT_READ, errors)
        if pending:
            selector.register(process.stdin, selectors.EVENT_WRITE, None)
        else:
            process.stdin.close()
        while selector.get_map():
            remaining = deadline - time.monotonic()
            require(remaining > 0, "The child deadline expired. Inspect the operation identity before replay.")
            events = selector.select(remaining)
            require(events, "The child deadline expired. Inspect the operation identity before replay.")
            for key, mask in events:
                if mask & selectors.EVENT_WRITE:
                    try:
                        amount = os.write(key.fd, pending[:65536])
                        pending = pending[amount:]
                    except BrokenPipeError:
                        pending = pending[:0]
                    if not pending:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                else:
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    key.data.extend(chunk)
                    limit = output_limit if key.data is output else 65536
                    require(len(key.data) <= limit, "The child response exceeds its byte limit.")
        require(process.wait(timeout=max(0.01, deadline - time.monotonic())) == 0,
                "The child operation failed. Inspect its source and operation identity before replay.")
        return bytes(output)
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
        for stream in (process.stdin, process.stdout, process.stderr):
            if not stream.closed:
                stream.close()


def clean_environment():
    return {"PATH": os.defpath, "LC_ALL": "C", "TZ": "UTC", "HOME": "/nonexistent",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_ALLOW_PROTOCOL": ""}


def committed_records(repository: Path, commit: str):
    require(re.fullmatch(r"[0-9a-f]{40}", commit or "") and commit != "0" * 40,
            "Use a nonzero full lowercase Git commit ID.")
    executable = shutil.which("git")
    require(executable is not None, "Install Git before reading an accepted source commit.")

    def git(*arguments, maximum=2 * 1024 * 1024):
        return run_bounded([executable, "--no-replace-objects", "-c", "credential.helper=",
            "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "fsck.skipList=/dev/null",
            "-C", str(repository), *arguments], environment=clean_environment(), output_limit=maximum)

    require(git("cat-file", "-t", commit, maximum=32).strip() == b"commit", "Source ID is not a commit.")
    # cat-file alone trusts loose object filenames. Verify the commit/tree/blob graph first.
    git("fsck", "--strict", "--no-reflogs", "--no-dangling", "--no-progress", commit)
    listing = git("ls-tree", "-r", "-z", "--full-tree", commit, "--", "registry/packages")
    records, total = [], 0
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        try:
            metadata, raw_path = entry.split(b"\t", 1)
            mode, kind, blob = metadata.decode("ascii").split()
            path = raw_path.decode("ascii")
        except (ValueError, UnicodeError):
            raise AdminError("Invalid committed registry path or object.") from None
        require(mode == "100644" and kind == "blob", "Invalid registry object type or mode.")
        size = int(git("cat-file", "-s", blob, maximum=32))
        require(0 <= size <= MAX_RECORD_BYTES, "Invalid manifest byte size.")
        body = git("cat-file", "blob", blob, maximum=MAX_RECORD_BYTES)
        require(len(body) == size, "The manifest blob size changed.")
        if path == "registry/packages/.gitkeep" and not body:
            continue
        total += size
        require(total <= MAX_RECORDS_BYTES and len(records) < 4096, "The catalog exceeds its record limit.")
        record = registry.validate_manifest(registry.strict_json(body))
        require(path == f"registry/packages/{record['name']}/{record['version']}.json",
                "Invalid committed manifest path.")
        records.append(record)
    return registry.check_records(records)


def prepare_import(repository: Path, commit: str, expected_revision: int):
    require(type(expected_revision) is int and 0 <= expected_revision < 2**63 - 1,
            "Use a nonnegative expected revision below 9223372036854775807.")
    records = committed_records(repository, commit)
    canonical = [registry.json_bytes(record).decode("ascii") for record in records]
    tsv, index = registry.make_indexes(records)
    exports = (registry.legacy_tsv(tsv), tsv, registry.json_bytes(index).decode("ascii"))
    require(len(exports[2].encode("ascii")) <= MAX_JSON_BYTES, "The JSON export exceeds four MiB.")
    plan = {"schema": 1, "acceptance_repository": ACCEPTANCE_REPOSITORY,
            "acceptance_commit": commit, "expected_revision": expected_revision,
            "record_count": len(records), "records_sha256": hashlib.sha256(registry.json_bytes(records)).hexdigest(),
            "validator_sha256": hashlib.sha256(Path(registry.__file__).read_bytes()).hexdigest(),
            "artifact_bytes_checked": False,
            "exports": {route: {"bytes": len(body.encode("ascii")),
                "sha256": hashlib.sha256(body.encode("ascii")).hexdigest()}
                for route, body in zip(ROUTES, exports)}}
    plan["plan_sha256"] = hashlib.sha256(registry.json_bytes(plan)).hexdigest()
    return plan, canonical, exports


def sql_text(value):
    # Hex contains no SQL, quotes, delimiters, or psql metacommands from input data.
    return "convert_from(decode('" + value.encode("utf-8").hex() + "','hex'),'UTF8')"


def reject_extended_acl(descriptor):
    """Inspect the opened file, not its replaceable path. Reject all extended ACLs."""
    if sys.platform == "darwin":
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        library.acl_get_fd_np.argtypes = (ctypes.c_int, ctypes.c_int)
        library.acl_get_fd_np.restype = ctypes.c_void_p
        library.acl_free.argtypes = (ctypes.c_void_p,)
        ctypes.set_errno(0)
        acl = library.acl_get_fd_np(descriptor, 0x100)  # macOS ACL_TYPE_EXTENDED
        if acl:
            library.acl_free(acl)
            raise AdminError("Use credential files without extended ACLs.")
        require(ctypes.get_errno() == errno.ENOENT, "Cannot inspect the credential file ACL.")
    elif sys.platform == "linux":
        try:
            os.getxattr(descriptor, "system.posix_acl_access")
        except OSError as error:
            require(error.errno == errno.ENODATA, "Cannot inspect the credential file ACL.")
        else:
            raise AdminError("Use credential files without extended ACLs.")
    else:
        raise AdminError("Use the qualified Linux or macOS operator host.")


def open_checked(path, maximum, *, private=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= maximum,
                "Use a bounded single-link regular credential file.")
        require(info.st_uid == os.geteuid() and not info.st_mode & (0o077 if private else 0o022),
                "Use owner-controlled credential files with protected permissions.")
        reject_extended_acl(descriptor)
        body = os.read(descriptor, maximum + 1)
        require(len(body) <= maximum, "The credential file exceeds its byte limit.")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor, body
    except BaseException:
        os.close(descriptor)
        raise


class Connection:
    """One explicit certificate-only psql authority; does not read ambient profiles.

    Validated certificate descriptors stay open and enter the child through /dev/fd.
    A same-user process can still modify the underlying files; this is not a sandbox.
    """
    def __init__(self, path, executable, role):
        self.descriptors = []
        try:
            require(role in {"asm_migrator", "asm_operator", "asm_reader"}, "Select one fixed catalog role.")
            fd, body = open_checked(path, 8192, private=True)
            self.descriptors.append(fd)
            value = body.decode("ascii").removesuffix("\n")
            require("\n" not in value and "\r" not in value and "\0" not in value,
                    "Use one canonical PostgreSQL connection URL.")
            parsed = urlsplit(value)
            require(parsed.scheme == "postgresql" and not parsed.fragment and parsed.username == role
                    and parsed.password is None and parsed.port is not None and 1 <= parsed.port <= 65535,
                    "Use the required certificate role, explicit host, and port without a password.")
            host = parsed.hostname or ""
            require(len(host) <= 253 and host == parsed.netloc.split("@", 1)[-1].rsplit(":", 1)[0]
                    and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                            for label in host.split(".")), "Use one lowercase DNS host for TLS verification.")
            require(re.fullmatch(r"/[a-z][a-z0-9_]{0,62}", parsed.path), "Use one bounded database name.")
            pairs = parse_qsl(parsed.query, strict_parsing=True, keep_blank_values=True)
            options = dict(pairs)
            require(len(options) == len(pairs), "Duplicate connection fields are not permitted.")
            required = {"hostaddr", "sslmode", "sslrootcert", "sslcert", "sslkey"}
            allowed = required | {"gssencmode", "connect_timeout", "ssl_min_protocol_version"}
            require(required <= set(options) <= allowed and options["sslmode"] == "verify-full",
                    "Require hostaddr, verify-full TLS, and explicit CA, certificate, and key files.")
            require(str(ipaddress.IPv4Address(options["hostaddr"])) == options["hostaddr"],
                    "Use one canonical IPv4 hostaddr to bound connection resolution.")
            require(options.get("gssencmode", "disable") == "disable"
                    and options.get("connect_timeout", "2") == "2"
                    and options.get("ssl_min_protocol_version", "TLSv1.2") in {"TLSv1.2", "TLSv1.3"},
                    "Use the reviewed connection deadline and TLS policy.")
            for name in ("sslrootcert", "sslcert", "sslkey"):
                require(Path(options[name]).is_absolute(), "Certificate paths must be absolute.")
                descriptor, content = open_checked(options[name], 65536, private=name == "sslkey")
                self.descriptors.append(descriptor)
                if name == "sslkey":
                    require(content.startswith((b"-----BEGIN PRIVATE KEY-----", b"-----BEGIN RSA PRIVATE KEY-----"))
                            and b"ENCRYPTED" not in content,
                            "Use an unencrypted private PEM key through the protected owner route.")
                options[name] = "/dev/fd/" + str(descriptor)
            options.update(connect_timeout="2", gssencmode="disable", passfile=os.devnull,
                           ssl_min_protocol_version=options.get("ssl_min_protocol_version", "TLSv1.2"),
                           options="-c statement_timeout=15000 -c lock_timeout=2000 -c search_path=pg_catalog,pg_temp -c standard_conforming_strings=on -c client_min_messages=warning")
            self.url = urlunsplit(("postgresql", f"{role}@{host}:{parsed.port}", parsed.path,
                                   urlencode(options, quote_via=quote), ""))
            candidate = Path(executable).resolve()
            require(candidate.is_file() and os.access(candidate, os.X_OK), "Select the reviewed PostgreSQL psql executable.")
            self.executable = str(candidate)
            self.environment = {"PATH": os.defpath, "LC_ALL": "C", "TZ": "UTC", "HOME": "/nonexistent",
                "PGPASSFILE": os.devnull, "PGSERVICEFILE": os.devnull, "PGSYSCONFDIR": "/nonexistent",
                "PSQL_HISTORY": os.devnull}
            version = run_bounded([self.executable, "--version"], environment=self.environment, output_limit=256)
            require(re.search(rb"\(PostgreSQL\) 16\.15(?:\s|$)", version), "Use the reviewed PostgreSQL 16.15 client.")
            self.role = role
        except BaseException:
            self.close()
            raise

    def execute(self, sql):
        # The private configuration and key bytes never enter SQL or the error stream.
        prefix = f"""DO $authority$ BEGIN
          IF current_user <> '{self.role}' OR session_user <> current_user OR
            NOT coalesce((SELECT ssl FROM pg_catalog.pg_stat_ssl WHERE pid=pg_catalog.pg_backend_pid()),false) OR
            EXISTS(SELECT 1 FROM pg_catalog.pg_roles r WHERE
              (r.rolname=current_user OR pg_catalog.pg_has_role(current_user,r.oid,'MEMBER'))
              AND (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls))
          THEN RAISE EXCEPTION 'Operator authority refused'; END IF;
        END $authority$;\n"""
        try:
            for descriptor in self.descriptors:
                os.lseek(descriptor, 0, os.SEEK_SET)
            result = run_bounded([self.executable, "--no-psqlrc", "--no-password", "--quiet", "--no-align",
                "--tuples-only", "--pset", "pager=off", "--set", "ON_ERROR_STOP=1", "--dbname", self.url,
                "--file", "-"], data=(prefix + sql).encode(), environment=self.environment,
                timeout=30, pass_fds=tuple(self.descriptors))
            return result.decode("utf-8")
        except (AdminError, OSError, UnicodeError, subprocess.TimeoutExpired):
            raise AdminError("Database operation failed or its outcome is unknown. Inspect status before replaying the same accepted commit.") from None

    def close(self):
        for descriptor in self.descriptors:
            os.close(descriptor)
        self.descriptors.clear()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def migrate(connection):
    source = ROOT / "server/catalog/schema.sql"
    body = source.read_bytes()
    require(hashlib.sha384(body).hexdigest() == MIGRATION_SHA384,
            "The catalog migration differs from its reviewed digest.")
    sql = f"""BEGIN;
      SELECT pg_catalog.pg_advisory_xact_lock(1095978307,0) AS migration_lock \\gset
      SELECT pg_catalog.to_regnamespace('asm_catalog') IS NULL AS install_schema \\gset
      \\if :install_schema
      {body.decode()}
      INSERT INTO asm_catalog.schema_version VALUES(1,'{MIGRATION_SHA384}');
      \\else
      DO $check$ BEGIN
        IF (SELECT count(*) FROM asm_catalog.schema_version) <> 1 OR
           NOT EXISTS(SELECT 1 FROM asm_catalog.schema_version WHERE version=1 AND sha384='{MIGRATION_SHA384}') OR
           (SELECT pg_catalog.pg_get_userbyid(nspowner) FROM pg_catalog.pg_namespace WHERE nspname='asm_catalog') <> 'asm_migrator'
        THEN RAISE EXCEPTION 'Catalog migration state differs'; END IF;
      END $check$;
      \\endif
      COMMIT;
    """
    connection.execute(sql)
    return {"status": "migrated", "schema": 1, "migration_sha384": MIGRATION_SHA384}


def grant(connection):
    connection.execute("""BEGIN;
      REVOKE ALL ON SCHEMA asm_catalog FROM PUBLIC,asm_reader,asm_operator;
      REVOKE ALL ON ALL TABLES IN SCHEMA asm_catalog FROM PUBLIC,asm_reader,asm_operator;
      REVOKE ALL ON ALL SEQUENCES IN SCHEMA asm_catalog FROM PUBLIC,asm_reader,asm_operator;
      REVOKE ALL ON ALL FUNCTIONS IN SCHEMA asm_catalog FROM PUBLIC,asm_reader,asm_operator;
      GRANT USAGE ON SCHEMA asm_catalog TO asm_reader,asm_operator;
      GRANT SELECT ON asm_catalog.current_exports,asm_catalog.schema_version TO asm_reader,asm_operator;
      GRANT SELECT ON asm_catalog.releases,asm_catalog.head,asm_catalog.snapshots,asm_catalog.namespaces TO asm_operator;
      GRANT EXECUTE ON FUNCTION asm_catalog.bind_namespace(text,bigint,text),
        asm_catalog.publish(text,bigint,text[],text,text,text) TO asm_operator;
      COMMIT;""")
    return {"status": "granted", "reader_role": "asm_reader", "operator_role": "asm_operator"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection-file", type=Path)
    parser.add_argument("--psql", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "import"):
        item = commands.add_parser(name, help="Prepare or apply one accepted canonical catalog.")
        item.add_argument("--repository", type=Path, required=True)
        item.add_argument("--commit", required=True)
        item.add_argument("--expected-revision", type=int, required=True)
        if name == "import":
            item.add_argument("--plan-sha256", required=True)
    for name in ("migrate", "grant", "status"):
        commands.add_parser(name)
    binding = commands.add_parser("bind-namespace")
    binding.add_argument("--namespace", required=True)
    binding.add_argument("--github-id", type=int, required=True)
    binding.add_argument("--acceptance-commit", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command in {"plan", "import"}:
            prepared, records, exports = prepare_import(args.repository, args.commit, args.expected_revision)
            if args.command == "plan":
                sys.stdout.buffer.write(registry.json_bytes(prepared))
                return 0
            require(args.plan_sha256 == prepared["plan_sha256"], "The reviewed import plan digest differs.")
        if args.command == "bind-namespace":
            registry.package_name(args.namespace + "/namespace-check")
            require(0 < args.github_id <= 2**63 - 1, "Use a positive numeric GitHub identity.")
            require(re.fullmatch(r"[0-9a-f]{40}", args.acceptance_commit or "")
                    and args.acceptance_commit != "0" * 40, "Use a nonzero full acceptance commit.")
        require(args.connection_file is not None and args.psql is not None,
                "Specify the private connection file and reviewed psql executable.")
        role = "asm_migrator" if args.command in {"migrate", "grant"} else "asm_operator"
        with Connection(args.connection_file, args.psql, role) as connection:
            if args.command == "migrate":
                result = migrate(connection)
            elif args.command == "grant":
                result = grant(connection)
            elif args.command == "bind-namespace":
                connection.execute("SELECT asm_catalog.bind_namespace(" + sql_text(args.namespace) +
                    "," + str(args.github_id) + "," + sql_text(args.acceptance_commit) + ") AS bound \\gset\n")
                result = {"status": "namespace-bound", "namespace": args.namespace,
                          "github_id": args.github_id, "ownership_evidence": "operator-assertion"}
            elif args.command == "status":
                raw = connection.execute("SELECT json_build_object('revision',coalesce((SELECT revision FROM asm_catalog.head),0),'acceptance_commit',(SELECT acceptance_commit FROM asm_catalog.current_exports LIMIT 1));")
                result = registry.strict_json(raw)
            else:
                array = "ARRAY[" + ",".join(sql_text(record) for record in records) + "]::text[]"
                raw = connection.execute("SELECT asm_catalog.publish(" + sql_text(args.commit) + "," +
                    str(args.expected_revision) + "," + array + "," + ",".join(sql_text(body) for body in exports) + ");")
                require(re.fullmatch(r"[1-9][0-9]*\n", raw), "The database returned an invalid revision.")
                result = {"status": "imported", "revision": int(raw), "acceptance_commit": args.commit,
                          "plan_sha256": prepared["plan_sha256"], "artifact_bytes_checked": False}
        sys.stdout.buffer.write(registry.json_bytes(result))
        return 0
    except AdminError as error:
        print("registry-admin: " + str(error), file=sys.stderr)
        return 1
    except (registry.RegistryError, OSError, ValueError, RecursionError, subprocess.TimeoutExpired):
        print("registry-admin: invalid source or credential input. Check the documented file and metadata requirements.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
