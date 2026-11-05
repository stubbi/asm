#!/usr/bin/env python3
"""Bounded observations for the PR37 RISC-V concurrency failure; never qualification.

SPDX-License-Identifier: AGPL-3.0-or-later
The original tests, client count, order, deadlines, and container limits remain.
No SQL, connection text, error strings, paths, or response text enters output.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import unittest
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
if Path("/qualification/tools/test_server_image.py").is_file():
    sys.path.insert(0, "/qualification/tools")
import test_server_image as image

PREFIX = "ASM_RISCV_DIAGNOSTIC="
TRACE = "ASM_LIBPQ_TRACE="
ERROR_PREFIX = "ASM_RISCV_DIAGNOSTIC_ERROR="
ERROR_REASONS = {"trace_bound", "trace_error", "trace_shape", "trace_value", "trace_state", "trace_count",
                 "execution_boundary", "security_boundary", "application_source", "filesystem_boundary",
                 "library_boundary", "interposer_binding", "missing_diagnostic_record", "report_binding"}
APPLICATION_SOURCE = "437fa424157d5e884a11bd2643b1eaca71674fc1"
BASE_HEAD = "61181be91d31cc671e3827a7aa17c9e2b37afe71"
UNAVAILABLE_SHA256 = "e72153001cb355982d6e5e823ec12146e3d0310eb1ce7457d7f981eaaec4b330"
ROUTES = {path: i+1 for i, path in enumerate(("/registry/v1/index.tsv", "/registry/v1/index-macos.tsv",
                                           "/registry/v1/index-all.tsv", "/registry/v1/index.json"))}
TYPES = {"application/json", "application/json; charset=utf-8", "text/tab-separated-values; charset=utf-8"}
ERROR_CODES = {"temporarily_unavailable", "invalid_query", "body_not_supported", "method_not_allowed",
               "not_found", "uri_too_long", "headers_too_large"}


def response_identity(code, headers, body):
    """Record fixed classifications and digests, never arbitrary response text."""
    content_type = headers.get("Content-Type", "")
    error_code = "unrecognized"
    if len(body) <= 512:
        try:
            candidate = json.loads(body).get("error", {}).get("code")
            if isinstance(candidate, str) and candidate in ERROR_CODES:
                error_code = candidate
        except (ValueError, AttributeError, TypeError):
            pass
    digest = hashlib.sha256(body).hexdigest()
    return {"status": int(code), "content_type": content_type if content_type in TYPES else "unrecognized",
            "content_type_sha256": hashlib.sha256(content_type.encode()).hexdigest(),
            "bytes": len(body), "body_sha256": digest, "error_code": error_code,
            "exact_application_unavailable_body": digest == UNAVAILABLE_SHA256}


def numeric_snapshot():
    """Only fixed numeric counters; unavailable files remain explicit nulls."""
    base = Path("/sys/fs/cgroup")
    result = {}
    for filename, keys in {
        "cpu.stat": {"usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec"},
        "memory.events": {"low", "high", "max", "oom", "oom_kill", "oom_group_kill"},
    }.items():
        try:
            result[filename] = {key: int(value) for key, value in
                                (line.split() for line in (base/filename).read_text().splitlines())
                                if key in keys and value.isdecimal()}
        except (OSError, ValueError):
            result[filename] = None
    for filename in ("memory.current", "memory.peak", "memory.max", "pids.current", "pids.max"):
        try:
            value = (base/filename).read_text().strip()
            result[filename] = int(value) if value.isdecimal() else None
        except OSError:
            result[filename] = None
    try:
        values = (base/"cpu.max").read_text().split()
        result["cpu.max"] = [int(v) if v.isdecimal() else None for v in values]
    except OSError:
        result["cpu.max"] = None
    try:
        result["host_cpu_ticks"] = [int(v) for v in Path("/proc/stat").read_text().splitlines()[0].split()[1:11]]
    except (OSError, ValueError, IndexError):
        result["host_cpu_ticks"] = None
    try:
        result["cpu.pressure"] = {
            line.split()[0]: {key: int(value) if key == "total" else float(value)
                             for key, value in (part.split("=") for part in line.split()[1:])
                             if key in {"avg10", "avg60", "avg300", "total"}}
            for line in (base/"cpu.pressure").read_text().splitlines() if line.split()[0] in {"some", "full"}}
    except (OSError, ValueError, IndexError):
        result["cpu.pressure"] = None
    return result


class SafeResult(unittest.TestResult):
    def _exc_info_to_string(self, err, test):
        # Preserve every assertion as a failure. Do not render arbitrary body
        # differences, exception values, tracebacks, SQL, or private paths.
        return err[0].__name__


def run_case(cls, name):
    before = numeric_snapshot()
    start = time.monotonic_ns()
    result = SafeResult()
    cls(name).run(result)
    return {"method": name, "started_ns": start, "finished_ns": time.monotonic_ns(),
            "tests_run": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
            "skipped": len(result.skipped), "before": before, "after": numeric_snapshot()}


def read_traces(path):
    if path.stat().st_size > 1024*1024:
        raise ValueError("trace_bound")
    records = []
    for line in path.read_text().splitlines():
        if line.startswith("ASM_LIBPQ_TRACE_ERROR="):
            raise ValueError("trace_error")
        if line.startswith(TRACE):
            record = json.loads(line[len(TRACE):])
            # Producer output contains integers, fixed keys, and 0/5-character
            # SQLSTATE values only. Refuse malformed output before forwarding.
            phases = record.get("phases")
            expected = {"id", "start_ns", "connected_us", "before_finish_us", "after_finish_us", "connect_poll",
                        "tls", "nonblocking", "sends", "route", "flush_result", "consume_result", "polls", "poll_us",
                        "poll_result", "poll_errno", "poll_revents", "poll_timeout_ms", "phases"}
            phase_keys = {"phase", "sent_us", "received_us", "drained_us", "send_result", "results", "status",
                          "rows", "fields", "null_cell", "bytes", "guard_one", "sqlstate"}
            if set(record) != expected or not isinstance(phases, list) or len(phases) != 3:
                raise ValueError("trace_shape")
            for key, value in record.items():
                if key != "phases" and type(value) is not int:
                    raise ValueError("trace_value")
            for phase in phases:
                if not isinstance(phase, dict) or set(phase) != phase_keys:
                    raise ValueError("trace_shape")
                for key, value in phase.items():
                    if key == "sqlstate":
                        if not isinstance(value, str) or re.fullmatch(r"(?:[A-Z0-9]{5})?", value) is None:
                            raise ValueError("trace_state")
                    elif type(value) is not int:
                        raise ValueError("trace_value")
            records.append(record)
    if not records or len(records) > 128:
        raise ValueError("trace_count")
    return records


def inside(args):
    if os.uname().sysname != "Linux" or os.uname().machine != "riscv64":
        raise ValueError("execution_boundary")
    if os.geteuid() != 65532 or os.getegid() != 65532 or not os.statvfs("/").f_flag & os.ST_RDONLY:
        raise ValueError("security_boundary")
    proc = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
    if proc.get("NoNewPrivs", "").strip() != "1" or int(proc.get("CapEff", "1").strip(), 16) != 0:
        raise ValueError("security_boundary")
    os.environ.update(ASM_SERVER_BINARY="/usr/local/bin/asm-hub", ASM_SERVER_SOURCE_REVISION=APPLICATION_SOURCE,
                      ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin", ASM_PROTO_LIBPQ="/opt/asm/postgres/lib/libpq.so.5")
    spec = importlib.util.spec_from_file_location("diagnostic_runtime_tests", "/qualification/server/test_runtime.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    base = module.RuntimeTests
    original_environment = base.environment.__func__
    original_request = base.raw_request.__func__
    responses = []
    lock = threading.Lock()
    stage = "setup"

    class Probe(base):
        @classmethod
        def environment(cls, **changes):
            env = original_environment(cls, **changes)
            env["LD_PRELOAD"] = "/diagnostic/libpq_trace.so"
            return env

        @classmethod
        def raw_request(cls, path, method="GET", body=None):
            start = time.monotonic_ns()
            value = original_request(cls, path, method, body)
            record = response_identity(*value)
            record.update(stage=stage, route=ROUTES.get(path, 0), started_ns=start, finished_ns=time.monotonic_ns())
            with lock:
                responses.append(record)
            return value

    cases = []
    try:
        Probe.setUpClass()
        if Probe.request("/api/v2/status")[2].get("source_revision") != APPLICATION_SOURCE:
            raise ValueError("application_source")
        # Preserve the original two preceding methods and their assertions.
        for name in ("test_canonical_exports_preserve_exact_current_bytes_and_media_types",
                     "test_cli_and_bind_configuration_fail_closed"):
            stage = "baseline"
            cases.append(run_case(Probe, name))
        # Both identical six-client/eight-path waves retain every assertion.
        # Wave2 is a reproducibility observation, never a retry-as-pass.
        for stage in ("wave1", "wave2"):
            cases.append(run_case(Probe, "test_concurrent_exports_keep_independent_response_ownership"))
        Probe.log.flush()
        traces = read_traces(Probe.base/"server.log")
    finally:
        Probe.doClassCleanups()
    cleanup_errors = len(Probe.tearDown_exceptions)
    report = {"schema": 1, "scope": "riscv-concurrency-diagnostic", "execution": "emulated",
              "diagnostic_checkout": args.diagnostic_checkout, "application_source": APPLICATION_SOURCE,
              "application_branch_head": BASE_HEAD, "rebuilt": True, "cases": cases,
              "responses": responses, "connections": traces, "cleanup_errors": cleanup_errors,
              "limits": {"cpus": 2, "memory_bytes": 536870912, "pids": 128, "tmpfs_bytes": 268435456,
                         "database_deadline_ms": 2000, "statement_timeout_ms": 1000, "clients": 6},
              "limitation": "The interposer adds overhead. Rebuilt bytes and diagnostic observations do not qualify PR37."}
    print(PREFIX+json.dumps(report, sort_keys=True))
    return int(cleanup_errors or any(case["failures"] or case["errors"] or case["skipped"] for case in cases))


def outside(args):
    runtime, diagnostic = [json.loads(image.command(["docker", "image", "inspect", value]).stdout)[0]
                           for value in (args.runtime, args.diagnostic_image)]
    runtime_id = image.image_contract(runtime, "riscv64", APPLICATION_SOURCE)
    diagnostic_id = image.image_contract(diagnostic, "riscv64", APPLICATION_SOURCE, qualification=True)
    if diagnostic["RootFS"]["Layers"][:len(runtime["RootFS"]["Layers"])] != runtime["RootFS"]["Layers"]:
        raise ValueError("filesystem_boundary")
    files = image.runtime_files(runtime_id, "riscv64")
    if image.runtime_files(diagnostic_id, "riscv64") != files:
        raise ValueError("library_boundary")
    base = ["docker", "run", "--rm", "--platform", "linux/riscv64", *image.security_arguments()]
    library_sha = image.command([*base, "--entrypoint", "/usr/bin/sha256sum", diagnostic_id,
                                 "/diagnostic/libpq_trace.so"]).stdout.decode().split()[0]
    if re.fullmatch("[0-9a-f]{64}", library_sha) is None:
        raise ValueError("interposer_binding")
    name = "asm-riscv-diagnostic-"+uuid.uuid4().hex
    try:
        result = subprocess.run([*base, "--name", name, "--tmpfs",
                                 "/tmp:rw,nosuid,nodev,noexec,size=256m,uid=65532,gid=65532,mode=0700",
                                 "--entrypoint", "/usr/bin/python3", diagnostic_id, "/diagnostic/riscv_probe.py",
                                 "--inside", "--diagnostic-checkout", args.diagnostic_checkout], capture_output=True, timeout=180)
    finally:
        subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=15)
    # Do not relay raw subprocess output. The one validated diagnostic record
    # is the only accepted producer channel. Failures never become qualification.
    reports = [line[len(PREFIX):] for line in result.stdout.decode().splitlines() if line.startswith(PREFIX)]
    if len(reports) != 1:
        for line in result.stderr.decode("ascii", "replace").splitlines():
            if line.startswith(ERROR_PREFIX):
                error = json.loads(line[len(ERROR_PREFIX):])
                if error.get("reason") in ERROR_REASONS:
                    raise ValueError(error["reason"])
        raise ValueError("missing_diagnostic_record")
    report = json.loads(reports[0])
    if (report.get("scope") != "riscv-concurrency-diagnostic" or report.get("application_source") != APPLICATION_SOURCE
            or report.get("diagnostic_checkout") != args.diagnostic_checkout or report.get("rebuilt") is not True
            or report.get("application_branch_head") != BASE_HEAD or report.get("execution") != "emulated"):
        raise ValueError("report_binding")
    report.update(runtime_image_id=runtime_id, diagnostic_image_id=diagnostic_id, files_sha256=files,
                  interposer_sha256=library_sha, process_exit=result.returncode)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+"\n")
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--diagnostic-checkout", required=True)
    parser.add_argument("--runtime")
    parser.add_argument("--diagnostic-image")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if re.fullmatch("[0-9a-f]{40}", args.diagnostic_checkout) is None:
        parser.error("Use an exact diagnostic checkout.")
    if not args.inside and (not args.runtime or not args.diagnostic_image or not args.output):
        parser.error("Select runtime, diagnostic image, and output.")
    try:
        return inside(args) if args.inside else outside(args)
    except Exception as error:
        # Exception values can contain response bodies or private paths.
        reason = error.args[0] if error.args and isinstance(error.args[0], str) else "unclassified"
        safe = {"type": type(error).__name__, "reason": reason if reason in ERROR_REASONS else "unclassified"}
        if args.output:
            args.output.write_text(json.dumps({"scope": "riscv-concurrency-diagnostic", "collection_error": safe,
                "diagnostic_checkout": args.diagnostic_checkout,
                "requested_application_source": APPLICATION_SOURCE}, sort_keys=True)+"\n")
        print(ERROR_PREFIX+json.dumps(safe, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
