#!/usr/bin/env python3
"""Snapshot fixed projected credentials for a short operator Job.

SPDX-License-Identifier: AGPL-3.0-or-later
No database connection or serving operation occurs here.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import ipaddress
import os
from pathlib import Path
import re
import secrets
import stat
import sys
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit

import registry
from registry_admin import AdminError, Connection, reject_extended_acl, require, run_bounded

SOURCE_UID = 0
SOURCE_GID = 65532
PSQL = Path("/opt/asm/postgres/bin/psql")
TLS_FILES = {"sslrootcert": "ca.crt", "sslcert": "tls.crt", "sslkey": "tls.key"}
ROLES = ("asm_migrator", "asm_operator", "asm_publisher", "asm_publication_worker", "asm_distributor")
DNS_PROGRAM = """import ipaddress,socket,sys
values=sorted({str(ipaddress.IPv4Address(v[4][0])) for v in socket.getaddrinfo(sys.argv[1],None,socket.AF_INET,socket.SOCK_STREAM)})
if not 1 <= len(values) <= 8: raise SystemExit(1)
print(values[0])
"""


def resolve_ipv4(host, *, timeout=5):
    value = run_bounded([sys.executable, "-I", "-c", DNS_PROGRAM, host], timeout=timeout, output_limit=256,
        environment={"PATH": os.defpath, "LC_ALL": "C", "HOME": "/nonexistent"}).decode("ascii")
    require(value.endswith("\n") and value.count("\n") == 1,
            "The bounded resolver did not return one IPv4 address.")
    value = value[:-1]
    require(str(ipaddress.IPv4Address(value)) == value, "The resolver returned a noncanonical address.")
    return value


def parse_source_url(body, role, tls_directory, destination, *, resolve_dns):
    require(role in ROLES, "Select one explicit operator authority.")
    value = body.decode("ascii").removesuffix("\n")
    require(value.startswith("postgresql://") and "\n" not in value and "\r" not in value and "\0" not in value,
            "Use one canonical connection URL.")
    parsed = urlsplit(value)
    require(parsed.scheme == "postgresql" and not parsed.fragment and parsed.username == role
            and parsed.password is None and parsed.port is not None and 1 <= parsed.port <= 65535,
            "Use the selected certificate role without a password.")
    host = parsed.hostname or ""
    require(len(host) <= 253 and host == parsed.netloc.split("@", 1)[-1].rsplit(":", 1)[0]
            and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in host.split("."))
            and re.fullmatch(r"/[a-z][a-z0-9_]{0,62}", parsed.path), "Use a canonical TLS host and database name.")
    pairs = parse_qsl(parsed.query, strict_parsing=True, keep_blank_values=True)
    options = dict(pairs)
    required = {"sslmode", *TLS_FILES}
    allowed = required | {"hostaddr", "gssencmode", "connect_timeout", "ssl_min_protocol_version"}
    require(len(options) == len(pairs) and required <= set(options) <= allowed
            and options["sslmode"] == "verify-full"
            and options.get("gssencmode", "disable") == "disable"
            and options.get("connect_timeout", "2") == "2"
            and options.get("ssl_min_protocol_version", "TLSv1.2") in {"TLSv1.2", "TLSv1.3"},
            "Use the fixed TLS, deadline, and connection field policy.")
    for key, name in TLS_FILES.items():
        require(options[key] == str(tls_directory / name), "Use the fixed files in the projected TLS mount.")
    if "hostaddr" in options:
        require(str(ipaddress.IPv4Address(options["hostaddr"])) == options["hostaddr"], "Use a canonical IPv4 hostaddr.")
    else:
        require(resolve_dns, "Select explicit bounded DNS resolution when hostaddr is absent.")
        options["hostaddr"] = resolve_ipv4(host)
    # Rewrite only after all source authority, option, and path checks succeed.
    for key, name in TLS_FILES.items():
        options[key] = str(destination / name)
    return (urlunsplit(("postgresql", parsed.netloc, parsed.path, urlencode(options, quote_via=quote), "")) + "\n").encode("ascii")


def check_directory(fd):
    info = os.fstat(fd)
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == SOURCE_UID and info.st_gid == SOURCE_GID,
            "Use the expected projected volume owner and group.")
    require(not info.st_mode & 0o022 or os.fstatvfs(fd).f_flag & os.ST_RDONLY,
            "Use a read-only or protected projected volume directory.")
    reject_extended_acl(fd)


def open_protected_directory(path):
    """Walk physical operator paths through descriptors; root and this Job remain trusted writers."""
    require(path.is_absolute() and all(part not in {".", ".."} for part in path.parts[1:]),
            "Use physical absolute directory paths.")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parts = path.parts[1:]
        for index, part in enumerate(parts):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            readonly = bool(os.fstatvfs(fd).f_flag & os.ST_RDONLY)
            require(info.st_uid in {0, os.geteuid()}, "Use protected directory ancestors.")
            public_temporary_ancestor = (info.st_uid == 0 and info.st_mode & stat.S_ISVTX and index < len(parts) - 1)
            require(readonly or public_temporary_ancestor or not info.st_mode & 0o020 or info.st_gid == os.getegid(),
                    "An untrusted group can change a directory ancestor.")
            require(readonly or not info.st_mode & 0o002 or public_temporary_ancestor,
                    "Use a protected final directory beneath trusted ancestors.")
            reject_extended_acl(fd)
        return fd
    except BaseException:
        os.close(fd)
        raise


def same_parent(path, fd):
    reopened = open_protected_directory(path)
    try:
        before, after = os.fstat(fd), os.fstat(reopened)
        require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino), "The private parent directory changed.")
    finally:
        os.close(reopened)


def publish_snapshot(parent_fd, staging_name, destination_name):
    """Atomically publish a new directory without replacing any existing name."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "linux":
        function = library.renameat2
        flags = 1  # Linux RENAME_NOREPLACE
    elif sys.platform == "darwin":
        function = library.renameatx_np
        flags = 4  # macOS RENAME_EXCL
    else:
        raise AdminError("This host has no qualified atomic no-replace directory operation.")
    function.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    if function(parent_fd, os.fsencode(staging_name), parent_fd, os.fsencode(destination_name), flags) != 0:
        raise OSError(ctypes.get_errno(), "Atomic private snapshot publication refused")


