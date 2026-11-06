"""UNQUALIFIED guest collection for the unchanged canonical export method.

SPDX-License-Identifier: AGPL-3.0-or-later
The signal timer detects failure. The host's bounded attached process supplies
the final remaining-budget kill; this is no independent hard target watchdog.
"""
from contextlib import contextmanager
import hashlib
import http.client
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from types import SimpleNamespace
import unittest

import canonical_riscv_phases as core
import canonical_riscv_trace as trace_reader

WORK, SCOPE, CANONICAL, METHOD, ROUTES = core.WORK, core.SCOPE, core.CANONICAL, core.METHOD, core.ROUTES
ERROR = "The bounded canonical guest is incomplete."
GUEST_PREFIX = b"ASM_CANONICAL_GUEST="
GUEST_BYTES, TRACE_BYTES = 768 * 1024, 128 * 1024
LIMITS = (
    "One shared guest180s envelope; no timer reset between arms.",
    "HTTP uses the original3s socket inactivity cap within that shared deadline; no3s whole-response claim.",
    "A signal timer is a failure detector; host bounded_process supplies the final kill.",
    "Fixed control-then-traced order, shared TLS fixtures and caches, and observer overhead limit comparisons.",
    "Memory peak is cumulative for the container lifetime.",
    "Connection route association is unknown; missing summaries remain inconclusive.",
    "Original failed executable/image equality is unestablished; original16/12 gates are not qualified.",
    "Only negative poll errno has documented error meaning; other errno values are preserved context.",
)
FAILURES = {"guest-contract", "input-binding", "runtime-inventory", "preflight", "control", "traced", "trace",
            "deadline", "cleanup", "guest-budget", "stream-validation"}
OUTPUTS = {"asm-hub", "abi-check", "canonical_libpq_trace.so", "libcanonical_provider.so", "canonical_trace_check"}
RESULTS = {"tests_run", "failures", "errors", "skipped", "expected_failures", "unexpected_successes"}
ORDINAL = "HTTP call-entry ordinal; not submission or completion order"
LIBRARIES = {
    "libmicrohttpd": "/opt/asm/mhd/lib/libmicrohttpd.so.12", "libpq": "/opt/asm/postgres/lib/libpq.so.5",
    "libssl": "/usr/lib/riscv64-linux-gnu/libssl.so.3", "libcrypto": "/usr/lib/riscv64-linux-gnu/libcrypto.so.3",
    "ea_libc": "/usr/lib/riscv64-linux-gnu/libc.so.6", "ea_loader": "/usr/lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1",
}


def _need(condition):
    if not condition:
        raise ValueError(ERROR)


class GuestDeadline(KeyboardInterrupt):
    pass


@contextmanager
def _watchdog(deadline):
    _need(threading.current_thread() is threading.main_thread() and signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0))
    previous = signal.getsignal(signal.SIGALRM)
    def expired(_signal, _frame):
        raise GuestDeadline()
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, core.remaining(deadline))
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def _guest_contract(context):
    _need(platform.system() == "Linux" and platform.machine() == "riscv64" and
          os.geteuid() == os.getegid() == 65532)
    _need(not any(key.startswith(("PG", "GITHUB_", "GH_")) or key in
                  {"LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"} for key in os.environ))
    _need(set(os.getgroups()) <= {65532} and Path(context) == Path("/inputs"))
    _need(os.statvfs("/").f_flag & os.ST_RDONLY and os.statvfs(context).f_flag & os.ST_RDONLY and
          os.statvfs("/tmp").f_flag & os.ST_NOEXEC)
    status = dict(line.split(":", 1) for line in core.bounded_file(Path("/proc/self/status"), 65536).decode("ascii").splitlines() if ":" in line)
    _need(status.get("NoNewPrivs", "").strip() == "1" and int(status.get("CapEff", "1").strip(), 16) == 0 and
          not Path("/var/run/secrets/kubernetes.io/serviceaccount/token").exists())


class NumericResult(unittest.TestResult):
    """Retain original result counts without formatting exception messages."""
    def addFailure(self, test, err): self.failures.append((None, "assertion"))
    def addError(self, test, err): self.errors.append((None, "error"))
    def addSkip(self, test, reason): self.skipped.append((None, "skip"))
    def addExpectedFailure(self, test, err): self.expectedFailures.append((None, "expected"))
    def addUnexpectedSuccess(self, test): self.unexpectedSuccesses.append(None)
    def addSubTest(self, test, subtest, err):
        if err is not None:
            (self.failures if issubclass(err[0], test.failureException) else self.errors).append((None, "subtest"))

    def counts(self):
        return {"tests_run": self.testsRun, "failures": len(self.failures), "errors": len(self.errors),
                "skipped": len(self.skipped), "expected_failures": len(self.expectedFailures),
                "unexpected_successes": len(self.unexpectedSuccesses)}


