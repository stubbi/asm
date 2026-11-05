#!/usr/bin/env python3
"""Qualify an assembly server image. This is test orchestration only.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import stat
import struct
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
QUALIFICATION_SCOPE = "assembly-canonical-exports"
MIN_RUNTIME_TESTS = 22
REPOSITORY = "ghcr.io/stubbi/asm-hub"
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
    tools = value["test_tools"]
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


def run_metrics_unit(path):
    try:
        result = subprocess.run([str(path)], capture_output=True, timeout=35)
        stdout, stderr = result.stdout, result.stderr
    except subprocess.TimeoutExpired as error:
        stdout, stderr = error.stdout or b"", error.stderr or b""
        result = None
    # Retain bounded failure diagnostics before rejecting a missing/failed record.
    sys.stdout.write(stdout[:METRICS_OUTPUT_LIMIT].decode("utf-8", "replace"))
    sys.stderr.write(stderr[:METRICS_OUTPUT_LIMIT].decode("utf-8", "replace"))
    if result is None or result.returncode or len(stdout) > METRICS_OUTPUT_LIMIT or len(stderr) > METRICS_OUTPUT_LIMIT:
        raise ValueError("The precompiled metrics unit checks failed, timed out, or exceeded their output bound.")
    return parse_metrics_unit_output(stdout)


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
    passed = re.findall(r"^(test_metrics_[a-z_]+) \((?:[A-Za-z_][A-Za-z0-9_]*\.)*(RuntimeTests\.\1)\) \.\.\. ok$", text, re.M)
    required = [name for _, name in passed if name in REQUIRED_METRICS_HTTP_TESTS]
    return metrics_descriptor(units[0], required, tools)


def binary_permissions(value):
    if value.strip() != "555:0:0":
        raise ValueError("The packaged runtime executable must be root-owned with mode 0555 for UID 65532.")
    return {"mode": "0555", "uid": 0, "gid": 0}


def runtime_evidence_contract(evidence, arch, revision):
    if (not isinstance(evidence, dict) or type(evidence.get("schema")) is not int
            or evidence["schema"] != 1 or evidence.get("status") != "pass"
            or evidence.get("scope") != QUALIFICATION_SCOPE or evidence.get("architecture") != arch
            or evidence.get("os") != "linux" or evidence.get("execution") not in ("native", "emulated")
            or evidence.get("source_revision") != revision
            or type(evidence.get("tests_run")) is not int or evidence["tests_run"] < MIN_RUNTIME_TESTS
            or type(evidence.get("tests_skipped")) is not int or evidence["tests_skipped"] != 0
            or type(evidence.get("tests_expected_failures")) is not int or evidence["tests_expected_failures"] != 0):
        raise ValueError("The image lacks complete canonical-export runtime qualification.")
    metrics_evidence_contract(evidence.get("metrics"))


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


def runtime_files(image_id, arch, *, qualification=False):
    base = ["docker", "run", "--rm", "--platform", "linux/" + arch, *security_arguments()]
    if qualification:
        probe = ["--entrypoint", "/usr/bin/ldd", image_id, "/usr/local/bin/asm-hub"]
    else:
        # Reuse this probe; fixed shell text consumes no request or package data.
        script = ("test ! -e /qualification/server/test-metrics && test ! -L /qualification/server/test-metrics && "
                  "test ! -e /qualification/server/metrics-faults.so && test ! -L /qualification/server/metrics-faults.so && "
                  "exec /usr/bin/ldd /usr/local/bin/asm-hub")
        probe = ["--entrypoint", "/bin/sh", image_id, "-ec", script]
    output = command([*base, *probe]).stdout.decode()
    if "not found" in output:
        raise ValueError("A runtime library is missing.")
    paths = sorted(set(re.findall(r"(?:=>\s+)?(/[^\s()]+)", output)))
    if not paths or len(paths) > 32:
        raise ValueError("The runtime library inventory is unavailable or exceeds its bound.")
    paths.append("/usr/local/bin/asm-hub")
    output = command([*base, "--entrypoint", "/usr/bin/sha256sum", image_id, *paths]).stdout.decode()
    files = {}
    for line in output.splitlines():
        digest, name = line.split("  ", 1)
        if name not in paths or not re.fullmatch(r"[0-9a-f]{64}", digest) or name in files:
            raise ValueError("The runtime file digest inventory is malformed.")
        files[name] = digest
    if set(files) != set(paths):
        raise ValueError("The runtime file digest inventory is incomplete.")
    return files


def inside(args):
    if platform.system() != "Linux" or platform.machine() != TARGETS[args.arch][0]:
        raise ValueError("The test process is not running the requested Linux architecture.")
    if os.geteuid() != 65532 or os.getegid() != 65532 or not os.statvfs("/").f_flag & os.ST_RDONLY:
        raise ValueError("The qualification container must use UID/GID 65532 and a read-only root filesystem.")
    status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
    if status.get("NoNewPrivs", "").strip() != "1" or int(status.get("CapEff", "1").strip(), 16) != 0:
        raise ValueError("The qualification process has unexpected Linux capabilities or privilege authority.")
    binary = Path("/usr/local/bin/asm-hub")
    artifact = runtime_binary_contract(binary.read_bytes(), args.arch)
    if artifact["sha256"] != args.expected_binary_sha256:
        raise ValueError("The test image changed the runtime executable.")
    mhd = ctypes.CDLL("/opt/asm/mhd/lib/libmicrohttpd.so.12")
    mhd.MHD_get_version.restype = ctypes.c_char_p
    if mhd.MHD_get_version() != b"1.0.3":
        raise ValueError("The loaded HTTP library is not libmicrohttpd 1.0.3.")
    libpq = ctypes.CDLL("/opt/asm/postgres/lib/libpq.so.5")
    if libpq.PQlibVersion() != 160015:
        raise ValueError("The loaded database client is not libpq 16.15.")
    tool_directory = Path("/qualification/server")
    metrics_tools = metrics_tool_inventory(tool_directory, args.arch, root_owned=True)
    unit = run_metrics_unit(tool_directory / "test-metrics")
    os.environ.update(ASM_SERVER_BINARY=str(binary), ASM_SERVER_SOURCE_REVISION=args.revision,
                      ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin",
                      ASM_PROTO_LIBPQ="/opt/asm/postgres/lib/libpq.so.5",
                      ASM_METRICS_TEST_DIRECTORY=str(tool_directory))
    spec = importlib.util.spec_from_file_location("asm_image_runtime_tests", "/qualification/server/test_runtime.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    metrics_names = metrics_suite_names(suite)
    count = suite.countTestCases()
    if count < MIN_RUNTIME_TESTS:
        raise ValueError("The runtime qualification suite is incomplete.")
    started = time.monotonic()
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    runtime_result_contract(result, count)
    report = {"schema": 1, "status": "pass", "scope": QUALIFICATION_SCOPE,
              "architecture": args.arch, "os": "linux", "execution": args.execution,
              "source_revision": args.revision, "binary": artifact,
              "tests_run": result.testsRun, "tests_skipped": 0, "tests_expected_failures": len(result.expectedFailures),
              "seconds": round(time.monotonic() - started, 3),
              "metrics": metrics_descriptor(unit, metrics_names, metrics_tools),
              "libraries": {"libmicrohttpd": "1.0.3", "libpq": "16.15"},
              "security": {"uid": 65532, "gid": 65532, "read_only_root": True,
                           "effective_capabilities": 0, "no_new_privileges": True}}
    print(REPORT_PREFIX + json.dumps(report, sort_keys=True))


def qualify(args):
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
    if runtime_files(test_id, args.arch, qualification=True) != files:
        raise ValueError("The qualification layer changed an executable runtime dependency.")
    executable = command(["docker", "run", "--rm", "--platform", "linux/" + args.arch,
                          *security_arguments(), "--entrypoint", "/bin/cat", image_id,
                          "/usr/local/bin/asm-hub"]).stdout
    artifact = runtime_binary_contract(executable, args.arch)
    name = "asm-server-qualification-" + uuid.uuid4().hex
    try:
        result = subprocess.run(
            ["docker", "run", "--rm", "--name", name, "--platform", "linux/" + args.arch,
             *security_arguments(), "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=256m,uid=65532,gid=65532,mode=0700",
             "--entrypoint", "/usr/bin/python3", test_id, "/qualification/tools/test_server_image.py",
             "--inside", "--arch", args.arch, "--revision", args.revision, "--execution", args.execution,
             "--expected-binary-sha256", artifact["sha256"]], capture_output=True, timeout=180)
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        if result.returncode:
            raise ValueError("The image runtime qualification failed.")
        reports = [line[len(REPORT_PREFIX):] for line in result.stdout.decode().splitlines()
                   if line.startswith(REPORT_PREFIX)]
        if len(reports) != 1:
            raise ValueError("Expected one successful runtime qualification report.")
        if len(reports[0].encode("utf-8")) > METRICS_OUTPUT_LIMIT:
            raise ValueError("The runtime qualification report exceeds its byte bound.")
        report = metrics_json(reports[0])
        runtime_evidence_contract(report, args.arch, args.revision)
        if report["binary"] != artifact or report["source_revision"] != args.revision:
            raise ValueError("The image qualification report identifies different bytes or source.")
        report.update(runtime_image_id=image_id, qualification_image_id=test_id,
                      binary_permissions=permissions, nonroot_configuration_refusal_exit=smoke.returncode,
                      executable_files=files,
                      observed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        Path(args.output).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    finally:
        subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=15)


def publish_index(args):
    if not re.fullmatch(r"sha-" + args.revision + r"-run-[0-9]+-[0-9]+", args.index_tag or ""):
        raise ValueError("The index tag must identify the exact source, run, and attempt.")
    expected = {}
    for arch in TARGETS:
        directory = Path(args.children_directory) / f"server-image-digest-{arch}-{args.revision}"
        ref = (directory / "registry-digest.txt").read_text().strip()
        if not re.fullmatch(re.escape(REPOSITORY) + r"@sha256:[0-9a-f]{64}", ref):
            raise ValueError("A child publication record has an unexpected repository or digest.")
        evidence = metrics_json(bounded_file(directory / "qualification.json", TEST_LOG_LIMIT))
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
        with self.assertRaisesRegex(ValueError, "metrics"):
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

    def test_image_report_requires_an_integer_zero_expected_failure_count(self):
        complete = {"schema": 1, "status": "pass", "scope": "assembly-canonical-exports",
                    "architecture": "amd64", "os": "linux", "execution": "native",
                    "source_revision": "c" * 40, "tests_run": 22, "tests_skipped": 0,
                    "metrics": self.metrics(), "tests_expected_failures": 0}
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
        with patch.object(subprocess, "run", return_value=result), patch.object(sys, "stdout", stdout), \
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
        timeout = subprocess.TimeoutExpired("test-metrics", 35, output=b"partial stdout\n", stderr=b"partial stderr\n")
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(subprocess, "run", side_effect=timeout), patch.object(sys, "stdout", stdout), \
                patch.object(sys, "stderr", stderr), self.assertRaises(ValueError):
            run_metrics_unit(Path("/qualification/server/test-metrics"))
        self.assertEqual(stdout.getvalue(), "partial stdout\n")
        self.assertEqual(stderr.getvalue(), "partial stderr\n")
        result = subprocess.CompletedProcess(["test-metrics"], 0, b"x" * 65537, b"y" * 65537)
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(subprocess, "run", return_value=result), patch.object(sys, "stdout", stdout), \
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

    def test_index_refuses_foundation_or_incomplete_catalog_evidence(self):
        revision = "c" * 40
        arch = next(iter(TARGETS))
        complete = {"schema": 1, "status": "pass", "scope": "assembly-canonical-exports",
                    "architecture": arch, "os": "linux", "execution": "native",
                    "source_revision": revision, "tests_run": 22, "tests_skipped": 0, "tests_expected_failures": 0,
                    "metrics": self.metrics(),
                    "runtime_image_id": "sha256:" + "d" * 64}
        runtime_evidence_contract(complete, arch, revision)
        with tempfile.TemporaryDirectory(prefix="asm-image-evidence-") as directory:
            child = Path(directory) / f"server-image-digest-{arch}-{revision}"
            child.mkdir()
            (child / "registry-digest.txt").write_text(REPOSITORY + "@sha256:" + "e" * 64 + "\n")
            args = argparse.Namespace(revision=revision, children_directory=directory,
                                      index_tag="sha-" + revision + "-run-1-1")
            for change in ({"scope": "assembly-runtime-foundation"}, {"scope": "unknown"},
                           {"tests_run": 21}, {"tests_run": "22"}, {"schema": 2}, {"schema": True},
                           {"execution": []}, {"tests_skipped": False}, {"tests_expected_failures": False},
                           {"tests_expected_failures": 1},
                           {"status": "fail"}, {"tests_skipped": 1},
                           {"architecture": "wrong"}, {"source_revision": "f" * 40}):
                with self.subTest(change=change):
                    (child / "qualification.json").write_text(json.dumps(complete | change))
                    with patch.object(sys.modules[__name__], "command") as registry:
                        registry.side_effect = AssertionError("Unqualified evidence reached the registry.")
                        with self.assertRaises(ValueError):
                            publish_index(args)
                        registry.assert_not_called()
            # A permissive parser would accept the final, otherwise valid field.
            (child / "qualification.json").write_text(json.dumps(complete)[:-1] + ',"metrics":' + json.dumps(self.metrics()) + '}')
            with patch.object(sys.modules[__name__], "command") as registry:
                with self.assertRaisesRegex(ValueError, "Duplicate"):
                    publish_index(args)
                registry.assert_not_called()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--inside", action="store_true")
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
    if not args.arch or not args.execution:
        parser.error("Supply --arch and --execution.")
    if args.inside:
        if not re.fullmatch(r"[0-9a-f]{64}", args.expected_binary_sha256 or ""):
            parser.error("Supply --expected-binary-sha256 inside the qualification image.")
        inside(args)
    else:
        if not args.image or not args.qualification_image or not args.output:
            parser.error("Supply both local image names and --output.")
        qualify(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Server image qualification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
