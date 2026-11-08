#!/usr/bin/env python3
"""Private enrollment for direct publication. This is not an HTTP backend.

SPDX-License-Identifier: AGPL-3.0-or-later
Application logic remains assembly. No bearer value enters SQL or stdout.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import secrets
import sys

import registry
import registry_admin as admin
from registry_storage import _absolute, _directory

ROOT = Path(__file__).resolve().parents[1]
MIGRATION_SHA384 = "6865173570e0ea1aafc519facfe9ba1a052bdb655f64df1f15474250d5d6d6180c62fcb530ef7766592e4c2afbb592f4"
DISTRIBUTION_MIGRATION_SHA384 = "235cdae69afec2e6f9c6e9ebe76ccb8ff47049021b1ce0296831ae39a770b12c50f95742ae3134602e3f8e8e70139e04"
HEX32 = re.compile(r"[0-9a-f]{32}")
TOKEN = re.compile(rb"asm_pub_v1_[0-9a-f]{64}\n?")


def _identifier(value):
    admin.require(isinstance(value, str) and HEX32.fullmatch(value) is not None, "Use a complete 32-character identity.")
    return value


def _reference(value):
    admin.require(isinstance(value, str) and re.fullmatch(r"[ -~]{1,256}", value) is not None,
                  "Use a bounded printable audit reference.")
    return value


def _array(values):
    return "ARRAY[" + ",".join(admin.sql_text(value) for value in values) + "]::text[]"


def token_file(path, *, reuse=False):
    """Create one complete private token without replacing a destination.

    Creation uses a checked parent descriptor. Reuse follows trusted operator
    parents and checks the final file. Same-user malicious processes and trusted
    administrators remain outside this boundary.
    """
    path = _absolute(path)
    with _directory(path.parent, private=True) as parent:
        admin.reject_extended_acl(parent)
        if reuse:
            descriptor, data = admin.open_checked(path, 76, private=True)
            os.close(descriptor)
            admin.require(TOKEN.fullmatch(data) is not None, "The saved token file is invalid; preserve it for inspection.")
            return data.removesuffix(b"\n").decode("ascii")
        token = "asm_pub_v1_" + secrets.token_hex(32)
        temporary = ".asm-publisher-token-" + secrets.token_hex(16)
        descriptor = None
        try:
            descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 0o600, dir_fd=parent)
            admin.reject_extended_acl(descriptor)
            pending = memoryview((token + "\n").encode("ascii"))
            while pending:
                amount = os.write(descriptor, pending)
                admin.require(amount > 0, "The private token write did not finish.")
                pending = pending[amount:]
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = None
            os.link(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
            os.unlink(temporary, dir_fd=parent)
            os.fsync(parent)
            return token
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(temporary, dir_fd=parent)
            except FileNotFoundError:
                pass


def migrate(connection):
    source = (ROOT / "server/publisher/schema.sql").read_bytes()
    admin.require(hashlib.sha384(source).hexdigest() == MIGRATION_SHA384,
                  "The publication migration differs from its reviewed digest.")
    sql = f"""BEGIN;
SELECT pg_catalog.pg_advisory_xact_lock(1095978320,2) AS migration_lock \\gset
SELECT pg_catalog.to_regnamespace('asm_publication') IS NULL AS install_schema \\gset
\\if :install_schema
{source.decode('ascii')}
INSERT INTO asm_publication.schema_version VALUES(1,'{MIGRATION_SHA384}');
\\else
DO $check$ BEGIN
 IF (SELECT count(*) FROM asm_publication.schema_version)<>1 OR NOT EXISTS(
   SELECT 1 FROM asm_publication.schema_version WHERE version=1 AND sha384='{MIGRATION_SHA384}') OR
   (SELECT pg_catalog.pg_get_userbyid(nspowner) FROM pg_catalog.pg_namespace WHERE nspname='asm_publication')<>'asm_migrator'
 THEN RAISE EXCEPTION 'Publication migration state differs'; END IF;
