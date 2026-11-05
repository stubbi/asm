#!/usr/bin/env python3
"""Explicit registry-image commands with fixed source and privileged tool paths.

SPDX-License-Identifier: AGPL-3.0-or-later
The native CLI and HTTP application do not use this entrypoint.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import stat
import sys

# The image invokes Python with -I; only this immutable application directory is added.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_operator
import registry
import registry_admin

PSQL = "/opt/asm/postgres/bin/psql"
SOURCE = Path("/app/SOURCE.json")
REPOSITORY = "/opt/asm/source.git"


def source_revision():
    fd = os.open(SOURCE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        registry_admin.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == 0
            and not info.st_mode & 0o022 and 1 <= info.st_size <= 16384, "Invalid image source marker.")
        body = os.read(fd, 16385)
        registry_admin.require(len(body) == info.st_size, "Image source marker size differs.")
        marker = registry.strict_json(body)
        registry_admin.require(isinstance(marker, dict), "Invalid image source marker shape.")
        value = marker.get("source_revision") if isinstance(marker, dict) else None
        registry_admin.require(type(marker.get("schema")) is int and marker.get("schema") == 1
            and marker.get("repository") == "https://github.com/stubbi/asm"
            and isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) and value != "0" * 40,
            "Invalid image source identity.")
        return value
    finally:
        os.close(fd)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "prepare-operator":
        return prepare_operator.main(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare-operator", help="Snapshot explicitly authorized projected credentials; use its --help.")
    for name in ("migrate", "grant", "status", "bind-namespace", "plan", "import"):
        item = commands.add_parser(name)
        if name != "plan":
            item.add_argument("--connection-file", type=Path, required=True)
        if name in {"plan", "import"}:
            item.add_argument("--expected-revision", type=int, required=True)
        if name == "import":
            item.add_argument("--plan-sha256", required=True)
        if name == "bind-namespace":
            item.add_argument("--namespace", required=True)
            item.add_argument("--github-id", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        commit = source_revision()
        delegated = ["--psql", PSQL]
        if args.command != "plan":
            delegated += ["--connection-file", str(args.connection_file)]
        delegated += [args.command]
        if args.command in {"plan", "import"}:
            delegated += ["--repository", REPOSITORY, "--commit", commit, "--expected-revision", str(args.expected_revision)]
        if args.command == "import":
            delegated += ["--plan-sha256", args.plan_sha256]
        if args.command == "bind-namespace":
            delegated += ["--namespace", args.namespace, "--github-id", str(args.github_id), "--acceptance-commit", commit]
        return registry_admin.main(delegated)
    except (registry_admin.AdminError, registry.RegistryError, OSError, ValueError):
        print("asm-operator: image source identity is invalid. Use a qualified image.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
