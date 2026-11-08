#!/usr/bin/env python3
"""Publish reviewed Git records to an operator-selected store and copy snapshots.

Digests establish transport integrity, not publisher identity. Native clients
still use the unchanged GitHub artifact URLs in the v1 exports.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

import registry
from registry_storage import LocalBlobStore, MissingBlob, S3BlobStore

LIMIT = 1024 * 1024
MAX_HISTORY = 4096
HEAD = "head.json"


def _digest(value):
    return isinstance(value, str) and registry.HEX64.fullmatch(value) is not None


def _objects(records):
    return [{"name": record["name"], "version": record["version"],
             "target": item["target"], "kind": item["kind"], "sha256": item["sha256"],
             "bytes": item["bytes"], "origin": item["url"]}
            for record in records for item in sorted(record["artifacts"], key=lambda a: (a["target"], a["kind"]))]


def parse_snapshot(data: bytes) -> dict:
    registry.require(len(data) <= LIMIT, "snapshot exceeds one MiB")
    snapshot = registry.exact_keys(registry.strict_json(data),
        {"schema", "source_commit", "sequence", "previous", "records", "objects"},
        {"schema", "source_commit", "sequence", "previous", "records", "objects"}, "snapshot")
    registry.require(type(snapshot["schema"]) is int and snapshot["schema"] == 1, "unsupported snapshot schema")
    commit = snapshot["source_commit"]
    registry.require(isinstance(commit, str) and registry.HEX40.fullmatch(commit) is not None
                     and commit != "0" * 40, "snapshot requires a full source commit")
    number = snapshot["sequence"]
    registry.require(type(number) is int and 1 <= number <= 2**53 - 1, "invalid snapshot sequence")
    registry.require(snapshot["previous"] is None if number == 1 else _digest(snapshot["previous"]),
                     "invalid previous snapshot digest")
    registry.require(isinstance(snapshot["records"], list), "snapshot records must be an array")
    records = registry.check_records(snapshot["records"])
    registry.require(records == snapshot["records"], "snapshot records must be sorted")
    objects = _objects(records)
    registry.require(len(objects) <= registry.MAX_ROWS, "snapshot has too many artifact rows")
    registry.require(snapshot["objects"] == objects, "snapshot objects differ from accepted records")
    registry.require(registry.json_bytes(snapshot) == data, "snapshot must use canonical JSON bytes")
    _exports(snapshot)
    return snapshot


def _exports(snapshot):
    import registry_admin
    records = snapshot["records"]
    tsv, index = registry.make_indexes(records)
    files = {"registry/v1/index.tsv": registry.legacy_tsv(tsv).encode("ascii"),
             "registry/v1/index-macos.tsv": registry.macos_compat_tsv(tsv).encode("ascii"),
             "registry/v1/index-all.tsv": tsv.encode("ascii"),
             "registry/v1/index.json": registry.json_bytes(index)}
    registry.require(all(len(data) <= (registry_admin.MAX_JSON_BYTES if key.endswith(".json") else registry.MAX_INDEX_BYTES)
                         for key, data in files.items()), "snapshot export exceeds its format limit")
    return files


def _snapshot(store, digest):
    registry.require(_digest(digest), "invalid snapshot digest")
    result = store.read_object(f"snapshots/{digest}/manifest.json", LIMIT)
    registry.require(result is not None, "snapshot manifest is missing; restore the selected store")
    raw = result[0]
    registry.require(hashlib.sha256(raw).hexdigest() == digest, "snapshot manifest digest mismatch")
    return parse_snapshot(raw)


def _head(store):
    result = store.read_object(HEAD, LIMIT)
    if result is None:
        return None
    raw, token = result
    value = registry.exact_keys(registry.strict_json(raw), {"schema", "snapshot", "sequence", "source_commit"},
                               {"schema", "snapshot", "sequence", "source_commit"}, "head")
    registry.require(type(value["schema"]) is int and value["schema"] == 1, "unsupported head schema")
    registry.require(registry.json_bytes(value) == raw, "head must use canonical JSON bytes")
    snapshot = _snapshot(store, value["snapshot"])
    registry.require(type(value["sequence"]) is int and value["sequence"] == snapshot["sequence"]
                     and value["source_commit"] == snapshot["source_commit"], "head does not match its snapshot")
    return value["snapshot"], snapshot, token


def load_current(store):
    """Return the bound head, manifest, and token, without checking blob availability."""
    current = _head(store)
    if current is None:
        return None
    digest, snapshot, token = current
    return {"schema": 1, "snapshot": digest, "sequence": snapshot["sequence"],
            "source_commit": snapshot["source_commit"]}, snapshot, token


def _destination(store, initialize):
    current = _head(store)
    registry.require((current is None) == initialize,
                     "use --initialize only for a store without a head")
    return current


def _git(repository, *arguments):
    import registry_admin
    executable = shutil.which("git")
    registry.require(executable is not None, "install Git before reading an accepted source commit")
    try:
        return registry_admin.run_bounded([executable, "--no-replace-objects", "-c", "credential.helper=",
            "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", str(repository), *arguments],
            environment=registry_admin.clean_environment(), output_limit=64, timeout=20)
    except registry_admin.AdminError as error:
        raise registry.RegistryError(str(error)) from None


def _artifact_path(directory, artifact):
    digest_path = directory / artifact["sha256"]
    if digest_path.exists() or digest_path.is_symlink():
        return digest_path
    return directory / registry.artifact_url(artifact["url"])[2]


def _local_bytes(path, size):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            registry.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size == size,
                             "artifact must be a regular file with the accepted byte size")
            data = stream.read(size + 1)
            registry.require(len(data) == size, "artifact changed while reading")
            return data
    except OSError:
        raise registry.RegistryError("cannot safely read the selected artifact; use a regular file") from None


def _install(store, snapshot, current):
    raw = registry.json_bytes(snapshot)
    digest = hashlib.sha256(raw).hexdigest()
    for key, data in {"manifest.json": raw, **_exports(snapshot)}.items():
        store.create_object(f"snapshots/{digest}/{key}", data)
    if current is None or current[0] != digest:
        head = {"schema": 1, "snapshot": digest, "sequence": snapshot["sequence"],
                "source_commit": snapshot["source_commit"]}
        store.compare_and_swap(HEAD, registry.json_bytes(head), None if current is None else current[2])
    return digest


def publish(store, repository: Path, commit: str, artifacts_dir: Path, *, initialize=False) -> str:
    """Advance an accepted snapshot after validating every retained artifact."""
    import registry_admin
    current = _destination(store, initialize)
    registry.require(isinstance(commit, str), "a full accepted Git commit is required")
    try:
        records = registry_admin.committed_records(repository, commit)
    except registry_admin.AdminError as error:
        raise registry.RegistryError(str(error)) from None
    registry.require(_git(repository, "cat-file", "-t", commit + ":registry/packages").strip() == b"tree",
                     "accepted commit must contain registry/packages")
    if current:
        ancestor = _git(repository, "merge-base", current[1]["source_commit"], commit).decode().strip()
        registry.require(ancestor == current[1]["source_commit"], "accepted commit must descend from the current head; rollback refused")
        registry.check_immutable(records, current[1]["records"])
    if current and current[1]["source_commit"] == commit:
        snapshot = current[1]
        registry.require(snapshot["records"] == records, "accepted commit differs from the stored records")
    else:
        snapshot = {"schema": 1, "source_commit": commit, "sequence": 1 if current is None else current[1]["sequence"] + 1,
                    "previous": None if current is None else current[0], "records": records, "objects": _objects(records)}
    parse_snapshot(registry.json_bytes(snapshot))
    local = []
    for record in records:
        for artifact in record["artifacts"]:
            path = _artifact_path(artifacts_dir, artifact)
            if path.exists() or path.is_symlink():
                data = _local_bytes(path, artifact["bytes"])
                local.append((path, artifact))
            else:
                data = store.get_blob(artifact["sha256"], artifact["bytes"])
            registry.validate_artifact(data, record, artifact)
    for path, artifact in local:
        store.put_blob(path, artifact["sha256"], artifact["bytes"])
    return _install(store, snapshot, current)


def _artifact_groups(records):
    groups = {}
    for record in records:
        for artifact in record["artifacts"]:
            groups.setdefault((artifact["sha256"], artifact["bytes"]), []).append((record, artifact))
    return groups.items()


def verify(store) -> str:
    """Audit the current snapshot's exports and all retained artifacts, including yanks."""
    current = _head(store)
    registry.require(current is not None, "store head is missing; select a published store")
    digest, snapshot, _ = current
    for key, expected in _exports(snapshot).items():
        result = store.read_object(f"snapshots/{digest}/{key}", len(expected))
        registry.require(result is not None and result[0] == expected,
                         "snapshot export is missing or differs; restore the selected snapshot")
    for (sha256, size), declarations in _artifact_groups(snapshot["records"]):
        data = store.get_blob(sha256, size)
        for record, artifact in declarations:
            registry.validate_artifact(data, record, artifact)
    return digest


