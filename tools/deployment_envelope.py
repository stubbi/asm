"""Bounded cgroup evidence for the fixed shared driver/runtime test profile.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import http.client
import json
import os
from pathlib import Path
import re
import socket
import sys
import time
import unittest

from postgres18_fixture import need

CGROUP = Path("/sys/fs/cgroup")
SAMPLE_PREFIX = "ASM_DEPLOYMENT_ENVELOPE_SAMPLE="
REQUEST_PREFIX = "ASM_DEPLOYMENT_ENVELOPE_REQUEST="
SCOPE = "selected-cnpg18-deployment-envelope"
PROFILE = "deployment-envelope"
MEASUREMENT_SCOPE = "Qualification drivers and test tools share one constrained cgroup with the assembly runtime; PostgreSQL is separate."
FILES = ("memory.max", "memory.current", "memory.peak", "memory.events", "memory.events.local",
         "memory.swap.max", "memory.swap.current", "cpu.max", "cpu.stat")
SUITES = {"baseline": ("test_runtime", "RuntimeTests", 22),
          "capacity": ("test_capacity", "CapacityTests", 12), "envelope": ("test_envelope", "EnvelopeTests", 3)}


def snapshot(directory, phase):
    files = {}
    for name in FILES:
        with (Path(directory) / name).open("rb") as source:
            body = source.read(8193)
        need(0 < len(body) <= 8192, "A required cgroup file is empty or exceeds its bound.")
        files[name] = body.decode("ascii")
    return {"phase": phase, "monotonic_ns": time.monotonic_ns(), "files": files}


def number(value):
    need(isinstance(value, str) and re.fullmatch(r"[0-9]{1,20}\n?", value), "A cgroup counter is not a bounded integer.")
    return int(value)


def counters(value, required):
    need(isinstance(value, str) and 0 < len(value) <= 8192, "A cgroup counter set is absent or exceeds its bound.")
    result = {}
    for line in value.splitlines():
        fields = line.split()
        need(len(fields) == 2 and len(fields[0]) <= 40 and
             re.fullmatch(r"[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)*", fields[0]) and fields[0] not in result,
             "A cgroup counter set is ambiguous.")
        result[fields[0]] = number(fields[1])
    need(set(required) <= result.keys(), "A required cgroup counter is unavailable.")
    return result


def validate_snapshots(samples, cases):
    need(isinstance(cases, list) and 0 < len(cases) <= 128 and len(set(cases)) == len(cases), "The case identity list is incomplete.")
    phases = ["before-suite"] + [phase + case for case in cases for phase in ("before:", "after:")] + ["after-suite"]
    need(isinstance(samples, list) and len(samples) == len(phases), "The cgroup evidence did not close every test boundary.")
    previous_time, previous = 0, {}
    for sample, phase in zip(samples, phases):
        need(isinstance(sample, dict) and set(sample) == {"phase", "monotonic_ns", "files"} and sample["phase"] == phase and
             type(sample["monotonic_ns"]) is int and sample["monotonic_ns"] > previous_time,
             "The cgroup sample order or identity differs.")
        files = sample["files"]
        need(isinstance(files, dict) and set(files) == set(FILES), "The cgroup sample is incomplete.")
        need(number(files["memory.max"]) == 268435456 and number(files["memory.swap.max"]) == 0 and
             number(files["memory.swap.current"]) == 0 and files["cpu.max"].split() == ["100000", "100000"],
             "The actual memory, swap, or CPU limit differs from the fixed profile.")
        need(0 <= number(files["memory.current"]) <= number(files["memory.peak"]) <= 268435456,
             "The current or peak memory exceeds its fixed bound.")
        for name in ("memory.events", "memory.events.local", "cpu.stat"):
            required = ("oom", "oom_kill", "oom_group_kill") if name.startswith("memory") else \
                       ("usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec")
            current = counters(files[name], required)
            need(all(current[key] == 0 for key in required) if name.startswith("memory") else True,
                 "The shared application cgroup recorded an OOM event.")
            need(all(current.get(key, -1) >= value for key, value in previous.get(name, {}).items()),
                 "A cgroup counter moved backwards.")
            previous[name] = current
        previous_time = sample["monotonic_ns"]


def run_suite(suite, samples, stream=None):
    def capture(phase):
        need(len(samples) < 258, "The cgroup sample count exceeds its bound.")
        value = snapshot(CGROUP, phase)
        samples.append(value)
        print(SAMPLE_PREFIX + json.dumps(value, sort_keys=True), flush=True)
    class Result(unittest.TextTestResult):
        def startTest(self, test):
            capture("before:" + test.id())
            super().startTest(test)
        def stopTest(self, test):
            super().stopTest(test)
            capture("after:" + test.id())
    capture("before-suite")
    try:
        return unittest.TextTestRunner(stream=stream or sys.stderr, verbosity=2, resultclass=Result).run(suite)
    finally:
        capture("after-suite")


def observe(records, path, call, *, valid=True):
    """Keep actual transport failures visible without changing the caller's assertions."""
    need(len(records) < 4096, "The raw request record count exceeds its bound.")
    start = time.monotonic_ns()
    record = {"path": path, "valid_request": valid, "status": None, "body_bytes": 0, "outcome": "reset"}
    try:
        response = call()
        record.update(status=response[0], body_bytes=len(response[2]), outcome="complete" if response[0] == 200 else "refused")
        return response
    except (TimeoutError, socket.timeout):
        record["outcome"] = "timeout"
        raise
    except http.client.IncompleteRead as error:
        record.update(outcome="truncated", body_bytes=len(error.partial))
        raise
    except (OSError, http.client.HTTPException) as error:
        record["error"] = type(error).__name__
        raise
    finally:
        record["elapsed_ns"] = time.monotonic_ns() - start
        append_request(records, record)


def append_request(records, record):
    need(len(records) < 4096, "The raw request record count exceeds its bound.")
    request_contract([record])
    records.append(record)
    print(REQUEST_PREFIX + json.dumps(record, sort_keys=True), flush=True)


def request_contract(records):
    need(isinstance(records, list) and len(records) <= 4096, "The raw request results exceed their bound.")
    for record in records:
        need(isinstance(record, dict) and set(record) <= {"path", "valid_request", "status", "body_bytes", "outcome", "elapsed_ns", "error"} and
             {"path", "valid_request", "status", "body_bytes", "outcome", "elapsed_ns"} <= record.keys() and
             isinstance(record["path"], str) and len(record["path"]) <= 4096 and type(record["valid_request"]) is bool and
             (record["status"] is None or type(record["status"]) is int and 100 <= record["status"] <= 599) and
             type(record["body_bytes"]) is int and 0 <= record["body_bytes"] <= 4259840 and
             type(record["elapsed_ns"]) is int and record["elapsed_ns"] >= 0 and
             record["outcome"] in {"complete", "refused", "reset", "truncated", "timeout", "closed"}, "A raw request result is malformed.")
        need(record["outcome"] != "complete" or record["status"] == 200,
             "An unavailable response was relabeled as complete.")
        need(record["outcome"] != "complete" or record["body_bytes"] <= 4194304,
             "An oversized response was relabeled as complete.")
        need(record["outcome"] != "refused" or record["status"] is not None and record["status"] != 200,
             "A refusal lacks its actual HTTP status.")
        need(record["outcome"] != "closed" or not record["valid_request"],
             "A valid request connection closed without a complete response.")
    valid = [record for record in records if record["valid_request"]]
    return {"valid_requests": len(valid), "availability_failures": sum(record["outcome"] != "complete" for record in valid)}
