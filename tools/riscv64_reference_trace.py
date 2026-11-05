"""Read bounded, numeric reference-server observations. These do not qualify it.

Schema 1 describes application-to-provider call boundaries. Provider-internal
public API calls are excluded. ``index`` is an exact synthetic fixture ordinal
or zero. ``kind`` is the observed parameter count (0 guard, 2 search), or -1
before a send. Zero timestamp/counter fields can mean unobserved; consult seen.
The first adverse return is an observation, not an inferred deadline or cause.
An EINTR or zero poll result can be followed by successful recovery.
Only errno after negative poll has the reference's documented error meaning.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import io
import json
import os
from pathlib import Path
import re
import stat

LOG_LIMIT = 1024 * 1024
LINE_LIMIT = 4096
RECORD_LIMIT = 2048  # Includes the prefix and final newline.
COUNT_LIMIT = 256
PREFIX = b"ASM_REFERENCE_TRACE="
ERROR_PREFIX = b"ASM_REFERENCE_TRACE_ERROR="
ERROR = "Invalid reference trace evidence."
INT_MAX = (1 << 31) - 1
TIME_MAX = (1 << 63) - 1
TIMESTAMPS = ("start_ns", "connect_ns", "send_ns", "result_ns", "drain_ns", "finish_ns", "end_ns")
RANGES = {
    "schema": (1, 1), "id": (1, COUNT_LIMIT), "index": (0, 16), "seen": (0, 65535),
    "first_api": (0, 15), "first_return": (-1, INT_MAX), "first_errno": (0, 4095),
    "connect_return": (0, 1), "connect_poll": (-1, 4), "socket": (-2, INT_MAX),
    "sends": (0, 1), "send_return": (-1, 1), "flush_return": (-2, 1),
    "consume_return": (-1, 1), "busy_return": (-1, 1), "poll_return": (-2, INT_MAX),
    "poll_errno": (0, 4095), "poll_events": (0, 65535), "poll_revents": (0, 65535),
    "poll_timeout": (-2, INT_MAX), "results": (0, 2), "status": (-1, 12),
    "rows": (-1, INT_MAX), "fields": (-1, INT_MAX), "bytes": (-1, INT_MAX),
    "null_cell": (-1, 1), "poll_ns": (0, TIME_MAX),
}
RANGES.update({name: (0, TIME_MAX) for name in TIMESTAMPS})
RANGES.update({name: (0, INT_MAX) for name in ("flush_calls", "consume_calls", "busy_calls", "poll_calls",
                                             "poll_eintr", "poll_timeouts", "poll_errors")})
ENUMS = {"kind": {-1, 0, 2}, "nonblocking": {-2, -1, 0}}
FIELDS = frozenset(RANGES) | frozenset(ENUMS) | {"sqlstate"}
API_NAMES = ("none", "connect", "connect_poll", "nonblocking", "send", "flush", "consume",
             "socket", "busy", "poll", "status", "rows", "fields", "null_cell", "length", "extra_result")
SEEN_FLAGS = {name: 1 << index for index, name in enumerate((
    "connect", "connect_poll", "nonblocking", "send", "flush", "consume", "socket", "busy",
    "poll", "get_result", "status", "rows", "fields", "null_cell", "length", "finish"))}


def _fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(ERROR)
        result[key] = value
    return result


def _constant(_value):
    raise ValueError(ERROR)


def _record(payload):
    value = None
    try:
        value = json.loads(payload.decode("ascii"), object_pairs_hook=_fields, parse_constant=_constant)
    except (ValueError, UnicodeError, RecursionError):
        pass
    # Raise outside the decoder exception handler. Do not expose its input or
    # attach a decoder exception containing arbitrary server text.
    if not isinstance(value, dict) or value.keys() != FIELDS:
        raise ValueError(ERROR)
    for name, (low, high) in RANGES.items():
        item = value[name]
        if type(item) is not int or not low <= item <= high:
            raise ValueError(ERROR)
    for name, permitted in ENUMS.items():
        item = value[name]
        if type(item) is not int or item not in permitted:
            raise ValueError(ERROR)
    state = value["sqlstate"]
    if type(state) is not str or (state != "" and re.fullmatch(r"[A-Z0-9]{5}", state) is None):
        raise ValueError(ERROR)
    start, end = value["start_ns"], value["end_ns"]
    if start == 0 or end == 0 or end < start:
        raise ValueError(ERROR)
    if any(value[name] != 0 and not start <= value[name] <= end for name in TIMESTAMPS[1:-1]):
        raise ValueError(ERROR)
    return value


def _log(path):
    try:
        if path.is_symlink():
            return None
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > LOG_LIMIT:
                return None
            data = source.read(LOG_LIMIT + 1)
        return data if len(data) <= LOG_LIMIT else None
    except (OSError, ValueError):
        return None


def read_records(path: Path) -> list[dict]:
    """Return only complete schema-1 trace objects from one regular bounded log.

    File errors, producer errors, missing evidence, and invalid records raise
    the same ValueError. Unrelated server lines are neither returned nor logged.
    """
    data = _log(path)
    if data is None or ERROR_PREFIX in data:
        raise ValueError(ERROR)
    records, identities = [], set()
    for line in io.BytesIO(data):
        if len(line) > LINE_LIMIT:
            raise ValueError(ERROR)
        if not line.startswith(PREFIX):
            if PREFIX in line:
                raise ValueError(ERROR)
            continue
        if len(line) > RECORD_LIMIT or not line.endswith(b"\n") or len(records) >= COUNT_LIMIT:
            raise ValueError(ERROR)
        value = _record(line[len(PREFIX):-1])
        if value["id"] in identities:
            raise ValueError(ERROR)
        identities.add(value["id"])
        records.append(value)
    if not records:
        raise ValueError(ERROR)
    return records