def sync(source, destination, *, initialize=False, check_existing=False) -> str:
    """Copy missing bytes and advance the head; unchanged heads receive metadata checks only."""
    incoming = _head(source)
    registry.require(incoming is not None, "source head is missing; select a published store")
    current = _destination(destination, initialize)
    if current and incoming[0] == current[0] and not check_existing:
        return incoming[0]
    chain = [incoming[0]]
    newest, previous = incoming[1], None
    if current and incoming[0] != current[0]:
        registry.require(incoming[1]["sequence"] > current[1]["sequence"], "source is older; rollback refused")
        registry.check_immutable(incoming[1]["records"], current[1]["records"])
    while chain[-1] != (None if current is None else current[0]):
        if newest["previous"] is None:
            registry.require(current is None, "source history does not extend the destination head")
            break
        registry.require(len(chain) < MAX_HISTORY, "snapshot history exceeds the bounded sync limit")
        previous = _snapshot(source, newest["previous"])
        registry.require(previous["sequence"] + 1 == newest["sequence"], "snapshot history sequence mismatch")
        registry.check_immutable(newest["records"], previous["records"])
        chain.append(newest["previous"])
        newest = previous
    newest = previous = None
    with tempfile.TemporaryDirectory(prefix="asm-mirror-") as temporary:
        path = Path(temporary) / "artifact"
        for (sha256, size), declarations in _artifact_groups(incoming[1]["records"]):
            missing = False
            try:
                data = destination.get_blob(sha256, size)
            except MissingBlob:
                missing = True
                data = source.get_blob(sha256, size)
            for record, artifact in declarations:
                registry.validate_artifact(data, record, artifact)
            if missing:
                path.write_bytes(data)
                destination.put_blob(path, sha256, size)
        for digest in reversed(chain):
            snapshot = _snapshot(source, digest)
            raw = registry.json_bytes(snapshot)
            for key, data in {"manifest.json": raw, **_exports(snapshot)}.items():
                destination.create_object(f"snapshots/{digest}/{key}", data)
    return _install(destination, incoming[1], current)