END $check$;
\\endif
COMMIT;
"""
    connection.execute(sql)
    return {"status": "migrated", "schema": 1, "migration_sha384": MIGRATION_SHA384}


def migrate_distribution(connection):
    """Install distribution independently without changing the publication pin."""
    source = (ROOT / "server/publisher/distribution.sql").read_bytes()
    admin.require(hashlib.sha384(source).hexdigest() == DISTRIBUTION_MIGRATION_SHA384,
                  "The distribution migration differs from its reviewed digest.")
    sql = f"""BEGIN;
SELECT pg_catalog.pg_advisory_xact_lock(1095978320,2) AS migration_lock \\gset
DO $check$ BEGIN
 IF (SELECT count(*) FROM asm_publication.schema_version)<>1 OR NOT EXISTS(
   SELECT 1 FROM asm_publication.schema_version WHERE version=1 AND sha384='{MIGRATION_SHA384}')
 THEN RAISE EXCEPTION 'Install the pinned publication prerequisite'; END IF;
END $check$;
SELECT pg_catalog.to_regclass('asm_publication.distribution_schema_version') IS NULL AS install_distribution \\gset
\\if :install_distribution
{source.decode('ascii')}
INSERT INTO asm_publication.distribution_schema_version VALUES(2,'{DISTRIBUTION_MIGRATION_SHA384}');
\\else
DO $check$ BEGIN
 IF (SELECT count(*) FROM asm_publication.distribution_schema_version)<>1 OR NOT EXISTS(
   SELECT 1 FROM asm_publication.distribution_schema_version WHERE version=2 AND sha384='{DISTRIBUTION_MIGRATION_SHA384}') OR
   (SELECT pg_catalog.pg_get_userbyid(nspowner) FROM pg_catalog.pg_namespace WHERE nspname='asm_publication')<>'asm_migrator'
 THEN RAISE EXCEPTION 'Distribution migration state differs'; END IF;
