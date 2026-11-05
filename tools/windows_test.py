#!/usr/bin/env python3
"""Run the native Windows CLI contract and retain target-bound evidence.

Python supplies test fixtures only. The PE executable implements every command.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import argparse
import ctypes
import contextlib
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MACHINES = {"x86_64-windows": 0x8664, "aarch64-windows": 0xAA64}
ABIS = {"x86_64-windows": "Microsoft x64", "aarch64-windows": "Microsoft ARM64"}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pe_machine(path):
    data = Path(path).read_bytes()
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError("The CLI is not a PE executable.")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset > len(data) - 26 or data[offset:offset + 4] != b"PE\0\0":
        raise ValueError("The CLI has an invalid PE header.")
    if struct.unpack_from("<H", data, offset + 24)[0] != 0x20B:
        raise ValueError("The CLI is not a PE32+ executable.")
    return struct.unpack_from("<H", data, offset + 4)[0]


def native_machine():
    """Ask Windows for the native ISA; platform.machine can describe emulation."""
    if os.name != "nt":
        raise RuntimeError("Native Windows is required. No runtime test was executed.")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    query = kernel.IsWow64Process2
    query.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort),
                      ctypes.POINTER(ctypes.c_ushort)]
    query.restype = ctypes.c_int
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    process, native = ctypes.c_ushort(), ctypes.c_ushort()
    if not query(kernel.GetCurrentProcess(), ctypes.byref(process), ctypes.byref(native)):
        raise ctypes.WinError(ctypes.get_last_error())
    return native.value


def command(argv, *, cwd=None):
    result = subprocess.run(list(map(str, argv)), cwd=cwd or ROOT, capture_output=True,
                            text=True, encoding="utf-8", errors="replace", timeout=30)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} failed ({result.returncode}): {result.stderr}")
    return result.stdout.strip()


def source_identity(expected=None, allow_dirty=False):
    commit = command(["git", "rev-parse", "HEAD"])
    if expected and commit != expected:
        raise RuntimeError("The checkout commit does not match --source-commit.")
    dirty = bool(command(["git", "status", "--porcelain", "--untracked-files=normal"]))
    if dirty and not allow_dirty:
        raise RuntimeError("Qualification requires a clean source checkout. Commit the reviewed source before qualification.")
    result = {"source_commit": commit, "source_dirty": dirty}
    if dirty:
        # A development run binds all source inputs, including untracked files.
        paths = command(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]).split("\0")
        result["experimental_inputs"] = {path: digest(ROOT / path) for path in sorted(paths)
                                         if path and (ROOT / path).is_file()}
    return result


class EvidenceResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.records = []

    def startTest(self, test):
        self.started = time.monotonic()
        super().startTest(test)

    def record(self, test, outcome, detail=None):
        self.records.append({"test": test.id(), "outcome": outcome,
                             "seconds": round(time.monotonic() - getattr(self, "started", time.monotonic()), 6),
                             **({"detail": detail} if detail else {})})

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record(test, "pass")

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.record(test, "fail", self._exc_info_to_string(error, test))

    def addError(self, test, error):
        super().addError(test, error)
        self.record(test, "error", self._exc_info_to_string(error, test))

    def addSkip(self, test, reason):
        # A missing native gate cannot become a green workflow.
        super().addSkip(test, reason)
        self.record(test, "not-run", reason)

    def addSubTest(self, test, subtest, error):
        super().addSubTest(test, subtest, error)
        if error:
            self.record(subtest, "fail", self._exc_info_to_string(error, test))


def require_package_execution(events, target):
    builds = [event for event in events if event.get("phase") == "build"]
    native = [event for event in events if event.get("phase") == "native-execution"]
    observed = set()
    for event in native:
        if event.get("target") != target:
            raise ValueError("A package runtime result has the wrong native target.")
        matches = {build["package"] for build in builds
                   if build.get("target") == target and build.get("source") == event.get("source")
                   and build.get("artifact_sha256") == event.get("artifact_sha256")}
        if len(matches) != 1:
            raise ValueError("A package runtime result lacks one exact build-artifact binding.")
        observed.add((matches.pop().split("-", 1)[0], event["source"], event["case"]))
    required = {("hello", "src/main.s", "stdout"), ("hello", "src/main.s", "read-only-stdout"),
                ("hello", "tests/main.s", "writer-contract"), ("math", "src/main.s", "stdout"),
                ("math", "src/main.s", "read-only-stdout"), ("math", "tests/main.s", "assembly-contract"),
                ("math", "tests/io.s", "assembly-contract")}
    if not required.issubset(observed):
        raise ValueError(f"Required native package cases did not execute: {sorted(required - observed)}")


def run_packages(target, llvm):
    os.environ["CLANG"] = str(llvm / "clang.exe")
    os.environ["LLD_LINK"] = str(llvm / "lld-link.exe")
    directory = ROOT / "tests/packages"
    sys.path.insert(0, str(directory))
    paths = list(directory.glob("*windows.py"))
    for package_target in MACHINES:
        for package in ("hello-" + package_target, "math-" + package_target):
            paths.extend(path for path in (ROOT / "examples" / package).rglob("*") if path.is_file())
    report = {"inputs_sha256": {str(path.relative_to(ROOT)): digest(path) for path in sorted(paths)}}
    report["generated_builds"] = []
    output = io.StringIO()
    suite = unittest.TestLoader().discover(str(directory), pattern="test_*windows.py")
    import test_hello_windows as windows
    original_build = windows.WindowsHelloTests.build

    def observe_build(instance, directory, selected, source):
        result = original_build(instance, directory, selected, source)
        report["generated_builds"].append({"package": selected[0], "target": selected[1], "source": source,
                                           "outputs_sha256": {path.name: digest(path) for path in sorted(directory.iterdir())
                                                              if path.is_file()}})
        return result

    with contextlib.redirect_stdout(output), patch.object(windows.WindowsHelloTests, "build", observe_build):
        result = unittest.TextTestRunner(verbosity=2, resultclass=EvidenceResult).run(suite)
    report.update(tests=result.records, tests_run=result.testsRun, output=output.getvalue(), outcome="fail")
    try:
        report["events"] = [json.loads(line) for line in output.getvalue().splitlines() if line.strip()]
        require_package_execution(report["events"], target)
        if result.testsRun and result.wasSuccessful() and not result.skipped:
            report["outcome"] = "pass"
    except (ValueError, KeyError) as error:
        report["error"] = str(error)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asm", type=Path)
    parser.add_argument("--target", required=True, choices=tuple(MACHINES))
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--toolchain-bin", type=Path,
                        help="Use this installed LLVM directory for fixture builds and tool recording.")
    parser.add_argument("--source-commit", help="Require this exact checkout commit.")
    parser.add_argument("--allow-dirty", action="store_true",
                        help="Run a development check. Its evidence cannot qualify a release.")
    package_scope = parser.add_mutually_exclusive_group()
    package_scope.add_argument("--packages", action="store_true", help="Also require native Windows reference-package execution.")
    package_scope.add_argument("--packages-only", action="store_true", help="Qualify native reference packages independently of the CLI.")
    args = parser.parse_args(argv)
    if not args.packages_only and args.asm is None:
        parser.error("--asm is required for CLI qualification.")
    args.asm = args.asm.resolve() if args.asm else None
    args.evidence = args.evidence.resolve()
    report = {"schema": "asm-windows-qualification-v1", "target": args.target,
              "isa": args.target.removesuffix("-windows"), "os": "windows",
              "abi": ABIS[args.target], "required_cpu_features": None,
              "minimum_supported_os": None,
              "scope": "packages" if args.packages_only else "cli",
              "reference_packages_required": args.packages or args.packages_only,
              "started_utc": datetime.now(timezone.utc).isoformat(),
              "outcome": "error", "qualifies_native_runtime": False, "tests": [], "commands": [],
              "host": {"platform": platform.platform(), "python": sys.version,
                       "machine": platform.machine(),
                       "cpu_identifier": os.environ.get("PROCESSOR_IDENTIFIER"),
                       "image_os": os.environ.get("ImageOS"),
                       "image_version": os.environ.get("ImageVersion")}}
    try:
        report.update(source_identity(args.source_commit, args.allow_dirty))
        if not args.packages_only:
            if not args.asm.is_file():
                raise RuntimeError(f"The CLI executable is absent: {args.asm}")
            report["artifact"] = {"file": args.asm.name, "bytes": args.asm.stat().st_size,
                                  "sha256": digest(args.asm)}
            report["artifact"]["pe_machine"] = pe_machine(args.asm)
            if report["artifact"]["pe_machine"] != MACHINES[args.target]:
                raise RuntimeError("The PE architecture does not match --target.")
        report["host"]["native_machine"] = native_machine()
        report["host"]["observed_windows_version"] = list(sys.getwindowsversion())
        if report["host"]["native_machine"] != MACHINES[args.target]:
            raise RuntimeError("The Windows host architecture does not match --target.")
        if args.toolchain_bin:
            if not args.toolchain_bin.is_dir():
                raise RuntimeError("The toolchain directory is absent.")
            os.environ["PATH"] = str(args.toolchain_bin.resolve()) + os.pathsep + os.environ.get("PATH", "")
        report["tools"] = {}
        llvm = args.toolchain_bin or Path("C:/Program Files/LLVM/bin")
        paths = {"clang.exe": llvm / "clang.exe", "lld-link.exe": llvm / "lld-link.exe"}
        if not args.packages_only:
            paths.update({"curl.exe": Path(os.environ["SystemRoot"]) / "System32/curl.exe",
                          "gzip.exe": Path("C:/Program Files/Git/usr/bin/gzip.exe")})
        for name, path in paths.items():
            if not path.is_file():
                raise RuntimeError(f"Required Windows tool is absent: {name}")
            report["tools"][name] = {"path": str(path), "sha256": digest(path),
                                      "version": command([path, "--version"])}
        passed = True
        if not args.packages_only:
            os.environ["ASM_WINDOWS_EXE"] = str(args.asm)
            os.environ["ASM_WINDOWS_TARGET"] = args.target
            sys.path.insert(0, str(ROOT / "tests/windows"))
            import test_runtime
            test_runtime.COMMANDS = report["commands"]
            test_runtime.TOOLCHAIN_BIN = llvm.resolve()
            report["test_artifacts"] = test_runtime.TEST_ARTIFACTS
            suite = unittest.defaultTestLoader.loadTestsFromModule(test_runtime)
            if not suite.countTestCases():
                raise RuntimeError("The Windows runtime suite contains no tests.")
            result = unittest.TextTestRunner(verbosity=2, resultclass=EvidenceResult).run(suite)
            report["tests"] = result.records
            report["tests_run"] = result.testsRun
            report["artifact"]["sha256_after_tests"] = digest(args.asm)
            passed = (result.wasSuccessful() and not result.skipped and
                      report["artifact"]["sha256_after_tests"] == report["artifact"]["sha256"])
        if args.packages or args.packages_only:
            report["packages"] = run_packages(args.target, llvm.resolve())
            passed = passed and report["packages"]["outcome"] == "pass"
        report["outcome"] = ("experimental-pass" if report["source_dirty"] else "pass") if passed else "fail"
        report["qualifies_native_runtime"] = passed and not report["source_dirty"]
        returncode = 0 if passed else 1
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        print(f"Windows qualification failed: {error}", file=sys.stderr)
        returncode = 2
    finally:
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return returncode


if __name__ == "__main__":
    raise SystemExit(main())