def _run_cohort(cls, deadline, budget):
    records, lock, sequence = [], threading.Lock(), 0
    result = NumericResult()
    original, own = cls.__dict__.get("raw_request"), "raw_request" in cls.__dict__
    def observed(selected, path, method="GET", body=None):
        nonlocal sequence
        _need(path in ROUTES and method == "GET" and body is None)
        with lock:
            sequence += 1
            ordinal = sequence
        _need(ordinal <= 8)
        started = time.monotonic_ns()
        value = {"schema": 1, "ordinal": ordinal, "route": ROUTES.index(path) + 1, "status": None,
                 "bytes": 0, "sha256": hashlib.sha256(b"").hexdigest(), "elapsed_ns": 0,
                 "transport": "reset", "bytes_equal": False, "media_ok": False, "cache_ok": False,
                 "nosniff_ok": False, "lf_ok": False, "size_ok": False, "declared_bytes": None}
        headers, payload = {}, b""
        connection = None
        try:
            request_deadline = deadline
            connection = http.client.HTTPConnection("127.0.0.1", selected.port, timeout=min(budget.remaining(3), core.remaining(request_deadline)))
            connection.connect()
            connection.sock.settimeout(min(budget.remaining(3), core.remaining(request_deadline)))
            connection.request(method, path, body=body)
            maximum = 4194304 if value["route"] == 4 else 1048576
            code, headers, payload = core.read_http(connection.sock, maximum=maximum, deadline=request_deadline, observation=value, inactivity=3)
            normalized = {key.lower(): item for key, item in headers.items()}
            value.update(transport="complete", bytes_equal=payload == selected.exports[path],
                         media_ok=normalized.get("content-type") == ("application/json" if value["route"] == 4 else "text/tab-separated-values; charset=utf-8"),
                         cache_ok=normalized.get("cache-control") == "no-store", nosniff_ok=normalized.get("x-content-type-options") == "nosniff",
                         lf_ok=payload.endswith(b"\n"), size_ok=0 < len(payload) <= maximum)
            return code, headers, payload
        except TimeoutError:
            value["transport"] = "timeout"
            raise
        except http.client.IncompleteRead:
            value["transport"] = "truncated"
            raise
        except (ValueError, http.client.HTTPException):
            value["transport"] = "protocol"
            raise
        except OSError:
            value["transport"] = "reset"
            raise
        finally:
            if connection is not None: connection.close()
            value["elapsed_ns"] = time.monotonic_ns() - started
            with lock:
                records.append(value)
    cls.raw_request = classmethod(observed)
    start, completed = time.monotonic_ns(), False
    report = {"cohort_start_ns": start, "application_passed": False}
    try:
        cls(METHOD).run(result)
        completed = True
    except GuestDeadline as error:
        error.partial_cohort = report
        raise
    finally:
        if own: cls.raw_request = original
        else: del cls.raw_request
        report.update(cohort_end_ns=time.monotonic_ns(), http=sorted(records, key=lambda value: value["ordinal"]),
                      original_result=result.counts(), original_method_completed=completed)
        if len(records) == 8:
            report["http_summary"] = core.http_contract(report["http"])
            counts = result.counts()
            report["application_passed"] = (completed and counts["tests_run"] == 1 and
                not any(counts[key] for key in ("failures", "errors", "skipped", "expected_failures", "unexpected_successes")) and
                report["http_summary"]["application_passed"])
    return report


