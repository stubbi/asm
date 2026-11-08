"""Bounded operator storage for immutable blobs and conditional metadata heads.

These adapters do not grant package ownership or execute package contents.
S3-compatible providers must enforce conditional writes; no unsafe fallback is
available. Local mutation uses a cooperative same-user advisory lock. It does
not protect against a compromised account or an administrator.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import base64
from contextlib import contextmanager
import fcntl
import hashlib
from io import BytesIO
import ipaddress
import os
from pathlib import Path
import re
import stat
import tempfile
from urllib.parse import urlsplit
import uuid

import registry

MAX_OBJECT_BYTES = 4 * 1024 * 1024
MAX_KEY_BYTES = 1024
CHUNK_BYTES = 64 * 1024


class StorageConflict(registry.RegistryError):
    """A conditional write lost to another writer; reread before retrying."""


class MissingBlob(registry.RegistryError):
    """The selected digest object is absent; other read failures use RegistryError."""


def _key(value):
    # S3 counts the prefix in its 1,024-byte key limit. Archive paths retain
    # their separate 240-byte limit; consistent TUF target paths can be longer.
    registry.require(isinstance(value, str) and 0 < len(value) <= MAX_KEY_BYTES, "invalid storage key length")
    for part in value.split("/"):
        registry.require(0 < len(part) <= registry.MAX_PATH_BYTES and re.fullmatch(r"[A-Za-z0-9_.-]+", part)
            and not part.startswith((".", "-")) and not part.endswith("."), "invalid storage key segment")
    return value


def _blob(sha256, size):
    registry.require(isinstance(sha256, str) and registry.HEX64.fullmatch(sha256) is not None,
                     "blob digest must be lowercase SHA-256")
    registry.require(type(size) is int and 0 < size <= registry.MAX_ARTIFACT_BYTES, "blob size is out of range")
    return "blobs/sha256/" + sha256


def _metadata_key(value):
    _key(value)
    registry.require(value.split("/", 1)[0] != "blobs", "the blob namespace requires digest-checked operations")


def _limit(value):
    registry.require(type(value) is int and 0 < value <= MAX_OBJECT_BYTES, "object read limit is out of range")


def _data(value):
    registry.require(isinstance(value, bytes) and 0 < len(value) <= MAX_OBJECT_BYTES,
                     "metadata must contain between one byte and four MiB")


def _read(stream, limit):
    chunks, count = [], 0
    while True:
        chunk = stream.read(min(CHUNK_BYTES, limit + 1 - count))
        registry.require(isinstance(chunk, bytes), "storage returned an invalid body")
        if not chunk:
            return b"".join(chunks)
        count += len(chunk)
        registry.require(count <= limit, "stored object exceeds its byte limit")
        chunks.append(chunk)


def _verify(data, sha256, size):
    registry.require(len(data) == size and hashlib.sha256(data).hexdigest() == sha256,
                     "stored object differs from its expected size or SHA-256")


def _absolute(path):
    path = Path(path).absolute()
    registry.require(".." not in path.parts, "storage path cannot contain traversal")
    # macOS exposes these fixed, root-owned aliases. No caller-selected links
    # are resolved; all later traversal opens directories with O_NOFOLLOW.
    for alias, target in ((Path("/var"), Path("/private/var")), (Path("/tmp"), Path("/private/tmp"))):
        if path.is_relative_to(alias):
            try:
                info = alias.lstat()
                if stat.S_ISLNK(info.st_mode) and info.st_uid == 0 and alias.resolve() == target:
                    path = target / path.relative_to(alias)
            except FileNotFoundError:
                pass
    return path


@contextmanager
def _directory(path, *, create=False, private=False):
    path = _absolute(path)
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.parts[1:]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        if private:
            info = os.fstat(descriptor)
            registry.require(info.st_uid == os.getuid() and not info.st_mode & 0o077,
                             "local storage directory must be private and owned")
            registry.reject_extended_acl(descriptor)
        yield descriptor
    except FileNotFoundError:
        raise
    except OSError:
        raise registry.RegistryError("cannot safely access local storage path") from None
    finally:
        os.close(descriptor)


def _regular(descriptor, limit, *, private=False):
    info = os.fstat(descriptor)
    registry.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= limit,
                     "storage requires a bounded regular file without hard links")
    if private:
        registry.require(info.st_uid == os.getuid() and not info.st_mode & 0o077,
                         "local storage file must be private and owned")
        registry.reject_extended_acl(descriptor)
    return info


@contextmanager
def _staged(source, sha256, size):
    """Copy an operator-selected file into a private, checked transfer source."""
    path = _absolute(source)
    try:
        with _directory(path.parent) as parent:
            descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(descriptor, "rb") as stream, tempfile.TemporaryFile() as stage:
            registry.require(_regular(stream.fileno(), size).st_size == size, "source blob size differs")
            digest, count = hashlib.sha256(), 0
            while True:
                chunk = stream.read(min(CHUNK_BYTES, size + 1 - count))
                if not chunk:
                    break
                count += len(chunk)
                registry.require(count <= size, "source blob grew during staging")
                digest.update(chunk)
                stage.write(chunk)
            registry.require(count == size and digest.hexdigest() == sha256, "source blob size or SHA-256 differs")
            stage.flush()
            stage.seek(0)
            yield stage
    except OSError:
        raise registry.RegistryError("cannot stage the source blob safely") from None


class _BlobOperations:
    def _create(self, key, stream, size, sha256):
        created = True
        try:
            self._write(key, stream, size, sha256, None, immutable=True)
        except StorageConflict:
            created = False
        result = self._read_object(key, size)
        registry.require(result is not None, "stored object is unavailable after conditional creation")
        _verify(result[0], sha256, size)
        return created

    def put_blob(self, source: Path, sha256: str, size: int) -> bool:
        """Create exact digest bytes; return False only for verified existing bytes."""
        key = _blob(sha256, size)
        with _staged(source, sha256, size) as stream:
            return self._create(key, stream, size, sha256)

    def get_blob(self, sha256: str, size: int) -> bytes:
        """Return at most 64 MiB, checking the expected length and SHA-256."""
        result = self._read_object(_blob(sha256, size), size)
        if result is None:
            raise MissingBlob("blob is unavailable")
        _verify(result[0], sha256, size)
        return result[0]

    def read_object(self, key: str, limit: int) -> tuple[bytes, str] | None:
        """Read bounded metadata and an opaque comparison token; absent is None."""
        _limit(limit)
        return self._read_object(_key(key), limit)

    def create_object(self, key: str, data: bytes) -> bool:
        """Conditionally create immutable metadata; conflicting bytes fail."""
        _metadata_key(key)
        _data(data)
        return self._create(key, BytesIO(data), len(data), hashlib.sha256(data).hexdigest())

    def compare_and_swap(self, key: str, data: bytes, expected: str | None) -> str:
        """Advance metadata only from its observed token; None requires absence."""
        _metadata_key(key)
        _data(data)
        registry.require(expected is None or (isinstance(expected, str) and 0 < len(expected) <= 1024
                         and all(32 <= ord(char) <= 126 for char in expected)), "invalid comparison token")
        return self._write(key, BytesIO(data), len(data), hashlib.sha256(data).hexdigest(), expected, immutable=False)


class LocalBlobStore(_BlobOperations):
    """Private filesystem storage with descriptor-based, symlink-refusing access.

    A cooperative nonblocking flock serializes writers. Reads observe complete
    atomic files. The lock cannot defend against another same-user process
    ignoring it; filesystem ownership is part of this adapter's boundary.
    """

    def __init__(self, root: Path):
        self.root = _absolute(root)
        with _directory(self.root, create=True, private=True):
            pass

    @contextmanager
    def _location(self, key, *, create=False):
        parts = key.split("/")
        with _directory(self.root, private=True) as root:
            descriptor = os.dup(root)
            try:
                for part in parts[:-1]:
                    if create:
                        try:
                            os.mkdir(part, 0o700, dir_fd=descriptor)
                        except FileExistsError:
                            pass
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                    try:
                        info = os.fstat(child)
                        registry.require(info.st_uid == os.getuid() and not info.st_mode & 0o077,
                                         "local object directory must be private and owned")
                        registry.reject_extended_acl(child)
                    except BaseException:
                        os.close(child)
                        raise
                    os.close(descriptor)
                    descriptor = child
                yield descriptor, parts[-1]
            finally:
                os.close(descriptor)

    def _read_object(self, key, limit):
        try:
            with self._location(key) as (directory, name):
                descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                with os.fdopen(descriptor, "rb") as stream:
                    info = _regular(stream.fileno(), limit, private=True)
                    data = _read(stream, limit)
                    registry.require(len(data) == info.st_size, "local object changed during its read")
                    return data, hashlib.sha256(data).hexdigest()
        except FileNotFoundError:
            return None
        except OSError:
            raise registry.RegistryError("cannot safely read local object") from None

    @contextmanager
    def _lock(self):
        with _directory(self.root, private=True) as root:
            descriptor = os.open(".asm-storage.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 0o600, dir_fd=root)
            try:
                _regular(descriptor, 0, private=True)
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise StorageConflict("local storage is busy; reread and retry") from None
                yield
            finally:
                os.close(descriptor)

    def _write(self, key, stream, size, sha256, expected, *, immutable):
        try:
            with self._lock():
                current = self._read_object(key, registry.MAX_ARTIFACT_BYTES if key.startswith("blobs/") else MAX_OBJECT_BYTES)
                if (current is None) != (expected is None) or (current is not None and current[1] != expected):
                    raise StorageConflict("storage changed; reread before retrying")
                with self._location(key, create=True) as (directory, name):
                    temporary = ".pending-" + uuid.uuid4().hex
                    descriptor = None
                    try:
                        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                             0o600, dir_fd=directory)
                        with os.fdopen(descriptor, "wb") as output:
                            descriptor = None
                            _regular(output.fileno(), 0, private=True)
                            count = 0
                            while chunk := stream.read(CHUNK_BYTES):
                                count += len(chunk)
                                registry.require(count <= size, "object transfer exceeded expected bytes")
                                output.write(chunk)
                            registry.require(count == size, "object transfer ended before expected bytes")
                            output.flush()
                            os.fsync(output.fileno())
                        if expected is None:
                            try:
                                os.link(temporary, name, src_dir_fd=directory, dst_dir_fd=directory,
                                        follow_symlinks=False)
                            except FileExistsError:
                                raise StorageConflict("storage changed; reread before retrying") from None
                        else:
                            os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
                        if expected is None:
                            os.unlink(temporary, dir_fd=directory)
                        os.fsync(directory)
                    finally:
                        if descriptor is not None:
                            os.close(descriptor)
                        try:
                            os.unlink(temporary, dir_fd=directory)
                        except FileNotFoundError:
                            pass
            return sha256
        except OSError:
            raise registry.RegistryError("cannot safely write local object") from None


def _endpoint(value):
    if value is None:
        return
    registry.require(isinstance(value, str) and all(33 <= ord(char) <= 126 for char in value),
                     "invalid storage endpoint")
    try:
        parsed = urlsplit(value)
        loopback = parsed.hostname == "localhost"
        if parsed.hostname and not loopback:
            try:
                loopback = ipaddress.ip_address(parsed.hostname).is_loopback
            except ValueError:
                pass
        registry.require(parsed.hostname is not None and parsed.username is None and parsed.password is None
                         and parsed.path in ("", "/") and not parsed.query and not parsed.fragment
                         and (parsed.scheme == "https" or (parsed.scheme == "http" and loopback)),
                         "storage endpoint requires HTTPS; only loopback may use HTTP")
        parsed.port
    except ValueError:
        raise registry.RegistryError("invalid storage endpoint") from None


class S3BlobStore(_BlobOperations):
    """Single-request S3 transfers using an operator-selected boto3 provider.

    Pass a boto3 Session for an explicit credentials profile or workload role.
    Client injection accepts an already-configured SDK client. Do not pass an
    untrusted client. Credentials, provider errors and request URLs are not logged.
    ETags are comparison tokens only, never evidence of content integrity.
    """

    def __init__(self, bucket: str, *, prefix="", endpoint_url=None, region_name=None,
                 addressing_style="auto", session=None, client=None):
        registry.require(isinstance(bucket, str) and re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket)
                         is not None and ".." not in bucket, "invalid storage bucket")
        if prefix:
            _key(prefix)
        _endpoint(endpoint_url)
        registry.require(addressing_style in ("auto", "path", "virtual"), "invalid S3 addressing style")
        registry.require(region_name is None or (isinstance(region_name, str) and
                         re.fullmatch(r"[a-z0-9-]{1,63}", region_name) is not None), "invalid storage region")
        registry.require(not (session is not None and client is not None), "select either an SDK session or client")
        self.bucket, self.prefix = bucket, prefix + "/" if prefix else ""
        if client is None:
            try:
                import boto3
                from botocore.config import Config
            except ImportError:
                raise registry.RegistryError("S3 storage requires requirements-storage.txt") from None
            try:
                config = Config(signature_version="s3v4", connect_timeout=5, read_timeout=30,
                                retries={"mode": "standard", "total_max_attempts": 3},
                                s3={"addressing_style": addressing_style}, ignore_configured_endpoint_urls=True)
                client = (session or boto3.Session()).client("s3", endpoint_url=endpoint_url,
                          region_name=region_name, config=config, verify=True)
            except Exception:
                raise registry.RegistryError("cannot initialize S3 storage; check the operator configuration") from None
        self.client = client

    @staticmethod
    def _status(error):
        response = getattr(error, "response", {})
        return response.get("ResponseMetadata", {}).get("HTTPStatusCode"), response.get("Error", {}).get("Code")

    def _read_object(self, key, limit):
        body = None
        try:
            response = self.client.get_object(Bucket=self.bucket, Key=_key(self.prefix + key))
            body = response["Body"]
            registry.require(type(response.get("ContentLength")) is int
                             and 0 <= response["ContentLength"] <= limit, "stored object exceeds its byte limit")
            token = response.get("ETag")
            registry.require(isinstance(token, str) and 0 < len(token) <= 1024, "S3 response lacks a comparison token")
            data = _read(body, limit)
            registry.require(len(data) == response["ContentLength"], "stored object transfer is incomplete")
            return data, token
        except registry.RegistryError:
            raise
        except Exception as error:
            status, code = self._status(error)
            if status == 404 and code in ("NoSuchKey", "NotFound", "404"):
                return None
            raise registry.RegistryError("S3 object read failed; check storage availability and permissions") from None
        finally:
            if body is not None:
                body.close()

    def _write(self, key, stream, size, sha256, expected, *, immutable):
        try:
            condition = {"IfNoneMatch": "*"} if expected is None else {"IfMatch": expected}
            response = self.client.put_object(Bucket=self.bucket, Key=_key(self.prefix + key), Body=stream,
                       ContentLength=size, ChecksumSHA256=base64.b64encode(bytes.fromhex(sha256)).decode("ascii"),
                       ContentType="application/octet-stream", CacheControl="public,max-age=31536000,immutable"
                       if immutable else "no-store", **condition)
            token = response.get("ETag")
            registry.require(isinstance(token, str) and 0 < len(token) <= 1024, "S3 response lacks a comparison token")
            return token
        except registry.RegistryError:
            raise
        except Exception as error:
            if self._status(error)[0] == 412:
                raise StorageConflict("storage changed; reread before retrying") from None
            raise registry.RegistryError("S3 conditional write failed; check availability and provider support") from None
