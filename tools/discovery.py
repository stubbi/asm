"""Keep bounded GitHub observations separate from immutable registry records.

Dates describe availability of the declared GitHub assets, not registry
admission. Counters include automation. A later boundary sample supplies a
lower bound, not a fabricated complete download window.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

from contextlib import closing
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
from typing import Callable
from urllib.parse import quote

import registry

POLICY = "github-release-assets-v1"
MAX_COUNT = 2 ** 53 - 1
MAX_ASSETS = 4096
MAX_OBSERVATIONS = 250000
MAX_DB_BYTES = 64 * 1024 * 1024
MAX_JSON_BYTES = 4 * 1024 * 1024
APPLICATION_ID = 0x41534D44
FAILURE = "Discovery refresh failed. The previous valid observation is retained."
INVALID_STATE = "Discovery observations are unavailable. Check the local discovery state."
STALE_AFTER = timedelta(hours=24)
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
API_PATTERN = re.compile(r"https://api\.github\.com/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/tags/[A-Za-z0-9_.-]+\Z")
TABLES = {
    "metadata": "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT",
    "releases": "CREATE TABLE releases (api TEXT PRIMARY KEY, release_id INTEGER NOT NULL, published_at TEXT NOT NULL) STRICT",
    "assets": "CREATE TABLE assets (url TEXT PRIMARY KEY, asset_id INTEGER NOT NULL UNIQUE, digest TEXT NOT NULL, size INTEGER NOT NULL, created_at TEXT NOT NULL, last_at TEXT NOT NULL, last_count INTEGER NOT NULL) STRICT",
    "observations": "CREATE TABLE observations (url TEXT NOT NULL REFERENCES assets(url), hour INTEGER NOT NULL, observed_at TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (url, hour)) STRICT",
}


def _time(value: object) -> datetime:
    registry.require(isinstance(value, str) and len(value) <= 40 and
                     re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})", value) is not None,
                     "invalid discovery timestamp")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        registry.require(result.tzinfo is not None and result.utcoffset() is not None, "discovery timestamp needs a timezone")
        result = result.astimezone(timezone.utc)
        registry.require(result >= EPOCH, "invalid discovery timestamp")
        return result
    except (ValueError, OverflowError) as error:
        raise registry.RegistryError("invalid discovery timestamp") from error


def _stamp(value: datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def _clock(value=None) -> datetime:
    actual = datetime.now(timezone.utc)
    result = actual if value is None else _time(value)
    registry.require(result <= actual, "discovery observation is in the future")
    return result


def _hour(value: datetime) -> int:
    return (value - EPOCH) // timedelta(hours=1)


def _integer(value: object, *, identity=False) -> int:
    limit = 2 ** 63 - 1 if identity else MAX_COUNT
    registry.require(type(value) is int and (1 if identity else 0) <= value <= limit, "invalid discovery integer")
    return value


def _records(records: list[dict]) -> list[dict]:
    result = registry.check_records(records)
    registry.require(sum(len(item["artifacts"]) for item in result) <= MAX_ASSETS, "too many discovery assets")
    return result


def _catalog(records: list[dict]) -> str:
    return hashlib.sha256(registry.json_bytes(records)).hexdigest()


def unknown_snapshot(records: list[dict]) -> dict:
    """Return explicitly unavailable evidence for a validated current catalog."""
    records = _records(records)
    return {"schema": 1, "policy": POLICY, "source": "github-release-assets", "observed_at": None,
            "stale": False, "refresh_error": None,
            "window": {"days": 30, "start": None, "end": None, "basis": "rolling-observation"},
            "packages": [{"name": name, "first_published_at": None, "last_published_at": None,
                          "publication_source": "github-release", "downloads_30d": None,
                          "downloads_30d_exact": False, "downloads_30d_coverage": "unavailable"}
                         for name in sorted({item["name"] for item in records})],
            "feeds": {"popular": [], "new": [], "updated": []}}


def _json(value: object) -> str:
    try:
        result = json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
    except (TypeError, ValueError, RecursionError) as error:
        raise registry.RegistryError("invalid discovery JSON") from error
    registry.require(len(result) <= MAX_JSON_BYTES, "discovery JSON exceeds its bound")
    return result


def _path(path: Path, *, create: bool) -> Path:
    path = Path(path).absolute()
    registry.require(path.name not in ("", ".", ".."), "invalid discovery state path")
    if create:
        path.parent.mkdir(parents=True, exist_ok=True)
    registry.require(not path.parent.is_symlink(), "discovery state parent cannot be a symlink")
    if path.parent.exists():
        path = path.parent.resolve() / path.name
    try:
        info = path.lstat()
    except FileNotFoundError:
        info = None
    if info is not None:
        registry.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid(),
                         "discovery state must be an owned regular file")
        registry.require(info.st_size <= MAX_DB_BYTES, "discovery state exceeds its bound")
    for suffix in ("-journal", "-wal", "-shm"):
        extra = path.with_name(path.name + suffix)
        registry.require(not extra.is_symlink(), "discovery sidecar cannot be a symlink")
        if extra.exists():
            side = extra.stat()
            registry.require(stat.S_ISREG(side.st_mode) and side.st_nlink == 1 and side.st_size <= MAX_DB_BYTES,
                             "invalid discovery sidecar")
    return path


def _connect(path: Path, *, create=False, writable=False):
    path = _path(path, create=create)
    existed = path.exists()
    if not existed:
        if not create:
            return None
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
    mode = "rw" if writable else "ro"
    connection = sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=" + mode, uri=True, timeout=5)
    try:
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA trusted_schema=OFF")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA temp_store=MEMORY")
        connection.execute("PRAGMA cache_size=-4096")
        connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, MAX_JSON_BYTES)
        if not existed:
            _limit_database(connection)
            with connection:
                for statement in TABLES.values(): connection.execute(statement)
                connection.execute("PRAGMA application_id=" + str(APPLICATION_ID))
                connection.execute("PRAGMA user_version=1")
                connection.execute("INSERT INTO metadata VALUES ('policy', ?)", (POLICY,))
        return connection
    except BaseException:
        connection.close()
        raise



def _limit_database(connection):
    page_size = connection.execute("PRAGMA page_size").fetchone()[0]
    connection.execute("PRAGMA max_page_count=" + str(MAX_DB_BYTES // page_size))


def _validate_snapshot(value: object, now: datetime) -> dict:
    required = {"schema", "policy", "source", "observed_at", "stale", "refresh_error", "window", "packages", "feeds"}
    registry.exact_keys(value, required, required, "discovery snapshot")
    registry.require(value["schema"] == 1 and value["policy"] == POLICY and value["source"] == "github-release-assets",
                     "unsupported discovery snapshot")
    observed = _time(value["observed_at"])
    registry.require(observed <= now and value["stale"] is False and value["refresh_error"] is None,
                     "invalid saved discovery snapshot")
    registry.require(value["window"] == {"days": 30, "start": _stamp(observed - timedelta(days=30)),
                     "end": _stamp(observed), "basis": "rolling-observation"}, "invalid discovery window")
    registry.require(isinstance(value["packages"], list) and len(value["packages"]) <= registry.MAX_ROWS,
                     "invalid discovery package list")
    names = []
    fields = {"name", "first_published_at", "last_published_at", "publication_source", "downloads_30d", "downloads_30d_exact", "downloads_30d_coverage"}
    for package in value["packages"]:
        registry.exact_keys(package, fields, fields, "discovery package")
        names.append(registry.package_name(package["name"]))
        registry.require(package["publication_source"] == "github-release", "invalid publication source")
        first = _time(package["first_published_at"])
        last = _time(package["last_published_at"]) if package["last_published_at"] is not None else None
        registry.require(first <= observed and (last is None or first <= last <= observed), "invalid publication dates")
        count = package["downloads_30d"]
        exact, coverage = package["downloads_30d_exact"], package["downloads_30d_coverage"]
        registry.require(type(exact) is bool, "invalid discovery exactness")
        if count is None:
            registry.require(not exact and coverage == "unavailable", "invalid missing discovery count")
        else:
            _integer(count)
            registry.require(coverage == ("complete" if exact else "lower-bound"), "invalid discovery coverage")
    registry.require(names == sorted(set(names)), "invalid discovery package identities")
    registry.exact_keys(value["feeds"], {"popular", "new", "updated"}, {"popular", "new", "updated"}, "discovery feeds")
    for feed in value["feeds"].values():
        registry.require(isinstance(feed, list) and all(isinstance(name, str) and name in names for name in feed)
                         and len(feed) == len(set(feed)), "invalid discovery feed")
    return value


def _state(connection, now: datetime) -> dict:
    registry.require(connection.execute("PRAGMA application_id").fetchone()[0] == APPLICATION_ID
                     and connection.execute("PRAGMA user_version").fetchone()[0] == 1, "unsupported discovery state")
    schema = dict(connection.execute("SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL"))
    registry.require(schema == TABLES, "invalid discovery database schema")
    registry.require([tuple(row) for row in connection.execute("PRAGMA quick_check").fetchmany(2)] == [("ok",)],
                     "corrupt discovery state")
    for table, limit in (("metadata", 5), ("releases", MAX_ASSETS), ("assets", MAX_ASSETS), ("observations", MAX_OBSERVATIONS)):
        registry.require(connection.execute("SELECT count(*) FROM " + table).fetchone()[0] <= limit,
                         "discovery state exceeds its row bound")
    metadata = dict(connection.execute("SELECT key, value FROM metadata"))
    registry.require(metadata.get("policy") == POLICY and set(metadata) <= {"policy", "snapshot", "catalog", "error", "failed_at"},
                     "invalid discovery metadata")
    snapshot = None
    if "snapshot" in metadata:
        snapshot = _validate_snapshot(registry.strict_json(metadata["snapshot"].encode()), now)
        registry.require(registry.HEX64.fullmatch(metadata.get("catalog", "")) is not None, "invalid discovery catalog binding")
    else:
        registry.require(set(metadata) == {"policy"}, "incomplete discovery snapshot")
    if "error" in metadata:
        registry.require(metadata["error"] == FAILURE and _time(metadata.get("failed_at")) <= now,
                         "invalid discovery failure state")
    else:
        registry.require("failed_at" not in metadata, "invalid discovery failure state")
    releases = {}
    for row in connection.execute("SELECT * FROM releases"):
        value = dict(row)
        registry.require(len(value["api"]) <= 2048 and API_PATTERN.fullmatch(value["api"]) is not None,
                         "invalid saved release URL")
        _integer(value["release_id"], identity=True)
        registry.require(_time(value["published_at"]) <= now, "saved publication is in the future")
        releases[value["api"]] = value
    registry.require(len({item["release_id"] for item in releases.values()}) == len(releases), "reused release identity")
    assets, observations = {}, {}
    for row in connection.execute("SELECT * FROM assets"):
        value = dict(row)
        registry.artifact_url(value["url"])
        _integer(value["asset_id"], identity=True); _integer(value["last_count"])
        registry.require(registry.HEX64.fullmatch(value["digest"]) is not None
                         and type(value["size"]) is int and 0 < value["size"] <= registry.MAX_ARTIFACT_BYTES,
                         "invalid saved asset binding")
        registry.require(_time(value["created_at"]) <= _time(value["last_at"]) <= now, "invalid saved asset timestamps")
        assets[value["url"]] = value
    for row in connection.execute("SELECT * FROM observations ORDER BY url, hour"):
        asset = assets.get(row["url"])
        at, count = _time(row["observed_at"]), _integer(row["count"])
        registry.require(asset is not None and type(row["hour"]) is int and row["hour"] == _hour(at), "invalid saved observation")
        registry.require(_time(asset["created_at"]) <= at <= _time(asset["last_at"]) and count <= asset["last_count"],
                         "invalid observation range")
        previous = observations.setdefault(row["url"], [])
        registry.require(not previous or (previous[-1][0] < at and previous[-1][1] <= count), "counter history is not monotonic")
        previous.append((at, count))
    for url, asset in assets.items():
        history = observations.setdefault(url, [])
        latest = (_time(asset["last_at"]), asset["last_count"])
        if not history or history[-1][0] != latest[0]: history.append(latest)
        else: registry.require(history[-1][1] == latest[1], "inconsistent latest observation")
    return {"metadata": metadata, "snapshot": snapshot, "releases": releases, "assets": assets, "observations": observations}


def _read(path: Path, now: datetime):
    connection = _connect(path)
    if connection is None: return None
    with closing(connection): return _state(connection, now)


def load_snapshot(state_path: Path, records: list[dict], *, now=None) -> dict:
    """Load valid cached evidence; invalid state stays intact and unavailable.

    A snapshot older than 24 hours is stale. A service can use a stricter
    interval. This read never repairs or replaces an invalid database.
    """
    records, at = _records(records), _clock(now)
    try:
        state = _read(state_path, at)
        if not state or not state["snapshot"]: return unknown_snapshot(records)
        if state["metadata"]["catalog"] != _catalog(records):
            value = unknown_snapshot(records)
            value.update(stale=True, refresh_error="Discovery observations do not cover the current catalog.")
            return value
        value = state["snapshot"]
        registry.require(value["feeds"] == _feeds(value, records), "inconsistent saved discovery feeds")
        if "error" in state["metadata"]:
            value = dict(value, stale=True, refresh_error=state["metadata"]["error"])
        elif at - _time(value["observed_at"]) > STALE_AFTER:
            value = dict(value, stale=True, refresh_error="Discovery observations are more than 24 hours old.")
        return value
    except (registry.RegistryError, sqlite3.Error, OSError, KeyError, TypeError, ValueError):
        return dict(unknown_snapshot(records), stale=True, refresh_error=INVALID_STATE)


def release_dates(state_path: Path, records: list[dict], *, now=None) -> dict:
    """Read exact historical GitHub availability without fetching or writing.

    Every registered artifact must retain its URL, size, and digest binding.
    Unavailable or inconsistent evidence leaves all requested dates unknown.
    These dates are not Asm admission dates or download observations.
    """
    records, at = _records(records), _clock(now)
    unknown = {item["name"] + "@" + item["version"]: None for item in records}
    try:
        state = _read(state_path, at)
        if not state or not state["snapshot"] or state["metadata"]["catalog"] != _catalog(records):
            return unknown
        cutoff = _time(state["snapshot"]["observed_at"])
        result = {}
        for record in records:
            available = _release_availability(record, state["releases"], state["assets"])
            registry.require(available <= cutoff, "release availability exceeds its observation")
            result[record["name"] + "@" + record["version"]] = _stamp(available)
        return result
    except (registry.RegistryError, sqlite3.Error, OSError, KeyError, TypeError, ValueError):
        return unknown


def _api(url: str) -> tuple[str, str]:
    repository, tag, _ = registry.artifact_url(url)
    api = repository.replace("https://github.com/", "https://api.github.com/repos/") + "/releases/tags/" + tag
    registry.require(API_PATTERN.fullmatch(api) is not None, "invalid release API URL")
    return api, tag


def _evidence(records: list[dict], responses: dict, now: datetime) -> tuple[dict, dict]:
    releases, assets = {}, {}
    for api, response in responses.items():
        registry.require(isinstance(response, dict) and response.get("draft") is False
                         and response.get("tag_name") == api.rsplit("/", 1)[1], "release metadata does not match")
        published = _time(response.get("published_at"))
        registry.require(published <= now, "release publication is in the future")
        registry.require(isinstance(response.get("assets"), list) and len(response["assets"]) <= 1000,
                         "invalid release asset list")
        releases[api] = {"api": api, "release_id": _integer(response.get("id"), identity=True),
                         "published_at": _stamp(published)}
    registry.require(len({item["release_id"] for item in releases.values()}) == len(releases), "reused release identity")
    for record in records:
        for artifact in record["artifacts"]:
            url = artifact["url"]
            api, _ = _api(url)
            matches = [item for item in responses[api]["assets"] if isinstance(item, dict) and item.get("browser_download_url") == url]
            registry.require(len(matches) == 1, "release artifact is missing or ambiguous")
            item = matches[0]
            registry.require(item.get("state") == "uploaded" and type(item.get("size")) is int
                             and item["size"] == artifact["bytes"] and item.get("digest") == "sha256:" + artifact["sha256"],
                             "release asset binding differs from the registry")
            created = _time(item.get("created_at"))
            registry.require(created <= now, "asset creation is in the future")
            assets[url] = {"url": url, "asset_id": _integer(item.get("id"), identity=True), "digest": artifact["sha256"],
                           "size": artifact["bytes"], "created_at": _stamp(created), "last_at": _stamp(now),
                           "last_count": _integer(item.get("download_count"))}
    registry.require(len({item["asset_id"] for item in assets.values()}) == len(assets), "reused asset identity")
    return releases, assets


def _window(asset: dict, history: list, start: datetime, end: datetime):
    if _time(asset["created_at"]) >= start:
        return asset["last_count"], True
    candidates = [(at, count) for at, count in history if start <= at <= start + timedelta(days=1) and at < end]
    if not candidates: return None, False
    at, baseline = min(candidates)
    exact = at == start or any(before < start and count == baseline for before, count in history)
    registry.require(asset["last_count"] >= baseline, "download counter decreased")
    return asset["last_count"] - baseline, exact


def _feeds(snapshot: dict, records: list[dict]) -> dict:
    active = {item["name"] for item in records if not item["yanked"]}
    packages = [item for item in snapshot["packages"] if item["name"] in active]
    popular = sorted((item for item in packages if item["downloads_30d"] is not None),
                     key=lambda item: (-item["downloads_30d"], item["name"]))
    new = sorted(packages, key=lambda item: (-_time(item["first_published_at"]).timestamp(), item["name"]))
    updated = sorted((item for item in packages if item["last_published_at"] and
                      _time(item["last_published_at"]) > _time(item["first_published_at"])),
                     key=lambda item: (-_time(item["last_published_at"]).timestamp(), item["name"]))
    return {"popular": [item["name"] for item in popular], "new": [item["name"] for item in new],
            "updated": [item["name"] for item in updated]}


def _release_availability(record: dict, releases: dict, assets: dict) -> datetime:
    dates = []
    for artifact in record["artifacts"]:
        asset = assets[artifact["url"]]
        registry.require(asset["digest"] == artifact["sha256"] and asset["size"] == artifact["bytes"],
                         "release availability artifact binding differs from the registry")
        dates.append(max(_time(releases[_api(artifact["url"])[0]]["published_at"]), _time(asset["created_at"])))
    return max(dates)


def _snapshot(records: list[dict], releases: dict, assets: dict, history: dict, now: datetime) -> dict:
    result = unknown_snapshot(records)
    start = now - timedelta(days=30)
    result.update(observed_at=_stamp(now), window={"days": 30, "start": _stamp(start), "end": _stamp(now), "basis": "rolling-observation"})
    for package in result["packages"]:
        versions = [item for item in records if item["name"] == package["name"]]
        dates, active_dates, urls = [], [], set()
        for record in versions:
            availability = _release_availability(record, releases, assets)
            dates.append(availability)
            if not record["yanked"]: active_dates.append(availability)
            urls.update(item["url"] for item in record["artifacts"])
        package.update(first_published_at=_stamp(min(dates)), last_published_at=_stamp(max(active_dates)) if active_dates else None)
        values = [_window(assets[url], history.get(url, []), start, now) for url in sorted(urls)]
        if all(count is not None for count, _ in values):
            count = _integer(sum(count for count, _ in values))
            exact = all(exact for _, exact in values)
            package.update(downloads_30d=count, downloads_30d_exact=exact,
                           downloads_30d_coverage="complete" if exact else "lower-bound")
    result["feeds"] = _feeds(result, records)
    return result


def _persist(connection, records: list[dict], releases: dict, assets: dict, snapshot: dict, now: datetime):
    for item in releases.values():
        connection.execute("INSERT INTO releases VALUES (:api, :release_id, :published_at) ON CONFLICT(api) DO NOTHING", item)
    connection.execute("DELETE FROM observations WHERE hour < ?", (_hour(now - timedelta(days=35)),))
    for item in assets.values():
        connection.execute("INSERT INTO assets VALUES (:url, :asset_id, :digest, :size, :created_at, :last_at, :last_count) "
                           "ON CONFLICT(url) DO UPDATE SET last_at=excluded.last_at, last_count=excluded.last_count", item)
        # Keep the first sample in each hour plus each asset's latest sample.
        connection.execute("INSERT INTO observations VALUES (?, ?, ?, ?) ON CONFLICT(url,hour) DO NOTHING",
                           (item["url"], _hour(now), item["last_at"], item["last_count"]))
    registry.require(connection.execute("SELECT count(*) FROM observations").fetchone()[0] <= MAX_OBSERVATIONS,
                     "discovery observations exceed their bound")
    registry.require(connection.execute("SELECT count(*) FROM assets").fetchone()[0] <= MAX_ASSETS
                     and connection.execute("SELECT count(*) FROM releases").fetchone()[0] <= MAX_ASSETS,
                     "discovery bindings exceed their bound")
    for key, value in (("snapshot", _json(snapshot)), ("catalog", _catalog(records))):
        connection.execute("INSERT INTO metadata VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))
    connection.execute("DELETE FROM metadata WHERE key IN ('error','failed_at')")


def _failure(path: Path, now: datetime):
    """Record a fixed failure separately; never replace prior successful data."""
    try:
        connection = _connect(path, writable=True)
        if connection is None: return
        with closing(connection), connection:
            connection.execute("BEGIN IMMEDIATE")
            state = _state(connection, now)
            if not state["snapshot"] or _time(state["snapshot"]["observed_at"]) > now: return
            _limit_database(connection)
            for key, value in (("error", FAILURE), ("failed_at", _stamp(now))):
                connection.execute("INSERT INTO metadata VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))
    except (registry.RegistryError, sqlite3.Error, OSError, KeyError, TypeError, ValueError):
        # Corrupt or unsafe state must stay untouched, including on a failure.
        return


def collect(records: list[dict], state_path: Path, *, fetch: Callable[[str], dict], observed_at: str | None = None) -> dict:
    """Collect one complete source observation and commit it atomically.

    The injected fetcher must use the public, fixed GitHub release-tag API.
    Network and validation failures raise RegistryError. No partial source
    observations replace a valid snapshot. No package is downloaded or run.
    """
    records, at = _records(records), _clock(observed_at)
    try:
        _read(state_path, at)  # Refuse unsafe/corrupt state before network work.
        responses, total = {}, 0
        for record in records:
            for artifact in record["artifacts"]:
                api, _ = _api(artifact["url"])
                if api not in responses:
                    response = fetch(api)
                    encoded = _json(response)
                    registry.require(len(encoded) <= 2 * 1024 * 1024, "release metadata exceeds its bound")
                    total += len(encoded)
                    registry.require(total <= 16 * 1024 * 1024, "discovery metadata exceeds its total bound")
                    responses[api] = response
        # A real observation ends after the requests, not before them.
        at = _clock(observed_at)
        releases, assets = _evidence(records, responses, at)
        with closing(_connect(state_path, create=True, writable=True)) as connection, connection:
            connection.execute("BEGIN IMMEDIATE")
            state = _state(connection, at)
            _limit_database(connection)
            if state["snapshot"]:
                registry.require(_time(state["snapshot"]["observed_at"]) < at, "discovery observation did not advance")
            for api, value in releases.items():
                previous = state["releases"].get(api)
                registry.require(previous is None or previous == value, "release publication binding changed")
            for url, value in assets.items():
                previous = state["assets"].get(url)
                if previous is None: continue
                registry.require(all(previous[key] == value[key] for key in ("url", "asset_id", "digest", "size", "created_at")),
                                 "release asset identity changed")
                registry.require(previous["last_count"] <= value["last_count"], "download counter decreased")
            snapshot = _snapshot(records, releases, assets, state["observations"], at)
            _validate_snapshot(snapshot, at)
            _persist(connection, records, releases, assets, snapshot, at)
        return snapshot
    except Exception as error:
        _failure(state_path, at)
        if isinstance(error, registry.RegistryError): raise
        raise registry.RegistryError("discovery refresh failed") from error


def delivery_snapshot(records: list[dict], publication: dict | None = None, observation: dict | None = None) -> dict:
    """Project Asm delivery events; upstream counters never supply this metric.

    Publication metadata is a separate adapter for retained legacy releases.
    An empty event history remains unknown, even if GitHub reports downloads.
    """
    result = unknown_snapshot(records)
    result.update(policy="asm-deliveries-v1", source="asm-delivery-events", stale=True,
                  collection_started_at=None, publication_observed_at=(publication or {}).get("publication_observed_at", (publication or {}).get("observed_at")),
                  coverage={"start": None, "end": None, "complete": False})
    if publication is not None:
        supplied = {item["name"]: item for item in publication.get("packages", [])}
        for item in result["packages"]:
            facts = supplied.get(item["name"], {})
            item["first_published_at"] = facts.get("first_published_at")
            item["last_published_at"] = facts.get("last_published_at")
    if observation is not None:
        complete = observation["complete"]
        registry.require(type(complete) is bool, "invalid delivery coverage")
        end = observation.get("coverage_end")
        result.update(observed_at=end, stale=observation["stale"],
                      collection_started_at=observation.get("collection_started_at"),
                      coverage={"start": observation.get("coverage_start"), "end": end, "complete": complete})
        if end is not None:
            instant = _time(end)
            result["window"] = {"days": 30, "start": _stamp(instant - timedelta(days=30)), "end": end, "basis": "rolling-observation"}
            for item in result["packages"]:
                count = observation["counts"].get(item["name"], 0)
                _integer(count)
                item.update(downloads_30d=count, downloads_30d_exact=complete,
                            downloads_30d_coverage="complete" if complete else "lower-bound")
    active = {item["name"] for item in records if not item["yanked"]}
    packages = [item for item in result["packages"] if item["name"] in active]
    result["feeds"] = {
        "popular": [item["name"] for item in sorted((item for item in packages if item["downloads_30d"] is not None and item["downloads_30d"] > 0), key=lambda item: (-item["downloads_30d"], item["name"]))],
        "new": [item["name"] for item in sorted((item for item in packages if item["first_published_at"] is not None), key=lambda item: (-_time(item["first_published_at"]).timestamp(), item["name"]))],
        "updated": [item["name"] for item in sorted((item for item in packages if item["first_published_at"] and item["last_published_at"] and _time(item["last_published_at"]) > _time(item["first_published_at"])), key=lambda item: (-_time(item["last_published_at"]).timestamp(), item["name"]))]
    }
    return result


def delivery_counts(records: list[dict], observation: dict | None) -> dict:
    """Use the same window and event classes on exact package pages."""
    packages = {}
    for record in records:
        packages.setdefault(record["name"], {"total": None, "versions": {}})["versions"][record["version"]] = None
    result = {"schema": 1, "source": "asm-delivery-events", "observed_at": None,
              "complete": False, "stale": True, "collection_started_at": None, "packages": packages}
    if observation is not None and observation.get("coverage_end") is not None:
        result.update(observed_at=observation["coverage_end"], complete=observation["complete"], stale=observation["stale"],
                      collection_started_at=observation.get("collection_started_at"))
        for name, package in packages.items():
            package["total"] = observation["counts"].get(name, 0)
            for version in package["versions"]:
                package["versions"][version] = observation.get("version_counts", {}).get(name + "@" + version, 0)
    return result


def retained_counts(records: list[dict], observation: dict | None) -> dict:
    """Project cumulative Asm transfers since collection, never global lifetime.

    Old rolling-window projections cannot supply these values. Complete
    coverage applies only to configured Asm sources since collection began.
    """
    records = _records(records)
    packages = {}
    for record in records:
        packages.setdefault(record["name"], {"total": None, "versions": {}})["versions"][record["version"]] = None
    result = {"schema": 1, "policy": "asm-deliveries-v1", "source": "asm-delivery-events",
              "scope": "since-collection", "observed_at": None, "collection_started_at": None,
              "window": {"start": None, "end": None, "basis": "since-collection"},
              "coverage": {"start": None, "end": None, "complete": False},
              "complete": False, "stale": True, "total": None, "packages": packages}
    fields = {"retained_counts", "retained_version_counts", "retained_complete", "retained_coverage_start"}
    if observation is None or observation.get("coverage_end") is None or not fields.intersection(observation):
        return result
    registry.require(fields <= observation.keys(), "retained download projection is incomplete")
    complete, stale = observation["retained_complete"], observation.get("stale")
    registry.require(type(complete) is bool and type(stale) is bool, "invalid retained download state")
    first, end = _time(observation.get("collection_started_at")), _time(observation["coverage_end"])
    start = _time(observation["retained_coverage_start"])
    registry.require(first <= start <= end and (not complete or start == first), "invalid retained download coverage")
    counts, versions = observation["retained_counts"], observation["retained_version_counts"]
    expected_versions = {record["name"] + "@" + record["version"] for record in records}
    registry.require(isinstance(counts, dict) and set(counts) == set(packages)
                     and isinstance(versions, dict) and set(versions) == expected_versions,
                     "retained download identities differ from the catalog")
    total = 0
    for name, package in packages.items():
        package["total"] = _integer(counts[name])
        for version in package["versions"]:
            package["versions"][version] = _integer(versions[name + "@" + version])
        registry.require(_integer(sum(package["versions"].values())) == package["total"],
                         "retained version counts differ from the package total")
        total = _integer(total + package["total"])
    result.update(observed_at=_stamp(end), collection_started_at=_stamp(first), complete=complete, stale=stale,
                  window={"start": _stamp(first), "end": _stamp(end), "basis": "since-collection"},
                  coverage={"start": _stamp(start), "end": _stamp(end), "complete": complete}, total=total)
    return result


def delivery_activity(records: list[dict], name: str | None, observation: dict | None, version: str | None = None) -> dict:
    """Project one bounded daily series from the same durable count window.

    Calendar dates partition (watermark minus thirty days, watermark].
    Both edge dates are clipped, so a non-midnight cutoff needs 31 bins.
    Missing coverage is null, not zero; recorded events remain lower bounds.
    No event identifier, exact transfer time, or visitor data is published.
    """
    records = _records(records)
    if name is None:
        registry.require(version is None, "registry activity cannot select one version")
    else:
        registry.package_name(name)
        versions = {item["version"] for item in records if item["name"] == name}
        registry.require(bool(versions), "unknown activity package")
        if version is not None:
            registry.version_tuple(version)
            registry.require(version in versions, "unknown activity version")
    result = {"schema": 1, "policy": "asm-deliveries-v1", "source": "asm-delivery-events",
              "name": name, "version": version, "observed_at": None, "collection_started_at": None,
              "stale": True, "window": {"days": 30, "start": None, "end": None, "basis": "rolling-observation"},
              "total": None, "complete": False, "days": []}
    if name is None:
        result.pop("name"); result.pop("version")
        result["scope"] = "registry"
    if observation is None or observation.get("coverage_end") is None:
        return result
    end = _time(observation["coverage_end"])
    start = end - timedelta(days=30)
    registry.require(start >= EPOCH, "activity window precedes supported time")
    registry.require(type(observation.get("stale")) is bool, "invalid activity freshness")
    collection_start = observation.get("collection_started_at")
    if collection_start is not None:
        registry.require(_time(collection_start) <= end, "activity collection starts after its cutoff")
    if name is None:
        counts = observation.get("counts")
        names = {record["name"] for record in records}
        registry.require(isinstance(counts, dict) and set(counts) <= names, "invalid registry activity counts")
        total = sum(_integer(counts.get(package, 0)) for package in names)
    else:
        total = (observation.get("counts", {}).get(name, 0) if version is None else
                 observation.get("version_counts", {}).get(name + "@" + version, 0))
    _integer(total)
    daily = observation.get("daily_counts")
    intervals = observation.get("coverage_intervals")
    registry.require(isinstance(daily, list) and len(daily) <= MAX_OBSERVATIONS
                     and isinstance(intervals, list) and len(intervals) <= MAX_OBSERVATIONS,
                     "activity history is unavailable or exceeds its bound")
    day_counts, seen = {}, set()
    accepted = {(item["name"], item["version"]) for item in records}
    for row in daily:
        registry.exact_keys(row, {"date", "name", "version", "count"}, {"date", "name", "version", "count"}, "activity day")
        date = row["date"]
        registry.require(isinstance(date, str) and re.fullmatch(r"\d{4}-\d\d-\d\d", date) is not None,
                         "invalid activity date")
        _time(date + "T00:00:00Z")
        identity = (row["name"], row["version"])
        registry.require(identity in accepted and start.date().isoformat() <= date <= end.date().isoformat(),
                         "activity day differs from the accepted window or release")
        _integer(row["count"])
        key = (*identity, date)
        registry.require(row["count"] > 0 and key not in seen, "ambiguous activity day")
        seen.add(key)
        if name is None or (row["name"] == name and (version is None or row["version"] == version)):
            day_counts[date] = _integer(day_counts.get(date, 0) + row["count"])
    merged = []
    for interval in intervals:
        registry.exact_keys(interval, {"start", "end"}, {"start", "end"}, "activity coverage")
        left, right = _time(interval["start"]), _time(interval["end"])
        registry.require(left <= right <= end, "invalid activity coverage interval")
        if right >= start:
            merged.append([max(left, start), right])
    merged.sort()
    coverage = []
    for left, right in merged:
        if coverage and left <= coverage[-1][1]:
            coverage[-1][1] = max(coverage[-1][1], right)
        else:
            coverage.append([left, right])
    day = start.replace(hour=0, minute=0, second=0, microsecond=0)
    while day <= end:
        left, right = max(day, start), min(day + timedelta(days=1), end)
        seconds = sum(max(timedelta(), min(right, b) - max(left, a)).total_seconds() for a, b in coverage)
        count = day_counts.get(day.date().isoformat(), 0)
        duration = (right - left).total_seconds()
        state = ("complete" if duration > 0 and seconds == duration else
                 "partial" if seconds > 0 or count > 0 else "unavailable")
        result["days"].append({"date": day.date().isoformat(), "start": _stamp(left), "end": _stamp(right),
                               "count": None if state == "unavailable" else count,
                               "coverage": state, "observed_seconds": seconds})
        day += timedelta(days=1)
    registry.require(sum(item["count"] or 0 for item in result["days"]) == total, "activity daily totals differ from the window")
    complete = all(item["coverage"] == "complete" for item in result["days"] if item["start"] != item["end"])
    result.update(observed_at=_stamp(end), collection_started_at=collection_start, stale=observation["stale"],
                  window={"days": 30, "start": _stamp(start), "end": _stamp(end), "basis": "rolling-observation"},
                  total=total, complete=complete)
    return result