def _raw_identity(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        _need(stat.S_ISREG(info.st_mode))
        data = stream.read(trace_reader.LOG_LIMIT + 1)
    if info.st_size <= trace_reader.LOG_LIMIT and len(data) == info.st_size:
        return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    return {"bytes": info.st_size, "sha256": None, "prefix_bytes": len(data),
            "prefix_sha256": hashlib.sha256(data).hexdigest()}


def _trace(path, destination, start, end):
    result = {"valid": False, "complete": False, "records": [], "cohort_ids": [],
              "route_association": "unknown", "failure_reason": "invalid-trace"}
    raw = b""
    try:
        result["raw_identity"] = _raw_identity(path)
        records, raw = trace_reader.read_trace(path)
        _need(len(raw) <= TRACE_BYTES)
        inside = [item["id"] for item in records if start <= item["start_ns"] and item["end_ns"] <= end]
        overlap = [item["id"] for item in records if item["start_ns"] < end and item["end_ns"] > start and item["id"] not in inside]
        complete = len(inside) == 8 and not overlap
        result.update(valid=True, complete=complete, records=records, cohort_ids=inside,
                      failure_reason=None if complete else "connection-missingness-or-overlap")
    except (OSError, ValueError, TypeError):
        raw = b""
    with destination.open("xb") as stream:
        stream.write(raw)
    result["identity"] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
    return result


def _runtime(context):
    """Execute only source bytes already bound by context_contract."""
    paths = (("registry", "tools/registry.py"), ("registry_admin", "tools/registry_admin.py"),
             ("local_postgres", "experiments/assembly-server/local_postgres.py"), ("_canonical_runtime", "server/test_runtime.py"))
    saved, path = {}, list(sys.path)
    try:
        for name, relative in paths:
            saved[name] = sys.modules.get(name)
            source = context / "source" / relative
            spec = importlib.util.spec_from_file_location(name, source)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            exec(compile(core.bounded_file(source, 256 * 1024), str(source), "exec"), module.__dict__)
        return module
    finally:
        sys.path[:] = path
        for name, value in saved.items():
            if value is None: sys.modules.pop(name, None)
            else: sys.modules[name] = value


def _timeout(budget, deadline, cap, *, cleanup=False):
    return min(budget.remaining(cap, cleanup=cleanup), core.remaining(deadline))


def _preflight(context, modules, build, budget, deadline, directory, result=None):
    result = {} if result is None else result
    env = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "HOME=/nonexistent", "LC_ALL=C", "TZ=UTC", "QEMU_LD_PREFIX=/"]
    for name in ("abi-check", "canonical_trace_check"):
        log = directory / (".preflight-" + name)
        arguments = [*env]
        if name == "canonical_trace_check":
            arguments += ["LD_LIBRARY_PATH=" + str(context / "canonical-build"),
                          "LD_PRELOAD=" + str(context / "canonical-build/canonical_libpq_trace.so")]
        else:
            arguments += ["LD_LIBRARY_PATH=/opt/asm/mhd/lib:/opt/asm/postgres/lib"]
        arguments += [str(context / "canonical-build" / name)]
        process = modules.combined.bounded_process(arguments, log, timeout=_timeout(budget, deadline, 30), max_bytes=65536)
        data = core.bounded_file(log, 65536)
        result[name] = {"process": process, "output": {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}}
        try:
            _need(process["outcome"] == "pass")
            if name == "abi-check": _need(not data)
            else:
                records = trace_reader.read_records(log)
                _need(len(records) == 1 and records[0]["sends"] == 3 and records[0]["first_api"] == 0)
                result[name]["records"] = records
        finally:
            log.unlink(missing_ok=True)
    return result


def _inventory(context, modules, build, budget, deadline, directory):
    # The pinned helper supplies bounded ldd traversal and file hashing. Its
    # reference-specific comparison prose is replaced before any serialization.
    previous = modules.observations.combined
    bounded = modules.combined.bounded_process
    def limited(arguments, log, *, timeout=20, **kwargs):
        return bounded(arguments, log, timeout=_timeout(budget, deadline, min(20, timeout)), **kwargs)
    modules.observations.combined = SimpleNamespace(bounded_process=limited)
    try:
        observed = modules.observations.runtime_inventory(context / "canonical-build/asm-hub", {}, directory)
    finally:
        modules.observations.combined = previous
    current = observed["current"]
    for value in current.values(): value["comparison_to_failed_run"] = "unestablished"
    result = {"current": current, "failed_canonical_equality": "unestablished",
              "ldd_output": {key: {"bytes": len(value.encode()), "sha256": hashlib.sha256(value.encode()).hexdigest()}
                             for key, value in observed["ldd"].items()}, "libraries": {}}
    _need(all("not found" not in text for text in observed["ldd"].values()))
    for name, path in LIBRARIES.items():
        actual = core.identity(Path(path).resolve(strict=True))
        _need(all(build["libraries"][name].get(key) == value for key, value in actual.items()))
        result["libraries"][name] = dict(actual, failed_canonical_equality="unestablished")
    return result


def _probe(cls, deadline, budget):
    deadline = min(deadline, time.monotonic() + budget.remaining(3))
    observation = {}
    connection = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=core.remaining(deadline))
    try:
        connection.connect()
        connection.sock.settimeout(core.remaining(deadline))
        connection.request("GET", "/api/v2/status")
        code, _, body = core.read_http(connection.sock, maximum=16384, deadline=deadline, observation=observation)
    finally:
        connection.close()
    value = core.object_json(body)
    _need(code == 200 and value.get("source_revision") == CANONICAL and value.get("application_language") == "assembly")


def _stop(process, budget, deadline):
    if process is None: return {"complete": True, "exit_status": None, "forced": False}
    forced = False
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=_timeout(budget, deadline, 3, cleanup=True))
        except (ValueError, TimeoutError, subprocess.TimeoutExpired):
            process.kill(); forced = True
            try:
                process.wait(timeout=_timeout(budget, deadline, 2, cleanup=True))
            except (ValueError, TimeoutError, subprocess.TimeoutExpired):
                pass
    return {"complete": process.poll() is not None, "exit_status": process.returncode, "forced": forced}


