#!/usr/bin/env python3
"""Build and check the Asm v1 registry. Requires Python 3.11 or later."""

from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import tomllib
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


SCHEMA = 1
HEADER = "# asm-registry-v1\n"
TARGETS = {"x86_64-linux": 62, "aarch64-linux": 183, "riscv64-linux": 243}
TARGETS["aarch64-macos"] = 0x0100000C
WINDOWS_TARGETS = {"x86_64-windows": 0x8664, "aarch64-windows": 0xAA64}
TARGETS.update(WINDOWS_TARGETS)
MAX_RELEASE_ARTIFACTS = 14
PE_MAX_SECTIONS = 96
PE_MAX_DIRECTORIES = 16
PE_MAX_IMAGE_BYTES = 2 * 1024 * 1024 * 1024
KINDS = {"source", "executable"}
MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_EXPANDED_BYTES = 64 * 1024 * 1024
MAX_FILES = 4096
MAX_INDEX_BYTES = 1024 * 1024
MAX_ROWS = 4096
MAX_ROW_BYTES = 2048
MAX_PATH_BYTES = 240
MAX_RESOLUTION_MANIFEST_BYTES = 8190
MAX_DEPENDENCIES = 64
MAX_FEATURES = 64
MAX_FEATURE_ENTRIES = 64
MAX_REQUIREMENT_BYTES = 128
MAX_REQUIREMENT_TERMS = 8
LICENSES = {
    "AGPL-3.0-only", "AGPL-3.0-or-later", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "BSL-1.0", "GPL-2.0-only",
    "GPL-2.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later", "ISC",
    "LGPL-2.1-only", "LGPL-2.1-or-later", "LGPL-3.0-only",
    "LGPL-3.0-or-later", "MIT", "MPL-2.0", "Unlicense", "Zlib",
}
EXCLUDED = {".git", ".asm", ".venv", "__pycache__", "build", "dist"}
SENSITIVE = {".env", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519"}
WINDOWS_RESERVED = {"con", "prn", "aux", "nul"} | {
    f"{prefix}{number}" for prefix in ("com", "lpt") for number in range(1, 10)
}
MANIFEST_KEYS = {
    "schema", "name", "version", "summary", "license", "source", "artifacts",
    "yanked", "yank_reason",
}
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")


class RegistryError(ValueError):
    """An input violates the registry contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RegistryError(message)


def exact_keys(value: object, allowed: set[str], required: set[str], label: str) -> dict:
    require(isinstance(value, dict), f"{label} must be an object")
    require(not (set(value) - allowed), f"{label} has unknown fields")
    require(required <= set(value), f"{label} is missing required fields")
    return value


def plain_text(value: object, maximum: int, label: str) -> str:
    require(isinstance(value, str), f"{label} must be text")
    require(0 < len(value) <= maximum, f"{label} has an invalid length")
    require(all(32 <= ord(char) <= 126 for char in value), f"{label} must be printable ASCII")
    require(value == value.strip(), f"{label} must not have outer whitespace")
    return value


def package_name(value: object) -> str:
    require(isinstance(value, str), "package name must be text")
    require(re.fullmatch(r"[a-z][a-z0-9-]{0,38}/[a-z][a-z0-9-]{0,63}", value) is not None,
            "package name must be owner/name in lowercase ASCII")
    require(all(not part.endswith("-") and "--" not in part for part in value.split("/")),
            "package name cannot have trailing or repeated hyphens")
    return value


def version_tuple(value: object) -> tuple[int, int, int]:
    require(isinstance(value, str), "version must be text")
    require(re.fullmatch(r"(0|[1-9][0-9]{0,9})\.(0|[1-9][0-9]{0,9})\.(0|[1-9][0-9]{0,9})", value)
            is not None, "version must be numeric major.minor.patch without leading zeroes")
    parts = tuple(int(part) for part in value.split("."))
    require(all(part <= 2147483647 for part in parts), "version component is too large")
    return parts


def portable_path(value: object, *, allow_root: bool = False) -> str:
    require(isinstance(value, str), "path must be text")
    if value == "." and allow_root:
        return value
    require(0 < len(value) <= MAX_PATH_BYTES, "path has an invalid length")
    parts = value.split("/")
    for part in parts:
        require(re.fullmatch(r"[A-Za-z0-9_.-]+", part) is not None, "path has invalid characters")
        require(part not in (".", "..") and not part.startswith("-"), "unsafe path segment")
        require(not part.endswith("."), "path cannot end in a dot")
        require(part.split(".", 1)[0].lower() not in WINDOWS_RESERVED, "reserved path segment")
    return value


def repository_url(value: object) -> str:
    require(isinstance(value, str), "source repository must be text")
    require(re.fullmatch(r"https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}", value)
            is not None, "source repository must be a canonical HTTPS GitHub URL")
    require(not value.endswith(".git"), "use the repository URL without .git")
    return value


def artifact_url(value: object) -> tuple[str, str, str]:
    require(isinstance(value, str), "artifact URL must be text")
    require(len(value) <= 768, "artifact URL is too long")
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and parsed.netloc == "github.com", "artifact URL must use HTTPS github.com")
    require(not parsed.query and not parsed.fragment, "artifact URL cannot have a query or fragment")
    parts = parsed.path.split("/")
    require(len(parts) == 7 and parts[0] == "" and parts[3:5] == ["releases", "download"],
            "artifact URL must identify a GitHub release asset")
    repository = repository_url("https://github.com/" + "/".join(parts[1:3]))
    for part in parts[5:]:
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", part) is not None,
                "release tag and asset must be simple unescaped path segments")
        require(part not in (".", ".."), "unsafe release URL")
    return repository, parts[5], parts[6]


def validate_manifest(value: object) -> dict:
    record = exact_keys(value, MANIFEST_KEYS, MANIFEST_KEYS - {"yank_reason"}, "manifest")
    require(type(record["schema"]) is int and record["schema"] == SCHEMA, "unsupported manifest schema")
    package_name(record["name"])
    version_tuple(record["version"])
    plain_text(record["summary"], 160, "summary")
    require(isinstance(record["license"], str) and record["license"] in LICENSES,
            "license is not supported by the v1 open-source policy")
    source = exact_keys(record["source"], {"repository", "commit", "path"},
                        {"repository", "commit", "path"}, "source")
    repository_url(source["repository"])
    require(isinstance(source["commit"], str) and HEX40.fullmatch(source["commit"]) is not None
            and source["commit"] != "0" * 40, "source commit must be a full lowercase Git commit ID")
    portable_path(source["path"], allow_root=True)
    require(type(record["yanked"]) is bool, "yanked must be a boolean")
    if record["yanked"]:
        plain_text(record.get("yank_reason"), 160, "yank reason")
    else:
        require(record.get("yank_reason", "") == "", "a published release cannot have a yank reason")
    require(isinstance(record["artifacts"], list) and 0 < len(record["artifacts"]) <= MAX_RELEASE_ARTIFACTS,
            "a release needs between one and fourteen artifacts")
    seen = set()
    seen_urls = set()
    for artifact in record["artifacts"]:
        exact_keys(artifact, {"target", "kind", "sha256", "url", "bytes"},
                   {"target", "kind", "sha256", "url", "bytes"}, "artifact")
        require(isinstance(artifact["target"], str) and artifact["target"] in TARGETS,
                "unsupported artifact target")
        require(isinstance(artifact["kind"], str) and artifact["kind"] in KINDS,
                "unsupported artifact kind")
        require(isinstance(artifact["sha256"], str) and HEX64.fullmatch(artifact["sha256"]) is not None,
                "artifact SHA-256 must have 64 lowercase hexadecimal characters")
        require(type(artifact["bytes"]) is int and 0 < artifact["bytes"] <= MAX_ARTIFACT_BYTES,
                "artifact byte size is out of range")
        _, _, asset = artifact_url(artifact["url"])
        if artifact["kind"] == "source":
            require(asset.endswith(".tar.gz"), "source artifacts must use .tar.gz")
        key = (artifact["target"], artifact["kind"])
        require(key not in seen, "duplicate target/kind artifact")
        require(artifact["url"] not in seen_urls, "duplicate artifact URL")
        seen.add(key)
        seen_urls.add(artifact["url"])
    return record


def strict_json(data: str | bytes) -> object:
    def unique_object(pairs: list[tuple[str, object]]) -> dict:
        result = {}
        for key, value in pairs:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def invalid_constant(value: str) -> None:
        raise RegistryError(f"invalid JSON number: {value}")

    try:
        return json.loads(data, object_pairs_hook=unique_object,
                          parse_constant=invalid_constant)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise RegistryError(f"invalid JSON: {error}") from error


def read_records(registry: Path) -> list[dict]:
    package_root = registry / "packages"
    require(package_root.is_dir() and not package_root.is_symlink(), "registry/packages must be a directory")
    records = []
    for path in sorted(package_root.rglob("*")):
        require(not path.is_symlink(), "registry metadata cannot contain symlinks")
        if path.is_dir():
            continue
        require(stat.S_ISREG(path.stat().st_mode), "registry metadata must be a regular file")
        if path == package_root / ".gitkeep":
            info = path.stat()
            require(stat.S_ISREG(info.st_mode) and info.st_size == 0,
                    "registry root .gitkeep must be an empty regular file")
            continue
        require(path.suffix == ".json", f"unexpected registry file: {path.name}")
        require(path.stat().st_size <= 65536, "manifest is too large")
        record = validate_manifest(strict_json(path.read_bytes()))
        expected = package_root / record["name"] / (record["version"] + ".json")
        require(path == expected, f"manifest path must be packages/{record['name']}/{record['version']}.json")
        records.append(record)
    return check_records(records)


def check_records(records: list[dict]) -> list[dict]:
    require(len(records) <= MAX_ROWS, "too many releases")
    seen = set()
    urls = set()
    for record in records:
        validate_manifest(record)
        key = (record["name"], record["version"])
        require(key not in seen, "duplicate package version")
        seen.add(key)
        for artifact in record["artifacts"]:
            require(artifact["url"] not in urls, "an artifact URL cannot be reused by another release")
            urls.add(artifact["url"])
    return sorted(records, key=lambda item: (item["name"], version_tuple(item["version"])))


def check_immutable(records: list[dict], baseline: list[dict]) -> None:
    current = {(record["name"], record["version"]): record for record in records}
    for old in baseline:
        key = (old["name"], old["version"])
        require(key in current, f"published release cannot be deleted: {key[0]}@{key[1]}")
        old_content = {k: v for k, v in old.items() if k not in {"yanked", "yank_reason"}}
        new_content = {k: v for k, v in current[key].items() if k not in {"yanked", "yank_reason"}}
        require(old_content == new_content, f"published release is immutable: {key[0]}@{key[1]}")


def read_regular(root: Path, relative: str, maximum: int = MAX_FILE_BYTES) -> bytes:
    portable_path(relative)
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        parts = relative.split("/")
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        file_descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                  dir_fd=descriptor)
        with os.fdopen(file_descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "source must be a regular, unlinked file")
            require(info.st_size <= MAX_FILE_BYTES, "source file is too large")
            require(info.st_size <= maximum, "source archive is too large")
            data = stream.read(min(MAX_FILE_BYTES, maximum) + 1)
            require(len(data) == info.st_size, "source file changed or exceeded the size limit")
            return data
    except OSError as error:
        raise RegistryError(f"cannot safely read {relative}: {error.strerror}") from error
    finally:
        os.close(descriptor)


def allowed_source_path(relative: str) -> bool:
    parts = PurePosixPath(relative).parts
    if any(part in EXCLUDED for part in parts):
        return False
    require(not any(part in SENSITIVE or part.startswith(".env.") for part in parts),
            "source contains a credential-file name")
    require(not relative.lower().endswith((".pem", ".key")), "source contains a private-key file name")
    portable_path(relative)
    return True


def collect_files(root: Path, includes: list[str] | None = None) -> dict[str, tuple[bytes, int]]:
    require(root.is_dir() and not root.is_symlink(), "source directory must exist and cannot be a symlink")
    roots = [root / portable_path(item) for item in includes] if includes else [root]
    files = {}
    total = 0
    for selected in roots:
        require(selected.exists() and not selected.is_symlink(), "included source path is missing or is a link")
        paths = [selected] if selected.is_file() else sorted(selected.rglob("*"))
        for path in paths:
            relative = path.relative_to(root).as_posix()
            if not allowed_source_path(relative):
                continue
            require(not path.is_symlink(), "source links are not allowed")
            if path.is_dir():
                continue
            if relative in files:
                continue
            data = read_regular(root, relative, MAX_EXPANDED_BYTES - total)
            total += len(data)
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            files[relative] = (data, mode)
            require(len(files) <= MAX_FILES, "too many source files")
    return files


def git_output(repository: Path, *arguments: str) -> bytes:
    # Source IDs and immutable baselines must identify the original objects.
    result = subprocess.run(["git", "--no-replace-objects", "-C", str(repository), *arguments], check=False,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RegistryError("Git command failed: " + result.stderr.decode("utf-8", "replace").strip())
    return result.stdout


def git_files(repository: Path, commit: str, source_path: str, includes: list[str] | None = None) -> dict[str, tuple[bytes, int]]:
    require(HEX40.fullmatch(commit) is not None and commit != "0" * 40, "a full source commit is required")
    require(git_output(repository, "cat-file", "-t", commit).strip() == b"commit", "source ID is not a Git commit")
    portable_path(source_path, allow_root=True)
    prefix = "" if source_path == "." else source_path + "/"
    selectors = [portable_path(item) for item in includes] if includes else None
    raw = git_output(repository, "ls-tree", "-r", "-z", "--full-tree", commit, "--", source_path)
    files = {}
    total = 0
    for item in raw.split(b"\0"):
        if not item:
            continue
        metadata, encoded_path = item.split(b"\t", 1)
        mode, kind, blob = metadata.decode("ascii").split()
        path = encoded_path.decode("ascii")
        require(path.startswith(prefix), "Git returned a path outside the source subtree")
        relative = path[len(prefix):]
        if selectors and not any(relative == selector or relative.startswith(selector + "/") for selector in selectors):
            continue
        if not allowed_source_path(relative):
            continue
        require(kind == "blob" and mode in {"100644", "100755"}, "Git links and submodules are not accepted")
        size = int(git_output(repository, "cat-file", "-s", blob).strip())
        require(size <= MAX_FILE_BYTES, "Git source file is too large")
        require(size <= MAX_EXPANDED_BYTES - total, "source archive is too large")
        data = git_output(repository, "cat-file", "blob", blob)
        require(len(data) == size, "Git blob size mismatch")
        total += len(data)
        files[relative] = (data, 0o755 if mode == "100755" else 0o644)
        require(len(files) <= MAX_FILES, "too many source files")
    require(files, "source commit has no selected files")
    return files


def make_archive(files: dict[str, tuple[bytes, int]]) -> bytes:
    require(0 < len(files) <= MAX_FILES, "source archive has an invalid file count")
    require(sum(len(data) for data, _ in files.values()) <= MAX_EXPANDED_BYTES, "source archive is too large")
    folded = set()
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT, encoding="ascii") as archive:
        for path, (data, mode) in sorted(files.items()):
            portable_path(path)
            require(path.casefold() not in folded, "source paths collide on a case-insensitive filesystem")
            folded.add(path.casefold())
            require(len(data) <= MAX_FILE_BYTES, "source file is too large")
            require(mode in (0o644, 0o755), "unsupported source mode")
            entry = tarfile.TarInfo(path)
            entry.size = len(data)
            entry.mode = mode
            entry.mtime = 0
            entry.uid = entry.gid = 0
            entry.uname = entry.gname = ""
            archive.addfile(entry, io.BytesIO(data))
    output = io.BytesIO()
    with gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0, compresslevel=9) as compressed:
        compressed.write(tar_buffer.getvalue())
    data = output.getvalue()
    require(len(data) <= MAX_ARTIFACT_BYTES, "compressed source archive is too large")
    return data


def tar_number(field: bytes, label: str) -> int:
    value = field.rstrip(b"\0 ").lstrip(b" ")
    require(bool(value) and re.fullmatch(rb"[0-7]+", value) is not None, f"invalid tar {label}")
    return int(value, 8)


def tar_string(field: bytes) -> str:
    head, separator, tail = field.partition(b"\0")
    require(not separator or not any(tail), "non-canonical tar text field")
    try:
        return head.decode("ascii")
    except UnicodeDecodeError as error:
        raise RegistryError("tar paths must be ASCII") from error


def read_archive(data: bytes) -> dict[str, bytes]:
    require(0 < len(data) <= MAX_ARTIFACT_BYTES, "archive size is out of range")
    # Match the native extractor: the whole TAR stream, including headers and
    # padding, must fit the decompression bound before it is parsed.
    limit = MAX_EXPANDED_BYTES
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data), mode="rb") as compressed:
            raw = compressed.read(limit + 1)
    except (OSError, EOFError) as error:
        raise RegistryError("invalid gzip source archive") from error
    require(len(raw) <= limit, "expanded archive exceeds the byte limit")
    require(len(raw) % 512 == 0, "tar length must be a multiple of 512")
    files = {}
    seen = set()
    path_types = {}
    offset = 0
    count = 0
    total = 0
    while offset + 512 <= len(raw):
        header = raw[offset:offset + 512]
        if not any(header):
            require(len(raw) - offset >= 1024 and not any(raw[offset:]), "invalid tar end or trailing hidden content")
            require(files, "archive contains no source files")
            return files
        require(header[257:263] == b"ustar\0" and header[263:265] == b"00", "only USTAR archives are accepted")
        checksum = sum(header[:148]) + 8 * 32 + sum(header[156:])
        require(tar_number(header[148:156], "checksum") == checksum, "tar checksum mismatch")
        require(header[156:157] in (b"0", b"\0", b"5"), "tar links, extensions, and special files are forbidden")
        require(not any(header[157:257]), "tar link target is forbidden")
        name = tar_string(header[:100])
        prefix = tar_string(header[345:500])
        path = (prefix + "/" if prefix else "") + name
        is_directory = header[156:157] == b"5"
        if is_directory:
            path = path.rstrip("/")
        portable_path(path)
        require(allowed_source_path(path), "archive contains an excluded directory")
        require(path.casefold() not in seen, "duplicate or case-colliding tar path")
        seen.add(path.casefold())
        folded = path.casefold()
        parents = PurePosixPath(folded).parents
        require(all(path_types.get(str(parent)) != "file" for parent in parents),
                "archive member has a file as its parent")
        if not is_directory:
            require(not any(existing.startswith(folded + "/") for existing in path_types),
                    "archive file replaces a directory")
        path_types[folded] = "directory" if is_directory else "file"
        count += 1
        require(count <= MAX_FILES, "archive has too many entries")
        mode = tar_number(header[100:108], "mode")
        require(mode in (0o644, 0o755), "tar file mode is not permitted")
        require(tar_number(header[108:116], "uid") == 0 and tar_number(header[116:124], "gid") == 0,
                "tar ownership must be normalized")
        size = tar_number(header[124:136], "size")
        require(size <= MAX_FILE_BYTES and (not is_directory or size == 0), "tar member size is invalid")
        total += size
        require(total <= MAX_EXPANDED_BYTES, "expanded source size exceeds the limit")
        start = offset + 512
        end = start + size
        next_offset = start + ((size + 511) // 512) * 512
        require(next_offset <= len(raw), "tar member is truncated")
        require(not any(raw[end:next_offset]), "tar padding must be zero")
        if not is_directory:
            files[path] = raw[start:end]
        offset = next_offset
    raise RegistryError("tar end marker is missing")


def validate_project(files: dict[str, bytes], name: str, version: str, target: str) -> dict:
    """Validate project contents and return the parsed source manifest."""
    require("asm.toml" in files, "source archive needs asm.toml")
    require(any(path in files for path in ("LICENSE", "LICENSE.txt", "LICENSE.md")), "source archive needs a license file")
    require(any(path in files for path in ("README", "README.md", "README.txt")), "source archive needs a README")
    try:
        project = tomllib.loads(files["asm.toml"].decode("utf-8"))
        if {"resolution", "dependencies", "features"} & project.keys():
            validate_resolution_project(files["asm.toml"], project)
        require(project["package"]["name"] == name.split("/")[-1], "project name does not match release")
        require(project["package"]["version"] == version, "project version does not match release")
        require(project["build"]["target"] == target, "project target does not match artifact")
        source = portable_path(project["build"]["source"])
        require(source in files, "declared assembly source is missing")
        require(source.endswith((".s", ".S", ".asm")), "build source must be an assembly file")
    except (KeyError, TypeError, UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise RegistryError("invalid source asm.toml") from error
    return project


def validate_requirement(value: object) -> None:
    """Validate a range over the existing bounded, numeric registry versions."""
    requirement = plain_text(value, MAX_REQUIREMENT_BYTES, "dependency requirement")
    if requirement == "*":
        return
    if requirement.startswith(("^", "~")):
        version_tuple(requirement[1:])
        return
    terms = requirement.split(",")
    require(len(terms) <= MAX_REQUIREMENT_TERMS, "dependency requirement has too many comparators")
    for term in terms:
        match = re.fullmatch(r"(<=|>=|<|>|=)?[ \t]*([^ \t]+)", term.strip(" \t"))
        require(match is not None, "dependency requirement has an invalid comparator")
        require(len(terms) == 1 or match[1] is not None, "range intersections need explicit comparators")
        version_tuple(match[2])


def feature_name(value: object) -> str:
    require(isinstance(value, str) and re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", value) is not None,
            "feature name must contain at most 32 lowercase ASCII characters")
    return value


def feature_entries(value: object, label: str) -> list[str]:
    require(isinstance(value, list) and len(value) <= MAX_FEATURE_ENTRIES,
            f"{label} must be an array with at most {MAX_FEATURE_ENTRIES} entries")
    require(all(isinstance(entry, str) for entry in value), f"{label} entries must be text")
    require(len(set(value)) == len(value), f"{label} contains duplicate entries")
    return value


def validate_resolution_syntax(data: bytes) -> None:
    """Restrict versioned metadata to the native parser's single-line subset.

    tomllib supplies duplicate-key and TOML checks. This second check rejects
    escapes, multiline values, literal strings, dotted keys, nested tables,
    and non-ASCII bytes that the native resolver does not interpret.
    """
    require(0 < len(data) <= MAX_RESOLUTION_MANIFEST_BYTES, "resolution manifest exceeds 8190 bytes")
    require(all(byte in (9, 10, 13) or 32 <= byte <= 126 for byte in data),
            "resolution manifest must use ASCII text")
    quoted = r'"[\x20-\x21\x23-\x5b\x5d-\x7e]*"'
    bare = r"[a-z][a-z0-9_-]*"
    space = r"[ \t]*"
    array = rf"\[{space}(?:{quoted}(?:{space},{space}{quoted})*{space},?{space})?\]"
    value = rf"(?:{quoted}|true|false|{array})"
    item = rf"{bare}{space}={space}{value}"
    inline = rf"\{{{space}{item}(?:{space},{space}{item})*{space}\}}"
    values = {"package": quoted, "build": quoted, "resolution": quoted,
              "dependencies": rf"(?:{quoted}|{inline})", "features": array}
    section = None
    for line in data.decode("ascii").splitlines():
        in_string = False
        for offset, char in enumerate(line):
            if char == '"':
                in_string = not in_string
            elif char == "#" and not in_string:
                line = line[:offset]
                break
        line = line.strip(" \t")
        if not line:
            continue
        if line.startswith("["):
            require(line in {f"[{name}]" for name in values}, "unsupported resolution manifest section")
            section = line[1:-1]
            continue
        require(section in values, "resolution manifest field needs a section")
        key = quoted if section == "dependencies" else rf"(?:{bare}|{quoted})" if section == "features" else bare
        require(re.fullmatch(rf"{key}{space}={space}{values[section]}", line) is not None,
                "resolution manifest uses unsupported TOML syntax")


def validate_resolution_project(data: bytes, project: dict) -> None:
    """Check source-bound dependency and feature declarations without resolving."""
    validate_resolution_syntax(data)
    exact_keys(project, {"package", "build", "resolution", "dependencies", "features"},
               {"package", "build", "resolution"}, "resolution project")
    exact_keys(project["package"], {"name", "version"}, {"name", "version"}, "project package")
    exact_keys(project["build"], {"source", "target"}, {"source", "target"}, "project build")
    resolution = exact_keys(project["resolution"], {"schema"}, {"schema"}, "resolution")
    require(resolution["schema"] == "1", "unsupported resolution schema")
    dependencies = project.get("dependencies", {})
    features = project.get("features", {})
    require(isinstance(dependencies, dict) and len(dependencies) <= MAX_DEPENDENCIES,
            "project can declare at most 64 dependencies")
    require(isinstance(features, dict) and len(features) <= MAX_FEATURES,
            "project can declare at most 64 features")
    optional = set()
    for name, dependency in dependencies.items():
        package_name(name)
        if isinstance(dependency, str):
            validate_requirement(dependency)
            continue
        dependency = exact_keys(dependency, {"version", "optional", "default-features", "features"},
                                {"version"}, "dependency")
        validate_requirement(dependency["version"])
        for field in ("optional", "default-features"):
            require(type(dependency.get(field, field == "default-features")) is bool,
                    f"dependency {field} must be a boolean")
        if dependency.get("optional", False):
            optional.add(name)
        for feature in feature_entries(dependency.get("features", []), "dependency features"):
            feature_name(feature)
    edges = {}
    for name, entries in features.items():
        feature_name(name)
        edges[name] = []
        for entry in feature_entries(entries, "feature"):
            if entry.startswith("dep:"):
                package_name(entry[4:])
                require(entry[4:] in optional, "dep: feature must select a declared optional dependency")
            elif "/" in entry:
                dependency, separator, feature = entry.rpartition("/")
                package_name(dependency)
                feature_name(feature)
                require(dependency in dependencies, "feature selects an undeclared dependency")
            else:
                feature_name(entry)
                require(entry in features, "feature selects an undeclared local feature")
                edges[name].append(entry)
    visited = set()
    active = set()

    def visit(name: str) -> None:
        require(name not in active, "local feature references contain a cycle")
        if name in visited:
            return
        active.add(name)
        for child in edges[name]:
            visit(child)
        active.remove(name)
        visited.add(name)

    for name in edges:
        visit(name)


def validate_elf(data: bytes, target: str) -> None:
    require(len(data) >= 64 and data[:4] == b"\x7fELF", "executable must be ELF")
    require(data[4:7] == b"\x02\x01\x01", "executable must be 64-bit little-endian ELF")
    kind, machine, elf_version = struct.unpack_from("<HHI", data, 16)
    require(kind in (2, 3) and machine == TARGETS[target] and elf_version == 1, "ELF target or type mismatch")
    program_offset = struct.unpack_from("<Q", data, 32)[0]
    header_size, entry_size, count = struct.unpack_from("<HHH", data, 52)
    require(header_size == 64 and entry_size == 56 and 0 < count <= 1024, "invalid ELF program headers")
    require(program_offset >= 64 and program_offset + entry_size * count <= len(data), "ELF program headers are truncated")
    has_load_segment = False
    for index in range(count):
        segment_type, _, file_offset, _, _, file_size, memory_size, _ = struct.unpack_from("<IIQQQQQQ", data, program_offset + index * entry_size)
        require(file_offset + file_size <= len(data), "ELF segment is out of bounds")
        if segment_type == 1:  # PT_LOAD; metadata segments need not occupy memory.
            has_load_segment = True
            require(file_size <= memory_size, "ELF load segment exceeds its memory size")
    require(has_load_segment, "ELF executable needs a load segment")


def validate_macho(data: bytes, target: str) -> None:
    """Check a thin arm64 macOS executable without mapping or executing it.

    Container checks do not authenticate code. Release provenance and the
    native codesign check are separate qualification gates.
    """
    require(target == "aarch64-macos" and len(data) >= 32, "unsupported Mach-O target")
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from("<8I", data)
    require((magic, cpu, subtype, kind, reserved) == (0xFEEDFACF, 0x100000C, 0, 2, 0),
            "Mach-O header or target mismatch")
    require(flags & 0x200000 and not flags & 0x20000, "Mach-O requires PIE and a non-executable stack")
    require(0 < count <= 128 and 0 < size <= 65536 and 32 + size <= len(data), "invalid Mach-O command bounds")
    offset, end = 32, 32 + size
    entry = None
    platform_seen = False
    executable_ranges = []
    for _ in range(count):
        require(offset + 8 <= end, "truncated Mach-O command")
        command, length = struct.unpack_from("<II", data, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= end, "invalid Mach-O command length")
        if command == 0x19:  # LC_SEGMENT_64
            require(length >= 72, "truncated Mach-O segment")
            _, memory, start, amount, maximum, protection, sections, _ = struct.unpack_from("<QQQQIIII", data, offset + 24)
            require(length == 72 + sections * 80 and start + amount <= len(data) and amount <= memory,
                    "invalid Mach-O segment bounds")
            require(protection & ~7 == 0 and maximum & ~7 == 0 and protection & maximum == protection,
                    "invalid Mach-O segment protections")
            require(not (protection & 2 and protection & 4), "writable executable Mach-O segment")
            if protection & 4 and amount:
                executable_ranges.append((start, start + amount))
        elif command == 0x80000028:  # LC_MAIN
            require(length == 24 and entry is None, "invalid Mach-O entry command")
            entry = struct.unpack_from("<Q", data, offset + 8)[0]
        elif command == 0x32:  # LC_BUILD_VERSION
            require(length >= 24 and not platform_seen, "invalid Mach-O platform command")
            platform, minimum, _, tools = struct.unpack_from("<4I", data, offset + 8)
            require(platform == 1 and minimum <= 0xF0000 and length == 24 + tools * 8,
                    "unsupported Mach-O platform or minimum OS")
            platform_seen = True
        offset += length
    require(offset == end and platform_seen and entry is not None and entry >= end,
            "incomplete Mach-O commands")
    require(any(start <= entry < stop for start, stop in executable_ranges), "Mach-O entry is not executable")



def validate_pe(data: bytes, target: str) -> None:
    """Check bounded PE32+ image headers without loading or executing code.

    This profile accepts Windows console/GUI images with page-aligned sections
    and declared NX compatibility. It checks section and directory extents;
    it does not validate imports, instructions, signatures, or runtime support.
    Microsoft PE/COFF reference, read 2026-11-05:
    https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
    """
    require(target in WINDOWS_TARGETS and 64 <= len(data) <= MAX_ARTIFACT_BYTES,
            "unsupported PE target or size")
    require(data[:2] == b"MZ", "Windows executable needs an MZ header")
    pe = struct.unpack_from("<I", data, 60)[0]
    require(pe >= 64 and pe % 8 == 0 and pe + 24 <= len(data), "invalid PE header offset")
    require(data[pe:pe + 4] == b"PE\0\0", "Windows executable needs a PE signature")
    machine, count, _, _, _, optional_size, flags = struct.unpack_from("<HHIIIHH", data, pe + 4)
    require(machine == WINDOWS_TARGETS[target], "PE target mismatch")
    require(flags & 2 and not flags & (0x100 | 0x1000 | 0x2000),
            "PE must be a 64-bit user executable, not a driver or DLL")
    require(0 < count <= PE_MAX_SECTIONS and 112 <= optional_size <= 4096,
            "invalid PE section or optional header count")
    optional = pe + 24
    table = optional + optional_size
    require(table + count * 40 <= len(data), "truncated PE section table")
    require(struct.unpack_from("<H", data, optional)[0] == 0x20B, "PE image must use PE32+")
    entry = struct.unpack_from("<I", data, optional + 16)[0]
    base = struct.unpack_from("<Q", data, optional + 24)[0]
    section_align, file_align = struct.unpack_from("<II", data, optional + 32)
    image_size, headers = struct.unpack_from("<II", data, optional + 56)
    subsystem, dll_flags = struct.unpack_from("<HH", data, optional + 68)
    directories = struct.unpack_from("<I", data, optional + 108)[0]
    require(0 < image_size <= PE_MAX_IMAGE_BYTES and 0 < base <= (1 << 64) - 1 - image_size
            and base % 65536 == 0, "invalid PE image base or size")
    require(512 <= file_align <= 65536 and file_align & (file_align - 1) == 0,
            "invalid PE file alignment")
    require(4096 <= section_align <= image_size and section_align >= file_align
            and section_align & (section_align - 1) == 0 and image_size % section_align == 0,
            "invalid PE section alignment")
    require(table + count * 40 <= headers <= len(data) and headers <= image_size
            and headers % file_align == 0, "invalid PE headers size")
    require(subsystem in (2, 3) and dll_flags & 0x100, "PE requires a Windows user subsystem and NX compatibility")
    require(directories <= PE_MAX_DIRECTORIES and 112 + directories * 8 <= optional_size,
            "PE data directories exceed the optional header")
    previous_memory_end = None
    raw_ranges = []
    initialized_ranges = [(0, headers)]
    executable_ranges = []
    first_rva = (headers + section_align - 1) // section_align * section_align
    for index in range(count):
        section = table + index * 40
        virtual_size, rva, raw_size, raw = struct.unpack_from("<IIII", data, section + 8)
        attributes = struct.unpack_from("<I", data, section + 36)[0]
        extent = max(virtual_size, raw_size)
        memory_end = rva + (extent + section_align - 1) // section_align * section_align
        require(extent > 0 and rva >= first_rva and rva % section_align == 0
                and memory_end <= image_size, "PE section memory range is out of bounds")
        require(previous_memory_end is None or rva == previous_memory_end,
                "PE section memory ranges must be ascending and adjacent")
        previous_memory_end = memory_end
        require(not (attributes & 0x80000000 and attributes & 0x20000000),
                "writable executable PE section")
        if raw_size:
            require(raw >= headers and raw % file_align == 0 and raw_size % file_align == 0
                    and raw + raw_size <= len(data), "PE section file range is out of bounds")
            require(not any(raw < stop and start < raw + raw_size for start, stop in raw_ranges),
                    "overlapping PE section file ranges")
            raw_ranges.append((raw, raw + raw_size))
            initialized_end = rva + min(virtual_size or raw_size, raw_size)
            initialized_ranges.append((rva, initialized_end))
            if attributes & 0x20000000:
                executable_ranges.append((rva, initialized_end))
        else:
            require(raw == 0, "empty PE section has a file offset")
    require(entry != 0 and any(start <= entry < stop for start, stop in executable_ranges),
            "PE entry is not in initialized executable bytes")
    for index in range(directories):
        address, size = struct.unpack_from("<II", data, optional + 112 + index * 8)
        if not address and not size:
            continue
        if index == 8:  # GlobalPtr contains an RVA but requires a zero size.
            require(size == 0 and any(start <= address < stop for start, stop in initialized_ranges),
                    "invalid PE global pointer directory")
            continue
        require(address > 0 and size > 0, "incomplete PE data directory")
        if index == 4:  # The certificate table uses a file offset, not an RVA.
            require(address >= headers and address % 8 == 0 and size >= 8 and size % 8 == 0
                    and address + size <= len(data), "PE certificate table is out of bounds")
            require(not any(address < stop and start < address + size for start, stop in raw_ranges),
                    "PE certificate table overlaps image bytes")
        else:
            require(any(start <= address and address + size <= stop for start, stop in initialized_ranges),
                    "PE data directory is not in initialized image bytes")


def validate_executable(data: bytes, target: str) -> None:
    require(target in TARGETS, "unsupported executable target")
    if target in WINDOWS_TARGETS:
        validate_pe(data, target)
    elif target.endswith("-macos"):
        validate_macho(data, target)
    else:
        validate_elf(data, target)


class _SourceDependencyMetadata:
    """Owned declarations derived only after source artifact validation.

    The immutable payload does not borrow manifest lists or published records.
    Identity includes the source's project name, version, target, size and hash.
    Namespace ownership remains a separate publication check.
    """
    __slots__ = ("identity", "payload")

    def __init__(self, project: dict, artifact: dict):
        self.identity = (project["package"]["name"], project["package"]["version"],
                         project["build"]["target"], artifact["bytes"], artifact["sha256"])
        dependencies = []
        for name, declaration in sorted(project.get("dependencies", {}).items()):
            declaration = {"version": declaration} if isinstance(declaration, str) else declaration
            dependencies.append({"name": name, "requirement": declaration["version"],
                "optional": declaration.get("optional", False),
                "default_features": declaration.get("default-features", True),
                "features": declaration.get("features", [])})
        self.payload = json_bytes({"schema": 1, "source_sha256": artifact["sha256"],
            "dependencies": dependencies, "features": project.get("features", {})})


def validate_artifact(data: bytes, record: dict, artifact: dict, *,
                      dependency_metadata: dict[str, _SourceDependencyMetadata] | None = None) -> None:
    require(len(data) == artifact["bytes"], "artifact byte size mismatch")
    require(hashlib.sha256(data).hexdigest() == artifact["sha256"], "artifact SHA-256 mismatch")
    if artifact["kind"] == "source":
        project = validate_project(read_archive(data), record["name"], record["version"], artifact["target"])
        if dependency_metadata is not None:
            dependency_metadata[artifact["sha256"]] = _SourceDependencyMetadata(project, artifact)
    else:
        validate_executable(data, artifact["target"])


def validate_local_artifacts(records: list[dict], directory: Path) -> set[tuple[str, str]]:
    checked = set()
    for record in records:
        for artifact in record["artifacts"]:
            _, _, asset = artifact_url(artifact["url"])
            path = directory / asset
            require(path.is_file() and not path.is_symlink(), f"artifact is missing: {asset}")
            require(path.stat().st_size == artifact["bytes"], f"artifact size mismatch: {asset}")
            validate_artifact(path.read_bytes(), record, artifact)
        checked.add((record["name"], record["version"]))
    return checked


def legacy_tsv(tsv: str) -> str:
    """Keep the published v0.3 Linux parser able to discover its next update.

    That parser rejects the entire index when any row has an unknown target.
    The full feed and JSON retain all other accepted targets.
    Input must be the canonical output of make_indexes.
    """
    return "".join(line for line in tsv.splitlines(keepends=True)
                   if line.startswith("#") or line.split("\t")[2] in
                   {"x86_64-linux", "aarch64-linux", "riscv64-linux"})


def macos_compat_tsv(tsv: str) -> str:
    """Preserve the four-target vocabulary of released macOS parsers.

    Input must be the canonical output of make_indexes. Keep this vocabulary
    fixed when a separately qualified target joins the full catalog.
    """
    return "".join(line for line in tsv.splitlines(keepends=True)
                   if line.startswith("#") or line.split("\t")[2] in
                   {"x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos"})


def make_indexes(records: list[dict], checked: set[tuple[str, str]] | None = None, *,
                 dependency_metadata: dict[str, _SourceDependencyMetadata] | None = None) -> tuple[str, dict]:
    records = check_records(records)
    checked = checked or set()
    dependency_metadata = dependency_metadata if dependency_metadata is not None else {}
    require(isinstance(dependency_metadata, dict), "dependency metadata must be a verified collection")
    for digest, metadata in dependency_metadata.items():
        require(isinstance(digest, str) and HEX64.fullmatch(digest) is not None
                and type(metadata) is _SourceDependencyMetadata and metadata.identity[4] == digest,
                "dependency metadata must identify its verified source digest")
    attached = set()
    lines = [HEADER]
    packages = {}
    rows = 0
    for record in records:
        name = record["name"]
        package = packages.setdefault(name, {"name": name, "summary": record["summary"],
            "license": record["license"], "repository": record["source"]["repository"],
            "latest": None, "targets": [], "versions": []})
        artifacts = copy.deepcopy(sorted(record["artifacts"], key=lambda item: (item["target"], item["kind"])))
        for artifact in artifacts:
            if artifact["kind"] != "source" or artifact["sha256"] not in dependency_metadata:
                continue
            metadata = dependency_metadata[artifact["sha256"]]
            require((name, record["version"]) in checked,
                    "dependency metadata needs checked release artifacts")
            require(metadata.identity == (name.split("/")[-1], record["version"], artifact["target"],
                                         artifact["bytes"], artifact["sha256"]),
                    "dependency metadata does not match its source artifact")
            artifact["dependency_metadata"] = json.loads(metadata.payload)
            attached.add(artifact["sha256"])
        release = {"version": record["version"], "license": record["license"], "source": record["source"],
            "yanked": record["yanked"], "artifacts": artifacts,
            "evidence": {"metadata": "validated", "artifacts": "validated" if (name, record["version"]) in checked else "not-run",
                         "provenance": "not-run", "formal": "not-run", "agent_review": "not-run"}}
        if record["yanked"]:
            release["yank_reason"] = record["yank_reason"]
        package["versions"].append(release)
        package["targets"] = sorted(set(package["targets"]) | {item["target"] for item in artifacts})
        if not record["yanked"]:
            package.update({"latest": record["version"], "summary": record["summary"],
                            "license": record["license"], "repository": record["source"]["repository"]})
            for artifact in artifacts:
                row = "\t".join([name, record["version"], artifact["target"], artifact["kind"],
                                 artifact["sha256"], artifact["url"], str(artifact["bytes"]), record["summary"]])
                require(len(row.encode("ascii")) <= MAX_ROW_BYTES, "index row is too long")
                lines.append(row + "\n")
                rows += 1
    require(rows <= MAX_ROWS, "index has too many artifact rows")
    require(attached == set(dependency_metadata), "dependency metadata has no matching source artifact")
    tsv = "".join(lines)
    require(len(tsv.encode("ascii")) <= MAX_INDEX_BYTES, "index exceeds one MiB")
    return tsv, {"schema": SCHEMA, "packages": list(packages.values())}


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".asm-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode("ascii")


def baseline_from_git(repository: Path, commit: str, registry_path: str = "registry") -> list[dict]:
    require(HEX40.fullmatch(commit) is not None, "baseline must be a full Git commit ID")
    require(git_output(repository, "cat-file", "-t", commit).strip() == b"commit", "baseline is not a commit")
    prefix = portable_path(registry_path) + "/packages/"
    raw = git_output(repository, "ls-tree", "-r", "-z", "--full-tree", commit, "--", prefix)
    records = []
    for item in raw.split(b"\0"):
        if not item:
            continue
        metadata, path = item.split(b"\t", 1)
        mode, kind, blob = metadata.decode("ascii").split()
        if path == (prefix + ".gitkeep").encode("ascii"):
            require(kind == "blob" and mode == "100644",
                    "registry root .gitkeep must be an empty regular file")
            require(git_output(repository, "cat-file", "-s", blob).strip() == b"0",
                    "registry root .gitkeep must be an empty regular file")
            continue
        require(kind == "blob" and mode == "100644" and path.endswith(b".json"), "invalid baseline metadata file")
        records.append(validate_manifest(strict_json(git_output(repository, "cat-file", "blob", blob))))
    return check_records(records)


def github_json(url: str) -> dict:
    require(url.startswith("https://api.github.com/repos/"), "untrusted metrics API URL")
    request = Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "asm-registry/1"})
    with urlopen(request, timeout=15) as response:
        payload = response.read(2 * 1024 * 1024 + 1)
    require(len(payload) <= 2 * 1024 * 1024, "metrics API response is too large")
    value = strict_json(payload)
    require(isinstance(value, dict), "invalid metrics API response")
    return value


def download_counts(records: list[dict], fetch=github_json, observed_at: str | None = None) -> dict:
    cache = {}
    packages = {}
    for record in check_records(records):
        counts = []
        for artifact in record["artifacts"]:
            repository, tag, _ = artifact_url(artifact["url"])
            api = repository.replace("https://github.com/", "https://api.github.com/repos/") + "/releases/tags/" + tag
            if api not in cache:
                try:
                    cache[api] = fetch(api)
                except (HTTPError, URLError, TimeoutError, OSError, RegistryError):
                    cache[api] = None
            response = cache[api]
            count = None
            if isinstance(response, dict) and isinstance(response.get("assets"), list):
                for asset in response["assets"]:
                    if not isinstance(asset, dict) or asset.get("browser_download_url") != artifact["url"]:
                        continue
                    value = asset.get("download_count")
                    digest = asset.get("digest")
                    if (type(value) is int and value >= 0 and asset.get("size") == artifact["bytes"]
                            and digest in (None, "sha256:" + artifact["sha256"])):
                        count = value
                    break
            counts.append(count)
        package = packages.setdefault(record["name"], {"total": None, "versions": {}})
        package["versions"][record["version"]] = sum(counts) if all(count is not None for count in counts) else None
    for package in packages.values():
        values = list(package["versions"].values())
        package["total"] = sum(values) if all(value is not None for value in values) else None
    return {"schema": SCHEMA, "source": "github-release-assets",
            "observed_at": observed_at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "packages": packages}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "build", "downloads"):
        item = commands.add_parser(command)
        item.add_argument("--registry", type=Path, default=Path("registry"))
        if command != "downloads":
            item.add_argument("--artifacts-dir", type=Path)
            item.add_argument("--baseline", type=Path)
            item.add_argument("--base-ref")
            item.add_argument("--repo", type=Path, default=Path("."))
        if command == "build":
            item.add_argument("--output", type=Path, default=Path("registry/v1"))
        if command == "downloads":
            item.add_argument("--output", type=Path, default=Path("registry/v1/downloads.json"))
    for command in ("pack", "pack-git"):
        item = commands.add_parser(command)
        item.add_argument("source", type=Path)
        item.add_argument("--output", type=Path, required=True)
        item.add_argument("--include", action="append")
        item.add_argument("--name", required=True)
        item.add_argument("--version", required=True)
        item.add_argument("--target", choices=sorted(TARGETS), required=True)
        if command == "pack-git":
            item.add_argument("--commit", required=True)
            item.add_argument("--source-path", default=".")
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--name", required=True)
    prepare.add_argument("--version", required=True)
    prepare.add_argument("--summary", required=True)
    prepare.add_argument("--license", required=True)
    prepare.add_argument("--repository", required=True)
    prepare.add_argument("--commit", required=True)
    prepare.add_argument("--source-path", default=".")
    prepare.add_argument("--artifact", nargs=4, action="append", metavar=("TARGET", "KIND", "FILE", "URL"), required=True)
    prepare.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command in ("pack", "pack-git"):
            package_name(arguments.name)
            version_tuple(arguments.version)
            files = (git_files(arguments.source, arguments.commit, arguments.source_path, arguments.include)
                     if arguments.command == "pack-git" else collect_files(arguments.source, arguments.include))
            data = make_archive(files)
            validate_project(read_archive(data), arguments.name, arguments.version, arguments.target)
            write_atomic(arguments.output, data)
            print(json.dumps({"file": str(arguments.output), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}))
        elif arguments.command == "prepare":
            record = {"schema": SCHEMA, "name": arguments.name, "version": arguments.version,
                      "summary": arguments.summary, "license": arguments.license,
                      "source": {"repository": arguments.repository, "commit": arguments.commit, "path": arguments.source_path},
                      "artifacts": [], "yanked": False}
            payloads = []
            for target, kind, filename, url in arguments.artifact:
                path = Path(filename)
                require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= MAX_ARTIFACT_BYTES,
                        "artifact file is missing, linked, or too large")
                data = path.read_bytes()
                artifact = {"target": target, "kind": kind, "sha256": hashlib.sha256(data).hexdigest(), "url": url, "bytes": len(data)}
                record["artifacts"].append(artifact)
                payloads.append(data)
            validate_manifest(record)
            for data, artifact in zip(payloads, record["artifacts"]):
                validate_artifact(data, record, artifact)
            write_atomic(arguments.output, json_bytes(record))
            print(f"Prepared {record['name']}@{record['version']}; submit this manifest for review. Nothing was uploaded.")
        else:
            records = read_records(arguments.registry)
            if arguments.command == "downloads":
                result = download_counts(records)
                write_atomic(arguments.output, json_bytes(result))
                unknown = sum(package["total"] is None for package in result["packages"].values())
                print(f"Wrote download counts; {unknown} package totals are unavailable.")
                return 0
            require(not (arguments.baseline and arguments.base_ref), "choose one immutable baseline source")
            if arguments.baseline:
                check_immutable(records, read_records(arguments.baseline))
            if arguments.base_ref:
                check_immutable(records, baseline_from_git(arguments.repo, arguments.base_ref))
            checked = validate_local_artifacts(records, arguments.artifacts_dir) if arguments.artifacts_dir else set()
            tsv, index = make_indexes(records, checked)
            if arguments.command == "build":
                write_atomic(arguments.output / "index.tsv", legacy_tsv(tsv).encode("ascii"))
                write_atomic(arguments.output / "index-macos.tsv", macos_compat_tsv(tsv).encode("ascii"))
                write_atomic(arguments.output / "index-all.tsv", tsv.encode("ascii"))
                write_atomic(arguments.output / "index.json", json_bytes(index))
            print(f"Validated {len(records)} releases; checked local artifacts for {len(checked)} releases.")
            if not arguments.artifacts_dir:
                print("Artifact bytes were not checked. Metadata validation is not artifact verification.")
        return 0
    except (RegistryError, OSError, UnicodeError, ValueError) as error:
        print(f"registry: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
