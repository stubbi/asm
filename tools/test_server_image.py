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
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

TARGETS = {"amd64": ("x86_64", 62), "arm64": ("aarch64", 183), "riscv64": ("riscv64", 243)}
PUBLISHED_TARGETS = ("amd64", "arm64")
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
MIN_RUNTIME_TESTS = 16
REPOSITORY = "ghcr.io/stubbi/asm-hub"


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
            or type(evidence.get("tests_skipped")) is not int or evidence["tests_skipped"] != 0):
        raise ValueError("The image lacks complete canonical-export runtime qualification.")


def index_contract(index, expected):
    digest = index.get("digest", "")
    children = index.get("manifests", [])
    if index.get("schemaVersion") != 2 or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("The registry index has no valid immutable descriptor.")
    if len(children) != len(PUBLISHED_TARGETS) or set(expected) != set(PUBLISHED_TARGETS):
        raise ValueError("The registry index must contain exactly the qualified AMD64 and ARM64 targets.")
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


def require_runtime_success(result, count, diagnostics):
    if not result.wasSuccessful() or result.skipped or result.testsRun != count:
        try:
            record = json.dumps(diagnostics if diagnostics is not None else
                                {"unavailable": "fixture capture did not complete"}, sort_keys=True)
        except Exception as error:
            record = json.dumps({"unavailable": type(error).__name__})
        try:
            print("ASM_SERVER_FAILURE_DIAGNOSTICS=" + record, file=sys.stderr)
        except Exception:
            pass  # A broken diagnostic stream cannot change the failed gate.
        raise ValueError("The architecture's complete runtime suite did not pass without skips.")


