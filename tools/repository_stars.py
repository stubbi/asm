"""Cache public GitHub stars for one fixed repository, independently of visits.

Unknown and stale observations never become invented zero activity.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from html import escape
import os
from pathlib import Path
import re
import stat
import tempfile
import threading

from count_format import count_html, exact_count
import registry

REPOSITORY = "stubbi/asm"
REPOSITORY_URL = "https://github.com/" + REPOSITORY
API_URL = "https://api.github.com/repos/" + REPOSITORY
MAX_AGE = 300
MAX_BYTES = 16384
CACHE_ERROR = "GitHub star cache is unavailable."
REFRESH_ERROR = "GitHub stars could not be refreshed."
START, END = "<!-- github-stars:start -->", "<!-- github-stars:end -->"
FIELDS = {"schema", "source", "repository", "observed_at", "stars", "stale", "refresh_error"}


def _clock(value=None):
    if value is None: return datetime.now(timezone.utc)
    if isinstance(value, str):
        registry.require(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|\+00:00)", value) is not None,
                         "GitHub observation must use a UTC timestamp")
        value = datetime.fromisoformat(value.replace("Z", "+00:00"))
    registry.require(isinstance(value, datetime) and value.utcoffset() == timedelta(0)
                     and value.year >= 1970, "invalid GitHub observation time")
    return value


def _unknown(error=None):
    return {"schema": 1, "source": "github", "repository": REPOSITORY,
            "observed_at": None, "stars": None, "stale": True, "refresh_error": error}


def unknown_snapshot():
    """Return an unavailable count without inventing an observation."""
    return _unknown()


def _validated(value, now):
    registry.require(isinstance(value, dict) and set(value) == FIELDS and type(value["schema"]) is int
                     and value["schema"] == 1 and value["source"] == "github" and value["repository"] == REPOSITORY,
                     "invalid GitHub star snapshot")
    registry.require(type(value["stale"]) is bool and value["refresh_error"] in (None, CACHE_ERROR, REFRESH_ERROR),
                     "invalid GitHub star snapshot state")
    result = dict(value)
    if value["stars"] is None:
        registry.require(value["observed_at"] is None and value["stale"], "unknown GitHub count has an observation")
    else:
        registry.require(type(value["stars"]) is int and 0 <= value["stars"] <= 2 ** 53 - 1,
                         "GitHub stars must be a safe nonnegative integer")
        registry.require(isinstance(value["observed_at"], str), "GitHub count has no observation time")
        observed = _clock(value["observed_at"])
        registry.require(observed <= now, "GitHub observation is in the future")
        result["stale"] = result["stale"] or (now - observed).total_seconds() >= MAX_AGE
    return result


def _path(value, create=False):
    path = Path(value).absolute()
    registry.portable_path(path.name)
    aliases = {Path("/var"): Path("/private/var"), Path("/tmp"): Path("/private/tmp")}
    for parent in path.parents:
        try: info = parent.lstat()
        except FileNotFoundError: continue
        trusted = parent in aliases and info.st_uid == 0 and parent.resolve() == aliases[parent]
        registry.require(not stat.S_ISLNK(info.st_mode) or trusted, "GitHub cache ancestors cannot be user symlinks")
    if create: path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try: info = path.lstat()
    except FileNotFoundError: return path
    registry.require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid()
                     and info.st_mode & 0o077 == 0 and info.st_size <= MAX_BYTES,
                     "GitHub cache must be a private owned regular file")
    return path


def load_snapshot(state_path, now=None):
    """Read one bounded cache; an invalid or absent cache cannot disable pages."""
    at = _clock(now)
    try:
        path = _path(state_path)
        if not path.exists(): return _unknown()
        return _validated(registry.strict_json(registry.read_regular(path.parent, path.name, MAX_BYTES)), at)
    except (OSError, ValueError, TypeError):
        return _unknown(CACHE_ERROR)


def _write_cache(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=".asm-github-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(registry.json_bytes(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, _path(path))
    finally:
        if os.path.lexists(temporary): os.unlink(temporary)


def collect(state_path, fetch, now=None):
    """Refresh a due fixed-repository cache; preserve valid bytes on failure."""
    at = _clock(now)
    previous = load_snapshot(state_path, now=at)
    if not previous["stale"]: return previous
    try:
        path = _path(state_path, create=True)
        response = fetch(API_URL)
        registry.require(isinstance(response, dict) and response.get("full_name") == REPOSITORY
                         and response.get("html_url") == REPOSITORY_URL, "GitHub repository identity does not match")
        value = _validated(dict(_unknown(), stars=response.get("stargazers_count"),
                                observed_at=at.isoformat().replace("+00:00", "Z"), stale=False), at)
        _write_cache(_path(path), value)
        return value
    except Exception:
        return dict(previous, stale=True, refresh_error=REFRESH_ERROR)


def render_header(content: str, snapshot, *, now=None) -> str:
    """Replace one marked header link, retaining markers for later projections."""
    if START not in content and END not in content: return content
    registry.require(content.count(START) == content.count(END) == 1 and content.index(START) < content.index(END),
                     "GitHub header requires one ordered marker pair")
    try: value = _validated(snapshot, _clock(now))
    except (ValueError, TypeError): value = _unknown()
    label = "Star on GitHub"
    count, context, observation = "", "", ""
    if value["stars"] is not None and not value["stale"]:
        context = exact_count(value["stars"]) + " stars on GitHub; observed " + value["observed_at"]
        count = '<span class="github-stars-count">' + count_html(value["stars"]) + '<span class="sr-only"> stars</span></span>'
        observation = '<span class="sr-only github-stars-observation">; observed ' + escape(value["observed_at"]) + '</span>'
    link = ('<a class="github-stars" href="' + REPOSITORY_URL + '"' + (' title="' + escape(context, quote=True) + '"' if context else '') +
            '><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">'
            '<path d="m12 3 2.8 5.7 6.3.9-4.6 4.4 1.1 6.3-5.6-3-5.6 3 1.1-6.3L2.9 9.6l6.3-.9Z"/></svg><span>' + label + '</span>' + count + observation + '</a>')
    before, after = content.split(START, 1)[0], content.split(END, 1)[1]
    return before + START + link + END + after


class RepositoryStats:
    """One independent refresh worker; request snapshots use memory only."""
    def __init__(self, state_path, fetch, refresh_seconds=MAX_AGE):
        registry.require(type(refresh_seconds) in (int, float) and 0 < refresh_seconds <= 86400,
                         "invalid GitHub refresh interval")
        self.path, self.fetch, self.interval = state_path, fetch, refresh_seconds
        self._value = load_snapshot(state_path)
        self._lock, self._stop, self._thread = threading.Lock(), threading.Event(), None

    def start(self):
        with self._lock:
            if self._thread is not None and self._thread.is_alive(): return
            self._stop.clear()
            self._thread = threading.Thread(target=self._run, name="asm-github-stars", daemon=True)
            self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            value = collect(self.path, self.fetch)
            with self._lock:
                if value["stars"] is None and self._value["stars"] is not None:
                    value = dict(self._value, stale=True, refresh_error=value["refresh_error"])
                self._value = value
            delay = self.interval
            if not value["stale"]:
                remaining = MAX_AGE - (_clock() - _clock(value["observed_at"])).total_seconds()
                delay = min(delay, max(0.01, remaining))
            if self._stop.wait(delay): break

    def snapshot(self):
        with self._lock:
            try: return _validated(deepcopy(self._value), _clock())
            except (ValueError, TypeError): return _unknown(CACHE_ERROR)

    def stop(self):
        self._stop.set()
        if self._thread is not None: self._thread.join(timeout=1)
