#!/usr/bin/env python3
"""Prepare one private online-key snapshot from a projected Secret.

SPDX-License-Identifier: AGPL-3.0-or-later
Production root private keys must remain offline.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import secrets
import stat
import sys

import prepare_operator as snapshot
import registry
from registry_admin import AdminError, reject_extended_acl, require, run_bounded

TRUST = Path("/app/bin/asm-trust")
KEYS = ("targets.pem", "snapshot.pem", "timestamp.pem")
ROOT_COPY = ".check-root.json"
TMPFS_MAGIC = 0x01021994


def require_memory_parent(fd):
    """Require Linux tmpfs through the already protected parent descriptor."""
    require(sys.platform == "linux", "Use a qualified Linux memory-backed signing volume.")
    library = ctypes.CDLL(None, use_errno=True)
    function = library.fstatfs
    function.argtypes = (ctypes.c_int, ctypes.c_void_p)
    function.restype = ctypes.c_int
    # The Linux statfs ABI starts with native-long f_type. The remaining
    # structure fits inside this bounded, aligned buffer on AMD64 and ARM64.
    storage = (ctypes.c_long * 64)()
    if function(fd, ctypes.byref(storage)) != 0:
        raise OSError(ctypes.get_errno(), "Cannot inspect the signing volume")
    require(storage[0] == TMPFS_MAGIC, "Use a memory-backed signing volume.")


def read_root(path):
    """Read a bounded public trust root through protected physical ancestors."""
    parent = snapshot.open_protected_directory(path.parent)
    fd = None
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid()
                and not info.st_mode & 0o022 and 1 <= info.st_size <= 1048576,
                "Use a bounded owner-controlled public registry root.")
        reject_extended_acl(fd)
        data = bytearray()
        while len(data) <= 1048576:
            chunk = os.read(fd, min(65536, 1048577 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(fd)
        require(len(data) == info.st_size and after.st_size == info.st_size
                and after.st_mtime_ns == info.st_mtime_ns and after.st_ctime_ns == info.st_ctime_ns,
                "The selected public registry root changed during its snapshot.")
        snapshot.same_parent(path.parent, parent)
        return bytes(data)
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)


def read_projection(directory, expected, maximum):
    """Read only explicitly named files from one protected AtomicWriter generation."""
    with snapshot.projected(directory) as generation:
        with os.scandir(generation) as entries:
            names = set()
            for entry in entries:
                names.add(entry.name)
                require(len(names) <= len(expected) and entry.name in expected,
                        "Project only the explicitly selected signing or public-root files.")
        require(names == set(expected), "The projected signing or public-root generation is incomplete.")
        return {name: snapshot.read_projected(generation, name, maximum) for name in expected}


def prepare(keys_directory, trust_root, destination, trust=TRUST, *, trust_root_directory=None):
    """Publish three coherent UID-owned keys; preserve every existing destination."""
    require((trust_root is None) != (trust_root_directory is None), "Select one explicit public registry root source.")
    root_source = trust_root if trust_root is not None else trust_root_directory
    require(all(path.is_absolute() for path in (keys_directory, root_source, destination, trust)),
            "Use physical absolute signing, root, tool, and destination paths.")
    require(destination.name not in {"", ".", ".."}, "Select a new private signing snapshot name.")
    root = (read_root(trust_root) if trust_root is not None else
            read_projection(trust_root_directory, ("registry-root.json",), 1048576)["registry-root.json"])
    files = read_projection(keys_directory, KEYS, 16384)
    parent = snapshot.open_protected_directory(destination.parent)
    private = None
    staging_name = ".asm-signers-" + secrets.token_hex(12)
    try:
        require_memory_parent(parent)
        os.mkdir(staging_name, 0o700, dir_fd=parent)
        private = os.open(staging_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        require(os.fstat(private).st_uid == os.geteuid(), "Use an owned private signing staging directory.")
        os.fchmod(private, 0o700)
        reject_extended_acl(private)
        require(stat.S_IMODE(os.fstat(private).st_mode) == 0o700, "Use an owner-only signing snapshot directory.")
        for name, content in files.items():
            snapshot.write_private(private, name, content)
        snapshot.write_private(private, ROOT_COPY, root)
        snapshot.same_parent(destination.parent, parent)
        staging = destination.parent / staging_name
        run_bounded([str(trust), "check-online-keys", str(staging / ROOT_COPY), str(staging)],
                    timeout=20, output_limit=1024,
                    environment={"PATH": os.defpath, "LC_ALL": "C", "HOME": "/nonexistent"})
        os.unlink(ROOT_COPY, dir_fd=private)
        os.fsync(private)
        os.fsync(parent)
        snapshot.same_parent(destination.parent, parent)
        current, owned = os.stat(staging_name, dir_fd=parent, follow_symlinks=False), os.fstat(private)
        require((current.st_dev, current.st_ino) == (owned.st_dev, owned.st_ino),
                "The private signing staging directory changed.")
        snapshot.publish_snapshot(parent, staging_name, destination.name)
    except BaseException:
        snapshot.discard_owned_staging(parent, staging_name, private, names=(*KEYS, ROOT_COPY))
        raise
    finally:
        if private is not None:
            os.close(private)
        os.close(parent)
    return {"status": "prepared", "keys_directory": str(destination), "root_sha256": hashlib.sha256(root).hexdigest()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keys-directory", type=Path, required=True)
    root_source = parser.add_mutually_exclusive_group(required=True)
    root_source.add_argument("--trust-root", type=Path)
    root_source.add_argument("--trust-root-directory", type=Path)
    parser.add_argument("--destination-directory", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = prepare(args.keys_directory, args.trust_root, args.destination_directory,
                         trust_root_directory=args.trust_root_directory)
        sys.stdout.buffer.write(registry.json_bytes(result))
        return 0
    except (AdminError, OSError, ValueError, UnicodeError):
        print("prepare-signers: preparation refused. Check projected permissions, registry key roles, and a new memory-backed destination.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