def _run_arm(cls, runtime, arm, budget, deadline, report, *, initialize):
    started = time.monotonic_ns()
    report.update(label=arm, collector_complete=False, application_passed=False, original_method="RuntimeTests." + METHOD,
                  ordinal_semantics=ORDINAL, preload=arm == "traced")
    cls._canonical_traced = arm == "traced"
    try:
        if initialize:
            cls.setUpClass()
        else:
            cls.port = runtime.free_port()
            cls.log = (cls.base / "canonical-traced.log").open("wb")
            cls.server = subprocess.Popen([str(cls.binary), "serve"], env=cls.environment(), stdout=cls.log, stderr=cls.log)
            ready = min(deadline, time.monotonic() + 5)
            while True:
                _need(cls.server.poll() is None)
                try:
                    _probe(cls, ready, budget)
                    break
                except (OSError, TimeoutError):
                    core.remaining(ready); time.sleep(0.01)
        _probe(cls, deadline, budget)
        report["source_revision"] = CANONICAL
        report["before"] = core.snapshot(Path("/sys/fs/cgroup"), "before")
        report.update(_run_cohort(cls, deadline, budget))
    except GuestDeadline as error:
        report.update(getattr(error, "partial_cohort", {}))
        report["failure_reason"] = "deadline"
        raise
    finally:
        try:
            report["after"] = core.snapshot(Path("/sys/fs/cgroup"), "after")
        finally:
            try:
                report["cleanup"] = _stop(getattr(cls, "server", None), budget, deadline + 15)
            finally:
                if hasattr(cls, "log"): cls.log.close()
                report["elapsed_ns"] = time.monotonic_ns() - started
        if "before" in report:
            core.snapshot_contract(report["before"], report["after"])
            report["resources"] = core.resource_assessment(report["before"], report["after"])
        if "http_summary" in report:
            counts = report["original_result"]
            report["collector_complete"] = (report["cleanup"]["complete"] and counts["tests_run"] == 1 and
                counts["skipped"] == counts["expected_failures"] == counts["unexpected_successes"] == 0 and
                report["original_method_completed"] and
                report.get("resources", {}).get("configured_budget") is True and "failure_reason" not in report)
    return cls.base / ("canonical-traced.log" if arm == "traced" else "server.log")


def _cleanup_fixture(cls, budget, deadline):
    process = getattr(getattr(cls, "cluster", None), "process", None)
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=_timeout(budget, deadline, 5, cleanup=True))
        except (ValueError, TimeoutError, subprocess.TimeoutExpired):
            os.killpg(process.pid, signal.SIGKILL)
            try:
                process.wait(timeout=_timeout(budget, deadline, 2, cleanup=True))
            except (ValueError, TimeoutError, subprocess.TimeoutExpired):
                pass
    if process is not None and process.poll() is None:
        return False
    cls.doClassCleanups()
    return not getattr(cls, "tearDown_exceptions", [])


def _keys(value, required, optional=()):
    _need(type(value) is dict and set(required) <= value.keys() <= set(required) | set(optional))


def _integer(value, low=0, high=(1 << 63) - 1):
    _need(type(value) is int and low <= value <= high)


def _hash(value, digits=64):
    _need(type(value) is str and re.fullmatch(r"[0-9a-f]{" + str(digits) + r"}", value) is not None)


def _identity(value, maximum=64 * 1024 * 1024):
    _keys(value, {"bytes", "sha256"})
    _integer(value["bytes"], 0, maximum); _hash(value["sha256"])


def _records(records, maximum=trace_reader.COUNT_LIMIT):
    _need(type(records) is list and len(records) <= maximum)
    ids = []
    for value in records:
        payload = json.dumps(value, separators=(",", ":"), allow_nan=False).encode("ascii")
        _need(len(payload) + len(trace_reader.PREFIX) + 1 <= trace_reader.RECORD_LIMIT)
        trace_reader._record(payload)
        ids.append(value["id"])
    _need(len(set(ids)) == len(ids))


