"""Replay one unchanged HTTP method against fresh ABBA backend fixtures.

SPDX-License-Identifier: AGPL-3.0-or-later
This bounded diagnostic does not run the acceptance suite or qualify a target.
Only the owned PostgreSQL initializer/daemon package changes between arms.
The native overlay and the parent verify executable/library inputs separately.
"""
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import sys
import tempfile
import time

import riscv64_combined as combined
from riscv64_reference_suite import EMULATOR_BYTES, EMULATOR_SHA256, bounded_bytes, error_type

METHOD = "test_simultaneous_searches_keep_request_data_separate"
ORIGINAL_BINDIR = Path("/opt/asm/postgres/bin")
QUERY_SHA256 = "5cd15a09fa823567a83b4042b799a33e9bd379ec3cd346b96371c02ebd234b0d"
MAX_REPORT = 1048576
BODY_RETAINED = 4096
ERROR = "The bounded backend comparison is incomplete."
ENV_KEYS = ("ASM_PROTO_BINARY", "ASM_PROTO_LIBPQ", "ASM_PROTO_PG_BINDIR", "LD_LIBRARY_PATH",
            "QEMU_LD_PREFIX", "PATH", "HOME", "LC_ALL", "TZ", "PYTHONDONTWRITEBYTECODE",
            "PYTHONUNBUFFERED", "ASM_PROTO_BUILD_DIR")
FIXTURE_EVIDENCE = {"binary_sha256": "3e0bce8b6d9be340be5dfabbdd39fda064d7c9dd46287432561d315603ba93c9",
                    "libpq_version": 160015, "database_version": "16.15",
                    "schema_sha384": "e9fce69caa758cb9d15a700d92b76aba0fc3ca466a81624733124a742f2211aadae612ab877bd908a6e1d6ab5e803ef2",
                    "fixture": "owned-local-cluster"}


def _encoded(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True, allow_nan=False).encode()


def _budget(deadline):
    if type(deadline) not in (int, float) or not math.isfinite(deadline) or time.monotonic() >= deadline:
        raise TimeoutError(ERROR)


def _failure(stage, error):
    return {"stage": stage, "type": error_type(error)}


def _publish(path, report):
    """Use the shared serializer in a private stage; retain old bytes on failure."""
    if len((json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()) > MAX_REPORT:
        raise ValueError(ERROR)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".backend-report-", dir=path.parent) as temporary:
        stage = Path(temporary) / "diagnostic.json"
        combined.write_report(stage, report)
        stage.chmod(0o600)
        with stage.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(stage, path)


def _environment():
    # Hash values, including unknown ambient keys, without retaining credentials.
    raw = _encoded(dict(os.environ))
    return {"all_environment_sha256": hashlib.sha256(raw).hexdigest(),
            "fields": {key: {"bytes": len(os.environ[key].encode()),
                              "sha256": hashlib.sha256(os.environ[key].encode()).hexdigest()}
                       for key in ENV_KEYS if key in os.environ}}


def _source_files(source):
    result = {}
    for name in ("test_server.py", "local_postgres.py", "search.sql"):
        raw = bounded_bytes(source / name, 131072)
        result[name] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
    return result


def _fixture_evidence(case):
    evidence, result = case.evidence, {}
    if type(evidence) is not dict:
        raise ValueError(ERROR)
    for key, pattern in (("binary_sha256", "[0-9a-f]{64}"), ("schema_sha384", "[0-9a-f]{96}"),
                         ("database_version", r"[0-9]{1,2}\.[0-9]{1,2}(?:\.[0-9]{1,2})?")):
        value = evidence.get(key)
        result[key] = value if type(value) is str and re.fullmatch(pattern, value) else None
    version = evidence.get("libpq_version")
    result["libpq_version"] = version if type(version) is int and 0 <= version < 2**31 else None
    result["fixture"] = evidence.get("fixture") if evidence.get("fixture") == "owned-local-cluster" else None
    return result


