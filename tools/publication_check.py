#!/usr/bin/env python3
"""Credential-free registry checks. This is not an HTTP application or sandbox.

Run the fixed checker in an isolated worker with read-only task inputs, no
network, no credentials, and external resource limits. It never executes a
package, fetches a source locator, extracts files, or changes staged objects.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry
from registry_storage import _absolute, _directory, _regular

MAX_MANIFEST = 65536
TARGETS = {
    ("x86_64", "linux", "sysv-amd64"): ("x86_64-linux", "elf"),
    ("aarch64", "linux", "aapcs64"): ("aarch64-linux", "elf"),
    ("riscv64", "linux", "lp64d"): ("riscv64-linux", "elf"),
    ("aarch64", "macos", "apple-arm64"): ("aarch64-macos", "macho"),
    ("x86_64", "windows", "windows-x64"): ("x86_64-windows", "pe"),
    ("aarch64", "windows", "windows-arm64"): ("aarch64-windows", "pe"),
}


class InputUnavailable(ValueError):
    """A retained staging input cannot be read exactly; it is not a package verdict."""


def policy_digest() -> str:
    """Bind this fixed checker and its validation/file-boundary implementations."""
    digest = hashlib.sha256(b"asm-publication-check-policy-v1\0")
    for name in ("publication_check.py", "registry.py", "registry_storage.py"):
        data = Path(__file__).with_name(name).read_bytes()
        digest.update(name.encode("ascii") + b"\0" + len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


def _read(path: Path, maximum: int) -> bytes:
    path = _absolute(path)
    try:
        with _directory(path.parent, private=True) as parent:
            descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(descriptor, "rb") as stream:
            _regular(stream.fileno(), maximum, private=True)
            data = stream.read(maximum + 1)
            registry.require(len(data) <= maximum, "checker input exceeds its byte limit")
            return data
    except (OSError, registry.RegistryError):
        raise InputUnavailable("The staged input is unavailable. Inspect its retained digest and permissions.") from None


def _object(value):
    registry.exact_keys(value, {"sha256", "bytes"}, {"sha256", "bytes"}, "object")
    registry.require(isinstance(value["sha256"], str) and registry.HEX64.fullmatch(value["sha256"]), "invalid object digest")
    registry.require(type(value["bytes"]) is int and 0 < value["bytes"] <= registry.MAX_ARTIFACT_BYTES, "invalid object size")
    return value["sha256"], value["bytes"]


def manifest(data: bytes):
    """Defensively check the worker input; PostgreSQL supplies publication authority."""
    registry.require(0 < len(data) <= MAX_MANIFEST, "invalid manifest size")
    value = registry.strict_json(data)
    fields = {"schema", "owner_id", "name", "version", "summary", "license", "source", "artifacts"}
    registry.exact_keys(value, fields | {"dependencies"}, fields, "publication manifest")
    registry.require(type(value["schema"]) is int and value["schema"] == 2, "unsupported publication schema")
    registry.require(isinstance(value["owner_id"], str) and re.fullmatch("[0-9a-f]{32}", value["owner_id"]), "invalid owner identity")
    registry.package_name(value["name"])
    registry.version_tuple(value["version"])
    registry.plain_text(value["summary"], 160, "summary")
    registry.require(value["summary"] == value["summary"].strip() and isinstance(value["license"], str)
        and value["license"] in registry.LICENSES, "invalid publication description")
    dependencies = value.get("dependencies", [])
    registry.require(isinstance(dependencies, list) and len(dependencies) <= registry.MAX_DEPENDENCIES,
                     "invalid dependency count")
    names = []
    for dependency in dependencies:
        registry.exact_keys(dependency, {"name", "requirement"}, {"name", "requirement"}, "dependency")
        names.append(registry.package_name(dependency["name"]))
        registry.validate_v2_requirement(dependency["requirement"])
    registry.require(names == sorted(set(names)), "dependencies are duplicated or unordered")
    source = registry.exact_keys(value["source"], {"commit", "path", "archive", "repository"}, {"commit", "path", "archive"}, "source")
    commit = registry.exact_keys(source["commit"], {"algorithm", "digest"}, {"algorithm", "digest"}, "source commit")
    length = {"git-sha1": 40, "git-sha256": 64}.get(commit["algorithm"]) if isinstance(commit["algorithm"], str) else None
    registry.require(length is not None and isinstance(commit["digest"], str)
        and re.fullmatch("[0-9a-f]{" + str(length) + "}", commit["digest"]) and commit["digest"] != "0" * length,
        "invalid source commit")
    registry.portable_path(source["path"], allow_root=True)
    if "repository" in source:
        locator = registry.plain_text(source["repository"], 1024, "source locator")
        try:
            parsed = urlsplit(locator)
            registry.require(parsed.scheme == "https" and parsed.hostname and parsed.username is None
                and parsed.password is None and not parsed.query and not parsed.fragment and "\\" not in locator,
                "invalid source locator")
        except ValueError:
            raise registry.RegistryError("invalid source locator") from None
    source_digest, source_size = _object(source["archive"])
    objects = {source_digest: source_size}
    artifacts, selections = value["artifacts"], set()
    registry.require(isinstance(artifacts, list) and 1 <= len(artifacts) <= registry.MAX_RELEASE_ARTIFACTS, "invalid artifact count")
    for artifact in artifacts:
        fields = {"kind", "format", "isa", "os", "abi", "cpu_features", "sha256", "bytes"}
        registry.exact_keys(artifact, fields, fields, "artifact")
        registry.require(all(isinstance(artifact[field], str) for field in ("isa", "os", "abi", "kind", "format")), "invalid artifact target")
        target = (artifact["isa"], artifact["os"], artifact["abi"])
        registry.require(target in TARGETS and artifact["cpu_features"] == [] and artifact["kind"] in registry.KINDS, "unsupported artifact target")
        registry.require(artifact["format"] == ("tar.gz" if artifact["kind"] == "source" else TARGETS[target][1]), "invalid artifact format")
        selection = (*target, artifact["kind"])
        registry.require(selection not in selections, "duplicate artifact selection")
        selections.add(selection)
        digest, size = _object({key: artifact[key] for key in ("sha256", "bytes")})
        registry.require(digest not in objects or objects[digest] == size, "object size conflict")
        registry.require(artifact["kind"] != "source" or (digest, size) == (source_digest, source_size), "source artifact differs from source archive")
        objects[digest] = size
    registry.require(sum(objects.values()) <= 128 * 1024 * 1024 and len(objects) <= 15, "task objects exceed their limit")
    registry.require(registry.json_bytes(value) == data, "publication manifest must use canonical JSON")
    return value, objects


def check(task_id: str, manifest_file: Path, objects_root: Path, checker_revision: str) -> dict:
    registry.require(isinstance(task_id, str) and re.fullmatch("[0-9a-f]{32}", task_id), "invalid task identity")
    registry.require(isinstance(checker_revision, str) and registry.HEX40.fullmatch(checker_revision)
        and checker_revision != "0" * 40, "invalid checker revision")
    data = _read(manifest_file, MAX_MANIFEST)
    value, objects = manifest(data)
    results = {digest: "pass" for digest in objects}

    def object_bytes(digest):
        data = _read(objects_root / (task_id + "-" + digest), objects[digest])
        if len(data) != objects[digest] or hashlib.sha256(data).hexdigest() != digest:
            raise InputUnavailable("The staged input differs from its retained receipt. Inspect storage before retrying.")
        return data

    source_digest = value["source"]["archive"]["sha256"]
    try:
        files = registry.read_archive(object_bytes(source_digest))
        registry.require("asm.toml" in files and 0 < len(files["asm.toml"]) <= registry.MAX_PROJECT_BYTES,
                         "source manifest exceeds this profile's byte limit")
        for target in sorted({TARGETS[(item["isa"], item["os"], item["abi"])][0] for item in value["artifacts"]}):
            project = registry.validate_project(files, value["name"], value["version"], target, v2_dependencies=True)
            registry.require(registry.v2_project_dependencies(files["asm.toml"], project) == value.get("dependencies", []),
                             "source dependencies differ from the signed declaration")
        del files
    except InputUnavailable:
        results[source_digest] = "error"
    except registry.RegistryError:
        results[source_digest] = "fail"
    for artifact in value["artifacts"]:
        if artifact["kind"] == "source":
            continue
        digest = artifact["sha256"]
        try:
            registry.validate_executable(object_bytes(digest), TARGETS[(artifact["isa"], artifact["os"], artifact["abi"])][0])
        except InputUnavailable:
            if results[digest] != "fail":
                results[digest] = "error"
        except registry.RegistryError:
            results[digest] = "fail"
    outcome = "fail" if "fail" in results.values() else "error" if "error" in results.values() else "pass"
    return {"schema": 1, "task_id": task_id, "manifest_sha256": hashlib.sha256(data).hexdigest(),
        "checker_revision": checker_revision, "policy_sha256": policy_digest(), "outcome": outcome,
        "objects": [{"sha256": digest, "bytes": objects[digest], "outcome": results[digest]} for digest in sorted(objects)]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("policy", help="print the exact local checker policy digest")
    run = commands.add_parser("check")
    run.add_argument("--task", required=True)
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--objects", type=Path, required=True)
    run.add_argument("--checker-revision", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "policy":
            print(policy_digest())
        else:
            sys.stdout.buffer.write(registry.json_bytes(check(args.task, args.manifest, args.objects, args.checker_revision)))
        return 0
    except (registry.RegistryError, InputUnavailable, OSError, TypeError):
        print("Asm checker: input is unavailable or invalid. Inspect the retained task and staged files.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