@contextmanager
def projected(directory):
    mount = open_protected_directory(directory)
    generation = None
    try:
        check_directory(mount)
        pointer = os.stat("..data", dir_fd=mount, follow_symlinks=False)
        require(stat.S_ISLNK(pointer.st_mode) and pointer.st_uid == SOURCE_UID and pointer.st_gid == SOURCE_GID,
                "Use one owned AtomicWriter generation pointer.")
        name = os.readlink("..data", dir_fd=mount)
        require(re.fullmatch(r"\.\.[A-Za-z0-9_.-]{1,120}", name) and name not in {"..", "..."},
                "Use one relative projected generation name.")
        generation = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=mount)
        check_directory(generation)
        yield generation
    finally:
        if generation is not None:
            os.close(generation)
        os.close(mount)


def read_projected(directory_fd, name, maximum):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == SOURCE_UID
                and info.st_gid == SOURCE_GID and stat.S_IMODE(info.st_mode) == 0o440
                and 1 <= info.st_size <= maximum, "Use bounded root:GID65532 projected files with mode0440.")
        reject_extended_acl(fd)
        body = bytearray()
        while len(body) <= maximum:
            value = os.read(fd, min(65536, maximum + 1 - len(body)))
            if not value:
                break
            body.extend(value)
        after = os.fstat(fd)
        require(len(body) == info.st_size and after.st_size == info.st_size and after.st_mtime_ns == info.st_mtime_ns,
                "The projected generation changed during its snapshot.")
        return bytes(body)
    finally:
        os.close(fd)


def write_private(directory_fd, name, body):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
    try:
        os.fchmod(fd, 0o600)
        remaining = memoryview(body)
        while remaining:
            written = os.write(fd, remaining)
            require(written > 0, "The private credential write stopped.")
            remaining = remaining[written:]
        os.fsync(fd)
    finally:
        os.close(fd)


