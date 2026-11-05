#!/usr/bin/env python3
"""Qualify an assembly server image. This is test orchestration only.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import platform
import re
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
SUITES = {"baseline": ("test_runtime", 16), "capacity": ("test_capacity", 12)}
MIN_RUNTIME_TESTS = 28
MAX_EVIDENCE_BYTES = 2 * 1024 * 1024
FIXTURE_PATH = "/qualification/fixtures/connect-null.so"
SECURITY = {"uid": 65532, "gid": 65532, "read_only_root": True,
            "effective_capabilities": 0, "no_new_privileges": True}
CONTAINER_LIMITS = {"cpus": 2, "memory_bytes": 536870912, "pids": 128,
                    "tmpfs_bytes": 268435456, "tmpfs_noexec": True, "watchdog_seconds": 180}
COMMON_FIELDS = {"architecture", "os", "execution", "source_revision", "runtime_image_id",
                 "qualification_image_id", "binary", "binary_permissions", "executable_files",
                 "libraries", "fixture", "security", "container_limits"}
PART_FIELDS = COMMON_FIELDS | {"schema", "status", "scope", "suite", "tests_run", "tests_skipped", "seconds"}
REPOSITORY = "ghcr.io/stubbi/asm-hub"


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
    require(typed_equal(report.get("security"), SECURITY) and typed_equal(report.get("container_limits"), CONTAINER_LIMITS),
            "The image part lacks the required isolation and resource bounds.")


def part_evidence_contract(report, suite, arch, revision):
    require(isinstance(report, dict) and set(report) == PART_FIELDS
            and type(report.get("schema")) is int and report["schema"] == 1
            and report.get("status") == "pass" and report.get("scope") == PART_SCOPE
            and report.get("suite") == suite, "The runtime part is missing, duplicated, excluded, or malformed.")
    common_evidence_contract(report, arch, revision)
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
    require(count >= MIN_RUNTIME_TESTS, "The admission image requires at least twenty-eight executed cases.")
    return {"schema": 1, "status": "pass", "scope": QUALIFICATION_SCOPE,
            **{key: first[key] for key in COMMON_FIELDS}, "parts": parts,
            "tests_run": count, "tests_skipped": 0,
            "seconds": round(sum(part["seconds"] for part in parts.values()), 3), "test_watchdog_seconds": 360}


def runtime_evidence_contract(evidence, arch, revision):
    required = COMMON_FIELDS | {"schema", "status", "scope", "parts", "tests_run", "tests_skipped", "seconds", "test_watchdog_seconds"}
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
    artifact = elf_contract(binary.read_bytes(), args.arch)
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
    mhd = ctypes.CDLL("/opt/asm/mhd/lib/libmicrohttpd.so.12")
    mhd.MHD_get_version.restype = ctypes.c_char_p
    if mhd.MHD_get_version() != b"1.0.3":
        raise ValueError("The loaded HTTP library is not libmicrohttpd 1.0.3.")
    os.environ.update(ASM_SERVER_BINARY=str(binary), ASM_SERVER_SOURCE_REVISION=args.revision,
                      ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin", ASM_PROTO_LIBPQ="/opt/asm/postgres/lib/libpq.so.5",
                      ASM_SERVER_CONNECT_NULL_FIXTURE=FIXTURE_PATH)
    sys.path.insert(0, "/qualification/server")
    module = importlib.import_module(SUITES[args.suite][0])
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    count = suite.countTestCases()
    if count < SUITES[args.suite][1]:
        raise ValueError("The runtime qualification part is incomplete.")
    started = time.monotonic()
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    if not result.wasSuccessful() or result.skipped or result.testsRun != count:
        raise ValueError("The architecture's complete runtime part did not pass without skips.")
    report = {"schema": 1, "status": "pass", "scope": PART_SCOPE, "suite": args.suite,
              "architecture": args.arch, "os": "linux", "execution": args.execution,
              "source_revision": args.revision, "binary": artifact, "binary_permissions": permissions,
              "runtime_image_id": args.runtime_image_id, "qualification_image_id": args.qualification_image_id,
              "fixture": fixture, "executable_files": files, "container_limits": dict(CONTAINER_LIMITS),
              "tests_run": result.testsRun, "tests_skipped": 0,
              "seconds": round(time.monotonic() - started, 3),
              "libraries": {"libmicrohttpd": "1.0.3", "libpq": "16.15"}, "security": dict(SECURITY)}
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
    artifact = elf_contract(executable, args.arch)
    # Read the qualification-only library without placing it in runtime data storage.
    for forbidden in (FIXTURE_PATH, "/usr/bin/cc", "/usr/bin/gcc", "/usr/bin/clang"):
        command([*base, "--entrypoint", "/usr/bin/test", image_id, "!", "-e", forbidden])
    mode = command([*base, "--entrypoint", "/usr/bin/stat", test_id, "-c", "%a:%u:%g:%s", FIXTURE_PATH]).stdout.decode()
    digest = command([*base, "--entrypoint", "/usr/bin/sha256sum", test_id, FIXTURE_PATH]).stdout.decode().split()
    require(len(digest) == 2 and digest[1] == FIXTURE_PATH, "The fixed fixture digest is unavailable.")
    fixture = fixture_descriptor(mode, digest[0])
    common = {"architecture": args.arch, "os": "linux", "execution": args.execution, "source_revision": args.revision,
              "runtime_image_id": image_id, "qualification_image_id": test_id,
              "binary": artifact, "binary_permissions": permissions, "executable_files": files,
              "fixture": fixture, "security": dict(SECURITY), "container_limits": dict(CONTAINER_LIMITS),
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
                  "security": dict(SECURITY), "container_limits": dict(CONTAINER_LIMITS)}
        common["executable_files"] = {"/usr/local/bin/asm-hub": common["binary"]["sha256"],
                                      "/opt/asm/mhd/lib/libmicrohttpd.so.12": "1" * 64,
                                      "/opt/asm/postgres/lib/libpq.so.5": "2" * 64}
        complete = aggregate_reports({name: {**common, "schema": 1, "status": "pass", "scope": PART_SCOPE,
                                             "suite": name, "tests_run": count, "tests_skipped": 0, "seconds": 1.0}
                                      for name, count in (("baseline", 16), ("capacity", 12))}, arch, revision)
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
