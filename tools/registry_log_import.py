#!/usr/bin/env python3
"""Import private, delayed origin logs without claiming complete coverage.

Logs describe sender observations, not people or installations. No web ingestion
endpoint exists. Private-directory ownership protects the SQLite state; this is
not a defense against a compromised same-user process or administrator. SQLite
reopens paths, so every ancestor must also exclude untrusted rename authority.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack, contextmanager
from copy import deepcopy
import ctypes
import errno
import hashlib
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
from urllib.parse import quote

import download_data as clock
import registry
from registry_storage import _absolute, _directory, _regular

MAX_BATCH_BYTES = 8 * 1024 * 1024
MAX_BATCH_EVENTS = 100000
MAX_DB_BYTES = 64 * 1024 * 1024
MAX_EVENTS = 250000
MAX_BATCHES = 10000
FIELDS = {"time", "request_id", "method", "uri", "status", "bytes", "complete", "traffic"}
SCHEMA = {
    "batches": "CREATE TABLE batches (source TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL, PRIMARY KEY(source,id)) STRICT",
    "artifacts": "CREATE TABLE artifacts (route TEXT PRIMARY KEY, bytes INTEGER NOT NULL) STRICT",
    "events": "CREATE TABLE events (source TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL, stamp INTEGER NOT NULL, route TEXT NOT NULL REFERENCES artifacts(route), method TEXT NOT NULL, status INTEGER NOT NULL, bytes INTEGER NOT NULL, complete INTEGER NOT NULL, traffic TEXT NOT NULL, PRIMARY KEY(source,id)) STRICT",
    "events_window": "CREATE INDEX events_window ON events(stamp,route)",
}
COUNTED = "method='GET' AND status=200 AND complete=1 AND traffic='public' AND e.bytes=a.bytes"
V2_ROUTE = re.compile(r"/downloads/v2/(?:[0-9a-f]{32}/){3}(?:x86_64-linux|aarch64-linux|riscv64-linux|aarch64-macos|x86_64-windows|aarch64-windows)/(?:source|executable)/[0-9a-f]{64}")
DARWIN_ACL_TYPE_EXTENDED = 0x100
DARWIN_ACL_EXTENDED_DENY = 2
DARWIN_ACL_ENTRY_LIMIT = 169


def _ledger_acl(descriptor):
    """Inspect opened objects; allow empty or deny-only Darwin ACLs.

    Constants and signatures follow the macOS SDK sys/acl.h and acl_get_entry(3),
    checked 7 November 2026. Darwin indexes have a 169-entry storage bound.
    Linux rejects extended access/default ACLs. Unsupported inspection fails.
    """
    if sys.platform == "darwin":
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        library.acl_get_fd_np.argtypes = (ctypes.c_int, ctypes.c_int)
        library.acl_get_fd_np.restype = ctypes.c_void_p
        library.acl_valid.argtypes = (ctypes.c_void_p,)
        library.acl_valid.restype = ctypes.c_int
        library.acl_get_entry.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p))
        library.acl_get_entry.restype = ctypes.c_int
        library.acl_get_tag_type.argtypes = (ctypes.c_void_p, ctypes.POINTER(ctypes.c_int))
        library.acl_get_tag_type.restype = ctypes.c_int
        library.acl_free.argtypes = (ctypes.c_void_p,)
        library.acl_free.restype = ctypes.c_int
        ctypes.set_errno(0)
        acl = library.acl_get_fd_np(descriptor, DARWIN_ACL_TYPE_EXTENDED)
        if acl is None:
            registry.require(ctypes.get_errno() == errno.ENOENT, "cannot inspect the origin ledger path ACL")
            return
        try:
            registry.require(library.acl_valid(acl) == 0, "origin ledger path ACL is invalid")
            for index in range(DARWIN_ACL_ENTRY_LIMIT + 1):
                entry, tag = ctypes.c_void_p(), ctypes.c_int()
                ctypes.set_errno(0)
                result = library.acl_get_entry(acl, index, ctypes.byref(entry))
                if result != 0:
                    registry.require(result == -1 and ctypes.get_errno() == errno.EINVAL,
                                     "cannot inspect the origin ledger path ACL entry")
                    return
                registry.require(index < DARWIN_ACL_ENTRY_LIMIT and
                                 library.acl_get_tag_type(entry, ctypes.byref(tag)) == 0 and
                                 tag.value == DARWIN_ACL_EXTENDED_DENY,
                                 "origin ledger path must have no ACL allow grants")
        finally:
            library.acl_free(acl)
    elif sys.platform == "linux":
        for attribute in ("system.posix_acl_access", "system.posix_acl_default"):
            try:
                os.getxattr(descriptor, attribute)
            except OSError as error:
                registry.require(error.errno == errno.ENODATA, "cannot inspect the origin ledger path ACL")
            else:
                raise registry.RegistryError("origin ledger path must have no extended POSIX ACL")
    else:
        raise registry.RegistryError("origin ledger requires the qualified Linux or macOS filesystem policy")


def _ledger_ancestor(descriptor):
    info = os.fstat(descriptor)
    registry.require(info.st_uid in (0, os.getuid()), "origin ledger ancestor must have a trusted owner")
    registry.require(not info.st_mode & 0o022 or (info.st_uid == 0 and info.st_mode & stat.S_ISVTX),
                     "origin ledger ancestor permits untrusted directory changes")
    _ledger_acl(descriptor)
    return info


@contextmanager
def _ledger_directory(path, *, create=False):
    """Exclude other-UID path replacement before SQLite's pathname-based open.

    A root-owned sticky ancestor is permitted only with a trusted child owner.
    Every child is checked before descent; the final directory stays private.
    The caller retains this descriptor until after the SQLite connection closes.
    """
    path = _absolute(path)
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = _ledger_ancestor(descriptor)
        for part in path.parts[1:]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            try:
                info = _ledger_ancestor(child)
            except BaseException:
                os.close(child)
                raise
            os.close(descriptor)
            descriptor = child
        registry.require(info.st_uid == os.getuid() and not info.st_mode & 0o077,
                         "origin ledger directory must be private and owned")
        yield descriptor
    finally:
        os.close(descriptor)


def _selection(record, artifact):
    return "/downloads/v1/" + "/".join((record["name"], record["version"], artifact["target"], artifact["kind"], artifact["sha256"]))


def _file(path, maximum):
    path = _absolute(path)
    try:
        with _ledger_directory(path.parent) as parent:
            descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(descriptor, "rb") as stream:
            info = _regular(stream.fileno(), maximum)
            registry.require(info.st_uid == os.getuid() and not info.st_mode & 0o022,
                             "operator input must be owned and protected from other writers")
            _ledger_acl(stream.fileno())
            data = stream.read(maximum + 1)
            registry.require(len(data) == info.st_size <= maximum, "operator input changed or exceeded its byte limit")
            return data
    except OSError:
        raise registry.RegistryError("cannot safely read the operator input file") from None


def _outside_public_store(path, store):
    """Compare held physical ancestry before creating any ledger directory."""
    if not hasattr(store, "root"):
        return
    import registry_distribution
    parent = _absolute(path).parent
    with _directory(store.root, private=True) as public:
        while True:
            try:
                with _directory(parent) as existing:
                    registry.require(not registry_distribution._contains_directory(public, existing),
                                     "origin ledger must remain outside public distribution storage")
                return
            except FileNotFoundError:
                registry.require(parent != parent.parent, "cannot inspect the ledger's existing ancestry")
                parent = parent.parent


class LogStore:
    def __init__(self, path: Path, records: list[dict], *, sources=("asm-origin",)):
        self.records = registry.check_records(deepcopy(records))
        self.registry_id = None
        self.unattributed = None
        self.pins = {}
        self._configure(path, sources)
        self.selections = {_selection(record, artifact): (record["name"], record["version"], artifact["bytes"])
                           for record in self.records for artifact in record["artifacts"]}
        registry.require(len(self.selections) <= registry.MAX_ROWS, "too many origin artifact selections")

    def _configure(self, path, sources):
        self.path = _absolute(path)
        registry.require(isinstance(sources, (list, tuple)) and 0 < len(sources) <= 32
                         and len(set(sources)) == len(sources), "configure one to thirty-two distinct log sources")
        self.sources = tuple(sorted(clock._opaque(source) for source in sources))

    @classmethod
    def from_distribution(cls, path, store, registry_id, *, sources=("asm-origin",)):
        """Bind operator-selected immutable metadata, without verifying TUF.

        Reserved non-countable artifact rows pin the registry and exact release
        envelopes while preserving the ledger schema. No blob or archive reads.
        """
        import publication_check
        import registry_distribution
        registry.require(isinstance(registry_id, str) and re.fullmatch(r"[0-9a-f]{32}", registry_id), "use a complete registry identity")
        _outside_public_store(path, store)
        current = registry_distribution.load_current(store)
        registry.require(current is not None and current[0]["registry_id"] == registry_id,
                         "the selected distribution has a different or absent registry identity")
        plan = current[1]
        blobs = {item["sha256"]: item["bytes"] for item in plan["blobs"]}
        result = cls.__new__(cls)
        result._configure(path, sources)
        result.registry_id, result.records = registry_id, None
        result.packages, result.releases, result.selections = {}, {}, {}
        result.unattributed = "/unattributed/v2/" + registry_id
        result.pins = {"/identity/v2/" + registry_id: 0, result.unattributed: -1}
        names, versions = {}, set()
        for item in plan["files"]:
            if not item["key"].startswith("targets/registries/" + registry_id + "/releases/"):
                continue
            registry.require(item["bytes"] <= 131072, "release envelope exceeds its byte bound")
            raw = registry_distribution._read_bound(store, item["key"], item)
            envelope = registry.strict_json(raw)
            fields = {"schema", "registry_id", "package_id", "release_id", "manifest_sha256", "publication"}
            registry.exact_keys(envelope, fields, fields, "observation release envelope")
            registry.require(type(envelope["schema"]) is int and envelope["schema"] == 2
                and envelope["registry_id"] == registry_id and registry.json_bytes(envelope) == raw,
                "observation release envelope is not canonical or has a different registry")
            package, release = envelope["package_id"], envelope["release_id"]
            registry.require(all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value) for value in (package, release)),
                             "observation release identities are invalid")
            manifest = registry.json_bytes(envelope["publication"])
            publication, objects = publication_check.manifest(manifest)
            name, version = publication["name"], publication["version"]
            registry.require(envelope["manifest_sha256"] == hashlib.sha256(manifest).hexdigest()
                and item["key"] == f"targets/registries/{registry_id}/releases/{name}/{item['sha256']}.{version}.json"
                and all(blobs.get(digest) == size for digest, size in objects.items()), "observation release binding differs")
            registry.require(release not in result.releases and (package, version) not in versions
                and result.packages.get(package, name) == name and names.get(name, package) == package,
                "observation package or release identity was rebound")
            result.packages[package] = name; names[name] = package; versions.add((package, version))
            result.releases[release] = {"package_id": package, "name": name, "version": version}
            result.pins[f"/binding/v2/{registry_id}/{package}/{release}/{item['sha256']}"] = item["bytes"]
            for artifact in publication["artifacts"]:
                target = publication_check.TARGETS[(artifact["isa"], artifact["os"], artifact["abi"])][0]
                route = "/downloads/v2/" + "/".join((registry_id, package, release, target, artifact["kind"], artifact["sha256"]))
                registry.require(route not in result.selections, "observation artifact selection is duplicated")
                result.selections[route] = (package, release, artifact["bytes"])
        registry.require(len(result.releases) <= 4095 and len(result.selections) <= 4095 * 14,
                         "too many V2 observation selections")
        return result

    def _event(self, value, start, end):
        registry.exact_keys(value, FIELDS, FIELDS, "origin log event")
        stamp, identifier = clock._time(value["time"]), clock._opaque(value["request_id"])
        registry.require(start <= stamp <= end, "origin event is outside its declared batch interval")
        route = value["uri"]
        registry.require(isinstance(route, str), "origin event selection must be text")
        original = route
        if route not in self.selections:
            registry.require(self.registry_id is not None and V2_ROUTE.fullmatch(route), "origin event has an unknown exact artifact selection")
            route = self.unattributed
        registry.require(isinstance(value["method"], str) and re.fullmatch(r"[A-Z]{1,16}", value["method"]) is not None,
                         "invalid origin method")
        registry.require(type(value["status"]) is int and 100 <= value["status"] <= 599, "invalid origin status")
        registry.require(type(value["bytes"]) is int and 0 <= value["bytes"] <= registry.MAX_ARTIFACT_BYTES,
                         "invalid origin body byte count")
        registry.require(value["complete"] in ("OK", "") and value["traffic"] in ("public", "bot", "internal"),
                         "invalid origin completion or traffic class")
        fields = (stamp, original, value["method"], value["status"], value["bytes"], value["complete"] == "OK", value["traffic"])
        return (identifier, hashlib.sha256(registry.json_bytes(fields)).hexdigest(), stamp, route,
                value["method"], value["status"], value["bytes"], int(value["complete"] == "OK"), value["traffic"])

    @contextmanager
    def _database(self, *, create=False):
        connection = None
        opened = ExitStack()
        try:
            parent = opened.enter_context(_ledger_directory(self.path.parent, create=create))
            existed = False
            for suffix in ("", "-journal", "-wal", "-shm"):
                try:
                    descriptor = os.open(self.path.name + suffix, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                except FileNotFoundError:
                    continue
                try:
                    _regular(descriptor, MAX_DB_BYTES, private=True)
                    _ledger_acl(descriptor)
                finally:
                    os.close(descriptor)
                if not suffix:
                    existed = True
                else:
                    registry.require(existed, "origin ledger has orphaned sidecar files")
            if not existed:
                if not create:
                    raise FileNotFoundError
                descriptor = os.open(self.path.name, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=parent)
                try:
                    _regular(descriptor, MAX_DB_BYTES, private=True)
                    _ledger_acl(descriptor)
                finally:
                    os.close(descriptor)
            connection = sqlite3.connect("file:" + quote(str(self.path), safe="/") + "?mode=rw", uri=True, timeout=3)
            connection.execute("PRAGMA trusted_schema=OFF")
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA temp_store=MEMORY")
            connection.execute("PRAGMA cache_size=-4096")
            if not existed:
                with connection:
                    connection.execute("BEGIN IMMEDIATE")
                    for statement in SCHEMA.values():
                        connection.execute(statement)
                    connection.execute("PRAGMA application_id=1095978311")
                    connection.execute("PRAGMA user_version=1")
            connection.execute("BEGIN IMMEDIATE" if create else "BEGIN")
            registry.require(connection.execute("PRAGMA application_id").fetchone()[0] == 1095978311
                             and connection.execute("PRAGMA user_version").fetchone()[0] == 1,
                             "unsupported origin ledger")
            registry.require(dict(connection.execute("SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL")) == SCHEMA,
                             "origin ledger schema differs")
            registry.require(connection.execute("PRAGMA quick_check").fetchmany(2) == [("ok",)], "origin ledger is corrupt")
            registry.require(not connection.execute("PRAGMA foreign_key_check").fetchmany(1), "origin ledger has invalid artifact references")
            expected = {route: selection[2] for route, selection in self.selections.items()} | self.pins
            retained = set()
            for route, size in connection.execute("SELECT route,bytes FROM artifacts"):
                registry.require(expected.get(route) == size,
                                 "origin ledger artifact identity differs from accepted records")
                retained.add(route)
            if self.registry_id is not None and "/identity/v2/" + self.registry_id not in retained:
                registry.require(not retained and connection.execute("SELECT 1 FROM batches LIMIT 1").fetchone() is None,
                                 "a V1 reporting history cannot become a V2 ledger")
            if create:
                page_size = connection.execute("PRAGMA page_size").fetchone()[0]
                connection.execute("PRAGMA max_page_count=" + str(MAX_DB_BYTES // page_size))
                connection.executemany("INSERT INTO artifacts VALUES (?,?) ON CONFLICT DO NOTHING",
                                       expected.items())
            yield connection
            registry.require(connection.execute("SELECT count(*) FROM events").fetchone()[0] <= MAX_EVENTS
                             and connection.execute("SELECT count(*) FROM batches").fetchone()[0] <= MAX_BATCHES,
                             "origin ledger reached its retention bound; archive it before further imports")
            connection.commit()
        except FileNotFoundError:
            raise
        except registry.RegistryError:
            raise
        except (OSError, sqlite3.Error):
            raise registry.RegistryError("origin ledger operation failed; preserve the file and inspect storage") from None
        finally:
            try:
                if connection is not None:
                    connection.close()
            finally:
                opened.close()

    def import_batch(self, source: str, batch_id: str, start: str, end: str, log_path: Path) -> bool:
        registry.require(source in self.sources, "origin log source is not configured")
        clock._opaque(batch_id)
        left, right = clock._time(start), clock._time(end)
        registry.require(left < right, "origin batch interval must advance")
        raw = _file(log_path, MAX_BATCH_BYTES)
        registry.require(raw.count(b"\n") <= MAX_BATCH_EVENTS, "origin batch has too many events")
        lines = raw.split(b"\n")
        if lines[-1] == b"":
            lines.pop()
        registry.require(len(lines) <= MAX_BATCH_EVENTS, "origin batch has too many events")
        events = []
        for line in lines:
            registry.require(0 < len(line) <= 4096, "origin log line is empty or exceeds four KiB")
            events.append(self._event(registry.strict_json(line), left, right))
        digest = hashlib.sha256(registry.json_bytes((left, right)) + raw).hexdigest()
        with self._database(create=True) as connection:
            old = connection.execute("SELECT digest FROM batches WHERE source=? AND id=?", (source, batch_id)).fetchone()
            if old is not None:
                registry.require(old == (digest,), "origin batch identity conflicts with retained content")
                return False
            for event in events:
                old = connection.execute("SELECT fingerprint FROM events WHERE source=? AND id=?", (source, event[0])).fetchone()
                registry.require(old is None or old == (event[1],), "origin request identity conflicts with retained content")
                if old is None:
                    connection.execute("INSERT INTO events VALUES (?,?,?,?,?,?,?,?,?,?)", (source, *event))
            connection.execute("INSERT INTO batches VALUES (?,?,?,?,?)", (source, batch_id, digest, left, right))
        return True

    def snapshot(self, *, at=None) -> dict:
        now = clock._time(at)
        v2 = self.registry_id is not None
        names = sorted(self.packages) if v2 else sorted({record["name"] for record in self.records})
        versions = sorted(self.releases) if v2 else sorted({record["name"] + "@" + record["version"] for record in self.records})
        initial = None if v2 else 0
        version_counts, retained_versions = ("release_counts", "retained_release_counts") if v2 else ("version_counts", "retained_version_counts")
        result = {"observed_at": clock._stamp(now), "collection_started_at": None, "coverage_start": None,
                  "coverage_end": None, "complete": False, "stale": True, "counts": dict.fromkeys(names, initial),
                  version_counts: dict.fromkeys(versions, initial), "daily_counts": [], "coverage_intervals": [],
                  "retained_counts": dict.fromkeys(names, initial), retained_versions: dict.fromkeys(versions, initial),
                  "retained_coverage_start": None, "retained_complete": False,
                  "sources": list(self.sources), "reporting": "origin-log-lower-bounds-v2" if v2 else "origin-log-lower-bounds-v1"}
        if v2:
            result.update(schema=2, registry_id=self.registry_id, packages=self.packages, releases=self.releases,
                          unattributed_requests=None, retained_unattributed_requests=None)
        placeholders = ",".join("?" for source in self.sources)
        try:
            with self._database() as connection:
                first, end = connection.execute("SELECT min(start),max(end) FROM batches WHERE source IN (" + placeholders + ")",
                                                self.sources).fetchone()
                if end is None:
                    return result
                registry.require(end <= now, "origin snapshot clock precedes its reporting cutoff")
                result.update(collection_started_at=clock._stamp(first), coverage_end=clock._stamp(end),
                              retained_coverage_start=clock._stamp(first), stale=now - end > clock.DAY)
                if v2:
                    for key, identities in (("counts", names), (version_counts, versions), ("retained_counts", names), (retained_versions, versions)):
                        result[key] = dict.fromkeys(identities, 0)
                    retained, window = connection.execute("SELECT count(*),coalesce(sum(stamp>?),0) FROM events WHERE source IN (" +
                        placeholders + ") AND route=? AND stamp<=?", (end - clock.WINDOW, *self.sources, self.unattributed, end)).fetchone()
                    result.update(unattributed_requests=window, retained_unattributed_requests=retained)
                query = "SELECT e.stamp,e.route FROM events e JOIN artifacts a USING(route) WHERE " + COUNTED
                if v2:
                    query += " AND e.route GLOB '/downloads/v2/*'"
                query += " AND source IN (" + placeholders + ") AND stamp<=? ORDER BY stamp,route"
                daily = {}
                for stamp, route in connection.execute(query, (*self.sources, end)):
                    name, version, _ = self.selections[route]
                    result["retained_counts"][name] += 1
                    selected = version if v2 else name + "@" + version
                    result[retained_versions][selected] += 1
                    if stamp > end - clock.WINDOW:
                        result["counts"][name] += 1
                        result[version_counts][selected] += 1
                        key = (clock._stamp(stamp)[:10], name, version)
                        daily[key] = daily.get(key, 0) + 1
                result["daily_counts"] = [{"date": day, "package_id" if v2 else "name": name,
                                           "release_id" if v2 else "version": version, "count": count}
                                          for (day, name, version), count in sorted(daily.items())]
        except FileNotFoundError:
            pass
        return result


def nginx_locations(records: list[dict], blob_root: str) -> str:
    """Generate exact selection aliases, excluding new yanked selections."""
    registry.require(isinstance(blob_root, str) and re.fullmatch(r"/[A-Za-z0-9_./-]+", blob_root) is not None
                     and ".." not in blob_root.split("/"), "nginx blob root must be a plain absolute path")
    lines = ["# Generated from accepted records. Reload atomically after nginx -t.\n"]
    for record in registry.check_records(records):
        if record["yanked"]:
            continue
        for artifact in record["artifacts"]:
            lines.append("location = " + _selection(record, artifact) + " {\n"
                         "    alias " + blob_root.rstrip("/") + "/" + artifact["sha256"] + ";\n"
                         "    access_log /var/log/asm/downloads.jsonl asm_delivery;\n"
                         "    default_type application/octet-stream;\n"
                         "    add_header Content-Disposition attachment always;\n"
                         "    add_header X-Content-Type-Options nosniff always;\n"
                         "    add_header Cache-Control 'public,max-age=300' always;\n"
                         "}\n")
    return "".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--registry", type=Path, help="explicit directory of accepted registry records")
    inputs.add_argument("--snapshot-file", type=Path, help="exact private mirrored manifest; at most one MiB")
    inputs.add_argument("--distribution-root", type=Path, help="existing local V2 mirror; metadata reads only")
    parser.add_argument("--registry-id", help="explicit immutable V2 registry identity")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("import", "snapshot"):
        command = commands.add_parser(name)
        command.add_argument("--state", type=Path, required=True)
        command.add_argument("--source", action="append", required=True)
        if name == "import":
            command.add_argument("--batch", required=True)
            command.add_argument("--start", required=True)
            command.add_argument("--end", required=True)
            command.add_argument("--log", type=Path, required=True)
    command = commands.add_parser("nginx")
    command.add_argument("--blob-root", required=True)
    args = parser.parse_args(argv)
    try:
        store = None
        if args.distribution_root is not None:
            from registry_storage import LocalBlobStore
            registry.require(args.command != "nginx", "use the V2 static nginx reference instead of V1 generated aliases")
            registry.require(args.distribution_root.is_dir(), "select an existing local V2 mirror")
            store = LogStore.from_distribution(args.state, LocalBlobStore(args.distribution_root), args.registry_id, sources=args.source)
        elif args.snapshot_file is not None:
            registry.require(args.registry_id is None, "registry identity requires a V2 distribution input")
            import registry_mirror
            raw = _file(args.snapshot_file, registry_mirror.LIMIT)
            if (args.snapshot_file.name == "manifest.json" and
                    registry.HEX64.fullmatch(args.snapshot_file.parent.name) is not None):
                registry.require(hashlib.sha256(raw).hexdigest() == args.snapshot_file.parent.name,
                                 "snapshot bytes differ from the selected digest directory")
            records = registry_mirror.parse_snapshot(raw)["records"]
        else:
            registry.require(args.registry_id is None, "registry identity requires a V2 distribution input")
            records = registry.read_records(args.registry or Path("registry"))
        if args.command == "nginx":
            sys.stdout.write(nginx_locations(records, args.blob_root))
        else:
            if store is None:
                store = LogStore(args.state, records, sources=args.source)
            if args.command == "import":
                registry.require(len(args.source) == 1, "import selects exactly one source")
                store.import_batch(args.source[0], args.batch, args.start, args.end, args.log)
            else:
                sys.stdout.buffer.write(registry.json_bytes(store.snapshot()))
    except (registry.RegistryError, OSError) as error:
        print("asm registry logs: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