def discard_owned_staging(parent_fd, staging_name, private_fd, *, names=(*TLS_FILES.values(), ".check.url", "database.url")):
    """Remove only a still-owned staging name; publication or uncertain identity preserves all files."""
    if private_fd is None:
        return
    try:
        current = os.stat(staging_name, dir_fd=parent_fd, follow_symlinks=False)
        owned = os.fstat(private_fd)
        if not stat.S_ISDIR(current.st_mode) or (current.st_dev, current.st_ino) != (owned.st_dev, owned.st_ino):
            return
    except OSError:
        return
    for name in names:
        try:
            os.unlink(name, dir_fd=private_fd)
        except FileNotFoundError:
            pass
        except OSError:
            return
    try:
        current = os.stat(staging_name, dir_fd=parent_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) == (owned.st_dev, owned.st_ino):
            os.rmdir(staging_name, dir_fd=parent_fd)
    except OSError:
        pass


def prepare(config_directory, tls_directory, destination, role, psql=PSQL, *, resolve_dns=False):
    require(all(path.is_absolute() for path in (config_directory, tls_directory, destination)),
            "Use absolute projected and private volume paths.")
    with projected(config_directory) as config:
        body = read_projected(config, "database.url", 8192)
    url = parse_source_url(body, role, tls_directory, destination, resolve_dns=resolve_dns)
    with projected(tls_directory) as tls:
        files = {name: read_projected(tls, name, 65536) for name in TLS_FILES.values()}
    parent = open_protected_directory(destination.parent)
    private = None
    staging_name = ".asm-operator-" + secrets.token_hex(12)
    try:
        os.mkdir(staging_name, 0o700, dir_fd=parent)
        private = os.open(staging_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        require(os.fstat(private).st_uid == os.geteuid(), "Use an owned private staging directory.")
        os.fchmod(private, 0o700)  # Clear inherited setgid without granting group or other access.
        require(os.fstat(private).st_uid == os.geteuid() and stat.S_IMODE(os.fstat(private).st_mode) == 0o700,
                "Use an owner-only private snapshot directory.")
        for name, content in files.items():
            write_private(private, name, content)
        same_parent(destination.parent, parent)
        staging = destination.parent / staging_name
        parsed = urlsplit(url.decode().strip())
        options = dict(parse_qsl(parsed.query))
        for key, name in TLS_FILES.items():
            options[key] = str(staging / name)
        validation_url = (urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(options, quote_via=quote), "")) + "\n").encode("ascii")
        write_private(private, ".check.url", validation_url)
        # This validates the unchanged private-file/URL/client policy without connecting.
        with Connection(staging / ".check.url", psql, role):
            pass
        os.unlink(".check.url", dir_fd=private)
        write_private(private, "database.url", url)
        os.fsync(private)
        os.fsync(parent)
        same_parent(destination.parent, parent)
        current = os.stat(staging_name, dir_fd=parent, follow_symlinks=False)
        require((current.st_dev, current.st_ino) == (os.fstat(private).st_dev, os.fstat(private).st_ino),
                "The private staging directory changed.")
        # Last state-changing operation: no partial snapshot is visible at the final name.
        publish_snapshot(parent, staging_name, destination.name)
    except BaseException:
        # A post-publication signal leaves the descriptor attached to the final directory.
        # Establish staging-name/inode ownership before any destructive cleanup.
        discard_owned_staging(parent, staging_name, private)
        raise
    finally:
        if private is not None:
            os.close(private)
        os.close(parent)
    return {"status": "prepared", "connection_file": str(destination / "database.url"), "role": role,
            "dns_resolved": resolve_dns and "hostaddr" not in dict(parse_qsl(urlsplit(body.decode().strip()).query))}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-directory", type=Path, required=True)
    parser.add_argument("--tls-directory", type=Path, required=True)
    parser.add_argument("--destination-directory", type=Path, required=True)
    parser.add_argument("--role", choices=ROLES, required=True)
    parser.add_argument("--resolve-dns", action="store_true")
    args = parser.parse_args(argv)
    try:
        value = prepare(args.config_directory, args.tls_directory, args.destination_directory, args.role,
                        resolve_dns=args.resolve_dns)
        sys.stdout.buffer.write(registry.json_bytes(value))
        return 0
    except (AdminError, OSError, ValueError, UnicodeError):
        print("prepare-operator: preparation refused. Check projected permissions, URL policy, DNS deadline, and a new private destination.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
