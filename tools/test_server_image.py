#!/usr/bin/env python3
"""Qualify an assembly server image. This is test orchestration only.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib
import io
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import struct
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

TARGETS = {"amd64": ("x86_64", 62), "arm64": ("aarch64", 183), "riscv64": ("riscv64", 243)}
DECLARED_TARGETS = {
    "amd64": {"isa": "x86_64", "os": "linux", "abi": "System V AMD64 LP64", "cpu_profile": "x86-64 baseline"},
    "arm64": {"isa": "aarch64", "os": "linux", "abi": "AAPCS64 LP64", "cpu_profile": "ARMv8-A"},
    "riscv64": {"isa": "riscv64", "os": "linux", "abi": "RISC-V LP64D", "cpu_profile": "RV64GC"},
}
DECLARATION_LIMIT = "Declared application profile; ELF flags do not audit every instruction or qualify hardware and library CPU requirements."
EF_RISCV_RVC = 0x1
EF_RISCV_FLOAT_ABI = 0x6
EF_RISCV_FLOAT_ABI_DOUBLE = 0x4
REPORT_PREFIX = "ASM_SERVER_QUALIFICATION="
QUALIFICATION_SCOPE = "assembly-canonical-exports-admission"
PART_SCOPE = "assembly-image-runtime-part"
SUITES = {"baseline": ("test_runtime", 22), "capacity": ("test_capacity", 12)}
MIN_RUNTIME_TESTS = 34
MAX_EVIDENCE_BYTES = 2 * 1024 * 1024
FIXTURE_PATH = "/qualification/fixtures/connect-null.so"
SECURITY = {"uid": 65532, "gid": 65532, "read_only_root": True,
            "effective_capabilities": 0, "no_new_privileges": True}
CONTAINER_LIMITS = {"cpus": 2, "memory_bytes": 536870912, "pids": 128,
                    "tmpfs_bytes": 268435456, "tmpfs_noexec": True, "watchdog_seconds": 180}
COMMON_FIELDS = {"architecture", "os", "execution", "source_revision", "runtime_image_id",
                 "qualification_image_id", "binary", "binary_permissions", "executable_files",
                 "libraries", "fixture", "metrics_test_tools", "security", "container_limits"}
PART_FIELDS = COMMON_FIELDS | {"schema", "status", "scope", "suite", "tests_run", "tests_skipped", "seconds", "cases"}
REPOSITORY = "ghcr.io/stubbi/asm-hub"
REQUIRED_CASE_IDS = {'baseline': ['RuntimeTests.test_canonical_exports_preserve_exact_current_bytes_and_media_types',
              'RuntimeTests.test_cli_and_bind_configuration_fail_closed',
              'RuntimeTests.test_concurrent_exports_keep_independent_response_ownership',
              'RuntimeTests.test_encrypted_client_key_never_prompts_on_an_open_terminal',
              'RuntimeTests.test_export_body_byte_limits_preserve_boundary_bytes',
              'RuntimeTests.test_export_database_work_obeys_the_request_deadline',
              'RuntimeTests.test_exports_reject_missing_null_duplicate_and_unready_results',
              'RuntimeTests.test_health_and_exact_source_identity',
              'RuntimeTests.test_metrics_aborts_preserve_queue_semantics',
              'RuntimeTests.test_metrics_concurrent_scrapes_preserve_snapshots',
              'RuntimeTests.test_metrics_database_delay_and_failed_request_timing',
              'RuntimeTests.test_metrics_errors_and_exactly_once_queue_accounting',
              'RuntimeTests.test_metrics_fixed_exposition_and_route_labels',
              'RuntimeTests.test_metrics_queue_failures_preserve_ownership',
              'RuntimeTests.test_new_connections_load_replaced_certificate_files',
              'RuntimeTests.test_private_configuration_file_is_required',
              'RuntimeTests.test_reader_rejects_migrator_operator_and_wrong_tls_identities',
              'RuntimeTests.test_readiness_checks_actual_permissions_after_start',
              'RuntimeTests.test_stalled_database_handshake_has_a_deadline',
              'RuntimeTests.test_tls_policy_rejects_ambient_options_and_ambiguous_connections',
              'RuntimeTests.test_unimplemented_write_routes_do_not_claim_success',
              'RuntimeTests.test_z_sigterm_closes_the_listener_within_three_seconds'],
 'capacity': ['CapacityTests.test_aborted_database_handshakes_release_admission',
              'CapacityTests.test_eight_handshakes_refuse_ninth_and_recover_in_the_same_process',
              'CapacityTests.test_guard_failures_release_admission_before_recovery',
              'CapacityTests.test_http_disconnects_release_admission_by_the_database_deadline',
              'CapacityTests.test_http_response_abort_preserves_database_capacity',
              'CapacityTests.test_invalid_results_release_admission_before_recovery',
              'CapacityTests.test_null_connection_creation_releases_admission',
              'CapacityTests.test_replacement_acquisitions_overlap_individual_releases',
              'CapacityTests.test_sixteen_contending_requests_never_hold_more_than_eight_connections',
              'CapacityTests.test_statement_timeouts_release_admission_before_recovery',
              'CapacityTests.test_successful_reads_release_admission_repeatedly',
              'CapacityTests.test_tls_failures_release_admission_before_recovery'],
 'envelope': ['EnvelopeTests.test_eight_slow_maximum_exports_preserve_bytes_and_recover',
              'EnvelopeTests.test_incomplete_headers_release_connections_after_inactivity',
              'EnvelopeTests.test_sigterm_bounds_exit_during_observed_inflight_work']}

REQUIRED_METRICS_HTTP_TESTS = tuple(sorted((
    "RuntimeTests.test_metrics_fixed_exposition_and_route_labels",
    "RuntimeTests.test_metrics_errors_and_exactly_once_queue_accounting",
    "RuntimeTests.test_metrics_database_delay_and_failed_request_timing",
    "RuntimeTests.test_metrics_concurrent_scrapes_preserve_snapshots",
    "RuntimeTests.test_metrics_queue_failures_preserve_ownership",
    "RuntimeTests.test_metrics_aborts_preserve_queue_semantics",
)))
REQUIRED_METRICS_UNIT_CHECKS = (
    "zero_exposition", "route_classification", "bucket_boundaries", "decimal_sum_and_capacity",
    "queue_failure", "parallel_snapshot", "clock_failure_begin", "clock_failure_finish",
    "clock_invalid_timespec", "clock_conversion_overflow", "clock_backwards", "overflow_count",
    "overflow_request_counter", "overflow_bucket", "overflow_sum", "overflow_queue_failure",
    "mutex_init_failure", "mutex_lock_failure", "mutex_unlock_failure",
)
METRICS_TOOLS = ("test-metrics", "metrics-faults.so")
METRICS_TOOL_LIMIT = 1024 * 1024
METRICS_OUTPUT_LIMIT = 65536
METRICS_UNIT_TIMEOUT = 35
TEST_LOG_LIMIT = 2 * 1024 * 1024


def bounded_file(path, maximum, *, mode=None, owner=None):
    """Read one regular descriptor without following a symbolic final entry."""
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or (mode is not None and stat.S_IMODE(info.st_mode) != mode)
                or (owner is not None and info.st_uid != owner)):
            raise ValueError("A qualification file has an unexpected type, owner, or mode.")
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("A qualification file exceeds its byte bound.")
    return data


def metrics_json(text):
    def unique(pairs):
        value = {}
        for name, item in pairs:
            if name in value:
                raise ValueError("Duplicate metrics evidence field.")
            value[name] = item
        return value
    def reject_constant(_):
        raise ValueError("Non-finite metrics evidence number.")
    return json.loads(text, object_pairs_hook=unique, parse_constant=reject_constant)


def exact_names(value, required, label):
    if (type(value) is not list or any(type(name) is not str for name in value)
            or len(value) != len(required) or len(set(value)) != len(value) or set(value) != set(required)):
        raise ValueError("The metrics " + label + " identities are incomplete or ambiguous.")


def metrics_unit_contract(value):
    if (type(value) is not dict or set(value) != {"schema", "status", "scope", "checks"}
            or type(value["schema"]) is not int or value["schema"] != 1
            or value["status"] != "pass" or value["scope"] != "assembly-metrics-unit"):
        raise ValueError("The metrics unit report is malformed or did not pass.")
    exact_names(value["checks"], REQUIRED_METRICS_UNIT_CHECKS, "unit-check")


def metrics_evidence_contract(value):
    keys = {"schema", "timing", "samples", "max_response_bytes", "http_tests", "unit", "test_tools"}
    if (type(value) is not dict or set(value) != keys
            or type(value["schema"]) is not int or value["schema"] != 1
            or value["timing"] != "handler-entry-to-accepted-queue"
            or type(value["samples"]) is not int or value["samples"] != 79
            or type(value["max_response_bytes"]) is not int or value["max_response_bytes"] != 16384):
        raise ValueError("The metrics scope, timing, or fixed bounds differ.")
    exact_names(value["http_tests"], REQUIRED_METRICS_HTTP_TESTS, "HTTP-test")
    metrics_unit_contract(value["unit"])
    metrics_test_tools_contract(value["test_tools"])


def metrics_test_tools_contract(tools):
    if type(tools) is not dict or set(tools) != set(METRICS_TOOLS):
        raise ValueError("The metrics test-tool inventory is incomplete.")
    for artifact in tools.values():
        if (type(artifact) is not dict or set(artifact) != {"sha256", "bytes"}
                or type(artifact["sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"])
                or type(artifact["bytes"]) is not int or not 0 < artifact["bytes"] <= METRICS_TOOL_LIMIT):
            raise ValueError("A metrics test-tool digest or byte count is malformed.")


def metrics_descriptor(unit, names, tools):
    value = {"schema": 1, "timing": "handler-entry-to-accepted-queue", "samples": 79,
             "max_response_bytes": 16384, "http_tests": sorted(names), "unit": unit, "test_tools": tools}
    metrics_evidence_contract(value)
    return value


def runtime_case_contract(cases, suite_name):
    require(isinstance(cases, list) and all(isinstance(name, str) and len(name) <= 512 for name in cases),
            "The runtime case identities are malformed.")
    normalized = [".".join(name.split(".")[-2:]) for name in cases]
    exact_names(normalized, REQUIRED_CASE_IDS[suite_name], suite_name + " case")


def runtime_suite_names(suite, suite_name):
    def leaves(value):
        for child in value:
            if isinstance(child, unittest.TestSuite):
                yield from leaves(child)
            else:
                yield ".".join(child.id().split(".")[-2:])
    names = sorted(leaves(suite))
    runtime_case_contract(names, suite_name)
    return names


def metrics_suite_names(suite):
    def leaves(value):
        for child in value:
            if isinstance(child, unittest.TestSuite):
                yield from leaves(child)
            else:
                yield ".".join(child.id().split(".")[-2:])
    found = [name for name in leaves(suite) if name in REQUIRED_METRICS_HTTP_TESTS]
    exact_names(found, REQUIRED_METRICS_HTTP_TESTS, "loaded HTTP-test")
    return sorted(found)


def runtime_result_contract(result, count):
    if (not result.wasSuccessful() or result.skipped or result.expectedFailures
            or result.unexpectedSuccesses or result.testsRun != count):
        raise ValueError("The architecture's complete runtime suite did not pass without exclusions.")


def metrics_tool_inventory(directory, arch, *, root_owned=False):
    result = {}
    for name in METRICS_TOOLS:
        data = bounded_file(directory / name, METRICS_TOOL_LIMIT, mode=0o555,
                            owner=0 if root_owned else os.geteuid())
        elf_contract(data, arch)
        result[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    return result


def parse_metrics_unit_output(data):
    if len(data) > METRICS_OUTPUT_LIMIT:
        raise ValueError("The metrics unit report exceeds its byte bound.")
    lines = [line for line in data.decode("utf-8").splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValueError("Expected one metrics unit success record.")
    value = metrics_json(lines[0])
    metrics_unit_contract(value)
    return value


class MetricsUnitFailure(ValueError):
    def __init__(self, message, stdout, stderr):
        super().__init__(message)
        self.stdout, self.stderr = bytes(stdout), bytes(stderr)


def _metrics_unit_result(arguments, *, timeout):
    """Use the reviewed selector pattern; bound each stream before appending."""
    output, errors = bytearray(), bytearray()
    selector = selectors.DefaultSelector()
    process, completed = None, False
    deadline = time.monotonic() + timeout
    try:
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        for stream, buffer in ((process.stdout, output), (process.stderr, errors)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, buffer)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise MetricsUnitFailure("The metrics unit deadline expired.", output, errors)
            events = selector.select(remaining)
            if not events:
                raise MetricsUnitFailure("The metrics unit deadline expired.", output, errors)
            for key, _ in events:
                buffer = key.data
                room = METRICS_OUTPUT_LIMIT - len(buffer)
                chunk = os.read(key.fd, min(65536, room + 1))
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                buffer.extend(chunk[:room])
                if len(chunk) > room:
                    raise MetricsUnitFailure("Metrics unit output exceeded its byte limit.", output, errors)
        try:
            returncode = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise MetricsUnitFailure("The metrics unit deadline expired.", output, errors) from None
        completed = True
        return subprocess.CompletedProcess(arguments, returncode, bytes(output), bytes(errors))
    finally:
        selector.close()
        if process is not None:
            if not completed or process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=3)
            for stream in (process.stdout, process.stderr):
                if stream is not None and not stream.closed:
                    stream.close()


def run_metrics_unit(path):
    failure = None
    try:
        result = _metrics_unit_result([str(path)], timeout=METRICS_UNIT_TIMEOUT)
        stdout, stderr = result.stdout, result.stderr
    except MetricsUnitFailure as error:
        stdout, stderr, failure = error.stdout, error.stderr, error
        result = None
    # Retain bounded failure diagnostics before rejecting a missing/failed record.
    for stream, data in ((sys.stdout, stdout), (sys.stderr, stderr)):
        data = data[:METRICS_OUTPUT_LIMIT]
        if hasattr(stream, "buffer"):
            stream.buffer.write(data)
        else:
            stream.write(data.decode("utf-8", "replace"))
    if failure is not None:
        raise failure
    if result is None or result.returncode or len(stdout) > METRICS_OUTPUT_LIMIT or len(stderr) > METRICS_OUTPUT_LIMIT:
        raise MetricsUnitFailure("The precompiled metrics unit checks failed or exceeded their output bound.",
                                 stdout[:METRICS_OUTPUT_LIMIT], stderr[:METRICS_OUTPUT_LIMIT])
    return parse_metrics_unit_output(stdout)


def prepare_metrics(suite, directory, arch, *, root_owned=False):
    """Run the unit gate for the suite that executes the six HTTP cases."""
    names = metrics_suite_names(suite)
    tools = metrics_tool_inventory(directory, arch, root_owned=root_owned)
    os.environ["ASM_METRICS_TEST_DIRECTORY"] = str(directory)
    return metrics_descriptor(run_metrics_unit(directory / "test-metrics"), names, tools)


def metrics_image_tools(image, arch, *, runner=None):
    """Bind the two fixed test artifacts through the selected container runner."""
    if runner is None:
        base = ["docker", "run", "--rm", "--platform", "linux/" + arch, *security_arguments()]
        def runner(selected, *arguments, entrypoint):
            return command([*base, "--entrypoint", entrypoint, selected, *arguments]).stdout
    tools = {}
    for name in METRICS_TOOLS:
        path = "/qualification/server/" + name
        mode = runner(image, "-c", "%a:%u:%g", path, entrypoint="/usr/bin/stat").decode()
        require(mode.strip() == "555:0:0", "A metrics qualification tool changed its ownership or mode.")
        data = runner(image, path, entrypoint="/bin/cat")
        require(0 < len(data) <= METRICS_TOOL_LIMIT, "A metrics qualification tool exceeds its byte bound.")
        elf_contract(data, arch)
        tools[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    metrics_test_tools_contract(tools)
    return tools


def metrics_from_test_log(data, tools):
    if len(data) > TEST_LOG_LIMIT:
        raise ValueError("The hosted test log exceeds its byte bound.")
    text = data.decode("utf-8")
    units = []
    for line in text.splitlines():
        if line.startswith("{"):
            value = metrics_json(line)
            if isinstance(value, dict) and value.get("scope") == "assembly-metrics-unit":
                units.append(value)
    if len(units) != 1:
        raise ValueError("Expected one complete metrics unit record in the hosted log.")
    passed = re.findall(r"^(test_metrics_[a-z_]+) \((?:[A-Za-z_][A-Za-z0-9_]*\.)*(RuntimeTests\.\1)\)(?:\n[^\n]*)? \.\.\. ok$", text, re.M)
    required = [name for _, name in passed if name in REQUIRED_METRICS_HTTP_TESTS]
    all_passed = re.findall(r"^test_[a-z_]+ \((?:[A-Za-z_][A-Za-z0-9_]*\.)*([A-Za-z_][A-Za-z0-9_]*\.test_[a-z_]+)\)(?:\n[^\n]*)? \.\.\. ok$", text, re.M)
    exact_names(all_passed, REQUIRED_CASE_IDS["baseline"] + REQUIRED_CASE_IDS["capacity"], "hosted case")
    return metrics_descriptor(units[0], required, tools)


def binary_permissions(value):
    if value.strip() != "555:0:0":
        raise ValueError("The packaged runtime executable must be root-owned with mode 0555 for UID 65532.")
    return {"mode": "0555", "uid": 0, "gid": 0}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def typed_equal(actual, expected):
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(typed_equal(actual[k], v) for k, v in expected.items())
    return actual == expected


def sha256_value(value, *, identifier=False):
    return isinstance(value, str) and re.fullmatch(("sha256:" if identifier else "") + r"[0-9a-f]{64}", value)


def common_evidence_contract(report, arch, revision):
    require(arch in TARGETS and report.get("architecture") == arch and report.get("os") == "linux"
            and report.get("execution") in ("native", "emulated") and report.get("source_revision") == revision,
            "The image part identifies a different target, execution mode, or source.")
    require(all(sha256_value(report.get(key), identifier=True)
                for key in ("runtime_image_id", "qualification_image_id")), "Missing immutable image identity.")
    binary = report.get("binary")
    require(isinstance(binary, dict) and type(binary.get("machine")) is int and binary["machine"] == TARGETS[arch][1]
            and type(binary.get("elf_flags")) is int and sha256_value(binary.get("sha256"))
            and type(binary.get("bytes")) is int and binary["bytes"] > 0
            and binary.get("declared_target") == DECLARED_TARGETS[arch]
            and binary.get("declaration_limit") == DECLARATION_LIMIT, "Incomplete executable identity.")
    flags = binary["elf_flags"]
    require((flags & EF_RISCV_FLOAT_ABI == EF_RISCV_FLOAT_ABI_DOUBLE
             and not flags & ~(EF_RISCV_RVC | EF_RISCV_FLOAT_ABI_DOUBLE)) if arch == "riscv64" else flags == 0,
            "The reported executable ABI differs.")
    require(typed_equal(report.get("binary_permissions"), {"mode": "0555", "uid": 0, "gid": 0}),
            "The image part changed executable ownership or permissions.")
    files = report.get("executable_files")
    require(isinstance(files, dict) and 3 <= len(files) <= 33
            and all(isinstance(name, str) and name.startswith("/") and sha256_value(value) for name, value in files.items())
            and files.get("/usr/local/bin/asm-hub") == binary["sha256"]
            and all(name in files for name in ("/opt/asm/mhd/lib/libmicrohttpd.so.12", "/opt/asm/postgres/lib/libpq.so.5")),
            "The executable or shared-library inventory is incomplete.")
    require(typed_equal(report.get("libraries"), {"libmicrohttpd": "1.0.3", "libpq": "16.15"}),
            "The image part changed its library source versions.")
    fixture = report.get("fixture")
    require(isinstance(fixture, dict) and set(fixture) == {"path", "sha256", "bytes", "mode", "uid", "gid"}
            and fixture.get("path") == FIXTURE_PATH and sha256_value(fixture.get("sha256"))
            and type(fixture.get("bytes")) is int and 0 < fixture["bytes"] <= 1024 * 1024
            and typed_equal({key: fixture[key] for key in ("mode", "uid", "gid")},
                            {"mode": "0444", "uid": 0, "gid": 0}), "The fixed read-only fixture is unqualified.")
    metrics_test_tools_contract(report.get("metrics_test_tools"))
    require(typed_equal(report.get("security"), SECURITY) and typed_equal(report.get("container_limits"), CONTAINER_LIMITS),
            "The image part lacks the required isolation and resource bounds.")


def part_evidence_contract(report, suite, arch, revision):
    require(isinstance(report, dict) and set(report) == PART_FIELDS | ({"metrics"} if suite == "baseline" else set())
            and type(report.get("schema")) is int and report["schema"] == 1
            and report.get("status") == "pass" and report.get("scope") == PART_SCOPE
            and report.get("suite") == suite, "The runtime part is missing, duplicated, excluded, or malformed.")
    common_evidence_contract(report, arch, revision)
    runtime_case_contract(report["cases"], suite)
    require(report["tests_run"] == len(report["cases"]), "The runtime count differs from its case identities.")
    if suite == "baseline":
        metrics_evidence_contract(report.get("metrics"))
        require(typed_equal(report["metrics"]["test_tools"], report["metrics_test_tools"]),
                "The baseline metrics result identifies different qualification tools.")
    require(type(report.get("tests_run")) is int and report["tests_run"] >= SUITES[suite][1]
            and type(report.get("tests_skipped")) is int and report["tests_skipped"] == 0,
            "The complete image part did not pass without skips.")
    seconds = report.get("seconds")
    require(type(seconds) in (int, float) and 0 <= seconds <= 180 and math.isfinite(seconds),
            "The part elapsed time exceeds its unchanged watchdog or is malformed.")


def aggregate_reports(parts, arch, revision):
    require(isinstance(parts, dict) and set(parts) == set(SUITES), "Both distinct runtime parts are required.")
    for name in SUITES:
        part_evidence_contract(parts[name], name, arch, revision)
    first = parts["baseline"]
    require(all(typed_equal(parts["capacity"][key], first[key]) for key in COMMON_FIELDS),
            "The two runtime parts identify different images, source, libraries, fixture, or isolation.")
    count = sum(part["tests_run"] for part in parts.values())
    require(count >= MIN_RUNTIME_TESTS, "The joined image requires at least thirty-four executed cases.")
    return {"schema": 1, "status": "pass", "scope": QUALIFICATION_SCOPE,
            **{key: first[key] for key in COMMON_FIELDS}, "parts": parts, "metrics": first["metrics"],
            "tests_run": count, "tests_skipped": 0,
            "seconds": round(sum(part["seconds"] for part in parts.values()), 3), "test_watchdog_seconds": 360}


def runtime_evidence_contract(evidence, arch, revision):
    required = COMMON_FIELDS | {"schema", "status", "scope", "parts", "tests_run", "tests_skipped", "seconds", "test_watchdog_seconds", "metrics"}
    require(isinstance(evidence, dict) and required <= set(evidence)
            and set(evidence) <= required | {"nonroot_configuration_refusal_exit", "observed_at"}
            and type(evidence.get("schema")) is int and evidence["schema"] == 1
            and evidence.get("status") == "pass" and evidence.get("scope") == QUALIFICATION_SCOPE,
            "The image lacks complete admission qualification.")
    expected = aggregate_reports(evidence["parts"], arch, revision)
    require(all(typed_equal(evidence[key], expected[key]) for key in required - {"parts"}),
            "The aggregate changed a part identity, count, elapsed time, or watchdog budget.")
    if "nonroot_configuration_refusal_exit" in evidence:
        require(type(evidence["nonroot_configuration_refusal_exit"]) is int and evidence["nonroot_configuration_refusal_exit"] == 78,
                "The packaged executable did not reject absent configuration.")


def strict_json(raw):
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON evidence field.")
            result[key] = value
        return result
    def constant(_):
        raise ValueError("Nonfinite JSON evidence value.")
    return json.loads(raw, object_pairs_hook=unique, parse_constant=constant)


def read_evidence(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode), "The evidence report must be a regular file.")
        require(metadata.st_size <= MAX_EVIDENCE_BYTES, "The evidence report exceeds two MiB.")
        body = bytearray()
        while len(body) <= MAX_EVIDENCE_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_EVIDENCE_BYTES + 1 - len(body)))
            if not chunk:
                break
            body.extend(chunk)
        require(len(body) <= MAX_EVIDENCE_BYTES, "The evidence report exceeds two MiB.")
        return strict_json(bytes(body))
    finally:
        os.close(descriptor)


def index_contract(index, expected):
    digest = index.get("digest", "")
    children = index.get("manifests", [])
    if index.get("schemaVersion") != 2 or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("The registry index has no valid immutable descriptor.")
    if len(children) != len(TARGETS) or set(expected) != set(TARGETS):
        raise ValueError("The registry index must contain exactly the three qualified targets.")
    found = {}
    for child in children:
        target = child.get("platform", {})
        arch = target.get("architecture")
        if target.get("os") != "linux" or arch in found or arch not in expected:
            raise ValueError("The registry index has an unexpected or duplicate platform.")
        found[arch] = child.get("digest")
    if found != expected:
        raise ValueError("The registry index changed a qualified child digest.")
    return digest


def image_contract(image, arch, revision, *, qualification=False):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    config = image.get("Config", {})
    require(image.get("Architecture") == arch and image.get("Os") == "linux", "Wrong image target.")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", image.get("Id", "")), "Missing immutable image ID.")
    require(config.get("User") == "65532:65532", "The image must use UID/GID 65532.")
    require(config.get("Labels", {}).get("org.opencontainers.image.revision") == revision,
            "The image source revision differs.")
    require(bool(image.get("RootFS", {}).get("Layers")), "The image has no root filesystem layers.")
    if not qualification:
        require(config.get("Entrypoint") == ["/usr/local/bin/asm-hub"] and config.get("Cmd") == ["serve"],
                "The runtime entrypoint must execute the assembly server directly.")
    return image["Id"]


def elf_contract(data, arch):
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("The runtime must be a little-endian ELF64 executable.")
    kind, machine, version, entry, offset, _, flags, header_size, entry_size, count, *_ = struct.unpack_from(
        "<HHIQQQIHHHHHH", data, 16)
    if kind != 3 or version != 1 or machine != TARGETS[arch][1] or header_size != 64:
        raise ValueError("The runtime ELF target or executable type differs.")
    if arch == "riscv64" and (flags & EF_RISCV_FLOAT_ABI != EF_RISCV_FLOAT_ABI_DOUBLE
                             or flags & ~(EF_RISCV_RVC | EF_RISCV_FLOAT_ABI_DOUBLE)):
        raise ValueError("The RISC-V runtime must declare LP64D without flags outside the RV64GC profile.")
    if entry_size != 56 or not 1 <= count <= 1024 or offset < 64 or offset + count * entry_size > len(data):
        raise ValueError("The runtime ELF program headers exceed the file.")
    stack = []
    for i in range(count):
        header = struct.unpack_from("<IIQQQQQQ", data, offset + i * entry_size)
        if header[0] == 0x6474E551:
            stack.append(header[1])
    if len(stack) != 1 or stack[0] & 1:
        raise ValueError("The runtime must declare one non-executable GNU stack.")
    return {"machine": machine, "elf_flags": flags, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
            "declared_target": dict(DECLARED_TARGETS[arch]), "declaration_limit": DECLARATION_LIMIT}


def runtime_binary_contract(data, arch):
    artifact = elf_contract(data, arch)
    for marker in (b"asm_metrics_test_seed", b"asm_metrics_test_snapshot", b"ASM_METRICS_TEST_FAULT"):
        if marker in data:
            raise ValueError("The runtime contains metrics test hooks or fault configuration.")
    return artifact


def command(arguments, *, timeout=15):
    return subprocess.run(arguments, check=True, capture_output=True, timeout=timeout)


def security_arguments():
    return ["--read-only", "--network", "none", "--user", "65532:65532", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--pids-limit", "128", "--memory", "512m", "--cpus", "2"]


def executable_inventory(execute):
    output = execute("/usr/bin/ldd", "/usr/local/bin/asm-hub").stdout.decode()
    if "not found" in output:
        raise ValueError("A runtime library is missing.")
    paths = sorted(set(re.findall(r"(?:=>\s+)?(/[^\s()]+)", output)))
    if not paths or len(paths) > 32:
        raise ValueError("The runtime library inventory is unavailable or exceeds its bound.")
    paths.append("/usr/local/bin/asm-hub")
    output = execute("/usr/bin/sha256sum", *paths).stdout.decode()
    files = {}
    for line in output.splitlines():
        digest, name = line.split("  ", 1)
        if name not in paths or not re.fullmatch(r"[0-9a-f]{64}", digest) or name in files:
            raise ValueError("The runtime file digest inventory is malformed.")
        files[name] = digest
    if set(files) != set(paths):
        raise ValueError("The runtime file digest inventory is incomplete.")
    return files


def runtime_files(image_id, arch, *, runner=None):
    if runner is not None:
        def execute(executable, *args):
            return subprocess.CompletedProcess([executable, *args], 0,
                stdout=runner(image_id, *args, entrypoint=executable))
        return executable_inventory(execute)
    base = ["docker", "run", "--rm", "--platform", "linux/" + arch, *security_arguments()]
    return executable_inventory(lambda executable, *args: command([*base, "--entrypoint", executable, image_id, *args]))


def fixture_descriptor(mode, digest):
    fields = mode.strip().split(":")
    require(len(fields) == 4 and fields[:3] == ["444", "0", "0"] and fields[3].isdigit(),
            "The fixture must be root-owned with mode 0444.")
    require(sha256_value(digest) and 0 < int(fields[3]) <= 1024 * 1024, "The fixture digest or byte count is invalid.")
    return {"path": FIXTURE_PATH, "sha256": digest, "bytes": int(fields[3]), "mode": "0444", "uid": 0, "gid": 0}


def inside(args):
    if platform.system() != "Linux" or platform.machine() != TARGETS[args.arch][0]:
        raise ValueError("The test process is not running the requested Linux architecture.")
    if os.geteuid() != 65532 or os.getegid() != 65532 or not os.statvfs("/").f_flag & os.ST_RDONLY:
        raise ValueError("The qualification container must use UID/GID 65532 and a read-only root filesystem.")
    if not os.statvfs("/tmp").f_flag & os.ST_NOEXEC:
        raise ValueError("The temporary filesystem must forbid executable code.")
    status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
    if status.get("NoNewPrivs", "").strip() != "1" or int(status.get("CapEff", "1").strip(), 16) != 0:
        raise ValueError("The qualification process has unexpected Linux capabilities or privilege authority.")
    binary = Path("/usr/local/bin/asm-hub")
    artifact = runtime_binary_contract(binary.read_bytes(), args.arch)
    if artifact["sha256"] != args.expected_binary_sha256:
        raise ValueError("The test image changed the runtime executable.")
    info = binary.stat()
    permissions = binary_permissions(f"{stat.S_IMODE(info.st_mode):o}:{info.st_uid}:{info.st_gid}")
    fixture_path = Path(FIXTURE_PATH)
    info = fixture_path.lstat()
    require(stat.S_ISREG(info.st_mode), "The fixed fixture must be a regular file.")
    fixture = fixture_descriptor(f"{stat.S_IMODE(info.st_mode):o}:{info.st_uid}:{info.st_gid}:{info.st_size}",
                                 hashlib.sha256(fixture_path.read_bytes()).hexdigest())
    require(fixture["sha256"] == args.expected_fixture_sha256, "The image part changed the fixed fixture.")
    files = executable_inventory(lambda executable, *values: command([executable, *values]))
    tool_directory = Path("/qualification/server")
    metrics_tools = metrics_tool_inventory(tool_directory, args.arch, root_owned=True)
    mhd = ctypes.CDLL("/opt/asm/mhd/lib/libmicrohttpd.so.12")
    mhd.MHD_get_version.restype = ctypes.c_char_p
    if mhd.MHD_get_version() != b"1.0.3":
        raise ValueError("The loaded HTTP library is not libmicrohttpd 1.0.3.")
    os.environ.update(ASM_SERVER_BINARY=str(binary), ASM_SERVER_SOURCE_REVISION=args.revision,
                      ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin", ASM_PROTO_LIBPQ="/opt/asm/postgres/lib/libpq.so.5",
                      ASM_SERVER_CONNECT_NULL_FIXTURE=FIXTURE_PATH, ASM_METRICS_TEST_DIRECTORY=str(tool_directory))
    sys.path.insert(0, "/qualification/server")
    module = importlib.import_module(SUITES[args.suite][0])
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    case_ids = runtime_suite_names(suite, args.suite)
    metrics = prepare_metrics(suite, tool_directory, args.arch, root_owned=True) if args.suite == "baseline" else None
    count = suite.countTestCases()
    if count < SUITES[args.suite][1]:
        raise ValueError("The runtime qualification part is incomplete.")
    started = time.monotonic()
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    runtime_result_contract(result, count)
    report = {"schema": 1, "status": "pass", "scope": PART_SCOPE, "suite": args.suite,
              "architecture": args.arch, "os": "linux", "execution": args.execution,
              "source_revision": args.revision, "binary": artifact, "binary_permissions": permissions,
              "runtime_image_id": args.runtime_image_id, "qualification_image_id": args.qualification_image_id,
              "fixture": fixture, "metrics_test_tools": metrics_tools, "executable_files": files, "container_limits": dict(CONTAINER_LIMITS),
              "tests_run": result.testsRun, "tests_skipped": 0, "cases": case_ids,
              "seconds": round(time.monotonic() - started, 3),
              "libraries": {"libmicrohttpd": "1.0.3", "libpq": "16.15"}, "security": dict(SECURITY)}
    if metrics is not None:
        report["metrics"] = metrics
    part_evidence_contract(report, args.suite, args.arch, args.revision)
    print(REPORT_PREFIX + json.dumps(report, sort_keys=True))


def run_image_part(args, common, suite, directory):
    name = "asm-server-qualification-" + suite + "-" + uuid.uuid4().hex
    # A failed or timed-out part never leaves a successful aggregate receipt.
    outcome = {"status": "fail", "suite": suite, "timed_out": False, "exit_code": None}
    try:
        try:
            result = subprocess.run(
                ["docker", "run", "--rm", "--name", name, "--platform", "linux/" + args.arch,
                 *security_arguments(), "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=256m,uid=65532,gid=65532,mode=0700",
                 "--entrypoint", "/usr/bin/python3", common["qualification_image_id"], "/qualification/tools/test_server_image.py",
                 "--inside", "--suite", suite, "--arch", args.arch, "--revision", args.revision, "--execution", args.execution,
                 "--runtime-image-id", common["runtime_image_id"], "--qualification-image-id", common["qualification_image_id"],
                 "--expected-binary-sha256", common["binary"]["sha256"], "--expected-fixture-sha256", common["fixture"]["sha256"]],
                capture_output=True, timeout=180)
            stdout, stderr = result.stdout, result.stderr
            outcome["exit_code"] = result.returncode
        except subprocess.TimeoutExpired as error:
            stdout, stderr = error.stdout or b"", error.stderr or b""
            outcome["timed_out"] = True
        (directory / (suite + ".stdout.log")).write_bytes(stdout)
        (directory / (suite + ".stderr.log")).write_bytes(stderr)
        if outcome["timed_out"]:
            raise ValueError(suite + " exceeded its unchanged 180-second image watchdog.")
        require(outcome["exit_code"] == 0, suite + " image qualification failed; inspect its retained raw logs.")
        reports = [line[len(REPORT_PREFIX):] for line in stdout.decode().splitlines() if line.startswith(REPORT_PREFIX)]
        require(len(reports) == 1, "Expected exactly one successful runtime part report.")
        report = strict_json(reports[0])
        part_evidence_contract(report, suite, args.arch, args.revision)
        require(all(typed_equal(report[key], common[key]) for key in COMMON_FIELDS),
                "The image part changed the runtime, source, library, fixture, or isolation binding.")
        (directory / (suite + ".qualification.json")).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        outcome["status"] = "pass"
        return report
    finally:
        (directory / (suite + ".outcome.json")).write_text(json.dumps(outcome, indent=2) + "\n")
        subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=15)


def qualify(args):
    output = Path(args.output)
    output.write_text(json.dumps({"schema": 1, "scope": QUALIFICATION_SCOPE, "status": "fail",
                                 "source_revision": args.revision, "parts": {}}, indent=2) + "\n")
    if args.execution == "native" and platform.machine() != TARGETS[args.arch][0]:
        raise ValueError("The runner architecture cannot supply native qualification for this target.")
    images = []
    for name in (args.image, args.qualification_image):
        result = json.loads(command(["docker", "image", "inspect", name]).stdout)
        if len(result) != 1:
            raise ValueError("Expected one local image.")
        images.append(result[0])
    runtime, test_image = images
    image_id = image_contract(runtime, args.arch, args.revision)
    test_id = image_contract(test_image, args.arch, args.revision, qualification=True)
    layers = runtime["RootFS"]["Layers"]
    if test_image["RootFS"]["Layers"][:len(layers)] != layers:
        raise ValueError("The qualification image does not extend the exact runtime filesystem.")
    base = ["docker", "run", "--rm", "--platform", "linux/" + args.arch, *security_arguments()]
    mode = command([*base, "--entrypoint", "/usr/bin/stat", image_id, "-c", "%a:%u:%g", "/usr/local/bin/asm-hub"])
    permissions = binary_permissions(mode.stdout.decode())
    smoke = subprocess.run([*base, image_id, "serve"], capture_output=True, timeout=15)
    if smoke.returncode != 78 or smoke.stdout:
        raise ValueError("The exact runtime image did not execute as UID 65532 and reject missing configuration with exit 78.")
    files = runtime_files(image_id, args.arch)
    if runtime_files(test_id, args.arch) != files:
        raise ValueError("The qualification layer changed an executable runtime dependency.")
    executable = command(["docker", "run", "--rm", "--platform", "linux/" + args.arch,
                          *security_arguments(), "--entrypoint", "/bin/cat", image_id,
                          "/usr/local/bin/asm-hub"]).stdout
    artifact = runtime_binary_contract(executable, args.arch)
    # Read the qualification-only library without placing it in runtime data storage.
    for forbidden in (FIXTURE_PATH, *("/qualification/server/" + name for name in METRICS_TOOLS),
                      "/usr/bin/cc", "/usr/bin/gcc", "/usr/bin/clang"):
        command([*base, "--entrypoint", "/usr/bin/test", image_id, "!", "-e", forbidden])
    mode = command([*base, "--entrypoint", "/usr/bin/stat", test_id, "-c", "%a:%u:%g:%s", FIXTURE_PATH]).stdout.decode()
    digest = command([*base, "--entrypoint", "/usr/bin/sha256sum", test_id, FIXTURE_PATH]).stdout.decode().split()
    require(len(digest) == 2 and digest[1] == FIXTURE_PATH, "The fixed fixture digest is unavailable.")
    fixture = fixture_descriptor(mode, digest[0])
    metrics_tools = metrics_image_tools(test_id, args.arch)
    common = {"architecture": args.arch, "os": "linux", "execution": args.execution, "source_revision": args.revision,
              "runtime_image_id": image_id, "qualification_image_id": test_id,
              "binary": artifact, "binary_permissions": permissions, "executable_files": files,
              "fixture": fixture, "metrics_test_tools": metrics_tools, "security": dict(SECURITY), "container_limits": dict(CONTAINER_LIMITS),
              "libraries": {"libmicrohttpd": "1.0.3", "libpq": "16.15"}}
    parts = {}
    for suite in SUITES:
        parts[suite] = run_image_part(args, common, suite, output.parent)
    report = aggregate_reports(parts, args.arch, args.revision)
    report.update(nonroot_configuration_refusal_exit=smoke.returncode,
                  observed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    runtime_evidence_contract(report, args.arch, args.revision)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"status": "pass", "tests_run": report["tests_run"], "report": str(output)}))


def publish_index(args):
    if not re.fullmatch(r"sha-" + args.revision + r"-run-[0-9]+-[0-9]+", args.index_tag or ""):
        raise ValueError("The index tag must identify the exact source, run, and attempt.")
    expected = {}
    for arch in TARGETS:
        directory = Path(args.children_directory) / f"server-image-digest-{arch}-{args.revision}"
        ref = (directory / "registry-digest.txt").read_text().strip()
        if not re.fullmatch(re.escape(REPOSITORY) + r"@sha256:[0-9a-f]{64}", ref):
            raise ValueError("A child publication record has an unexpected repository or digest.")
        evidence = read_evidence(directory / "qualification.json")
        runtime_evidence_contract(evidence, arch, args.revision)
        manifest = json.loads(command(["docker", "buildx", "imagetools", "inspect", "--raw", ref]).stdout)
        if manifest.get("config", {}).get("digest") != evidence["runtime_image_id"]:
            raise ValueError("The published child config differs from the tested image ID.")
        config = json.loads(command(["docker", "buildx", "imagetools", "inspect", "--format",
                                     "{{json .Image}}", ref]).stdout)
        if (config.get("architecture") != arch or config.get("os") != "linux"
                or config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.revision") != args.revision):
            raise ValueError("The published child identifies a different platform or source.")
        expected[arch] = ref.split("@", 1)[1]
    reference = REPOSITORY + ":" + args.index_tag
    command(["docker", "buildx", "imagetools", "create", "--tag", reference,
             *(REPOSITORY + "@" + expected[arch] for arch in TARGETS)], timeout=120)
    index = json.loads(command(["docker", "buildx", "imagetools", "inspect", "--format",
                               "{{json .Manifest}}", reference]).stdout)
    digest = index_contract(index, expected)
    # Re-read through the immutable name before recording the combined result.
    immutable = REPOSITORY + "@" + digest
    observed = json.loads(command(["docker", "buildx", "imagetools", "inspect", "--format",
                                  "{{json .Manifest}}", immutable]).stdout)
    if index_contract(observed, expected) != digest:
        raise ValueError("The immutable index read differs from the published descriptor.")
    report = {"schema": 1, "status": "pass", "source_revision": args.revision,
              "index_digest": digest, "reference": immutable, "children": expected,
              "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    Path(args.output).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(immutable)


class ContractTests(unittest.TestCase):
    def metrics_real_child(self, script, timeout=35):
        """Replace only the executable boundary; exercise real pipes and processes."""
        original = subprocess.Popen
        processes, groups = [], []
        def launch(_arguments, **keywords):
            groups.append(keywords.get("start_new_session", False))
            # Keep the RED fixture isolated even when the unfixed runner omits it.
            keywords["start_new_session"] = True
            process = original([sys.executable, "-c", script], **keywords)
            processes.append(process)
            return process
        stdout, stderr = io.StringIO(), io.StringIO()
        started = time.monotonic()
        with patch.object(subprocess, "Popen", side_effect=launch), patch.object(sys, "stdout", stdout), \
                patch.object(sys, "stderr", stderr), \
                patch.object(sys.modules[__name__], "METRICS_UNIT_TIMEOUT", timeout, create=True):
            with self.assertRaises(ValueError) as failure:
                run_metrics_unit(Path("/qualification/server/test-metrics"))
        return processes, groups, time.monotonic() - started, stdout.getvalue(), stderr.getvalue(), failure.exception

    def metrics_child_stopped(self, process, descendant):
        self.assertIsNotNone(process.returncode, "The owned leader was not reaped.")
        with self.assertRaises(ChildProcessError):
            os.waitpid(process.pid, os.WNOHANG)
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(descendant)], capture_output=True,
                               text=True, timeout=2).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), "The owned descendant remains alive.")

    def test_metrics_unit_overflow_stops_owned_group_before_completion(self):
        for stream in (1, 2):
            with self.subTest(stream=stream), tempfile.TemporaryDirectory(prefix="asm-metrics-bound-") as temporary:
                directory = Path(temporary)
                pidfile, marker = directory / "child.pid", directory / "completed"
                script = ("import os,time,pathlib\n"
                    "child=os.fork()\n"
                    "if child == 0:\n"
                    f" pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid()))\n"
                    " time.sleep(2)\n"
                    f" pathlib.Path({str(marker)!r}).write_text('descendant completed')\n"
                    " os._exit(0)\n"
                    f"while not pathlib.Path({str(pidfile)!r}).exists(): time.sleep(0.001)\n"
                    "os.write(1,b'partial stdout\\n');os.write(2,b'partial stderr\\n')\n"
                    f"for _ in range(256): os.write({stream}, b'x'*4096)\n"
                    f"pathlib.Path({str(marker)!r}).write_text('producer completed')\n"
                    "os.waitpid(child,0)\n")
                processes = []
                try:
                    processes, groups, elapsed, stdout, stderr, failure = self.metrics_real_child(script)
                    self.assertLess(elapsed, 1.5, "Overflow was checked only after the child completed.")
                    self.assertFalse(marker.exists(), "The producer reached its post-limit completion marker.")
                    self.assertEqual(groups, [True])
                    self.assertLessEqual(len(failure.stdout), METRICS_OUTPUT_LIMIT)
                    self.assertLessEqual(len(failure.stderr), METRICS_OUTPUT_LIMIT)
                    self.assertLessEqual(len(stdout), METRICS_OUTPUT_LIMIT)
                    self.assertLessEqual(len(stderr), METRICS_OUTPUT_LIMIT)
                    self.assertTrue(stdout.startswith("partial stdout\n"))
                    self.assertTrue(stderr.startswith("partial stderr\n"))
                    self.metrics_child_stopped(processes[0], int(pidfile.read_text()))
                finally:
                    for process in processes:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=3)

    def test_metrics_unit_deadline_stops_owned_group_and_keeps_partial_output(self):
        with tempfile.TemporaryDirectory(prefix="asm-metrics-time-") as temporary:
            directory = Path(temporary)
            pidfile, marker = directory / "child.pid", directory / "completed"
            script = ("import os,time,pathlib\nchild=os.fork()\n"
                "if child == 0:\n"
                f" pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid()))\n"
                " time.sleep(2)\n"
                f" pathlib.Path({str(marker)!r}).write_text('descendant completed')\n"
                " os._exit(0)\n"
                f"while not pathlib.Path({str(pidfile)!r}).exists(): time.sleep(0.001)\n"
                "os.write(1,b'partial stdout\\n');os.write(2,b'partial stderr\\n')\n"
                "os.waitpid(child,0)\n")
            processes = []
            try:
                processes, groups, elapsed, stdout, stderr, failure = self.metrics_real_child(script, timeout=0.2)
                self.assertLess(elapsed, 1.5, "The declared child deadline was not enforced.")
                self.assertFalse(marker.exists())
                self.assertEqual(groups, [True])
                self.assertEqual(failure.stdout, b"partial stdout\n")
                self.assertEqual(failure.stderr, b"partial stderr\n")
                self.assertEqual(stdout, "partial stdout\n")
                self.assertEqual(stderr, "partial stderr\n")
                self.metrics_child_stopped(processes[0], int(pidfile.read_text()))
            finally:
                for process in processes:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)

    def metrics(self):
        return {"schema": 1, "timing": "handler-entry-to-accepted-queue", "samples": 79,
                "max_response_bytes": 16384, "http_tests": list(REQUIRED_METRICS_HTTP_TESTS),
                "unit": {"schema": 1, "status": "pass", "scope": "assembly-metrics-unit",
                         "checks": list(REQUIRED_METRICS_UNIT_CHECKS)},
                "test_tools": {"test-metrics": {"sha256": "a" * 64, "bytes": 120},
                               "metrics-faults.so": {"sha256": "b" * 64, "bytes": 120}}}

    def test_runtime_evidence_requires_metrics_evidence_in_addition_to_a_count(self):
        evidence = {"schema": 1, "status": "pass", "scope": "assembly-canonical-exports",
                    "architecture": "amd64", "os": "linux", "execution": "native",
                    "source_revision": "c" * 40, "tests_run": 22, "tests_skipped": 0, "tests_expected_failures": 0}
        with self.assertRaises(ValueError):
            runtime_evidence_contract(evidence, "amd64", "c" * 40)

    def test_expected_failure_is_not_a_successful_applicable_runtime_case(self):
        class ExpectedFailure(unittest.TestCase):
            @unittest.expectedFailure
            def test_fixture(self):
                self.fail("Fixed expected-failure fixture.")
        result = unittest.TestResult()
        ExpectedFailure("test_fixture").run(result)
        self.assertTrue(result.wasSuccessful(), "This fixture must expose unittest's expected-failure success rule.")
        self.assertEqual(len(result.expectedFailures), 1)
        with self.assertRaises(ValueError):
            runtime_result_contract(result, 1)

    def test_unexpected_success_is_not_a_successful_applicable_runtime_case(self):
        class UnexpectedSuccess(unittest.TestCase):
            @unittest.expectedFailure
            def test_fixture(self):
                pass
        result = unittest.TestResult()
        UnexpectedSuccess("test_fixture").run(result)
        self.assertEqual(len(result.unexpectedSuccesses), 1)
        with self.assertRaises(ValueError):
            runtime_result_contract(result, 1)

    def test_single_report_expected_failure_counts_cannot_bypass_split_evidence(self):
        complete = {"schema": 1, "status": "pass", "scope": "assembly-canonical-exports",
                    "architecture": "amd64", "os": "linux", "execution": "native",
                    "source_revision": "c" * 40, "tests_run": 22, "tests_skipped": 0,
                    "metrics": self.metrics(), "tests_expected_failures": 0}
        with self.assertRaises(ValueError):
            runtime_evidence_contract(complete, "amd64", "c" * 40)
        missing = dict(complete)
        missing.pop("tests_expected_failures")
        for evidence in [missing, *(complete | {"tests_expected_failures": value}
                                    for value in (False, True, 1, -1, "0", None))]:
            with self.subTest(value=evidence.get("tests_expected_failures", "missing")), self.assertRaises(ValueError):
                runtime_evidence_contract(evidence, "amd64", "c" * 40)

    def test_metrics_rejects_wrong_scope_bounds_or_incomplete_identities(self):
        value = self.metrics()
        metrics_evidence_contract(value)
        changes = [{"schema": True}, {"schema": 2}, {"samples": True}, {"samples": 80},
                   {"max_response_bytes": False}, {"max_response_bytes": 65536},
                   {"timing": "completed-transfer"}, {"http_tests": []},
                   {"http_tests": list(REQUIRED_METRICS_HTTP_TESTS[:-1])},
                   {"http_tests": [REQUIRED_METRICS_HTTP_TESTS[0]] * 6}, {"http_tests": "all"},
                   {"unit": {"schema": 1, "status": "fail", "scope": "assembly-metrics-unit", "checks": []}},
                   {"test_tools": {}}, {"unexpected": 1}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                metrics_evidence_contract(value | change)
        for field, bad in (("schema", True), ("checks", list(REQUIRED_METRICS_UNIT_CHECKS[:-1])),
                           ("checks", [REQUIRED_METRICS_UNIT_CHECKS[0]] * 19), ("checks", [False] * 19)):
            changed = self.metrics()
            changed["unit"][field] = bad
            with self.subTest(unit_field=field, bad=bad), self.assertRaises(ValueError):
                metrics_evidence_contract(changed)
        for field, bad in (("bytes", True), ("bytes", 0), ("bytes", 1048577),
                           ("sha256", "not-a-digest"), ("sha256", False)):
            changed = self.metrics()
            changed["test_tools"]["test-metrics"][field] = bad
            with self.subTest(tool_field=field, bad=bad), self.assertRaises(ValueError):
                metrics_evidence_contract(changed)

    def test_loaded_suite_requires_each_metrics_identity_once(self):
        methods = {name.split(".")[-1]: lambda self: None for name in REQUIRED_METRICS_HTTP_TESTS}
        case = type("RuntimeTests", (unittest.TestCase,), methods)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(case)
        self.assertEqual(metrics_suite_names(suite), list(REQUIRED_METRICS_HTTP_TESTS))
        children = list(suite)
        for bad in (children[:-1], children + children[:1]):
            with self.assertRaises(ValueError):
                metrics_suite_names(unittest.TestSuite(bad))

    def test_metrics_tools_require_readonly_regular_target_bytes(self):
        with tempfile.TemporaryDirectory(prefix="asm-metrics-tools-") as temporary:
            directory = Path(temporary)
            for name in METRICS_TOOLS:
                (directory / name).write_bytes(self.elf())
                (directory / name).chmod(0o555)
            inventory = metrics_tool_inventory(directory, "amd64")
            self.assertEqual(inventory["test-metrics"]["bytes"], 120)
            unit = directory / "test-metrics"
            unit.chmod(0o755)
            with self.assertRaises(ValueError):
                metrics_tool_inventory(directory, "amd64")
            unit.unlink()
            unit.symlink_to(directory / "metrics-faults.so")
            with self.assertRaises((OSError, ValueError)):
                metrics_tool_inventory(directory, "amd64")
            unit.unlink()
            unit.write_bytes(b"x" * (METRICS_TOOL_LIMIT + 1))
            unit.chmod(0o555)
            with self.assertRaises(ValueError):
                metrics_tool_inventory(directory, "amd64")

    def test_runtime_rejects_qualification_hooks_without_rejecting_test_tools(self):
        runtime_binary_contract(self.elf(), "amd64")
        for marker in (b"asm_metrics_test_seed", b"asm_metrics_test_snapshot", b"ASM_METRICS_TEST_FAULT"):
            data = self.elf() + marker
            elf_contract(data, "amd64")
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                runtime_binary_contract(data, "amd64")

    def test_failed_metrics_unit_output_is_retained_and_never_a_pass(self):
        result = subprocess.CompletedProcess(["test-metrics"], 1, b"fixture output\n", b"fixture failure\n")
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys.modules[__name__], "_metrics_unit_result", return_value=result), patch.object(sys, "stdout", stdout), \
                patch.object(sys, "stderr", stderr), self.assertRaises(ValueError):
            run_metrics_unit(Path("/qualification/server/test-metrics"))
        self.assertEqual(stdout.getvalue(), "fixture output\n")
        self.assertEqual(stderr.getvalue(), "fixture failure\n")
        valid = json.dumps(self.metrics()["unit"]).encode()
        self.assertEqual(parse_metrics_unit_output(valid)["scope"], "assembly-metrics-unit")
        for data in (b"[]", valid + b"\n" + valid, valid + b"x", valid[:-1] + b',"schema":1}',
                     b"x" * (METRICS_OUTPUT_LIMIT + 1)):
            with self.subTest(data=data[:80]), self.assertRaises(ValueError):
                parse_metrics_unit_output(data)

    def test_metrics_unit_timeout_and_output_overflow_keep_bounded_diagnostics(self):
        timeout = MetricsUnitFailure("The metrics unit deadline expired.", b"partial stdout\n", b"partial stderr\n")
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys.modules[__name__], "_metrics_unit_result", side_effect=timeout), patch.object(sys, "stdout", stdout), \
                patch.object(sys, "stderr", stderr), self.assertRaises(ValueError):
            run_metrics_unit(Path("/qualification/server/test-metrics"))
        self.assertEqual(stdout.getvalue(), "partial stdout\n")
        self.assertEqual(stderr.getvalue(), "partial stderr\n")
        result = subprocess.CompletedProcess(["test-metrics"], 0, b"x" * 65537, b"y" * 65537)
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys.modules[__name__], "_metrics_unit_result", return_value=result), patch.object(sys, "stdout", stdout), \
                patch.object(sys, "stderr", stderr), self.assertRaises(ValueError):
            run_metrics_unit(Path("/qualification/server/test-metrics"))
        self.assertEqual(len(stdout.getvalue()), 65536)
        self.assertEqual(len(stderr.getvalue()), 65536)

    def image(self):
        return {"Id": "sha256:" + "a" * 64, "Architecture": "amd64", "Os": "linux",
                "RootFS": {"Layers": ["sha256:" + "b" * 64]},
                "Config": {"User": "65532:65532", "Entrypoint": ["/usr/local/bin/asm-hub"],
                           "Cmd": ["serve"], "Labels": {"org.opencontainers.image.revision": "c" * 40}}}

    def elf(self, machine=62, stack_flags=6, flags=0):
        # Synthetic ELF headers test rejection only; they are not port evidence.
        header = bytearray(64 + 56)
        header[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
        struct.pack_into("<HHIQQQIHHHHHH", header, 16, 3, machine, 1, 0, 64, 0, flags, 64, 56, 1, 0, 0, 0)
        struct.pack_into("<IIQQQQQQ", header, 64, 0x6474E551, stack_flags, 0, 0, 0, 0, 0, 16)
        return bytes(header)

    def test_image_checks_reject_wrong_architecture_identity_or_authority(self):
        image_contract(self.image(), "amd64", "c" * 40)
        for key, bad in (("Architecture", "arm64"), ("Os", "windows")):
            value = self.image()
            value[key] = bad
            with self.assertRaises(ValueError):
                image_contract(value, "amd64", "c" * 40)
        for key, bad in (("User", "0:0"), ("Entrypoint", ["python"]), ("Cmd", ["migrate"]),
                         ("Labels", {"org.opencontainers.image.revision": "d" * 40})):
            value = self.image()
            value["Config"][key] = bad
            with self.assertRaises(ValueError):
                image_contract(value, "amd64", "c" * 40)

    def test_binary_packaging_rejects_private_or_writable_executable_modes(self):
        self.assertEqual(binary_permissions("555:0:0\n"), {"mode": "0555", "uid": 0, "gid": 0})
        for value in ("700:0:0", "600:0:0", "444:0:0", "777:0:0", "4555:0:0", "555:65532:65532", "invalid"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    binary_permissions(value)
    def test_elf_checks_bytes_instead_of_trusting_the_image_label(self):
        self.assertEqual(elf_contract(self.elf(), "amd64")["machine"], 62)
        for value, arch in ((self.elf(), "arm64"), (self.elf(stack_flags=7), "amd64"),
                            (b"not an ELF", "amd64"), (self.elf()[:-1], "amd64")):
            with self.assertRaises(ValueError):
                elf_contract(value, arch)
        for arch, (_, machine) in TARGETS.items():
            flags = 0x5 if arch == "riscv64" else 0
            self.assertEqual(elf_contract(self.elf(machine, flags=flags), arch)["machine"], machine)

    def test_riscv_elf_requires_lp64d_and_rejects_other_profile_flags(self):
        for flags in (0x4, 0x5):
            with self.subTest(valid_flags=hex(flags)):
                self.assertEqual(elf_contract(self.elf(243, flags=flags), "riscv64")["elf_flags"], flags)
        invalid = {"soft": 0, "soft_rvc": 1, "single": 2, "single_rvc": 3,
                   "quad": 6, "quad_rvc": 7, "rve": 0xc, "tso": 0x14,
                   "rv64ilp32": 0x24, "pure_capability": 0x44,
                   "reserved": 0x84, "nonstandard": 0x01000004}
        for name, flags in invalid.items():
            with self.subTest(invalid_profile=name, flags=hex(flags)):
                with self.assertRaises(ValueError):
                    elf_contract(self.elf(243, flags=flags), "riscv64")

    def test_index_rejects_missing_extra_duplicate_or_changed_children(self):
        expected = {arch: "sha256:" + str(i) * 64 for i, arch in enumerate(TARGETS, 1)}
        index = {"schemaVersion": 2, "digest": "sha256:" + "a" * 64,
                 "manifests": [{"digest": digest, "platform": {"os": "linux", "architecture": arch}}
                               for arch, digest in expected.items()]}
        self.assertEqual(index_contract(index, expected), index["digest"])
        for children in (index["manifests"][:-1], index["manifests"] * 2,
                         index["manifests"] + [{"digest": "sha256:" + "b" * 64,
                                                "platform": {"os": "linux", "architecture": "s390x"}}]):
            with self.assertRaises(ValueError):
                index_contract(dict(index, manifests=children), expected)
        changed = json.loads(json.dumps(index))
        changed["manifests"][0]["digest"] = "sha256:" + "f" * 64
        with self.assertRaises(ValueError):
            index_contract(changed, expected)

    def test_index_refuses_foundation_or_incomplete_admission_evidence(self):
        revision = "c" * 40
        arch = next(iter(TARGETS))
        common = {"architecture": arch, "os": "linux", "execution": "native", "source_revision": revision,
                  "runtime_image_id": "sha256:" + "d" * 64, "qualification_image_id": "sha256:" + "e" * 64,
                  "binary": elf_contract(self.elf(), arch), "binary_permissions": {"mode": "0555", "uid": 0, "gid": 0},
                  "libraries": {"libmicrohttpd": "1.0.3", "libpq": "16.15"},
                  "fixture": {"path": "/qualification/fixtures/connect-null.so", "sha256": "f" * 64,
                              "bytes": 16000, "mode": "0444", "uid": 0, "gid": 0},
                  "metrics_test_tools": self.metrics()["test_tools"],
                  "security": dict(SECURITY), "container_limits": dict(CONTAINER_LIMITS)}
        common["executable_files"] = {"/usr/local/bin/asm-hub": common["binary"]["sha256"],
                                      "/opt/asm/mhd/lib/libmicrohttpd.so.12": "1" * 64,
                                      "/opt/asm/postgres/lib/libpq.so.5": "2" * 64}
        complete = aggregate_reports({name: {**common, "schema": 1, "status": "pass", "scope": PART_SCOPE,
                                             "suite": name, "tests_run": count, "tests_skipped": 0, "seconds": 1.0,
                                             "cases": list(REQUIRED_CASE_IDS[name]),
                                             **({"metrics": self.metrics()} if name == "baseline" else {})}
                                      for name, count in (("baseline", 22), ("capacity", 12))}, arch, revision)
        runtime_evidence_contract(complete, arch, revision)
        with tempfile.TemporaryDirectory(prefix="asm-image-evidence-") as directory:
            child = Path(directory) / f"server-image-digest-{arch}-{revision}"
            child.mkdir()
            (child / "registry-digest.txt").write_text(REPOSITORY + "@sha256:" + "e" * 64 + "\n")
            args = argparse.Namespace(revision=revision, children_directory=directory,
                                      index_tag="sha-" + revision + "-run-1-1")
            for change in ({"scope": "assembly-runtime-foundation"}, {"scope": "unknown"},
                           {"tests_run": 27}, {"tests_run": "28"}, {"scope": "assembly-canonical-exports"}, {"schema": 2}, {"schema": True},
                           {"execution": []}, {"tests_skipped": False},
                           {"status": "fail"}, {"tests_skipped": 1},
                           {"architecture": "wrong"}, {"source_revision": "f" * 40}):
                with self.subTest(change=change):
                    (child / "qualification.json").write_text(json.dumps(complete | change))
                    with patch.object(sys.modules[__name__], "command") as registry:
                        registry.side_effect = AssertionError("Unqualified evidence reached the registry.")
                        with self.assertRaises(ValueError):
                            publish_index(args)
                        registry.assert_not_called()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--suite", choices=SUITES)
    parser.add_argument("--check-evidence", type=Path)
    parser.add_argument("--runtime-image-id")
    parser.add_argument("--qualification-image-id")
    parser.add_argument("--expected-fixture-sha256")
    parser.add_argument("--publish-index", action="store_true")
    parser.add_argument("--arch", choices=TARGETS)
    parser.add_argument("--revision")
    parser.add_argument("--execution", choices=("native", "emulated"))
    parser.add_argument("--expected-binary-sha256")
    parser.add_argument("--image")
    parser.add_argument("--qualification-image")
    parser.add_argument("--output")
    parser.add_argument("--children-directory")
    parser.add_argument("--index-tag")
    args = parser.parse_args()
    if args.self_test:
        unittest.main(argv=[sys.argv[0]], verbosity=2)
        return
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision or ""):
        parser.error("Supply an exact --revision.")
    if args.revision == "0" * 40:
        parser.error("The source revision cannot be zero.")
    if args.publish_index:
        if not args.children_directory or not args.index_tag or not args.output:
            parser.error("Supply --children-directory, --index-tag and --output.")
        publish_index(args)
        return
    if args.check_evidence:
        if not args.arch:
            parser.error("Supply --arch with --check-evidence.")
        runtime_evidence_contract(read_evidence(args.check_evidence), args.arch, args.revision)
        return
    if not args.arch or not args.execution:
        parser.error("Supply --arch and --execution.")
    if args.inside:
        if not re.fullmatch(r"[0-9a-f]{64}", args.expected_binary_sha256 or ""):
            parser.error("Supply --expected-binary-sha256 inside the qualification image.")
        if not args.suite or not sha256_value(args.expected_fixture_sha256):
            parser.error("Supply --suite and --expected-fixture-sha256 inside the image.")
        if not all(sha256_value(value, identifier=True) for value in (args.runtime_image_id, args.qualification_image_id)):
            parser.error("Supply both immutable image IDs inside the image.")
        inside(args)
    else:
        if not args.image or not args.qualification_image or not args.output:
            parser.error("Supply both local image names and --output.")
        qualify(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Server image qualification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