def runtime_files(image_id, arch):
    base = ["docker", "run", "--rm", "--platform", "linux/" + arch, *security_arguments()]
    output = command([*base, "--entrypoint", "/usr/bin/ldd", image_id, "/usr/local/bin/asm-hub"]).stdout.decode()
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
    artifact = elf_contract(binary.read_bytes(), args.arch)
    if artifact["sha256"] != args.expected_binary_sha256:
        raise ValueError("The test image changed the runtime executable.")
    mhd = ctypes.CDLL("/opt/asm/mhd/lib/libmicrohttpd.so.12")
    mhd.MHD_get_version.restype = ctypes.c_char_p
    if mhd.MHD_get_version() != b"1.0.3":
        raise ValueError("The loaded HTTP library is not libmicrohttpd 1.0.3.")
    os.environ.update(ASM_SERVER_BINARY=str(binary), ASM_SERVER_SOURCE_REVISION=args.revision,
                      ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin",
                      ASM_PROTO_LIBPQ="/opt/asm/postgres/lib/libpq.so.5")
    spec = importlib.util.spec_from_file_location("asm_image_runtime_tests", "/qualification/server/test_runtime.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    count = suite.countTestCases()
    if count < MIN_RUNTIME_TESTS:
        raise ValueError("The runtime qualification suite is incomplete.")
    started = time.monotonic()
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    require_runtime_success(result, count, getattr(module.RuntimeTests, "failure_diagnostics", None))
    report = {"schema": 1, "status": "pass", "scope": QUALIFICATION_SCOPE,
              "architecture": args.arch, "os": "linux", "execution": args.execution,
              "source_revision": args.revision, "binary": artifact,
              "tests_run": result.testsRun, "tests_skipped": 0,
              "seconds": round(time.monotonic() - started, 3),
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
    if runtime_files(test_id, args.arch) != files:
        raise ValueError("The qualification layer changed an executable runtime dependency.")
    executable = command(["docker", "run", "--rm", "--platform", "linux/" + args.arch,
                          *security_arguments(), "--entrypoint", "/bin/cat", image_id,
                          "/usr/local/bin/asm-hub"]).stdout
    artifact = elf_contract(executable, args.arch)
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
        report = json.loads(reports[0])
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
    for arch in PUBLISHED_TARGETS:
        directory = Path(args.children_directory) / f"server-image-digest-{arch}-{args.revision}"
        ref = (directory / "registry-digest.txt").read_text().strip()
        if not re.fullmatch(re.escape(REPOSITORY) + r"@sha256:[0-9a-f]{64}", ref):
            raise ValueError("A child publication record has an unexpected repository or digest.")
        evidence = json.loads((directory / "qualification.json").read_text())
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
             *(REPOSITORY + "@" + expected[arch] for arch in PUBLISHED_TARGETS)], timeout=120)
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
    def runtime_module(self):
        path = Path(__file__).resolve().parents[1] / "server/test_runtime.py"
        spec = importlib.util.spec_from_file_location("asm_runtime_diagnostic_tests", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_diagnostic_redaction_removes_credentials_in_memory(self):
        module = self.runtime_module()
        secret = "a" * 48
        self.assertEqual(module.redact_diagnostic_text("fixture " + secret + "\n", secret),
                         "fixture [redacted]\n")
        for scheme in ("postgresql", "postgres"):
            text = 'fixture "' + scheme + '://user:password@localhost/db"\n'
            self.assertEqual(module.redact_diagnostic_text(text), 'fixture "[redacted]"\n')
        for absent in (None, "", 1):
            self.assertEqual(module.redact_diagnostic_text("plain diagnostic text", absent),
                             "plain diagnostic text")

        # Exercise the real tail reader without writing credential-shaped data.
        for text, limit, expected in (
                ("fixture " + secret + " postgresql://user:password@localhost/db\n", 256,
                 "fixture [redacted] [redacted]\n"),
                ("postgresql://user:" + secret + "@localhost/db\nretained line\n", 32, "retained line\n")):
            stream = io.BytesIO(text.encode())
            stream.fileno = lambda: 0
            metadata = type("Metadata", (), {"st_mode": module.stat.S_IFREG, "st_size": len(stream.getvalue())})()
            with patch.object(module.os, "open", return_value=0), \
                 patch.object(module.os, "fdopen", return_value=stream), \
                 patch.object(module.os, "fstat", return_value=metadata):
                self.assertEqual(module.diagnostic_file(Path("in-memory-log"), limit, tail=True,
                                                       secret=secret)["text"], expected)

    def test_runtime_log_capture_is_bounded_and_refuses_links(self):
        module = self.runtime_module()
        with tempfile.TemporaryDirectory(prefix="asm-runtime-diagnostics-") as directory:
            root = Path(directory)
            log = root / "server.log"
            log.write_bytes(b"discarded prefix\n" * 100 + b"plain retained line\n")
            value = module.diagnostic_file(log, 256, tail=True)
            self.assertTrue(value["truncated"])
            self.assertLessEqual(len(value["text"].encode()), 256)
            self.assertIn("plain retained line\n", value["text"])
            log.write_text("discarded partial line " + "x" * 64 + "\nretained line\n")
            self.assertEqual(module.diagnostic_file(log, 32, tail=True)["text"],
                             "retained line\n")
            link = root / "linked.log"
            link.symlink_to(log)
            for path in (link, root / "missing.log", root):
                with self.subTest(path=path):
                    self.assertIn("unavailable", module.diagnostic_file(path, 256, tail=True))
            counters = root / "cgroup"
            counters.mkdir()
            (counters / "cpu.stat").write_text("usage_usec 123\nnr_throttled 2\n")
            snapshot = module.cgroup_snapshot(counters)
            self.assertEqual(snapshot["cpu.stat"]["text"], "usage_usec 123\nnr_throttled 2\n")
            self.assertIn("unavailable", snapshot["memory.events"])
            with patch.object(module, "diagnostic_file", side_effect=RuntimeError("private counter detail")):
                self.assertEqual(module.cgroup_snapshot(counters), {"unavailable": "RuntimeError"})

    def test_concurrent_diagnostics_preserve_status_body_and_exception_failures(self):
        module = self.runtime_module()
        exports = {"/registry/v1/" + name: b"expected" for name in
                   ("index.tsv", "index-macos.tsv", "index-all.tsv", "index.json")}
        for status, body in ((503, b"unavailable"), (200, b"wrong bytes")):
            with self.subTest(status=status):
                case = module.RuntimeTests("test_concurrent_exports_keep_independent_response_ownership")
                case.exports = exports
                case.raw_request = lambda path: (status, {}, body)
                result = unittest.TestResult()
                case.run(result)
                self.assertEqual(len(result.failures), 8)
                requests = case.concurrent_wave["requests"]
                self.assertEqual([value["path"] for value in requests], list(exports) * 2)
                self.assertEqual([value["status"] for value in requests], [status] * 8)
                self.assertTrue(all(value["seconds"] >= 0 for value in requests))
        case.raw_request = lambda path: (_ for _ in ()).throw(TimeoutError("private exception detail"))
        result = unittest.TestResult()
        case.run(result)
        self.assertEqual(len(result.errors), 1)
        requests = case.concurrent_wave["requests"]
        self.assertTrue(any(value.get("error") == "TimeoutError" for value in requests))
        self.assertTrue(all(value.get("error") == "TimeoutError" or "unavailable" in value for value in requests))
        self.assertNotIn("private exception detail", json.dumps(case.concurrent_wave))

    def test_fixture_diagnostics_survive_owned_postgres_cleanup(self):
        module = self.runtime_module()
        fixture = module.RuntimeTests
        with tempfile.TemporaryDirectory(prefix="asm-runtime-log-retention-") as directory:
            fixture.base = Path(directory)
            fixture.cluster = module.LocalPostgres(fixture.base)
            fixture.cluster.temp = tempfile.TemporaryDirectory(dir=directory)
            fixture.cluster.base = Path(fixture.cluster.temp.name)
            fixture.cluster.password = "b" * 48
            fixture.concurrent_wave = {"requests": []}
            (fixture.base / "server.log").write_text("fixed server error\n")
            pg_log = fixture.cluster.base / "postgres.log"
            pg_log.write_text("fixed PostgreSQL error\n")
            fixture.retain_diagnostics()
            fixture.cluster.close()
            self.assertFalse(pg_log.exists())
            self.assertEqual(fixture.failure_diagnostics["logs"]["postgres"]["text"],
                             "fixed PostgreSQL error\n")
            self.assertEqual(fixture.failure_diagnostics["logs"]["server"]["text"], "fixed server error\n")
            with patch.object(module, "diagnostic_file", side_effect=RuntimeError("private error detail")):
                fixture.retain_diagnostics()
            self.assertEqual(fixture.failure_diagnostics, {"unavailable": "RuntimeError"})

    def test_failed_runtime_suite_emits_diagnostics_without_qualifying(self):
        from contextlib import redirect_stderr

        def fail():
            raise AssertionError("synthetic runtime failure")

        diagnostics = {"logs": {"server": {"text": "fixed fixture error"}}}
        for action, skipped in ((lambda: None, False), (fail, False),
                                (lambda: self.skipTest("synthetic skip"), True)):
            suite = unittest.TestSuite(unittest.FunctionTestCase(action) for _ in range(MIN_RUNTIME_TESTS))
            result = unittest.TestResult()
            suite.run(result)
            output = io.StringIO()
            with redirect_stderr(output):
                if action is fail or skipped:
                    with self.assertRaises(ValueError):
                        require_runtime_success(result, MIN_RUNTIME_TESTS, diagnostics)
                else:
                    require_runtime_success(result, MIN_RUNTIME_TESTS, diagnostics)
            if action is fail or skipped:
                prefix = "ASM_SERVER_FAILURE_DIAGNOSTICS="
                self.assertTrue(output.getvalue().startswith(prefix))
                self.assertEqual(json.loads(output.getvalue()[len(prefix):]), diagnostics)
            else:
                self.assertEqual(output.getvalue(), "")
        # A diagnostic serialization or output failure must retain the failed gate.
        suite = unittest.TestSuite([unittest.FunctionTestCase(fail)])
        result = unittest.TestResult()
        suite.run(result)
        output = io.StringIO()
        with redirect_stderr(output), self.assertRaisesRegex(ValueError, "complete runtime suite"):
            require_runtime_success(result, MIN_RUNTIME_TESTS, {"not JSON": object()})
        self.assertIn('"unavailable": "TypeError"', output.getvalue())
        with patch.object(sys, "stderr") as stream:
            stream.write.side_effect = OSError("diagnostic stream unavailable")
            with self.assertRaisesRegex(ValueError, "complete runtime suite"):
                require_runtime_success(result, MIN_RUNTIME_TESTS, diagnostics)

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
        expected = {arch: "sha256:" + str(i) * 64 for i, arch in enumerate(PUBLISHED_TARGETS, 1)}
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

    def test_native_index_excludes_the_experimental_riscv_server(self):
        self.assertIn("riscv64", TARGETS)  # The manual full-suite target remains available.
        expected = {"amd64": "sha256:" + "1" * 64, "arm64": "sha256:" + "2" * 64}
        children = [{"digest": digest, "platform": {"os": "linux", "architecture": arch}}
                    for arch, digest in expected.items()]
        index = {"schemaVersion": 2, "digest": "sha256:" + "a" * 64, "manifests": children}
        self.assertEqual(index_contract(index, expected), index["digest"])
        experimental = {**expected, "riscv64": "sha256:" + "3" * 64}
        index["manifests"] = [*children, {"digest": experimental["riscv64"],
                                         "platform": {"os": "linux", "architecture": "riscv64"}}]
        with self.assertRaises(ValueError):
            index_contract(index, experimental)

    def test_index_refuses_foundation_or_incomplete_catalog_evidence(self):
        revision = "c" * 40
        arch = next(iter(TARGETS))
        complete = {"schema": 1, "status": "pass", "scope": "assembly-canonical-exports",
                    "architecture": arch, "os": "linux", "execution": "native",
                    "source_revision": revision, "tests_run": 16, "tests_skipped": 0,
                    "runtime_image_id": "sha256:" + "d" * 64}
        runtime_evidence_contract(complete, arch, revision)
        with tempfile.TemporaryDirectory(prefix="asm-image-evidence-") as directory:
            child = Path(directory) / f"server-image-digest-{arch}-{revision}"
            child.mkdir()
            (child / "registry-digest.txt").write_text(REPOSITORY + "@sha256:" + "e" * 64 + "\n")
            args = argparse.Namespace(revision=revision, children_directory=directory,
                                      index_tag="sha-" + revision + "-run-1-1")
            for change in ({"scope": "assembly-runtime-foundation"}, {"scope": "unknown"},
                           {"tests_run": 15}, {"tests_run": "16"}, {"schema": 2}, {"schema": True},
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