END $check$;
\\endif
COMMIT;
"""
    connection.execute(sql)
    return {"status": "migrated", "schema": 2, "migration_sha384": DISTRIBUTION_MIGRATION_SHA384}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection-file", required=True, type=Path)
    parser.add_argument("--psql", required=True, type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("migrate")
    commands.add_parser("migrate-distribution")
    enroll = commands.add_parser("enroll")
    enroll.add_argument("--owner-id", required=True)
    enroll.add_argument("--namespace", required=True)
    issue = commands.add_parser("issue")
    issue.add_argument("--owner-id", required=True)
    issue.add_argument("--credential-id", required=True)
    issue.add_argument("--package", action="append", required=True)
    issue.add_argument("--operation", choices=("publish", "task-read"), action="append")
    issue.add_argument("--ttl-seconds", type=int, default=3600)
    issue.add_argument("--token-file", required=True, type=Path)
    issue.add_argument("--reuse-token-file", action="store_true")
    revoke = commands.add_parser("revoke")
    revoke.add_argument("--credential-id", required=True)
    policy = commands.add_parser("check-policy")
    policy.add_argument("--checker-revision", required=True)
    policy.add_argument("--policy-sha256", required=True)
    configure = commands.add_parser("configure-distribution")
    configure.add_argument("--registry-id", required=True)
    configure.add_argument("--origin", required=True)
    lifecycle = commands.add_parser("lifecycle")
    lifecycle.add_argument("--release-id", required=True)
    lifecycle.add_argument("--action", choices=("yank", "unyank", "revoke"), required=True)
    lifecycle.add_argument("--operation-id", required=True)
    lifecycle.add_argument("--expected-policy-revision", type=int, required=True)
    for command in (enroll, issue, revoke, policy, configure, lifecycle):
        command.add_argument("--reference", required=True)
    args = parser.parse_args(argv)
    try:
        statement = None
        if args.command not in ("migrate", "migrate-distribution"):
            reference = admin.sql_text(_reference(args.reference))
        if args.command == "enroll":
            _identifier(args.owner_id)
            admin.require(re.fullmatch(r"[a-z][a-z0-9-]{0,38}", args.namespace) is not None
                          and not args.namespace.endswith("-") and "--" not in args.namespace, "Use a canonical namespace.")
            statement = "SELECT asm_publication.enroll_owner(" + ",".join(map(admin.sql_text, (args.owner_id, args.namespace))) + "," + reference + ");"
        elif args.command == "issue":
            _identifier(args.owner_id); _identifier(args.credential_id)
            admin.require(1 <= args.ttl_seconds <= 86400, "Use a credential lifetime from 1 to 86400 seconds.")
            packages = sorted(args.package)
            operations = sorted(args.operation or ["publish", "task-read"])
            admin.require(1 <= len(packages) <= 32 and len(set(packages)) == len(packages)
                and all(re.fullmatch(r"[a-z][a-z0-9-]{0,38}/[a-z][a-z0-9-]{0,63}", p)
                        and "--" not in p and "-/" not in p and not p.endswith("-") for p in packages)
                and len(set(operations)) == len(operations), "Use distinct canonical packages and operation scopes.")
            token = token_file(args.token_file, reuse=args.reuse_token_file)
            statement = ("SELECT asm_publication.issue_credential(" + ",".join(map(admin.sql_text,
                (args.credential_id, args.owner_id, hashlib.sha256(token.encode()).hexdigest()))) + "," + _array(packages) + "," +
                admin.sql_text(str(args.ttl_seconds) + " seconds") + "::interval," + reference + "," + _array(operations) + ");")
        elif args.command == "revoke":
            statement = "SELECT asm_publication.revoke_credential(" + admin.sql_text(_identifier(args.credential_id)) + "," + reference + ");"
        elif args.command == "check-policy":
            admin.require(registry.HEX40.fullmatch(args.checker_revision) is not None and args.checker_revision != "0" * 40
                          and registry.HEX64.fullmatch(args.policy_sha256) is not None, "Use complete checker and policy identities.")
            statement = "SELECT asm_publication.set_check_policy(" + ",".join(map(admin.sql_text,
                (args.checker_revision, args.policy_sha256))) + "," + reference + ");"
        elif args.command == "configure-distribution":
            _identifier(args.registry_id)
            admin.require(isinstance(args.origin, str) and 9 <= len(args.origin) <= 1024
                          and re.fullmatch(r"https://[a-z0-9][a-z0-9.-]*(?::[1-9][0-9]{0,4})?(?:/[A-Za-z0-9._/-]+)?", args.origin)
                          and not args.origin.endswith("/"), "Use a bounded HTTPS distribution origin.")
            statement = "SELECT asm_publication.configure_distribution(" + ",".join(map(admin.sql_text,
                (args.registry_id, args.origin))) + "," + reference + ");"
        elif args.command == "lifecycle":
            _identifier(args.release_id); _identifier(args.operation_id)
            admin.require(0 <= args.expected_policy_revision <= 9007199254740991, "Use the observed policy revision.")
            statement = "SELECT asm_publication.set_lifecycle(" + ",".join(map(admin.sql_text,
                (args.release_id, args.action, args.operation_id))) + "," + str(args.expected_policy_revision) + "," + reference + ");"
        role = "asm_migrator" if args.command in ("migrate", "migrate-distribution") else "asm_operator"
        with admin.Connection(args.connection_file, args.psql, role) as connection:
            if args.command == "migrate":
                result = migrate(connection)
            elif args.command == "migrate-distribution":
                result = migrate_distribution(connection)
            else:
                connection.execute(statement)
                result = {"status": args.command + "-completed"}
                if args.command == "issue":
                    result.update(credential_id=args.credential_id, token_file=str(args.token_file), requested_ttl_seconds=args.ttl_seconds)
        sys.stdout.buffer.write(registry.json_bytes(result))
        return 0
    except (admin.AdminError, registry.RegistryError, OSError, UnicodeError, ValueError):
        print("asm-publisher-admin: operation failed. Preserve saved tokens and inspect the operation identity before retrying.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