def _resources():
    import riscv64_reference_native as native
    value = native.resource_snapshot()
    result = {"available": False, "usable": False, "cpu": {}}
    if type(value) is not dict:
        return result
    cpu = value.get("cpu")
    required = {"usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec"}
    if type(cpu) is dict:
        result["cpu"] = {key: item for key, item in cpu.items()
                         if key in required and type(item) is int and 0 <= item < 2**64}
    for key in ("memory_current", "memory_peak"):
        item = value.get(key)
        if type(item) is int and 0 <= item < 2**64:
            result[key] = item
    captured = value.get("captured_monotonic")
    if type(captured) in (int, float) and math.isfinite(captured) and captured >= 0:
        result["captured_monotonic"] = captured
    if value.get("memory_peak_scope") == "whole-cgroup-lifetime-not-reset":
        result["memory_peak_scope"] = "whole-cgroup-lifetime-not-reset"
    result["available"] = value.get("available") is True
    result["usable"] = (result["available"] and set(result["cpu"]) == required and
                        all(key in result for key in ("memory_current", "memory_peak", "captured_monotonic", "memory_peak_scope"))
                        and result["memory_current"] <= result["memory_peak"])
    return result


def _cleanup_state(case):
    """Confirm owned process/thread/file postconditions after class cleanups."""
    result = {
        "server_stopped_and_drainer_joined": case._owned_server_stopped(case.server, case.attribution),
        "postmaster_stopped": case.cluster.process is None or case.cluster.process.poll() is not None,
        "cluster_closed": case.cluster.admin is None and case.cluster.temp is None,
        "fixture_admin_closed": case.fixture_admin.conn is None,
        "proxy_stopped": (not case.proxy.thread.is_alive() and
                          all(not thread.is_alive() for thread in case.proxy.workers) and
                          case.proxy.listener.fileno() == -1),
        "server_log_closed": case.log.closed,
    }
    if any(value is not True for value in result.values()):
        raise RuntimeError(ERROR)
    return result


def _identity(path):
    """Hash a bounded executable through one descriptor, including proc/exe."""
    digest, header = hashlib.sha256(), b""
    with path.open("rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or not 20 <= before.st_size <= 64 * 1024 * 1024:
            raise ValueError(ERROR)
        remaining = before.st_size
        while remaining:
            data = stream.read(min(65536, remaining))
            if not data:
                raise ValueError(ERROR)
            if not header:
                header = data[:64]
            remaining -= len(data)
            digest.update(data)
        after = os.fstat(stream.fileno())
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError(ERROR)
    if header[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError(ERROR)
    return {"bytes": before.st_size, "sha256": digest.hexdigest(),
            "elf_machine": struct.unpack_from("<H", header, 18)[0]}


def _postmaster(case, backend, baseline, native):
    """Distinguish the guest PG ELF from QEMU's actual host executable."""
    import riscv64_reference_native as overlay
    proc = case.cluster.process
    if proc is None or proc.poll() is not None:
        raise ValueError(ERROR)
    path = Path(f"/proc/{proc.pid}/exe")
    actual = _identity(path)
    declared = _identity(ORIGINAL_BINDIR / "postgres" if backend == "A" else overlay.POSTGRES)
    expected = baseline["postgres"] if backend == "A" else native["postgres"]
    if any(declared[key] != expected[key] for key in ("bytes", "sha256", "elf_machine")):
        raise ValueError(ERROR)
    if backend == "A":
        if declared["elf_machine"] != 243 or actual != {"bytes": EMULATOR_BYTES,
                "sha256": EMULATOR_SHA256, "elf_machine": 62}:
            raise ValueError(ERROR)
    elif (declared["elf_machine"] != 62 or actual != declared
          or path.resolve() != overlay.POSTGRES.resolve()):
        raise ValueError(ERROR)
    if proc.poll() is not None:
        raise ValueError(ERROR)
    return {"outcome": "pass", "pid": proc.pid, "declared_postgres": declared,
            "actual_executable": actual, "execution": "qemu-user" if backend == "A" else "native-amd64"}


def _same_typed(actual, expected):
    if type(actual) is not type(expected):
        return False
    if type(expected) is dict:
        return set(actual) == set(expected) and all(_same_typed(actual[key], value) for key, value in expected.items())
    if type(expected) is list:
        return len(actual) == len(expected) and all(_same_typed(a, b) for a, b in zip(actual, expected))
    return actual == expected


def _json(raw):
    def fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(ERROR)
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=fields,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(ERROR)))


