#!/usr/bin/env python3
"""Build and restore complete, bounded operator source bundles.

SPDX-License-Identifier: AGPL-3.0-or-later
This is image build tooling, never a package or HTTP backend.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys

import registry
from registry_admin import AdminError, clean_environment, open_checked, require, run_bounded

MAX_BUNDLE = 64 * 1024 * 1024
MAX_OBJECTS = 131072
FILES = ("LICENSE", "README.md", "tools/registry.py", "tools/registry_admin.py", "tools/operator_entrypoint.py",
         "tools/prepare_operator.py", "server/catalog/schema.sql", "server/catalog/reader-guard.sql",
         "server/catalog/read-exports.sql")
REPOSITORY = "https://github.com/stubbi/asm"


def git(repository, *arguments, maximum=2 * 1024 * 1024, protocols=""):
    executable = shutil.which("git")
    require(executable is not None, "Install Git before packaging source objects.")
    environment = dict(clean_environment(), GIT_ALLOW_PROTOCOL=protocols)
    return run_bounded([executable, "--no-replace-objects", "-c", "credential.helper=",
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "fsck.skipList=/dev/null",
        "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-C", str(repository), *arguments],
        environment=environment, output_limit=maximum)


def revision(value):
    require(re.fullmatch(r"[0-9a-f]{40}", value or "") and value != "0" * 40,
            "Use one nonzero full lowercase source commit.")


def inventory(repository, commit):
    listing = git(repository, "ls-tree", "-r", "-z", "--full-tree", commit, "--", *FILES)
    entries = {}
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split()
        name = name.decode("ascii")
        require(mode == "100644" and kind == "blob" and name not in entries,
                "Source runtime files must be unique committed regular files.")
        entries[name] = hashlib.sha256(git(repository, "cat-file", "blob", oid, maximum=1024 * 1024)).hexdigest()
    require(set(entries) == set(FILES), "The accepted source omits a required operator file.")
    return entries


def write_new(path, body):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        remaining = memoryview(body)
        while remaining:
            amount = os.write(fd, remaining)
            require(amount > 0, "The source snapshot write stopped.")
            remaining = remaining[amount:]
        os.fsync(fd)
    finally:
        os.close(fd)


def object_ids(repository, *arguments):
    raw = git(repository, *arguments, maximum=41 * MAX_OBJECTS)
    lines = raw.splitlines()
    require(1 <= len(lines) <= MAX_OBJECTS and len(set(lines)) == len(lines)
            and all(re.fullmatch(rb"[0-9a-f]{40}", line) for line in lines),
            "The source object enumeration is malformed or exceeds its count bound.")
    return set(lines)


def create(repository, commit, output):
    revision(commit)
    require(git(repository, "rev-parse", "HEAD", maximum=64).decode().strip() == commit,
            "The image source commit must equal the clean checkout HEAD.")
    require(git(repository, "rev-parse", "--is-shallow-repository", maximum=16) == b"false\n",
            "Fetch complete history before packaging accepted source.")
    require(not git(repository, "status", "--porcelain", "--untracked-files=all", "-z"),
            "Use a clean checkout without untracked files.")
    git(repository, "fsck", "--strict", "--no-reflogs", "--no-dangling", "--no-progress", commit)
    files = inventory(repository, commit)
    bundle = git(repository, "bundle", "create", "--version=2", "-", "HEAD", maximum=MAX_BUNDLE)
    manifest = {"schema": 1, "repository": REPOSITORY, "source_revision": commit,
                "bundle_sha256": hashlib.sha256(bundle).hexdigest(), "bundle_bytes": len(bundle), "files": files}
    output.mkdir(mode=0o700)
    try:
        for name, body in (("source.bundle", bundle), ("source.json", registry.json_bytes(manifest))):
            write_new(output / name, body)
    except BaseException:
        shutil.rmtree(output)
        raise
    return manifest


def read_file(path, maximum):
    fd, body = open_checked(path, maximum)
    os.close(fd)
    return body


def restore(bundle_path, manifest_path, commit, destination):
    revision(commit)
    bundle = read_file(bundle_path, MAX_BUNDLE)
    manifest = registry.strict_json(read_file(manifest_path, 16384))
    require(isinstance(manifest, dict) and set(manifest) == {
        "schema", "repository", "source_revision", "bundle_sha256", "bundle_bytes", "files"}
        and type(manifest["schema"]) is int and manifest["schema"] == 1
        and manifest["repository"] == REPOSITORY and manifest["source_revision"] == commit
        and type(manifest["bundle_bytes"]) is int and manifest["bundle_bytes"] == len(bundle)
        and manifest["bundle_sha256"] == hashlib.sha256(bundle).hexdigest()
        and isinstance(manifest["files"], dict) and set(manifest["files"]) == set(FILES)
        and all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in manifest["files"].values()),
        "The source bundle identity or manifest differs.")
    header = b"# v2 git bundle\n" + commit.encode("ascii") + b" HEAD\n\n"
    require(bundle.startswith(header), "Use a complete bundle with exactly one accepted HEAD and no prerequisites.")
    destination.mkdir(mode=0o700)
    try:
        # Git must consume these verified bytes, never reopen the mutable input pathname.
        verified = destination / ".verified-source.bundle"
        write_new(verified, bundle)
        git(destination, "init", "--bare", "--template=", "--initial-branch=accepted", ".")
        git(destination, "bundle", "verify", str(verified.resolve()))
        git(destination, "fetch", "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance",
            str(verified.resolve()), "HEAD:refs/heads/accepted", protocols="file")
        require(git(destination, "for-each-ref", "--format=%(refname) %(objectname)") ==
                ("refs/heads/accepted " + commit + "\n").encode(), "The restored source has unexpected refs.")
        git(destination, "fsck", "--strict", "--no-reflogs", "--no-dangling", "--no-progress", commit)
        reachable = object_ids(destination, "rev-list", "--objects", "--no-object-names", commit)
        stored = object_ids(destination, "cat-file", "--batch-all-objects", "--batch-check=%(objectname)")
        require(stored == reachable, "The source bundle contains objects outside the accepted commit graph.")
        require(inventory(destination, commit) == manifest["files"], "The restored runtime source bytes differ.")
        require(not (destination / "objects/info/alternates").exists(), "Source alternates are not permitted.")
        verified.unlink()
    except BaseException:
        shutil.rmtree(destination)
        raise
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    creating = commands.add_parser("create")
    creating.add_argument("--repository", type=Path, required=True)
    creating.add_argument("--revision", required=True)
    creating.add_argument("--output", type=Path, required=True)
    restoring = commands.add_parser("restore")
    restoring.add_argument("--bundle", type=Path, required=True)
    restoring.add_argument("--manifest", type=Path, required=True)
    restoring.add_argument("--revision", required=True)
    restoring.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = (create(args.repository, args.revision, args.output) if args.command == "create" else
                  restore(args.bundle, args.manifest, args.revision, args.destination))
        sys.stdout.buffer.write(registry.json_bytes(result))
        return 0
    except (AdminError, registry.RegistryError, OSError, ValueError, UnicodeError):
        print("operator-source: source preparation refused. Check the clean commit, complete objects, bounds, and new destination.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
