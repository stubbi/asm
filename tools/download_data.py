"""Bound first-party delivery events to canonical artifact selections.

This private local ledger has no network dependency or public ingestion API.
Events describe server responses, never people or client installations.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import re
import sqlite3
import stat
import threading
from urllib.parse import quote
import uuid

import registry

MAX_DB_BYTES = 64 * 1024 * 1024
MAX_EVENTS = 250000
MAX_INTERVALS = 50000
MAX_SESSIONS = 10000
MAX_COUNT = 2 ** 53 - 1
MAX_GAP = 60 * 1000000
DAY = 86400 * 1000000
WINDOW = 30 * DAY
APPLICATION_ID = 0x41534D4C
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
OPAQUE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
FIELDS = {"schema", "event_id", "occurred_at", "name", "version", "target", "kind", "sha256", "bytes", "event_type", "traffic"}
TABLES = {
    "metadata": "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT",
    "artifacts": "CREATE TABLE artifacts (name TEXT NOT NULL, version TEXT NOT NULL, target TEXT NOT NULL, kind TEXT NOT NULL, sha256 TEXT NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY(name,version,target,kind)) STRICT",
    "sessions": "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, started_at INTEGER NOT NULL, heartbeat INTEGER NOT NULL, finished_at INTEGER, interrupted INTEGER NOT NULL CHECK(interrupted IN (0,1)), segment INTEGER NOT NULL) STRICT",
    "intervals": "CREATE TABLE intervals (session_id TEXT NOT NULL REFERENCES sessions(session_id), segment INTEGER NOT NULL, start_at INTEGER NOT NULL, end_at INTEGER NOT NULL, PRIMARY KEY(session_id,segment)) STRICT",
    "events": "CREATE TABLE events (event_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(session_id), occurred_at INTEGER NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL, target TEXT NOT NULL, kind TEXT NOT NULL, sha256 TEXT NOT NULL, bytes INTEGER NOT NULL, event_type TEXT NOT NULL, traffic TEXT NOT NULL, FOREIGN KEY(name,version,target,kind) REFERENCES artifacts(name,version,target,kind)) STRICT",
    "events_window": "CREATE INDEX events_window ON events(occurred_at,name,version)",
}


def _time(value=None) -> int:
    actual = datetime.now(timezone.utc)
    if value is None:
        value = actual
    else:
        registry.require(isinstance(value, str) and len(value) <= 35 and
                         re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|\+00:00)", value) is not None,
                         "download time must be a UTC timestamp")
        try:
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as error:
            raise registry.RegistryError("invalid download timestamp") from error
    registry.require(EPOCH <= value <= actual, "download timestamp is invalid or in the future")
    difference = value - EPOCH
    return (difference.days * 86400 + difference.seconds) * 1000000 + difference.microseconds


def _stamp(value: int | None):
    return (EPOCH + timedelta(microseconds=value)).isoformat().replace("+00:00", "Z") if value is not None else None


def _opaque(value: object) -> str:
    registry.require(isinstance(value, str) and OPAQUE.fullmatch(value) is not None, "invalid download event or session identity")
    return value


class Store:
    """Lazy, thread-safe local storage. Corruption never triggers replacement.

    Healthy intervals extend only through heartbeats at most sixty seconds
    apart. Interruptions and restarts create new segments. Counts cover
    (latest heartbeat minus thirty days, latest heartbeat], not unobserved time.
    """

    def __init__(self, path: Path, records: list[dict], source="asm-local"):
        self.path = Path(path).absolute()
        registry.require(self.path.name not in ("", ".", ".."), "invalid download state path")
        registry.require(isinstance(source, str) and re.fullmatch(r"[a-z][a-z0-9._-]{0,63}", source) is not None,
                         "invalid download source")
        self.source = source
        self.records = registry.check_records(records)
        self.artifacts = {(record["name"], record["version"], item["target"], item["kind"]): (item["sha256"], item["bytes"])
                          for record in self.records for item in record["artifacts"]}
        registry.require(len(self.artifacts) <= registry.MAX_ROWS, "too many download artifact identities")
        self.names = sorted({record["name"] for record in self.records})
        self.versions = sorted({record["name"] + "@" + record["version"] for record in self.records})
        self._lock = threading.RLock()

    def _safe_path(self, create=False):
        path = self.path
        # Permit fixed OS aliases (for example macOS /var), but do not create
        # directories through an operator-controlled symlink at any depth.
        for parent in path.parents:
            try: info = parent.lstat()
            except FileNotFoundError: continue
            aliases = {Path("/var"): Path("/private/var"), Path("/tmp"): Path("/private/tmp")}
            trusted_alias = parent in aliases and info.st_uid == 0 and parent.resolve() == aliases[parent]
            registry.require(not stat.S_ISLNK(info.st_mode) or trusted_alias,
                             "download state ancestors cannot be user symlinks")
        if create: path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if path.parent.exists(): path = path.parent.resolve() / path.name
        for candidate in [path] + [path.with_name(path.name + suffix) for suffix in ("-journal", "-wal", "-shm")]:
            try: info = candidate.lstat()
            except FileNotFoundError: continue
            registry.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid()
                             and info.st_mode & 0o077 == 0 and info.st_size <= MAX_DB_BYTES,
                             "download state must use private owned regular files")
        return path

    def _connect(self, write=False, create=False):
        path = self._safe_path(create)
        existed = path.exists()
        if not existed:
            registry.require(create, "download data is not initialized")
            registry.require(not any(path.with_name(path.name + suffix).exists() for suffix in ("-journal", "-wal", "-shm")),
                             "download state has orphaned sidecars")
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            os.close(descriptor)
        connection = sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=" + ("rw" if write else "ro"), uri=True, timeout=3)
        try:
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA trusted_schema=OFF")
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA temp_store=MEMORY")
            connection.execute("PRAGMA cache_size=-4096")
            connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, 4096)
            if not existed:
                with connection:
                    connection.execute("BEGIN IMMEDIATE")
                    for statement in TABLES.values(): connection.execute(statement)
                    connection.execute("PRAGMA application_id=" + str(APPLICATION_ID))
                    connection.execute("PRAGMA user_version=1")
                    connection.execute("INSERT INTO metadata VALUES ('source', ?)", (self.source,))
            return connection
        except BaseException:
            connection.close()
            raise

    def _validate(self, connection):
        registry.require(connection.execute("PRAGMA application_id").fetchone()[0] == APPLICATION_ID
                         and connection.execute("PRAGMA user_version").fetchone()[0] == 1,
                         "unsupported download ledger")
        registry.require(dict(connection.execute("SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL")) == TABLES,
                         "invalid download ledger schema")
        registry.require([tuple(row) for row in connection.execute("PRAGMA quick_check").fetchmany(2)] == [("ok",)], "corrupt download ledger")
        metadata = dict(connection.execute("SELECT key,value FROM metadata"))
        registry.require(metadata.get("source") == self.source and set(metadata) <= {"source", "collection_started_at"},
                         "download source identity changed")
        for table, bound in (("artifacts", registry.MAX_ROWS), ("sessions", MAX_SESSIONS), ("intervals", MAX_INTERVALS), ("events", MAX_EVENTS)):
            registry.require(connection.execute("SELECT count(*) FROM " + table).fetchone()[0] <= bound, "download ledger exceeds its bound")
        now = _time()
        for row in connection.execute("SELECT * FROM artifacts"):
            registry.package_name(row["name"]); registry.version_tuple(row["version"])
            registry.require(row["target"] in registry.TARGETS and row["kind"] in registry.KINDS
                             and registry.HEX64.fullmatch(row["sha256"]) is not None
                             and 0 < row["bytes"] <= registry.MAX_ARTIFACT_BYTES, "invalid retained artifact identity")
            expected = self.artifacts.get((row["name"], row["version"], row["target"], row["kind"]))
            registry.require(expected is None or expected == (row["sha256"], row["bytes"]), "download artifact identity changed")
        for row in connection.execute("SELECT * FROM sessions"):
            _opaque(row["session_id"])
            registry.require(0 <= row["started_at"] <= row["heartbeat"] <= now and row["segment"] >= 0
                             and (row["finished_at"] is None or row["heartbeat"] <= row["finished_at"] <= now),
                             "invalid retained collection session")
        registry.require(connection.execute("SELECT count(*) FROM sessions WHERE finished_at IS NULL").fetchone()[0] <= 1,
                         "overlapping collection sessions")
        bad_interval = connection.execute("SELECT 1 FROM intervals i LEFT JOIN sessions s USING(session_id) WHERE s.session_id IS NULL OR i.segment<0 OR i.segment>s.segment OR i.start_at<s.started_at OR i.start_at>i.end_at OR i.end_at>s.heartbeat LIMIT 1").fetchone()
        registry.require(bad_interval is None, "invalid collection coverage")
        bad_session = connection.execute("SELECT 1 FROM sessions s LEFT JOIN intervals i ON i.session_id=s.session_id AND i.segment=s.segment WHERE i.session_id IS NULL OR i.end_at<>s.heartbeat LIMIT 1").fetchone()
        registry.require(bad_session is None, "collection watermark lacks coverage")
        missing_segment = connection.execute("SELECT 1 FROM sessions s WHERE (SELECT count(*) FROM intervals i WHERE i.session_id=s.session_id)<>s.segment+1 OR NOT EXISTS (SELECT 1 FROM intervals i WHERE i.session_id=s.session_id AND i.segment=0 AND i.start_at=s.started_at) LIMIT 1").fetchone()
        overlap = connection.execute("SELECT 1 FROM intervals i JOIN intervals p ON p.session_id=i.session_id AND p.segment=i.segment-1 WHERE i.start_at<p.end_at LIMIT 1").fetchone()
        registry.require(missing_segment is None and overlap is None, "collection coverage segments are inconsistent")
        bad_event = connection.execute("SELECT 1 FROM events e LEFT JOIN artifacts a USING(name,version,target,kind) LEFT JOIN sessions s USING(session_id) WHERE a.name IS NULL OR s.session_id IS NULL OR e.sha256<>a.sha256 OR e.bytes<0 OR e.bytes>a.bytes OR e.event_type NOT IN ('completed','range','redirect','failed') OR e.traffic NOT IN ('public','bot','internal') OR (e.event_type='completed' AND e.bytes<>a.bytes) OR (e.event_type='redirect' AND e.bytes<>0) OR e.occurred_at<s.started_at OR e.occurred_at>? OR (s.finished_at IS NOT NULL AND e.occurred_at>s.finished_at) OR length(e.event_id) NOT BETWEEN 1 AND 128 OR substr(e.event_id,1,1) NOT GLOB '[A-Za-z0-9]' OR e.event_id GLOB '*[^A-Za-z0-9._:-]*' LIMIT 1", (now,)).fetchone()
        registry.require(bad_event is None, "invalid retained download event")
        first = connection.execute("SELECT min(started_at) FROM sessions").fetchone()[0]
        registry.require((first is None and "collection_started_at" not in metadata) or
                         (first is not None and metadata.get("collection_started_at") == _stamp(first)), "invalid first collection timestamp")

    @contextmanager
    def _database(self, *, write=False, create=False):
        with self._lock:
            connection = None
            try:
                connection = self._connect(write, create)
                connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
                self._validate(connection)
                if write:
                    page_size = connection.execute("PRAGMA page_size").fetchone()[0]
                    connection.execute("PRAGMA max_page_count=" + str(MAX_DB_BYTES // page_size))
                    for identity, binding in self.artifacts.items():
                        connection.execute("INSERT INTO artifacts VALUES (?,?,?,?,?,?) ON CONFLICT DO NOTHING", (*identity, *binding))
                yield connection
                self._validate(connection)
                connection.commit()
            except BaseException as error:
                if connection is not None: connection.rollback()
                if isinstance(error, (registry.RegistryError, KeyboardInterrupt, SystemExit)): raise
                raise registry.RegistryError("download ledger operation failed") from error
            finally:
                if connection is not None: connection.close()

    def _session(self, connection, session_id, *, active=True):
        _opaque(session_id)
        row = connection.execute("SELECT * FROM sessions WHERE session_id=?", (session_id,)).fetchone()
        registry.require(row is not None and (not active or row["finished_at"] is None), "collection session is unavailable")
        return row

    def begin(self, at: str | None = None) -> str:
        stamp = _time(at)
        session_id = uuid.uuid4().hex
        with self._database(write=True, create=True) as connection:
            latest = connection.execute("SELECT max(heartbeat) FROM sessions").fetchone()[0]
            event_time = connection.execute("SELECT max(occurred_at) FROM events").fetchone()[0]
            registry.require(stamp >= max(latest or 0, event_time or 0), "collection clock did not advance")
            # An unfinished prior process cannot certify the time after its
            # last heartbeat. Its events stay retained through the restart.
            connection.execute("UPDATE sessions SET finished_at=?, interrupted=1 WHERE finished_at IS NULL", (stamp,))
            connection.execute("INSERT INTO sessions VALUES (?,?,?,NULL,0,0)", (session_id, stamp, stamp))
            connection.execute("INSERT INTO intervals VALUES (?,0,?,?)", (session_id, stamp, stamp))
            connection.execute("INSERT INTO metadata VALUES ('collection_started_at',?) ON CONFLICT DO NOTHING", (_stamp(stamp),))
        return session_id

    def _advance(self, connection, session_id, stamp):
        session = self._session(connection, session_id)
        registry.require(stamp >= session["heartbeat"], "collection clock moved backwards")
        segment = session["segment"]
        if session["interrupted"] or stamp - session["heartbeat"] > MAX_GAP:
            segment += 1
            connection.execute("INSERT INTO intervals VALUES (?,?,?,?)", (session_id, segment, stamp, stamp))
        else:
            connection.execute("UPDATE intervals SET end_at=? WHERE session_id=? AND segment=?", (stamp, session_id, segment))
        connection.execute("UPDATE sessions SET heartbeat=?, segment=?, interrupted=0 WHERE session_id=?", (stamp, segment, session_id))

    def heartbeat(self, session_id: str, at: str | None = None) -> None:
        stamp = _time(at)
        with self._database(write=True) as connection: self._advance(connection, session_id, stamp)

    def interrupt(self, session_id: str) -> None:
        """End assurance at the last heartbeat; a later heartbeat starts anew."""
        with self._database(write=True) as connection:
            self._session(connection, session_id)
            connection.execute("UPDATE sessions SET interrupted=1 WHERE session_id=?", (session_id,))

    def finish(self, session_id: str, at: str | None = None) -> None:
        stamp = _time(at)
        with self._database(write=True) as connection:
            last_event = connection.execute("SELECT max(occurred_at) FROM events WHERE session_id=?", (session_id,)).fetchone()[0]
            registry.require(stamp >= (last_event or 0), "collection cannot finish before a retained event")
            self._advance(connection, session_id, stamp)
            connection.execute("UPDATE sessions SET finished_at=? WHERE session_id=?", (stamp, session_id))

    def record(self, session_id: str, event: dict) -> bool:
        """Retain an event once; identical replay returns False, conflicts fail.

        A delivery adapter must call interrupt if event recording fails.
        Clients cannot submit events through this module's HTTP interface;
        this module has no HTTP interface.
        """
        registry.exact_keys(event, FIELDS, FIELDS, "download event")
        registry.require(type(event["schema"]) is int and event["schema"] == 1, "unsupported download event schema")
        identifier = _opaque(event["event_id"])
        stamp = _time(event["occurred_at"])
        identity = (event["name"], event["version"], event["target"], event["kind"])
        registry.require(all(isinstance(part, str) for part in identity), "invalid download artifact selection")
        binding = self.artifacts.get(identity)
        registry.require(binding is not None and event["sha256"] == binding[0], "download event does not match a registered artifact")
        registry.require(type(event["bytes"]) is int and 0 <= event["bytes"] <= binding[1], "invalid delivered byte count")
        registry.require(event["event_type"] in ("completed", "range", "redirect", "failed")
                         and event["traffic"] in ("public", "bot", "internal"), "invalid download event classification")
        registry.require((event["event_type"] != "completed" or event["bytes"] == binding[1])
                         and (event["event_type"] != "redirect" or event["bytes"] == 0), "download event has inconsistent response bytes")
        value = (identifier, stamp, *identity, event["sha256"], event["bytes"], event["event_type"], event["traffic"])
        with self._database(write=True) as connection:
            session = self._session(connection, session_id, active=False)
            existing = connection.execute("SELECT event_id,occurred_at,name,version,target,kind,sha256,bytes,event_type,traffic FROM events WHERE event_id=?", (identifier,)).fetchone()
            if existing is not None:
                registry.require(tuple(existing) == value, "download event identity conflicts with retained content")
                return False
            registry.require(session["finished_at"] is None and stamp >= session["started_at"], "download event falls outside its collection session")
            connection.execute("INSERT INTO events VALUES (?,?,?,?,?,?,?,?,?,?,?)", (identifier, session_id, *value[1:]))
        return True

    def snapshot(self, at: str | None = None) -> dict:
        stamp = _time(at)
        with self._database() as connection:
            metadata = dict(connection.execute("SELECT key,value FROM metadata"))
            session = connection.execute("SELECT * FROM sessions ORDER BY heartbeat DESC,rowid DESC LIMIT 1").fetchone()
            counts = dict.fromkeys(self.names, 0)
            versions = dict.fromkeys(self.versions, 0)
            retained_counts = dict.fromkeys(self.names, 0)
            retained_versions = dict.fromkeys(self.versions, 0)
            daily, intervals = [], []
            start, end, complete, stale = None, None, False, True
            retained_start, retained_complete = None, False
            if session is not None:
                end = session["heartbeat"]
                registry.require(stamp >= end, "snapshot clock precedes the collection watermark")
                stale = bool(session["interrupted"] or session["finished_at"] is not None or stamp - end > MAX_GAP)
                rows = connection.execute("SELECT name,version,count(*) AS count FROM events WHERE event_type='completed' AND traffic='public' AND occurred_at>? AND occurred_at<=? GROUP BY name,version", (end - WINDOW, end))
                for row in rows:
                    key = row["name"] + "@" + row["version"]
                    registry.require(type(row["count"]) is int and 0 <= row["count"] <= MAX_COUNT, "download count exceeds its bound")
                    if key in versions: versions[key] = row["count"]
                    if row["name"] in counts:
                        counts[row["name"]] += row["count"]
                        registry.require(counts[row["name"]] <= MAX_COUNT, "download aggregate exceeds its bound")
                for row in connection.execute("SELECT name,version,count(*) AS count FROM events WHERE event_type='completed' AND traffic='public' AND occurred_at<=? GROUP BY name,version", (end,)):
                    key = row["name"] + "@" + row["version"]
                    registry.require(type(row["count"]) is int and 0 <= row["count"] <= MAX_COUNT,
                                     "retained download count exceeds its bound")
                    if key in retained_versions: retained_versions[key] = row["count"]
                    if row["name"] in retained_counts:
                        retained_counts[row["name"]] += row["count"]
                        registry.require(retained_counts[row["name"]] <= MAX_COUNT,
                                         "retained download aggregate exceeds its bound")
                for row in connection.execute("SELECT occurred_at / ? AS day,name,version,count(*) AS count FROM events WHERE event_type='completed' AND traffic='public' AND occurred_at>? AND occurred_at<=? GROUP BY day,name,version ORDER BY day,name,version", (DAY, end - WINDOW, end)):
                    if row["name"] in counts:
                        daily.append({"date": _stamp(row["day"] * DAY)[:10], "name": row["name"],
                                      "version": row["version"], "count": row["count"]})
                # Retain every healthy segment. The latest segment alone
                # cannot establish what was observed on an earlier date.
                retained_intervals = []
                for row in connection.execute("SELECT start_at,end_at FROM intervals ORDER BY start_at,end_at"):
                    left, right = row["start_at"], row["end_at"]
                    if retained_intervals and left <= retained_intervals[-1][1]:
                        retained_intervals[-1][1] = max(retained_intervals[-1][1], right)
                    else:
                        retained_intervals.append([left, right])
                retained_start = retained_intervals[-1][0]
                retained_complete = retained_start <= _time(metadata["collection_started_at"])
                merged = [[max(left, end - WINDOW), min(right, end)] for left, right in retained_intervals
                          if right >= end - WINDOW and left <= end]
                start = merged[-1][0]
                complete = start <= end - WINDOW
                intervals = [{"start": _stamp(left), "end": _stamp(right)} for left, right in merged]
            return {"observed_at": _stamp(stamp), "collection_started_at": metadata.get("collection_started_at"),
                    "coverage_start": _stamp(start), "coverage_end": _stamp(end), "complete": complete,
                    "counts": counts, "version_counts": versions, "stale": stale,
                    "daily_counts": daily, "coverage_intervals": intervals,
                    "retained_counts": retained_counts, "retained_version_counts": retained_versions,
                    "retained_coverage_start": _stamp(retained_start), "retained_complete": retained_complete}