def _row(record, index):
    if type(record) is not dict or type(record.get("index")) is not int or record["index"] != index:
        raise ValueError(ERROR)
    result = {"index": index, "recorded": True, "expected_body_matches": False}
    status = record.get("status")
    if status is not None and (type(status) is not int or not 100 <= status <= 599):
        raise ValueError(ERROR)
    result["status"] = status
    for key in ("start_monotonic", "end_monotonic", "elapsed_seconds"):
        value = record.get(key)
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise ValueError(ERROR)
        result[key] = value
    if result["end_monotonic"] < result["start_monotonic"]:
        raise ValueError(ERROR)
    headers = record.get("headers")
    if type(headers) is not dict or len(headers) > 64:
        raise ValueError(ERROR)
    result["headers"] = {key.lower(): value for key, value in headers.items()
                         if type(key) is str and key.lower() in ("content-type", "content-length", "connection",
                             "cache-control", "x-content-type-options") and type(value) is str and len(value) <= 128}
    for key in ("body_bytes", "body_sha256", "body_complete", "body_truncated", "body_redacted", "body_state"):
        result[key] = record.get(key)
    if result["body_bytes"] is not None and (type(result["body_bytes"]) is not int or not 0 <= result["body_bytes"] <= 2**31):
        raise ValueError(ERROR)
    if result["body_sha256"] is not None and (type(result["body_sha256"]) is not str or
            re.fullmatch("[0-9a-f]{64}", result["body_sha256"]) is None):
        raise ValueError(ERROR)
    if any(type(result[key]) is not bool for key in ("body_complete", "body_truncated", "body_redacted")):
        raise ValueError(ERROR)
    if result["body_state"] not in ("complete", "partial", "unavailable"):
        raise ValueError(ERROR)
    encoded = record.get("body_base64")
    if type(encoded) is not str or len(encoded) > 21848:
        raise ValueError(ERROR)
    raw = base64.b64decode(encoded, validate=True)
    if len(raw) > 16384:
        raise ValueError(ERROR)
    result.update(body_base64=base64.b64encode(raw[:BODY_RETAINED]).decode(),
                  retained_body_truncated=len(raw) > BODY_RETAINED)
    for key in ("exception", "attribution_exception"):
        error = record.get(key)
        if error is not None:
            if type(error) is not dict:
                raise ValueError(ERROR)
            result[key] = {"type": error.get("type") if error.get("type") in
                ("OSError", "TimeoutError", "RuntimeError", "ValueError", "AssertionError", "KeyError", "IncompleteRead",
                 "ConnectionRefusedError", "ConnectionResetError", "RemoteDisconnected", "JSONDecodeError",
                 "UnicodeDecodeError", "CensusInconclusive") else "Exception",
                "stage": error.get("stage") if error.get("stage") in ("transport", "json", "attribution") else "other",
                "errno": error.get("errno") if type(error.get("errno")) is int and 0 <= error["errno"] <= 4095 else None}
    if result["body_complete"] and not result["body_truncated"] and not result["body_redacted"]:
        if len(raw) != result["body_bytes"] or hashlib.sha256(raw).hexdigest() != result["body_sha256"]:
            raise ValueError(ERROR)
    if status == 200 and result["body_complete"] and not result["body_truncated"] and not result["body_redacted"]:
        expected = {"schema": 0, "experimental": True, "packages": [{"name": f"fixture/p{index:02d}",
            "latest": "0.2.0", "summary": f"Assembly fixture {index:02d}", "license": "MIT",
            "owner_github_id": 12345, "targets": ["x86_64-linux"]}],
            "next_after": None, "order": "package-name-ascii"}
        try:
            result["expected_body_matches"] = _same_typed(_json(raw), expected)
        except (ValueError, UnicodeError, RecursionError):
            result["body_validation"] = "invalid-json"
    return result


def _records(case, arm):
    records = case.diagnostic.data["simultaneous_searches"]["records"]
    complete = type(records) is list and len(records) == 16
    for index in range(1, 17):
        try:
            if not complete:
                raise ValueError(ERROR)
            arm["records"].append(_row(records[index - 1], index))
        except Exception as error:
            arm["records"].append({"index": index, "recorded": False, "expected_body_matches": False})
            arm["failures"].append(_failure("http-evidence", error))


