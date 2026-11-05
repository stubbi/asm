#!/usr/bin/env python3
"""Prepare a standalone source tree with one explicit native target.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tomllib


HERE = Path(__file__).resolve().parent
SOURCES = {"x86_64-linux": "server.s", "aarch64-linux": "aarch64/server.s",
           "riscv64-linux": "riscv64/server.s"}
EXCLUDED = {".git", ".asm", ".venv", "__pycache__", "build", "dist"}
SENSITIVE = {".env", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519"}
RESERVED = {"con", "prn", "aux", "nul"} | {
    f"{prefix}{number}" for prefix in ("com", "lpt") for number in range(1, 10)}


def standalone_files():
    """Read regular files without following links in an extracted package."""
    files = {}
    total = 0
    for directory, directories, names, descriptor in os.fwalk(HERE, follow_symlinks=False):
        directories[:] = sorted(name for name in directories if name not in EXCLUDED)
        for name in directories:
            if not stat.S_ISDIR(os.stat(name, dir_fd=descriptor, follow_symlinks=False).st_mode):
                raise ValueError("source directory links are not allowed")
        for name in sorted(names):
            if name in EXCLUDED:
                continue
            path = Path(directory, name).relative_to(HERE).as_posix()
            if len(path) > 240 or not path.isascii():
                raise ValueError("source path exceeds the portable bounds")
            parts = path.split("/")
            if any(not re.fullmatch(r"[A-Za-z0-9_.-]+", part) or part in (".", "..")
                   or part.startswith("-") or part.endswith(".")
                   or part.split(".", 1)[0].lower() in RESERVED for part in parts):
                raise ValueError("source contains a nonportable path")
            if any(part in SENSITIVE or part.startswith(".env.") for part in parts) or path.lower().endswith((".pem", ".key")):
                raise ValueError("source contains a credential-file name")
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            with os.fdopen(os.open(name, flags, dir_fd=descriptor), "rb") as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError("source must be a regular, unlinked file")
                if info.st_size > min(16 * 1024 * 1024, 64 * 1024 * 1024 - total):
                    raise ValueError("source exceeds the package byte limits")
                data = stream.read(info.st_size + 1)
                if len(data) != info.st_size:
                    raise ValueError("source changed while it was read")
            total += len(data)
            files[path] = (data, 0o755 if info.st_mode & 0o111 else 0o644)
            if len(files) > 4096:
                raise ValueError("source exceeds the package file limit")
    return files


def source_files():
    # Reuse the repository's source boundary when this is its experiment tree.
    # An extracted package has no repository tools and uses the local reader.
    tool = HERE.parents[1] / "tools/registry.py"
    if HERE.parent.name == "experiments" and tool.is_file():
        spec = importlib.util.spec_from_file_location("asm_package_registry", tool)
        registry = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(registry)
        return registry.collect_files(HERE)
    return standalone_files()


def prepare(target, output):
    files = source_files()
    manifest = files[f"targets/{target}.toml"][0]
    project = tomllib.loads(manifest.decode("utf-8"))
    current = tomllib.loads(files["asm.toml"][0].decode("utf-8"))
    if project["package"] != current["package"]:
        raise ValueError("target manifest changes the package identity")
    if project["build"]["target"] != target or project["build"]["source"] != SOURCES[target]:
        raise ValueError("target manifest does not match the selected source")
    required = {SOURCES[target], "abi-check.c", "Makefile", "LICENSE", "README.md",
                "guard.sql", "search.sql", "local_postgres.py", "package.py",
                "test_fixture.py", "test_server.py", "test_runtime_versions.py", "test_package.py",
                "fixtures/0001_registry.sql", "fixtures/p00.json"}
    if required - files.keys():
        raise ValueError("package source is incomplete: " + ", ".join(sorted(required - files.keys())))
    files["asm.toml"] = (manifest, 0o644)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(mode=0o700)  # Atomic refusal of an existing file, directory, or link.
    try:
        for name, (data, mode) in sorted(files.items()):
            destination = output / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as stream:
                stream.write(data)
            destination.chmod(mode)
    except BaseException:
        shutil.rmtree(output)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=sorted(SOURCES), required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        prepare(arguments.target, arguments.output)
    except (OSError, ValueError, KeyError) as error:
        print(f"package: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
