"""Read bounded canonical-client observations without inferring their cause.

Each record describes one application PGconn. Provider-internal API calls are
excluded. Query ordinals 1/2/3 mean BEGIN/guard/export; route 0 is unknown.
Zero timestamps mean unobserved; a zero CPU clock can also be real. A first
adverse return, including EINTR, is an observation rather than a terminal cause.
No provider text is returned. Raw matched lines retain their original bytes.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import io
import json
import os
from pathlib import Path
import re
import stat

PREFIX = b"ASM_CANONICAL_TRACE="
ERROR_PREFIX = b"ASM_CANONICAL_TRACE_ERROR="
ERROR = "Invalid canonical trace evidence."
LOG_LIMIT = 1048576
RECORD_LIMIT = 4096
COUNT_LIMIT = 256
INT_MAX = (1 << 31) - 1
TIME_MAX = (1 << 63) - 1
API_NAMES = ("none", "connect", "connect_poll", "nonblocking", "socket", "send", "flush",
             "consume", "busy", "poll", "status", "rows", "fields", "null_cell", "length", "guard", "extra_result")
PHASE_NAMES = ("connect", "begin", "guard", "export")
TOP_TIMES = ("start_ns", "start_cpu_ns", "created_ns", "created_cpu_ns", "connect_ns", "connect_cpu_ns",
             "finish_ns", "finish_cpu_ns", "end_ns", "end_cpu_ns", "poll_ns", "poll_cpu_ns")
RANGES = {
    "schema": (1, 1), "id": (1, COUNT_LIMIT), "route": (0, 0), "finish_called": (0, 1),
    "connect_return": (0, 1), "connect_poll": (-1, 4), "socket": (-2, INT_MAX), "sends": (0, 3),
    "active_phase": (0, 3), "first_api": (0, 16), "first_return": (-1, INT_MAX), "first_errno": (0, 4095),
    "poll_calls": (0, INT_MAX), "poll_return": (-2, INT_MAX), "poll_errno": (0, 4095),
    "poll_events": (0, 65535), "poll_revents": (0, 65535), "poll_timeout": (-2, INT_MAX),
    "poll_eintr": (0, INT_MAX), "poll_timeouts": (0, INT_MAX), "poll_errors": (0, INT_MAX),
}
RANGES.update({name: (0, TIME_MAX) for name in TOP_TIMES})
PHASE_TIMES = ("send_ns", "send_cpu_ns", "result_ns", "result_cpu_ns", "drain_ns", "drain_cpu_ns")
PHASE_RANGES = {"ordinal": (1, 3), "send_return": (-1, 1), "results": (0, 2), "status": (-1, 12),
                "rows": (-1, INT_MAX), "fields": (-1, INT_MAX), "null_cell": (-1, 1),
                "bytes": (-1, INT_MAX), "guard": (-1, 1)}
PHASE_RANGES.update({name: (0, TIME_MAX) for name in PHASE_TIMES})
FIELDS = frozenset(RANGES) | {"nonblocking", "phases"}
PHASE_FIELDS = frozenset(PHASE_RANGES) | {"sqlstate"}


def _need(condition):
    if not condition:
        raise ValueError(ERROR)


def _fields(pairs):
    value = {}
    for key, item in pairs:
        _need(key not in value)
        value[key] = item
    return value


def _constant(_value):
    raise ValueError(ERROR)


def _ranges(value, ranges):
    for name, (low, high) in ranges.items():
        _need(type(value[name]) is int and low <= value[name] <= high)


def _record(payload):
    value = None
    try:
        value = json.loads(payload.decode("ascii"), object_pairs_hook=_fields, parse_constant=_constant)
    except (ValueError, UnicodeError, RecursionError):
        pass
    # Raise outside the decoder handler, so its private input is not attached.
    _need(type(value) is dict and value.keys() == FIELDS)
    _ranges(value, RANGES)
    _need(type(value["nonblocking"]) is int and value["nonblocking"] in {-2, -1, 0})
    start, end = value["start_ns"], value["end_ns"]
    start_cpu, end_cpu = value["start_cpu_ns"], value["end_cpu_ns"]
    _need(0 < start <= value["created_ns"] <= end and start_cpu <= value["created_cpu_ns"] <= end_cpu)
    if value["connect_ns"]:
        _need(value["created_ns"] <= value["connect_ns"] <= end and value["connect_poll"] == 3 and
              value["created_cpu_ns"] <= value["connect_cpu_ns"] <= end_cpu)
    else:
        _need(value["connect_cpu_ns"] == 0)
    if value["finish_called"]:
        _need(value["connect_return"] == 1 and value["created_ns"] <= value["finish_ns"] <= end and
              value["created_cpu_ns"] <= value["finish_cpu_ns"] <= end_cpu)
        if value["connect_ns"]:
            _need(value["connect_ns"] <= value["finish_ns"] and value["connect_cpu_ns"] <= value["finish_cpu_ns"])
        upper, upper_cpu = value["finish_ns"], value["finish_cpu_ns"]
    else:
        _need(value["connect_return"] == 0 and value["finish_ns"] == value["finish_cpu_ns"] == 0 and
              value["connect_ns"] == 0 and value["connect_poll"] == -1 and value["sends"] == 0)
        upper, upper_cpu = end, end_cpu
    _need(value["active_phase"] == value["sends"])
    if value["sends"]:
        _need(value["connect_ns"] > 0 and value["nonblocking"] == 0)
    if value["first_api"] == 0:
        _need(value["first_return"] == value["first_errno"] == 0)
    _need(value["poll_eintr"] <= value["poll_errors"] <= value["poll_calls"] and
          value["poll_timeouts"] + value["poll_errors"] <= value["poll_calls"] and
          value["poll_ns"] <= end - start and value["poll_cpu_ns"] <= end_cpu - start_cpu)
    if value["poll_calls"] == 0:
        _need(value["poll_ns"] == value["poll_cpu_ns"] == 0 and
              value["poll_return"] == value["poll_timeout"] == -2 and
              value["poll_errno"] == value["poll_events"] == value["poll_revents"] == 0)
    if value["poll_return"] >= 0:
        _need(value["poll_errno"] == 0)
    phases = value["phases"]
    _need(type(phases) is list and len(phases) == 3)
    previous, previous_cpu = value["connect_ns"], value["connect_cpu_ns"]
    for ordinal, phase in enumerate(phases, 1):
        _need(type(phase) is dict and phase.keys() == PHASE_FIELDS)
        _ranges(phase, PHASE_RANGES)
        _need(phase["ordinal"] == ordinal)
        state = phase["sqlstate"]
        _need(type(state) is str and (state == "" or re.fullmatch(r"[A-Z0-9]{5}", state) is not None))
        if ordinal > value["sends"]:
            _need(all(phase[name] == 0 for name in PHASE_TIMES) and phase["results"] == 0 and
                  all(phase[name] == -1 for name in ("send_return", "status", "rows", "fields", "null_cell", "bytes", "guard")) and state == "")
            continue
        _need(0 < previous <= phase["send_ns"] <= upper and previous_cpu <= phase["send_cpu_ns"] <= upper_cpu)
        if phase["results"]:
            _need(phase["status"] >= 0 and phase["rows"] >= 0 and phase["fields"] >= 0 and
                  phase["send_ns"] <= phase["result_ns"] <= upper and
                  phase["send_cpu_ns"] <= phase["result_cpu_ns"] <= upper_cpu)
        else:
            _need(phase["result_ns"] == phase["result_cpu_ns"] == 0 and
                  all(phase[name] == -1 for name in ("status", "rows", "fields", "null_cell", "bytes", "guard")) and state == "")
        if phase["drain_ns"]:
            _need(max(phase["send_ns"], phase["result_ns"]) <= phase["drain_ns"] <= upper and
                  max(phase["send_cpu_ns"], phase["result_cpu_ns"]) <= phase["drain_cpu_ns"] <= upper_cpu)
        else:
            _need(phase["drain_cpu_ns"] == 0)
        if phase["status"] == 2 and phase["rows"] == phase["fields"] == 1:
            _need(phase["null_cell"] >= 0 and phase["bytes"] >= 0)
        else:
            _need(phase["null_cell"] == phase["bytes"] == -1)
        if ordinal != 2 or phase["status"] != 2 or phase["rows"] != 1 or phase["fields"] != 1 or phase["null_cell"] != 0 or phase["bytes"] != 1:
            _need(phase["guard"] == -1)
        if ordinal < value["sends"]:
            _need(phase["drain_ns"] > 0)
        previous, previous_cpu = phase["drain_ns"], phase["drain_cpu_ns"]
    return value


def _log(path):
    try:
        path = Path(path)
        if path.is_symlink():
            return None
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
        with os.fdopen(descriptor, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > LOG_LIMIT:
                return None
            value = source.read(LOG_LIMIT + 1)
        return value if len(value) <= LOG_LIMIT else None
    except (OSError, ValueError, TypeError):
        return None


def read_trace(path: Path) -> tuple[list[dict], bytes]:
    """Return validated records and only their original matching line bytes."""
    data = _log(path)
    _need(data is not None and ERROR_PREFIX not in data)
    records, identities, raw = [], set(), []
    for line in io.BytesIO(data):
        _need(len(line) <= RECORD_LIMIT)
        if not line.startswith(PREFIX):
            _need(PREFIX not in line)
            continue
        _need(line.endswith(b"\n") and len(records) < COUNT_LIMIT)
        value = _record(line[len(PREFIX):-1])
        _need(value["id"] not in identities)
        identities.add(value["id"])
        records.append(value)
        raw.append(line)
    _need(bool(records))
    return records, b"".join(raw)


def read_records(path: Path) -> list[dict]:
    return read_trace(path)[0]