def _store_arguments(parser, prefix=""):
    label = prefix.replace("-", "_")
    parser.add_argument("--" + prefix + "store", choices=("local", "s3"), required=True)
    parser.add_argument("--" + prefix + "root", type=Path)
    for name in ("bucket", "endpoint", "region", "prefix", "profile"):
        parser.add_argument("--" + prefix + name, dest=label + name)


def _store(args, prefix=""):
    get = lambda name: getattr(args, prefix + name)
    if get("store") == "local":
        registry.require(get("root") is not None and not any(get(n) for n in ("bucket", "endpoint", "region", "prefix", "profile")),
                         "a local store requires --root and no S3 settings")
        return LocalBlobStore(get("root"))
    registry.require(get("bucket") and get("root") is None, "an S3 store requires --bucket and no local root")
    session = None
    if get("profile"):
        try:
            import boto3
        except ImportError:
            raise registry.RegistryError("S3 storage requires the pinned requirements-storage.txt dependencies") from None
        try:
            session = boto3.Session(profile_name=get("profile"))
        except Exception:
            raise registry.RegistryError("cannot load the selected S3 profile; check the credential configuration") from None
    return S3BlobStore(get("bucket"), prefix=get("prefix") or "", endpoint_url=get("endpoint"),
                       region_name=get("region"), session=session)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    publication = commands.add_parser("publish", help="Publish records from an accepted full Git commit")
    publication.add_argument("--repository", type=Path, required=True)
    publication.add_argument("--commit", required=True)
    publication.add_argument("--artifacts-dir", type=Path, required=True)
    synchronization = commands.add_parser("sync", help="Copy a selected store without fetching package URLs")
    synchronization.add_argument("--check-existing", action="store_true",
                                 help="Audit existing bytes and restore missing objects even when the head is unchanged")
    _store_arguments(synchronization, "source-")
    verification = commands.add_parser("verify", help="Audit current exports and every retained artifact byte")
    _store_arguments(verification)
    for command in (publication, synchronization):
        _store_arguments(command)
        command.add_argument("--initialize", action="store_true", help="Explicitly create the first destination head")
    args = parser.parse_args(argv)
    try:
        destination = _store(args)
        if args.command == "verify":
            digest = verify(destination)
        elif args.command == "publish":
            digest = publish(destination, args.repository, args.commit, args.artifacts_dir, initialize=args.initialize)
        else:
            digest = sync(_store(args, "source_"), destination, initialize=args.initialize,
                          check_existing=args.check_existing)
        print(digest)
        return 0
    except (registry.RegistryError, OSError, UnicodeError) as error:
        print(f"asm mirror: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