def _trace(case):
    records = case.diagnostic.data["simultaneous_searches"]["records"]
    # The unchanged server uses the proxy URL. This label also rejects any
    # positive-index terminal record outside the sole HTTP cohort.
    case._collect_phase_trace("proxy", case.base / "server.log", records)
    source = case.diagnostic.data["phase_traces"]["proxy"]
    ids = source.get("cohort_record_ids", {})
    rows = source.get("records", [])
    if (source.get("association") != "complete" or type(ids) is not dict or
            set(map(str, ids)) != {str(i) for i in range(1, 17)} or
            any(type(value) is not int for value in ids.values()) or len(set(ids.values())) != 16 or
            type(rows) is not list or not 16 <= len(rows) <= 256):
        raise ValueError(ERROR)
    selected = [row for row in rows if row.get("id") in ids.values()]
    if len(selected) != 16 or {row.get("index") for row in selected} != set(range(1, 17)):
        raise ValueError(ERROR)
    result = {"association": "complete", "cohort_record_ids": ids, "records": selected,
              "noncohort_records": len(rows) - 16, "all_records_sha256": hashlib.sha256(_encoded(rows)).hexdigest()}
    if len(_encoded(result)) > 65536:
        raise ValueError(ERROR)
    return result


def _attribution(case):
    record = case.attribution.record
    result = {key: record[key] for key in ("pid", "released", "target_ready", "reader_ever_opened",
              "no_reader_before_capture", "drained_bytes", "early_eof_count", "writer_connected", "returncode",
              "forced_stop", "registration_sha256") if key in record}
    result["cleanup_error_count"] = len(record.get("cleanup_errors", []))
    if (record.get("released") is not True or record.get("target_ready") is not True or
            record.get("cleanup_errors") or record.get("returncode") != 0):
        raise ValueError(ERROR)
    return result