def _http(records):
    # Reuse the full contract for each partial record by completing only its
    # validation fixture. The published list stays unchanged and never padded.
    _need(type(records) is list and len(records) <= 8)
    ids = []
    for value in records:
        _need(type(value) is dict and type(value.get("route")) is int and 1 <= value["route"] <= 4)
        copies = [dict(value, ordinal=index, route=(index - 1) // 2 + 1) for index in range(1, 9)]
        core.http_contract(copies)
        _integer(value["ordinal"], 1, 8)
        ids.append(value["ordinal"])
    _need(len(set(ids)) == len(ids) and all(sum(value["route"] == route for value in records) <= 2 for route in range(1, 5)))
    if len(records) == 8: return core.http_contract(records)


def _cleanup(value):
    _keys(value, {"complete", "exit_status", "forced"})
    _need(type(value["complete"]) is bool and type(value["forced"]) is bool)
    if value["exit_status"] is not None: _integer(value["exit_status"], -(1 << 31), (1 << 31) - 1)


def _arm(value):
    _keys(value, {"label", "collector_complete", "application_passed", "original_method", "ordinal_semantics", "preload"},
          {"source_revision", "before", "after", "http", "cohort_start_ns", "cohort_end_ns", "original_result",
           "original_method_completed", "http_summary", "cleanup", "elapsed_ns", "resources", "failure_reason"})
    _need(value["label"] in {"control", "traced"} and type(value["label"]) is str and
          value["original_method"] == "RuntimeTests." + METHOD and value["ordinal_semantics"] == ORDINAL and
          value["preload"] is (value["label"] == "traced"))
    for key in ("collector_complete", "application_passed", "original_method_completed"):
        if key in value: _need(type(value[key]) is bool)
    if "source_revision" in value: _need(value["source_revision"] == CANONICAL)
    if "failure_reason" in value: _need(type(value["failure_reason"]) is str and value["failure_reason"] in FAILURES)
    for key in ("cohort_start_ns", "cohort_end_ns", "elapsed_ns"):
        if key in value: _integer(value[key])
    if "cohort_end_ns" in value: _need(0 < value.get("cohort_start_ns", 0) <= value["cohort_end_ns"])
    for key in ("before", "after"):
        if key in value:
            core.validate_snapshot(value[key]); _need(value[key]["phase"] == key)
    if "cleanup" in value: _cleanup(value["cleanup"])
    if "original_result" in value:
        _keys(value["original_result"], RESULTS)
        for key, item in value["original_result"].items(): _integer(item, 0, 1 if key == "tests_run" else 8)
    summary = _http(value["http"]) if "http" in value else None
    if "http_summary" in value:
        _keys(value["http_summary"], {"requests", "complete", "application_passed", "availability_failures"})
        _need(summary is not None and value["http_summary"] == summary and
              type(value["http_summary"]["application_passed"]) is bool)
        for key in ("requests", "complete", "availability_failures"): _integer(value["http_summary"][key], 0, 8)
    if "resources" in value:
        resource = value["resources"]
        _keys(resource, {"configured_budget", "peak_exceeded_budget", "current_exceeded_budget", "oom_delta", "memory_peak_scope"})
        for key in ("configured_budget", "peak_exceeded_budget", "current_exceeded_budget"): _need(type(resource[key]) is bool)
        _keys(resource["oom_delta"], (), {"oom", "oom_kill", "oom_group_kill"})
        for item in resource["oom_delta"].values(): _integer(item, -(1 << 64) + 1, (1 << 64) - 1)
        _need(resource["memory_peak_scope"] == "container-lifetime-cumulative" and "before" in value and "after" in value and
              resource == core.resource_assessment(value["before"], value["after"]))
    counts = value.get("original_result", {})
    if value["application_passed"]:
        _need(summary is not None and summary["application_passed"] and value.get("original_method_completed") is True and
              counts.get("tests_run") == 1 and not any(counts.get(key, 1) for key in RESULTS - {"tests_run"}))
    if value["collector_complete"]:
        _need({"source_revision", "before", "after", "http_summary", "cohort_start_ns", "cohort_end_ns", "cleanup", "resources", "elapsed_ns"} <= value.keys() and
              value.get("original_method_completed") is True and counts.get("tests_run") == 1 and
              all(counts.get(key) == 0 for key in ("skipped", "expected_failures", "unexpected_successes")) and
              value["cleanup"]["complete"] is True and value["resources"]["configured_budget"] is True and "failure_reason" not in value)
        core.snapshot_contract(value["before"], value["after"])
        _need(value["before"]["monotonic_ns"] <= value["cohort_start_ns"] <= value["cohort_end_ns"] <= value["after"]["monotonic_ns"])


def _path(value):
    _need(type(value) is str and len(value) <= 512 and re.fullmatch(r"/[A-Za-z0-9_./+:-]+", value) is not None and
          not any(item in {".", ".."} for item in value.split("/")) and
          value.startswith(("/usr/", "/lib/", "/lib64/", "/opt/asm/", "/inputs/canonical-build/")))


def _trace_contract(value):
    _keys(value, {"valid", "complete", "records", "cohort_ids", "route_association", "failure_reason", "identity"}, {"raw_identity"})
    _need(type(value["valid"]) is bool and type(value["complete"]) is bool and value["route_association"] == "unknown" and
          value["failure_reason"] in {None, "invalid-trace", "connection-missingness-or-overlap", "stream-validation"})
    _identity(value["identity"], TRACE_BYTES); _records(value["records"])
    _need(type(value["cohort_ids"]) is list and len(value["cohort_ids"]) <= 8)
    for item in value["cohort_ids"]: _integer(item, 1, 256)
    _need(len(set(value["cohort_ids"])) == len(value["cohort_ids"]) and set(value["cohort_ids"]) <= {item["id"] for item in value["records"]})
    if "raw_identity" in value:
        raw = value["raw_identity"]
        if type(raw) is dict and raw.get("sha256") is None:
            _keys(raw, {"bytes", "sha256", "prefix_bytes", "prefix_sha256"})
            _integer(raw["bytes"], trace_reader.LOG_LIMIT + 1); _integer(raw["prefix_bytes"], 0, trace_reader.LOG_LIMIT + 1); _hash(raw["prefix_sha256"])
        else: _identity(raw, trace_reader.LOG_LIMIT)
    if not value["valid"]: _need(not value["complete"] and not value["records"] and not value["cohort_ids"] and value["identity"]["bytes"] == 0)
    if value["complete"]: _need(value["valid"] and len(value["cohort_ids"]) == 8 and value["failure_reason"] is None)


def validate_guest_report(value):
    """Reject unknown fields and provider text before publishing any guest JSON."""
    try:
        _keys(value, {"schema", "scope", "qualification", "collector_complete", "application_qualified", "native_qualified", "release_qualified",
                      "canonical_revision", "arms", "cleanup_complete", "limits", "elapsed_ns"},
              {"failure_reason", "inputs", "diagnostic_revision", "started_ns", "guest_deadline_ns", "cleanup_reserve_seconds", "build", "preflight", "runtime_inventory", "trace"})
        _need(type(value["schema"]) is int and value["schema"] == 1 and value["scope"] == SCOPE and value["qualification"] == "UNQUALIFIED" and
              value["canonical_revision"] == CANONICAL and type(value["limits"]) is list and value["limits"] == list(LIMITS))
        _need(all(value[key] is False for key in ("application_qualified", "native_qualified", "release_qualified")))
        for key in ("collector_complete", "cleanup_complete"): _need(type(value[key]) is bool)
        _integer(value["elapsed_ns"])
        if "failure_reason" in value: _need(type(value["failure_reason"]) is str and value["failure_reason"] in FAILURES)
        if "diagnostic_revision" in value: _hash(value["diagnostic_revision"], 40)
        for key in ("started_ns", "guest_deadline_ns"):
            if key in value: _integer(value[key], 1)
        if "cleanup_reserve_seconds" in value: _need(type(value["cleanup_reserve_seconds"]) is int and value["cleanup_reserve_seconds"] == 15)
        if "inputs" in value:
            inputs = value["inputs"]
            _keys(inputs, {"canonical_revision", "diagnostic_revision", "sdk_revision", "trees", "observer", "observer_test", "started_ns", "deadline_ns"})
            _need(inputs["canonical_revision"] == CANONICAL and inputs["diagnostic_revision"] == value.get("diagnostic_revision") and inputs["sdk_revision"] == core.SDK_REVISION)
            _hash(inputs["diagnostic_revision"], 40); _keys(inputs["trees"], {"source", "runner", "sdk"})
            for item in inputs["trees"].values(): _hash(item)
            for key in ("observer", "observer_test"): _identity(inputs[key], 256 * 1024)
            for key in ("started_ns", "deadline_ns"): _integer(inputs[key], 1)
            _need(inputs["deadline_ns"] - inputs["started_ns"] == 600000000000)
        if "build" in value:
            build = value["build"]
            _keys(build, {"identity", "outputs", "failed_canonical_equality", "source_rebuilt"}); _identity(build["identity"], 1024 * 1024)
            _need(build["failed_canonical_equality"] == "unestablished" and build["source_rebuilt"] is True); _keys(build["outputs"], OUTPUTS)
            for item in build["outputs"].values():
                _keys(item, {"bytes", "sha256", "elf_machine", "elf_flags", "mode"})
                _identity({key: item[key] for key in ("bytes", "sha256")})
                for key, expected in (("elf_machine", 243), ("elf_flags", 5)):
                    _need(type(item[key]) is int and item[key] == expected)
                _need(type(item["mode"]) is str and item["mode"] == "0555")
        if "runtime_inventory" in value:
            inventory = value["runtime_inventory"]
            _keys(inventory, {"current", "failed_canonical_equality", "ldd_output", "libraries"})
            _need(inventory["failed_canonical_equality"] == "unestablished" and type(inventory["current"]) is dict and 0 < len(inventory["current"]) <= 64)
            for path, item in inventory["current"].items():
                _path(path); _keys(item, {"resolved_path", "bytes", "sha256", "comparison_to_failed_run"}); _path(item["resolved_path"])
                _identity({key: item[key] for key in ("bytes", "sha256")}); _need(item["comparison_to_failed_run"] == "unestablished")
            _keys(inventory["ldd_output"], {"server", "postgres", "python"})
            for item in inventory["ldd_output"].values(): _identity(item, 131072)
            _keys(inventory["libraries"], LIBRARIES)
            for item in inventory["libraries"].values():
                _keys(item, {"bytes", "sha256", "failed_canonical_equality"}); _need(item["failed_canonical_equality"] == "unestablished")
                _identity({key: item[key] for key in ("bytes", "sha256")})
        if "preflight" in value:
            _keys(value["preflight"], (), {"abi-check", "canonical_trace_check"})
            for key, item in value["preflight"].items():
                _keys(item, {"process", "output"}, {"records"}); _identity(item["output"], 65536)
                process = item["process"]
                _keys(process, {"outcome", "exit_code", "failure", "bytes", "seconds"})
                _need(process["outcome"] in {"pass", "fail"} and process["failure"] in {None, "deadline", "byte-limit"})
                if process["exit_code"] is not None: _integer(process["exit_code"], -(1 << 31), (1 << 31) - 1)
                _integer(process["bytes"], 0, 65537)
                _need(type(process["seconds"]) in (int, float) and math.isfinite(process["seconds"]) and 0 <= process["seconds"] <= 180)
                if "records" in item: _need(key == "canonical_trace_check"); _records(item["records"], 1)
        _need(type(value["arms"]) is list and len(value["arms"]) <= 2)
        for index, arm in enumerate(value["arms"]):
            _arm(arm); _need(arm["label"] == ("control", "traced")[index])
        if "trace" in value: _trace_contract(value["trace"])
        if value["collector_complete"]:
            _need({"inputs", "build", "preflight", "runtime_inventory", "trace", "started_ns", "guest_deadline_ns", "cleanup_reserve_seconds"} <= value.keys() and
                  len(value["arms"]) == 2 and all(item["collector_complete"] for item in value["arms"]) and value["cleanup_complete"] is True and
                  value["trace"]["complete"] is True and value["elapsed_ns"] <= 180000000000 and "failure_reason" not in value)
            _need(set(value["preflight"]) == {"abi-check", "canonical_trace_check"} and
                  all(item["process"]["outcome"] == "pass" and item["process"]["exit_code"] == 0 and item["process"]["failure"] is None and
                      item["process"]["bytes"] == item["output"]["bytes"] for item in value["preflight"].values()))
            _need(value["preflight"]["abi-check"]["output"]["bytes"] == 0)
            smoke = value["preflight"]["canonical_trace_check"].get("records", [])
            _need(len(smoke) == 1 and smoke[0]["sends"] == 3 and smoke[0]["first_api"] == 0)
        return value
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeError, OverflowError, RecursionError):
        raise ValueError(ERROR) from None


def _emit(report, trace_path=None):
    """Emit one controlled JSON line and only revalidated numeric trace lines."""
    raw = b""
    if trace_path is not None and trace_path.is_file():
        try:
            if trace_path.stat().st_size:
                records, raw = trace_reader.read_trace(trace_path)
                _need(len(raw) <= TRACE_BYTES and records == report["trace"]["records"] and
                      {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()} == report["trace"]["identity"])
        except (OSError, ValueError, KeyError, TypeError):
            raw = b""
            report["collector_complete"] = False
            report["failure_reason"] = "stream-validation"
            if "trace" in report:
                report["trace"].update(valid=False, complete=False, records=[], cohort_ids=[], identity={"bytes": 0, "sha256": hashlib.sha256(b"").hexdigest()})
    validate_guest_report(report)
    payload = json.dumps(report, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("ascii")
    _need(len(GUEST_PREFIX) + len(payload) + 1 <= GUEST_BYTES)
    sys.stdout.buffer.write(GUEST_PREFIX + payload + b"\n" + raw)
    sys.stdout.buffer.flush()
    return payload


def run_inside(context: Path, output: Path) -> int:
    report = {"schema": 1, "scope": SCOPE, "qualification": "UNQUALIFIED", "collector_complete": False,
              "application_qualified": False, "native_qualified": False, "release_qualified": False,
              "canonical_revision": CANONICAL, "arms": [], "cleanup_complete": False,
              "limits": list(LIMITS)}
    context, output = Path(context), Path(output)
    cls, budget, traced_log, own_work = None, None, None, False
    started = time.monotonic_ns()
    stage, deadline = "guest-contract", None
    try:
        _guest_contract(context)
        _need(output == WORK / "qualification.json" and not WORK.exists() and not WORK.is_symlink())
        WORK.mkdir(mode=0o700)
        own_work = True
        stage = "input-binding"
        receipt, modules = core.context_contract(context, readonly_guest=True)
        budget = core.Budget(receipt["started_ns"], receipt["deadline_ns"])
        deadline = min(started / 1000000000 + 180, time.monotonic() + budget.remaining(180))
        work_deadline = deadline - 15
        revision = receipt["diagnostic_revision"]
        _need(type(revision) is str and re.fullmatch(r"[0-9a-f]{40}", revision) is not None)
        inputs = {key: receipt[key] for key in ("canonical_revision", "diagnostic_revision", "sdk_revision", "trees", "observer", "observer_test", "started_ns", "deadline_ns")}
        report.update(inputs=inputs, diagnostic_revision=revision, started_ns=started,
                      guest_deadline_ns=int(deadline * 1000000000), cleanup_reserve_seconds=15)
        build = core.build_contract(context)
        report["build"] = {"identity": core.identity(context / "canonical-build/manifest.json"),
                           "outputs": {name: {key: value[key] for key in ("bytes", "sha256", "elf_machine", "elf_flags", "mode")} for name, value in build["outputs"].items()},
                           "failed_canonical_equality": "unestablished", "source_rebuilt": True}
        for name in build["outputs"]:
            mode = (context / "canonical-build" / name).lstat()
            _need(stat.S_ISREG(mode.st_mode) and stat.S_IMODE(mode.st_mode) == 0o555)
        with _watchdog(work_deadline):
            stage = "runtime-inventory"
            report["runtime_inventory"] = _inventory(context, modules, build, budget, work_deadline, WORK)
            stage = "preflight"
            report["preflight"] = {}
            _preflight(context, modules, build, budget, work_deadline, WORK, report["preflight"])
            os.environ.update(ASM_SERVER_BINARY=str(context / "canonical-build/asm-hub"), ASM_SERVER_SOURCE_REVISION=CANONICAL,
                              ASM_PROTO_LIBPQ=LIBRARIES["libpq"], ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin",
                              LD_LIBRARY_PATH="/opt/asm/mhd/lib:/opt/asm/postgres/lib", LC_ALL="C", TZ="UTC")
            runtime = _runtime(context)
            class Cohort(runtime.RuntimeTests):
                _canonical_traced = False
                @classmethod
                def environment(selected, **changes):
                    env = runtime.RuntimeTests.environment.__func__(selected, **changes)
                    env.pop("LD_PRELOAD", None)
                    if selected._canonical_traced:
                        env["LD_PRELOAD"] = str(context / "canonical-build/canonical_libpq_trace.so")
                    return env
            cls = Cohort
            for name in ("control", "traced"):
                stage = name
                arm = {}; report["arms"].append(arm)
                log = _run_arm(cls, runtime, name, budget, work_deadline, arm, initialize=name == "control")
                if name == "traced": traced_log = log
                _need(arm["collector_complete"])
            stage = "trace"
            arm = report["arms"][1]
            report["trace"] = _trace(traced_log, WORK / "server_package.log", arm["cohort_start_ns"], arm["cohort_end_ns"])
            _need(report["trace"]["complete"])
            core.context_contract(context, budget, readonly_guest=True)
            core.build_contract(context)
            report["collector_complete"] = True
    except GuestDeadline:
        report["failure_reason"] = "deadline"
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, subprocess.SubprocessError):
        report["failure_reason"] = stage
    finally:
        if cls is not None:
            cleanup_ok, stopped = True, {"complete": False}
            try:
                stopped = _stop(getattr(cls, "server", None), budget, deadline)
            except (OSError, ValueError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError):
                cleanup_ok = False
            try:
                if hasattr(cls, "log"): cls.log.close()
                if traced_log is None and hasattr(cls, "base"):
                    candidate = cls.base / "canonical-traced.log"
                    if candidate.is_file(): traced_log = candidate
                if "trace" not in report and traced_log is not None and not (WORK / "server_package.log").exists():
                    arm = next((value for value in report["arms"] if value.get("label") == "traced"), {})
                    report["trace"] = _trace(traced_log, WORK / "server_package.log", arm.get("cohort_start_ns", 0), arm.get("cohort_end_ns", 0))
            except (OSError, ValueError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError):
                cleanup_ok = False
            try:
                fixture_clean = _cleanup_fixture(cls, budget, deadline)
            except (OSError, ValueError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError):
                fixture_clean = False
            report["cleanup_complete"] = cleanup_ok and fixture_clean and stopped["complete"]
            if not report["cleanup_complete"]: report.setdefault("failure_reason", "cleanup")
        elif budget is not None:
            report["cleanup_complete"] = True
        if not report["cleanup_complete"]: report["collector_complete"] = False
        report["elapsed_ns"] = time.monotonic_ns() - started
        if report["elapsed_ns"] > 180000000000: report["collector_complete"] = False; report.setdefault("failure_reason", "guest-budget")
        _emit(report, WORK / "server_package.log" if own_work else None)
    return 0 if report["collector_complete"] and report["cleanup_complete"] else 1
