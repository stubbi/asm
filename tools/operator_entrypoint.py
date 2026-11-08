#!/usr/bin/env python3
"""Explicit registry-image commands with fixed source and privileged tool paths.

SPDX-License-Identifier: AGPL-3.0-or-later
The native CLI and HTTP application do not use this entrypoint.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

# The image invokes Python with -I; only this immutable application directory is added.
sys.path.insert(0, str(Path(__file__).resolve().parent))
# Hash-locked storage libraries are immutable image content, never caller paths.
sys.path.append("/opt/asm/storage")
import prepare_operator
import registry
import registry_admin
from image_source import source_revision

PSQL = "/opt/asm/postgres/bin/psql"
REPOSITORY = "/opt/asm/source.git"
TRUST = "/app/bin/asm-trust"


def v2_parser(commands):
    """Expose only supported operations; executable/source overrides are absent."""
    publisher = commands.add_parser("publisher-admin", allow_abbrev=False)
    publisher.add_argument("--connection-file", type=Path, required=True)
    operations = publisher.add_subparsers(dest="operation", required=True)
    for name in ("migrate", "migrate-distribution", "enroll", "issue", "revoke", "check-policy",
                 "configure-distribution", "lifecycle"):
        item = operations.add_parser(name, allow_abbrev=False)
        if name not in ("migrate", "migrate-distribution"):
            item.add_argument("--reference", required=True)
        if name in ("enroll", "issue"):
            item.add_argument("--owner-id", required=True)
        if name == "enroll":
            item.add_argument("--namespace", required=True)
        if name in ("issue", "revoke"):
            item.add_argument("--credential-id", required=True)
        if name == "issue":
            item.add_argument("--package", action="append", required=True)
            item.add_argument("--operation", dest="credential_operation", choices=("publish", "task-read"), action="append")
            item.add_argument("--ttl-seconds", type=int)
            item.add_argument("--token-file", type=Path, required=True)
            item.add_argument("--reuse-token-file", action="store_true")
        if name == "configure-distribution":
            item.add_argument("--registry-id", required=True)
            item.add_argument("--origin", required=True)
        if name == "lifecycle":
            item.add_argument("--release-id", required=True)
            item.add_argument("--action", choices=("yank", "unyank", "revoke"), required=True)
            item.add_argument("--operation-id", required=True)
            item.add_argument("--expected-policy-revision", type=int, required=True)
    distribution = commands.add_parser("distribution", allow_abbrev=False)
    operations = distribution.add_subparsers(dest="operation", required=True)
    import registry_mirror
    for name in ("publish", "sync", "verify"):
        item = operations.add_parser(name, allow_abbrev=False)
        registry_mirror._store_arguments(item)
        if name != "verify":
            registry_mirror._store_arguments(item, "source-")
            item.add_argument("--work-root", type=Path, required=True)
        if name == "publish":
            item.add_argument("--connection-file", type=Path, required=True)
            item.add_argument("--worker-id", required=True)
            item.add_argument("--trust-root", type=Path, required=True)
            item.add_argument("--keys-dir", type=Path, required=True)
            item.add_argument("--refresh", action="store_true")


def v2_delegate(args, commit):
    """Translate parsed values directly to existing private operators."""
    values = vars(args)
    if args.command == "publisher-admin":
        import publisher_admin
        import publication_check
        result = ["--connection-file", str(args.connection_file), "--psql", PSQL, args.operation]
        omitted = {"command", "operation", "connection_file"}
        target = publisher_admin.main
    else:
        import registry_distribution
        result = [args.operation]
        omitted = {"command", "operation"}
        target = registry_distribution.main
        if args.operation == "publish":
            result += ["--psql", PSQL, "--trust-tool", TRUST]
    for key, value in values.items():
        if key in omitted or value is None or value is False:
            continue
        option = "--" + ("operation" if key == "credential_operation" else key.replace("_", "-"))
        if value is True:
            result.append(option)
        else:
            for item in value if isinstance(value, list) else [value]:
                result += [option, str(item)]
    if args.command == "publisher-admin" and args.operation == "check-policy":
        result += ["--checker-revision", commit, "--policy-sha256", publication_check.policy_digest()]
    return target(result)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "prepare-operator":
        return prepare_operator.main(argv[1:])
    if argv and argv[0] == "prepare-signers":
        import prepare_signers
        return prepare_signers.main(argv[1:])
    if argv and argv[0] == "check-worker":
        import publication_worker
        try:
            return publication_worker.main(argv[1:], fixed_tools={"psql": PSQL, "kubectl": "/usr/bin/kubectl"},
                                           checker_revision=source_revision())
        except (registry.RegistryError, registry_admin.AdminError, OSError, ValueError):
            print("asm-operator: image source identity is invalid. Use a qualified image.", file=sys.stderr)
            return 1
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare-operator", help="Snapshot explicitly authorized projected credentials; use its --help.")
    commands.add_parser("prepare-signers", help="Snapshot authorized projected online keys; use its --help.")
    commands.add_parser("check-worker", help="Run one fixed-image Kubernetes check; use its --help.")
    v2_parser(commands)
    for name in ("migrate", "grant", "status", "bind-namespace", "plan", "import"):
        item = commands.add_parser(name)
        if name != "plan":
            item.add_argument("--connection-file", type=Path, required=True)
        if name in {"plan", "import"}:
            item.add_argument("--expected-revision", type=int, required=True)
        if name == "import":
            item.add_argument("--plan-sha256", required=True)
            item.add_argument("--distribution-root", type=Path,
                              help="Check a matching private local distribution before reading database credentials")
        if name == "bind-namespace":
            item.add_argument("--namespace", required=True)
            item.add_argument("--github-id", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        commit = source_revision()
        if args.command in ("publisher-admin", "distribution"):
            return v2_delegate(args, commit)
        delegated = ["--psql", PSQL]
        if args.command != "plan":
            delegated += ["--connection-file", str(args.connection_file)]
        delegated += [args.command]
        if args.command in {"plan", "import"}:
            delegated += ["--repository", REPOSITORY, "--commit", commit, "--expected-revision", str(args.expected_revision)]
        if args.command == "import":
            delegated += ["--plan-sha256", args.plan_sha256]
            if args.distribution_root is not None:
                delegated += ["--distribution-root", str(args.distribution_root)]
        if args.command == "bind-namespace":
            delegated += ["--namespace", args.namespace, "--github-id", str(args.github_id), "--acceptance-commit", commit]
        return registry_admin.main(delegated)
    except (registry_admin.AdminError, registry.RegistryError, OSError, ValueError):
        print("asm-operator: image source identity is invalid. Use a qualified image.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