def run_backend_comparison(cls, source: Path, deadline: float) -> dict:
    """Run fresh A1/B1/B2/A2 fixtures; every failed method remains a failure."""
    import riscv64_reference_native as native
    started = time.monotonic()
    report = {"schema": 1, "scope": "reference-backend-control", "qualification": "UNQUALIFIED", "outcome": "fail",
              "application_qualified": False, "native_qualified": False, "release_qualified": False,
              "acceptance_tests_run": 0, "acceptance_tests_not_run": 19, "historical_original19": "FAIL",
              "base_commit": "04c93b3f0200173298d24f22a06393bc359a1af0",
              "runtime": {"sha256": "3e0bce8b6d9be340be5dfabbdd39fda064d7c9dd46287432561d315603ba93c9", "bytes": 33584},
              "diagnostic_method": METHOD, "diagnostic_method_invocations": 0,
              "http_assertions_outcome": "not-run", "measurement_complete": False, "acceptance_suite": "not-run",
              "recorded_outcomes": 0, "observed_http_responses": 0,
              "order": ["A1", "B1", "B2", "A2"], "requests_per_arm": 16, "workers_per_arm": 8,
              "limits": {"database_seconds": 2, "statement_seconds": 1, "http_seconds": 4,
                         "guest_seconds": 180, "host_seconds": 600, "report_bytes": MAX_REPORT},
              "limits_of_evidence": "The backend package, libc and build differ; this does not isolate emulation alone.",
              "arms": [{"label": label, "backend": backend, "state": "not_run", "records": [],
                        "failures": [], "cleanup_complete": False, "method_outcome": "not-run"} for label, backend in
                       (("A1", "A"), ("B1", "B"), ("B2", "B"), ("A2", "A"))],
              "paired_bodies": [], "failures": []}
    original_environment = dict(os.environ)
    destination = Path(os.environ["ASM_PROTO_BUILD_DIR"]) / "reference-backend/diagnostic.json"
    _publish(destination, report)
    prohibit = False
    try:
        _budget(deadline)
        fixture = sys.modules[cls.__module__]
        if (Path(fixture.__file__).resolve() != (source / "test_server.py").resolve() or fixture.ServerTests is not cls
                or cls.attribution_config is None or cls.trace_config is None
                or cls.attribution_config.runner_deadline != deadline
                or os.environ.get("ASM_PROTO_PG_BINDIR") != str(ORIGINAL_BINDIR)
                or os.environ.get("ASM_PROTO_LIBPQ") != "/opt/asm/postgres/lib/libpq.so.5"
                or os.environ.get("LD_LIBRARY_PATH") != "/opt/asm/mhd/lib:/opt/asm/postgres/lib"
                or os.environ.get("LD_PRELOAD") or any(key.startswith("PG") for key in os.environ)):
            raise ValueError(ERROR)
        query = bounded_bytes(source / "search.sql", 16384)
        if hashlib.sha256(query).hexdigest() != QUERY_SHA256:
            raise ValueError(ERROR)
        report["query"] = {"bytes": len(query), "sha256": QUERY_SHA256}
        report["source_files"] = _source_files(source)
        baseline = native.verify_risc()
        if baseline.get("outcome") != "pass":
            raise ValueError(ERROR)
        report["risc_baseline"] = baseline
        report["native_preflight"] = native.inspect_native(Path(os.environ["ASM_PROTO_BUILD_DIR"]) / "reference-backend", deadline)
        if report["native_preflight"].get("outcome") != "pass":
            raise ValueError(ERROR)
        _budget(deadline)
        for arm in report["arms"]:
            if prohibit or time.monotonic() >= deadline:
                arm["reason"] = "earlier-unsafe-cleanup-or-binding" if prohibit else "deadline"
                continue
            case = type("Backend" + arm["label"], (cls,), {"_class_cleanups": [], "tearDown_exceptions": [],
                        "_classSetupFailed": False, "server": None, "attribution": None, "diagnostic": None,
                        "fixture_ready": False, "cluster": None, "proxy": None, "log": None,
                        "fixture_admin": None, "evidence": None})
            setup_complete = False
            os.environ["ASM_PROTO_PG_BINDIR"] = str(ORIGINAL_BINDIR if arm["backend"] == "A" else native.BINDIR)
            selected_environment = dict(os.environ)
            arm["environment_before"] = _environment()
            arm["start_monotonic"] = time.monotonic()
            arm["state"] = "starting"
            _publish(destination, report)
            try:
                _budget(deadline)
                arm["risc_before"] = native.verify_risc()
                if arm["risc_before"] != baseline:
                    raise ValueError(ERROR)
                case.setUpClass()
                setup_complete = True
                _budget(deadline)
                arm["postmaster"] = _postmaster(case, arm["backend"], baseline, report["native_preflight"])
                arm["target_pid"] = case.server.pid
                arm["fixture_evidence"] = _fixture_evidence(case)
                if not _same_typed(arm["fixture_evidence"], FIXTURE_EVIDENCE):
                    raise ValueError(ERROR)
                arm["resources_before_http"] = _resources()
                if not arm["resources_before_http"]["usable"]:
                    raise ValueError(ERROR)
                _budget(deadline)
                arm["http_start_monotonic"] = time.monotonic()
                arm["state"] = "running"
                _publish(destination, report)
                _budget(deadline)
                try:
                    report["diagnostic_method_invocations"] += 1
                    getattr(case(METHOD), METHOD)()
                    arm["method_outcome"] = "pass"
                except BaseException as error:
                    arm["method_outcome"] = "fail"
                    arm["failures"].append(_failure("method", error))
                finally:
                    arm["http_end_monotonic"] = time.monotonic()
                    try:
                        arm["resources_after_http"] = _resources()
                    finally:
                        _records(case, arm)
                if not arm["resources_after_http"]["usable"]:
                    raise ValueError(ERROR)
                _budget(deadline)
            except BaseException as error:
                arm["failures"].append(_failure("setup-or-budget", error))
                prohibit = True
            finally:
                stopped = False
                try:
                    case.stop_server()
                    stopped = case.server is not None and case._owned_server_stopped(case.server, case.attribution)
                    if setup_complete and not stopped:
                        raise RuntimeError(ERROR)
                except BaseException as error:
                    arm["failures"].append(_failure("stop-server", error))
                    prohibit = True
                if setup_complete:
                    try:
                        case.log.flush()
                        if not stopped:
                            raise RuntimeError(ERROR)
                        arm["phase_trace"] = _trace(case)
                        arm["attribution"] = _attribution(case)
                    except BaseException as error:
                        arm["failures"].append(_failure("trace-or-attribution", error))
                    try:
                        case.tearDownClass()
                    except BaseException as error:
                        arm["failures"].append(_failure("teardown", error))
                        prohibit = True
                cleanup_failed = False
                try:
                    case.doClassCleanups()
                    for _kind, error, _traceback in case.tearDown_exceptions:
                        cleanup_failed = True
                        arm["failures"].append(_failure("class-cleanup", error))
                except BaseException as error:
                    cleanup_failed = True
                    arm["failures"].append(_failure("class-cleanup", error))
                if cleanup_failed:
                    prohibit = True
                if setup_complete and not cleanup_failed:
                    try:
                        arm["cleanup_checks"] = _cleanup_state(case)
                    except BaseException as error:
                        cleanup_failed = True
                        prohibit = True
                        arm["failures"].append(_failure("cleanup-postconditions", error))
                arm["cleanup_complete"] = not cleanup_failed and not any(
                    row["stage"] in ("stop-server", "teardown") for row in arm["failures"])
                try:
                    arm["risc_after"] = native.verify_risc()
                    arm["source_after"] = _source_files(source)
                    arm["environment_after"] = _environment()
                    arm["bindings_unchanged"] = (arm["risc_after"] == baseline and dict(os.environ) == selected_environment
                                                and arm["source_after"] == report["source_files"])
                    if not arm["bindings_unchanged"]:
                        raise ValueError(ERROR)
                except BaseException as error:
                    arm["failures"].append(_failure("binding-after", error))
                    prohibit = True
                os.environ.clear()
                os.environ.update(original_environment)
                arm["end_monotonic"] = time.monotonic()
                if arm["end_monotonic"] >= deadline:
                    arm["failures"].append(_failure("deadline-after-cleanup", TimeoutError()))
                    prohibit = True
                arm["state"] = "failed" if arm["failures"] else "passed"
                _publish(destination, report)
        for index in range(1, 17):
            hashes = {arm["label"]: next((row.get("body_sha256") for row in arm["records"]
                if row["index"] == index and row.get("expected_body_matches")), None) for arm in report["arms"]}
            available = [value for value in hashes.values() if value is not None]
            report["paired_bodies"].append({"index": index, "sha256_by_arm": hashes,
                "matching": bool(hashes["A1"] or hashes["A2"]) and bool(hashes["B1"] or hashes["B2"])
                            and len(set(available)) == 1})
        report["recorded_outcomes"] = sum(row.get("recorded", False) for arm in report["arms"] for row in arm["records"])
        report["observed_http_responses"] = sum(type(row.get("status")) is int for arm in report["arms"] for row in arm["records"])
        report["measurement_complete"] = report["recorded_outcomes"] == 64 and all(
            arm["cleanup_complete"] and "phase_trace" in arm and arm.get("bindings_unchanged") for arm in report["arms"])
        report["http_assertions_outcome"] = ("not-run" if report["diagnostic_method_invocations"] == 0 else
            "pass" if all(arm.get("method_outcome") == "pass" for arm in report["arms"]) else "fail")
        report["all_successful_bodies_match_expected"] = all(row.get("expected_body_matches")
            for arm in report["arms"] for row in arm["records"] if row.get("status") == 200)
        if (report["measurement_complete"] and all(row["matching"] for row in report["paired_bodies"])
                and report["all_successful_bodies_match_expected"]
                and all(all(row["stage"] == "method" for row in arm["failures"]) for arm in report["arms"])):
            report["outcome"] = "pass"
    except BaseException as error:
        report["failures"].append(_failure("preflight-or-finalization", error))
    finally:
        os.environ.clear()
        os.environ.update(original_environment)
    for arm in report["arms"]:
        if arm["state"] == "not_run":
            arm.setdefault("reason", "preflight-failed")
    report["seconds"] = time.monotonic() - started
    # Account for serialization before the last budget check. Never prune HTTP
    # outcomes to turn incomplete evidence into passing evidence.
    if len(_encoded(report)) > MAX_REPORT - 1024:
        raise ValueError(ERROR)
    if type(deadline) not in (int, float) or not math.isfinite(deadline) or time.monotonic() >= deadline:
        report["outcome"] = "fail"
        report["failures"].append(_failure("final-deadline", TimeoutError()))
    _publish(destination, report)
    if report["outcome"] == "pass" and time.monotonic() >= deadline:
        report["outcome"] = "fail"
        report["failures"].append(_failure("final-publication-deadline", TimeoutError()))
        # Invalidate a passing destination before corrective I/O can fail.
        destination.unlink()
        _publish(destination, report)
    return report
