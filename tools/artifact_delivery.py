"""Verified local artifact delivery and server-side transfer observations.

Storage reads are adapters. Package bytes are never executed or extracted.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import errno
import os
from pathlib import Path
import re
import stat
import threading
import time
from urllib.parse import urlsplit
import uuid

import registry


MAX_CACHE_BYTES = 512 * 1024 * 1024
MAX_TRANSFERS = 4
CHUNK_BYTES = 64 * 1024
TRANSFER_SECONDS = 30
FREE_RESERVE_BYTES = 16 * 1024 * 1024


def route(record: dict, artifact: dict) -> str:
    registry.validate_manifest(record)
    registry.require(artifact in record["artifacts"], "artifact is not part of this release")
    return "/downloads/v1/" + "/".join((record["name"], record["version"], artifact["target"],
                                        artifact["kind"], artifact["sha256"]))


def _legacy_reader(url, limit, hosts, *, expected_size):
    # A default import source is not the authority for delivery observations.
    import build_site
    return build_site.read_https(url, limit, hosts, expected_size=expected_size)


def _private_directory(path: Path) -> Path:
    path = Path(path).absolute()
    aliases = {Path("/var"): Path("/private/var"), Path("/tmp"): Path("/private/tmp")}
    for candidate in (path, *path.parents):
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        trusted_alias = candidate in aliases and info.st_uid == 0 and candidate.resolve() == aliases[candidate]
        registry.require(not stat.S_ISLNK(info.st_mode) or trusted_alias,
                         "artifact cache cannot use caller-controlled symlinks")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    registry.require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                     and not stat.S_IMODE(info.st_mode) & 0o077, "artifact cache must be private and owned")
    return path.resolve()


def _open_directory(path: Path) -> int:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        registry.require(info.st_uid == os.getuid() and not stat.S_IMODE(info.st_mode) & 0o077,
                         "artifact cache must be private and owned")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


class ArtifactDelivery:
    """Serve accepted immutable selections; record only server-observed sends.

    At most four transfers and two new imports run concurrently. Cache bytes
    have a fixed quota. Host and Origin validation belongs to the caller.
    Session providers may return None while the independent ledger recovers.
    """

    def __init__(self, records, cache_dir: Path, store, session_id, reader=None):
        self.records = registry.check_records(deepcopy(records))
        self._selections = {route(record, artifact): (record, artifact)
                            for record in self.records for artifact in record["artifacts"]}
        self.cache_dir = _private_directory(cache_dir)
        self._objects = _private_directory(self.cache_dir / "sha256")
        self.store, self.session_id = store, session_id
        self.reader = reader if reader is not None else _legacy_reader
        self._transfers = threading.BoundedSemaphore(MAX_TRANSFERS)
        self._imports = threading.BoundedSemaphore(2)
        self._validation = threading.Lock()
        self._cache_lock = threading.Lock()
        self._reserved = 0
        self._digests = {artifact["sha256"]: threading.Lock()
                         for record in self.records for artifact in record["artifacts"]}

    @staticmethod
    def _file(info, *, maximum):
        registry.require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                         and not stat.S_IMODE(info.st_mode) & 0o077 and info.st_size <= maximum,
                         "invalid artifact cache file")

    def _cached(self, directory, record, artifact):
        descriptor = os.open(artifact["sha256"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            self._file(os.fstat(descriptor), maximum=artifact["bytes"])
            with os.fdopen(descriptor, "rb") as stream:
                descriptor = None
                data = stream.read(artifact["bytes"] + 1)
            with self._validation:
                registry.validate_artifact(data, record, artifact)
            return data
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def _usage(self, directory):
        names = os.listdir(directory)
        registry.require(len(names) <= registry.MAX_ROWS * registry.MAX_RELEASE_ARTIFACTS + MAX_TRANSFERS,
                         "too many artifact cache files")
        total = 0
        for name in names:
            registry.require(re.fullmatch(r"[a-f0-9]{64}|\.pending-[a-f0-9]{32}", name),
                             "unrecognized artifact cache file")
            info = os.stat(name, dir_fd=directory, follow_symlinks=False)
            self._file(info, maximum=registry.MAX_ARTIFACT_BYTES)
            total += info.st_size
        return total

    def _promote(self, directory, artifact, data):
        temporary = ".pending-" + uuid.uuid4().hex
        descriptor = None
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory)
            offset = 0
            while offset < len(data):
                amount = os.write(descriptor, memoryview(data)[offset:offset + CHUNK_BYTES])
                registry.require(amount > 0, "artifact cache write stopped")
                offset += amount
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = None
            # Conditional creation keeps an existing digest key unchanged.
            os.link(temporary, artifact["sha256"], src_dir_fd=directory, dst_dir_fd=directory,
                    follow_symlinks=False)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
        try:
            os.fsync(directory)
        except OSError as error:
            if error.errno not in (errno.EINVAL, errno.ENOTSUP):
                raise

    def _bytes(self, record, artifact):
        lock = self._digests[artifact["sha256"]]
        registry.require(lock.acquire(blocking=False), "artifact import is already in progress")
        directory = None
        reserved = False
        importing = False
        try:
            directory = _open_directory(self._objects)
            try:
                return self._cached(directory, record, artifact)
            except FileNotFoundError:
                pass
            registry.require(self._imports.acquire(blocking=False), "artifact imports are busy")
            importing = True
            with self._cache_lock:
                registry.require(self._usage(directory) + self._reserved + artifact["bytes"] <= MAX_CACHE_BYTES,
                                 "artifact cache exceeds its byte quota")
                available = os.fstatvfs(directory)
                registry.require(available.f_bavail * available.f_frsize >= artifact["bytes"] + self._reserved + FREE_RESERVE_BYTES,
                                 "artifact cache has insufficient free space")
                self._reserved += artifact["bytes"]
                reserved = True
            data = self.reader(artifact["url"], artifact["bytes"],
                               {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"},
                               expected_size=artifact["bytes"])
            registry.require(type(data) is bytes and len(data) == artifact["bytes"], "artifact read has the wrong size")
            with self._validation:
                registry.validate_artifact(data, record, artifact)
            with self._cache_lock:
                try:
                    self._promote(directory, artifact, data)
                except FileExistsError:
                    return self._cached(directory, record, artifact)
            return data
        finally:
            if reserved:
                with self._cache_lock:
                    self._reserved -= artifact["bytes"]
            if directory is not None:
                os.close(directory)
            if importing:
                self._imports.release()
            lock.release()

    @staticmethod
    def _traffic(handler):
        agent = handler.headers.get("User-Agent", "")[:2048]
        if agent.startswith("AsmValidation/"):
            return "internal"
        if any(marker in agent.lower() for marker in ("bot", "spider", "crawler", "slurp", "headless")):
            return "bot"
        return "public"

    def _record(self, record, artifact, event_type, traffic, amount):
        try:
            session = self.session_id() if callable(self.session_id) else self.session_id
        except Exception:
            return
        if not isinstance(session, str) or not session:
            return
        event = {"schema": 1, "event_id": uuid.uuid4().hex,
                 "occurred_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                 "name": record["name"], "version": record["version"], "target": artifact["target"],
                 "kind": artifact["kind"], "sha256": artifact["sha256"], "bytes": amount,
                 "event_type": event_type, "traffic": traffic}
        try:
            self.store.record(session, event)
        except Exception:
            # Recording cannot turn a completed file response into an error.
            try:
                self.store.interrupt(session)
            except Exception:
                pass

    @staticmethod
    def _error(handler, status, message, *, head=False, size=None):
        data = (message + "\n").encode("utf-8")
        try:
            handler.send_response(status)
            handler.send_header("Content-Type", "text/plain; charset=utf-8")
            handler.send_header("Content-Length", str(len(data)))
            handler.send_header("Cache-Control", "no-store")
            handler.send_header("X-Content-Type-Options", "nosniff")
            if status == 503:
                handler.send_header("Retry-After", "1")
            if status == 416:
                handler.send_header("Content-Range", f"bytes */{size}")
            handler.end_headers()
            if not head:
                handler.wfile.write(data)
                handler.wfile.flush()
        except OSError:
            handler.close_connection = True

    @staticmethod
    def _range(handler, size, etag):
        value = handler.headers.get("Range")
        if value is None or not value.lower().startswith("bytes="):
            return None
        if_range = handler.headers.get("If-Range")
        if if_range is not None and if_range != etag:
            return None
        match = re.fullmatch(r"bytes=([0-9]{0,20})-([0-9]{0,20})", value.strip(), re.I) if len(value) <= 128 else None
        registry.require(match is not None and (match[1] or match[2]), "request one valid byte range")
        if not match[1]:
            suffix = int(match[2])
            registry.require(suffix > 0, "empty suffix range")
            return max(0, size - suffix), size - 1
        start = int(match[1])
        end = int(match[2]) if match[2] else size - 1
        registry.require(start < size and end >= start, "unsatisfiable byte range")
        return start, min(end, size - 1)

    def handle(self, handler, path: str, head=False) -> bool:
        if not isinstance(path, str) or not path.startswith("/downloads/"):
            return False
        original = handler.path
        if ("?" in original or "#" in original or urlsplit(original).path != path
                or len(handler.headers.get_all("Range", [])) > 1):
            self._error(handler, 400, "Use one canonical artifact route and at most one Range field.", head=head)
            return True
        selected = self._selections.get(path)
        if selected is None:
            self._error(handler, 404, "This artifact selection is unavailable.", head=head)
            return True
        record, artifact = selected
        traffic = self._traffic(handler)
        if record["yanked"]:
            self._error(handler, 410, "This release is yanked. Inspect its version record.", head=head)
            return True
        if not self._transfers.acquire(blocking=False):
            self._error(handler, 503, "Artifact delivery is busy. Retry shortly.", head=head)
            return True
        try:
            try:
                data = self._bytes(record, artifact)
            except Exception:
                if not head:
                    self._record(record, artifact, "failed", traffic, 0)
                self._error(handler, 503, "Artifact verification or storage is unavailable. Retry or inspect the release record.", head=head)
                return True
            size = len(data)
            etag = '"sha256:' + artifact["sha256"] + '"'
            validators = [item.strip() for item in handler.headers.get("If-None-Match", "").split(",")]
            status = 304 if any(item in ("*", etag, "W/" + etag) for item in validators) else 200
            selected_range = None
            if status != 304 and not head:
                try:
                    selected_range = self._range(handler, size, etag)
                except registry.RegistryError:
                    self._record(record, artifact, "failed", traffic, 0)
                    self._error(handler, 416, "Request one satisfiable byte range.", size=size)
                    return True
            if selected_range is not None:
                status = 206
            start, end = selected_range if selected_range is not None else (0, size - 1)
            sent = 0
            try:
                handler.send_response(status)
                handler.send_header("Content-Type", "application/octet-stream")
                handler.send_header("Content-Disposition", 'attachment; filename="' + urlsplit(artifact["url"]).path.rsplit("/", 1)[1] + '"')
                handler.send_header("Content-Length", str(end - start + 1))
                handler.send_header("X-Content-Type-Options", "nosniff")
                handler.send_header("Accept-Ranges", "bytes")
                handler.send_header("ETag", etag)
                handler.send_header("Cache-Control", "public, max-age=31536000, immutable")
                if selected_range is not None:
                    handler.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                handler.end_headers()
                if head or status == 304:
                    return True
                deadline = time.monotonic() + TRANSFER_SECONDS
                while sent < end - start + 1:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("artifact response deadline expired")
                    handler.connection.settimeout(min(5, remaining))
                    chunk = memoryview(data)[start + sent:min(start + sent + CHUNK_BYTES, end + 1)]
                    amount = handler.wfile.write(chunk)
                    if not isinstance(amount, int) or not 0 < amount <= len(chunk):
                        raise OSError("artifact response write stopped")
                    sent += amount
                handler.wfile.flush()
            except OSError:
                handler.close_connection = True
                if not head:
                    self._record(record, artifact, "failed", traffic, sent)
            else:
                self._record(record, artifact, "range" if status == 206 else "completed", traffic, sent)
            return True
        finally:
            self._transfers.release()
