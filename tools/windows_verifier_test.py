#!/usr/bin/env python3
"""Run the frozen verifier suite on native Windows with bounded JSON evidence.

This development gate does not activate production trust or qualify skipped paths.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import argparse
import ctypes
import contextlib
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import queue
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import threading
import time

import registry

ROOT = Path(__file__).resolve().parents[1]
MACHINES = {"x86_64-windows": 0x8664, "aarch64-windows": 0xAA64}
ABIS = {"x86_64-windows": "Microsoft x64", "aarch64-windows": "Microsoft ARM64"}

PACKAGE = "github.com/stubbi/asm/verifier"
GO_VERSION = "go1.27.3"
MAX_OUTPUT = 16 * 1024 * 1024
MAX_SECONDS = 900
MAX_EVENTS = 100000
REQUIRED = {(PACKAGE, name) for name in (
    "TestWindowsPrivateStateCreation", "TestWindowsRejectUnsafeStateACL",
    "TestWindowsRejectUnsafeExistingRolesBeforeRefresh", "TestWindowsRejectUnsafeFileACL",
    "TestWindowsPrivateCreationBlocksInheritedReadAccess", "TestWindowsRejectJunctionStatePaths",
    "TestWindowsRejectHardLinks", "TestWindowsHeldAncestorsRefuseRename",
    "TestWindowsReplacementFailurePreservesExistingFile", "TestWindowsFlushFailuresPreserveCommittedBytes",
    "TestWindowsRejectAmbiguousStatePaths", "TestWindowsStateLockAcrossProcesses",
    "TestWindowsRootPersistenceObservedBeforeProcessExit", "TestFailedCleanupRetainsRecoveryCheckpoint",
)} | {(PACKAGE + "/cmd/asm-trust", name) for name in (
    "TestWindowsSigningKeyAcceptsPrivateACL", "TestWindowsSigningKeyAcceptsRelativePath",
    "TestWindowsSigningKeyRejectsEveryoneRead", "TestWindowsSigningKeyRejectsNULLDACL",
    "TestWindowsSigningKeyRejectsHardLinks",
)}
PRIVILEGE_SKIPS = {(PACKAGE, "TestWindowsRejectSymbolicLinks"),
                   (PACKAGE, "TestWindowsRejectForeignOwnerWhenRestorePrivilegeExists")}
OTHER_PLATFORM_SKIPS = {(PACKAGE, "TestDarwinAncestorACL")}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pe_machine(path):
    with Path(path).open("rb") as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise ValueError("The Go tool is not a PE executable.")
        offset = struct.unpack_from("<I", header, 60)[0]
        if not 64 <= offset <= 1024 * 1024:
            raise ValueError("The Go tool has an invalid PE offset.")
        stream.seek(offset)
        header = stream.read(26)
    if len(header) != 26 or header[:4] != b"PE\0\0" or struct.unpack_from("<H", header, 24)[0] != 0x20B:
        raise ValueError("The Go tool is not a PE32+ executable.")
    return struct.unpack_from("<H", header, 4)[0]


def native_machine():
    """Use the native Windows ISA, independent of the Python process ISA."""
    if os.name != "nt":
        raise RuntimeError("Native Windows is required. No verifier runtime test was executed.")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    query = kernel.IsWow64Process2
    query.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ushort)]
    query.restype = ctypes.c_int
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    process, native = ctypes.c_ushort(), ctypes.c_ushort()
    if not query(kernel.GetCurrentProcess(), ctypes.byref(process), ctypes.byref(native)):
        raise ctypes.WinError(ctypes.get_last_error())
    return native.value


def source_identity(expected, *, root=ROOT):
    """Require original verifier blobs and the complete regular-file set.

    Source checks run before capture threads start and after they finish.
    The canonical collector receives the same clean Git environment.
    """
    if re.fullmatch(r"[0-9a-f]{40}", expected or "") is None or expected == "0" * 40:
        raise RuntimeError("Use a nonzero full lowercase source commit.")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_LAZY_FETCH="1")
    executable = shutil.which("git", path=environment.get("PATH"))
    if not executable:
        raise RuntimeError("Git is required for exact-source qualification.")
    def git(*args):
        result = subprocess.run([executable, "--no-replace-objects", "-c", "core.hooksPath=/dev/null",
                                 "-c", "core.fsmonitor=false", "-C", str(root), *args],
                                env=environment, capture_output=True, text=True, check=True, timeout=30)
        return result.stdout.strip()
    commit = git("rev-parse", "--verify", "HEAD^{commit}")
    if commit != expected:
        raise RuntimeError("The checkout commit does not match --source-commit.")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise RuntimeError("Qualification requires a clean source checkout.")
    saved_environment = dict(os.environ)
    try:
        os.environ.clear()
        os.environ.update(environment)
        original = registry.git_files(root, expected, "verifier")
    finally:
        os.environ.clear()
        os.environ.update(saved_environment)
    directories = {str(parent) for name in original for parent in PurePosixPath(name).parents}
    pending, inputs = [root / "verifier"], {}
    while pending:
        path = pending.pop()
        info = path.lstat()
        relative = path.relative_to(root / "verifier").as_posix()
        # Windows directory junctions and other reparse points are not regular
        # inputs, even when their stat mode describes a directory.
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise RuntimeError("Verifier source links, junctions, and reparse points are forbidden.")
        if stat.S_ISDIR(info.st_mode):
            if relative not in directories:
                raise RuntimeError("The verifier file set has an extra directory.")
            pending.extend(path.iterdir())
            continue
        if not stat.S_ISREG(info.st_mode) or relative not in original:
            raise RuntimeError("The verifier file set has an extra or nonregular input.")
        data = original[relative][0]
        flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        with os.fdopen(os.open(path, flags), "rb") as stream:
            opened = os.fstat(stream.fileno())
            if not stat.S_ISREG(opened.st_mode) or opened.st_size != len(data) or stream.read(len(data) + 1) != data:
                raise RuntimeError("Verifier input bytes differ from the original Git blob.")
        inputs["verifier/" + relative] = hashlib.sha256(data).hexdigest()
    if set(inputs) != {"verifier/" + name for name in original}:
        raise RuntimeError("The verifier file set is missing original Git inputs.")
    return {"source_commit": commit, "source_tree": git("rev-parse", "HEAD^{tree}"),
            "verifier_tree": git("rev-parse", "HEAD:verifier"), "source_dirty": False,
            "original_verifier_blobs": "exact file set and bytes verified", "inputs_sha256": dict(sorted(inputs.items()))}


def json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Go JSON has a duplicate field.")
        result[key] = value
    return result


def invalid_json_constant(value):
    raise ValueError("Go JSON has an invalid numeric constant.")


def summarize(raw, exit_code, required=REQUIRED):
    if len(raw) > MAX_OUTPUT:
        raise ValueError("Go JSON exceeds the evidence byte limit.")
    outcomes, packages, output, failures, started = {}, {}, {}, [], set()
    for count, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        if count > MAX_EVENTS:
            raise ValueError("Go JSON exceeds the event limit.")
        if not line:
            continue
        event = json.loads(line, object_pairs_hook=json_object, parse_constant=invalid_json_constant)
        if not isinstance(event, dict) or event.get("Action") not in {
            "start", "run", "pause", "cont", "pass", "fail", "skip", "output", "bench"
        }:
            raise ValueError("Go emitted an unknown or malformed test event.")
        package, test, action = event.get("Package"), event.get("Test"), event["Action"]
        if not isinstance(package, str) or not package or (test is not None and (not isinstance(test, str) or not test)):
            raise ValueError("Go test event lacks a package identity.")
        key = (package, test)
        if action == "run":
            if not test or key in started:
                raise ValueError("Go emitted an invalid or duplicate test start.")
            started.add(key)
        if action == "output":
            if not isinstance(event.get("Output"), str):
                raise ValueError("Go emitted invalid test output.")
            output[key] = (output.get(key, "") + event["Output"])[-8192:]
        if action == "fail":
            failures.append({"package": package, "test": test, "failed_build": event.get("FailedBuild")})
        if action in {"pass", "fail", "skip"}:
            if test:
                if key not in started or key in outcomes:
                    raise ValueError("Go emitted an unstarted or duplicate terminal test outcome.")
                outcomes[key] = action
            else:
                if package in packages:
                    raise ValueError("Go emitted duplicate package outcomes.")
                packages[package] = action
    missing = sorted(f"{package}:{test}" for package, test in required if outcomes.get((package, test)) != "pass")
    missing_privilege = sorted(f"{package}:{test}" for package, test in PRIVILEGE_SKIPS
                               if outcomes.get((package, test)) not in {"pass", "skip"})
    unfinished = sorted(f"{package}:{test}" for package, test in started - outcomes.keys())
    skipped = [{"package": package, "test": test, "outcome": "not-run", "detail": output.get((package, test), "")}
               for (package, test), outcome in outcomes.items() if outcome == "skip"]
    unexpected_skips = [item for item in skipped
                        if (item["package"], item["test"]) not in PRIVILEGE_SKIPS | OTHER_PLATFORM_SKIPS]
    privilege_skips = [item for item in skipped if (item["package"], item["test"]) in PRIVILEGE_SKIPS]
    accepted = (exit_code == 0 and not failures and not missing and not missing_privilege and not unfinished and not unexpected_skips
                and all(packages.get(package) == "pass" for package in (PACKAGE, PACKAGE + "/cmd/asm-trust")))
    return {"outcome": ("pass-with-unqualified-paths" if privilege_skips else "pass") if accepted else "fail",
            "required_cases_passed": accepted, "declared_windows_cases_executed": accepted and not privilege_skips,
            "coverage_scope": "The required case set and named privilege cases; not general Windows path or filesystem qualification.",
            "missing_required_cases": missing, "missing_privilege_cases": missing_privilege,
            "unfinished_tests": unfinished, "failures": failures, "skipped_cases": skipped,
            "unqualified_privilege_paths": privilege_skips, "unexpected_skips": unexpected_skips,
            "packages": packages,
            "tests": [{"package": package, "test": test, "outcome": "not-run" if outcome == "skip" else outcome}
                      for (package, test), outcome in sorted(outcomes.items())]}


class WindowsJob:
    """Own a noninherited kill-on-close job; no child may request breakaway."""
    def __init__(self):
        class BasicLimits(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                        ("flags", ctypes.c_uint32), ("minimum_working_set", ctypes.c_size_t),
                        ("maximum_working_set", ctypes.c_size_t), ("active_processes", ctypes.c_uint32),
                        ("affinity", ctypes.c_size_t), ("priority", ctypes.c_uint32),
                        ("scheduling", ctypes.c_uint32)]
        class ExtendedLimits(ctypes.Structure):
            _fields_ = [("basic", BasicLimits), ("io", ctypes.c_uint64 * 6),
                        ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                        ("peak_process_memory", ctypes.c_size_t), ("peak_job_memory", ctypes.c_size_t)]
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p]
        self.kernel.CreateJobObjectW.restype = ctypes.c_void_p
        self.kernel.SetInformationJobObject.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.kernel.SetInformationJobObject.restype = ctypes.c_int
        self.kernel.AssignProcessToJobObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.kernel.AssignProcessToJobObject.restype = ctypes.c_int
        self.kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        self.kernel.CloseHandle.restype = ctypes.c_int
        # A NULL SECURITY_ATTRIBUTES pointer creates a noninherited handle.
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def assign(self, process):
        # CPython retains its CreateProcess handle until this Popen is closed.
        # It avoids reopening a possibly terminated process by numeric PID.
        handle = getattr(process, "_handle", None)
        if handle is None or not self.kernel.AssignProcessToJobObject(self.handle, int(handle)):
            raise RuntimeError("Cannot assign the waiting bootstrap to its Windows job.")

    def close(self):
        if self.handle:
            if not self.kernel.CloseHandle(self.handle):
                raise ctypes.WinError(ctypes.get_last_error())
            self.handle = None


BOOTSTRAP = ("import subprocess,sys\n"
             "if sys.stdin.buffer.read(1) != b'1': sys.exit(125)\n"
             "sys.exit(subprocess.call(sys.argv[1:], stdin=subprocess.DEVNULL))\n")


def capture(argv, cwd, environment, path, *, timeout=MAX_SECONDS, limit=MAX_OUTPUT, stderr_path=None):
    """Bound bytes and time, kill owned descendants, then close stable raw output.

    Only the caller writes the evidence file. Reader threads deliver bounded
    chunks through a bounded queue. Failed cleanup cannot modify a closed file.
    The isolated bootstrap launches Go only after Windows job assignment.
    """
    job = WindowsJob() if os.name == "nt" else None
    command = [sys.executable, "-I", "-c", BOOTSTRAP, *argv] if job else argv
    process = None
    readers = []
    messages, stop = queue.Queue(maxsize=2), threading.Event()
    complete, group_closed, total, problem = set(), False, 0, None

    def close_group():
        nonlocal group_closed
        if group_closed:
            return
        if job:
            job.close()
        elif process:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        group_closed = True

    def deliver(value):
        while not stop.is_set():
            try:
                messages.put(value, timeout=0.05)
                return
            except queue.Full:
                pass

    def read_output(label, stream):
        try:
            while chunk := os.read(stream.fileno(), 65536):
                deliver((label, chunk))
            deliver((label, None))
        except OSError as error:
            deliver((label, error))

    with contextlib.ExitStack() as files:
        outputs = {"stdout": files.enter_context(path.open("wb"))}
        if stderr_path is not None:
            outputs["stderr"] = files.enter_context(stderr_path.open("wb"))
        def retain(label, chunk):
            nonlocal total
            amount = min(len(chunk), limit - total)
            outputs[label].write(chunk[:amount])
            total += amount
            return amount == len(chunk)
        try:
            process = subprocess.Popen(command, cwd=cwd, env=environment,
                stdin=subprocess.PIPE if job else subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE if stderr_path else subprocess.STDOUT, bufsize=0,
                start_new_session=os.name != "nt")
            if job:
                job.assign(process)
                process.stdin.write(b"1")
                process.stdin.close()
            streams = {"stdout": process.stdout}
            if stderr_path is not None:
                streams["stderr"] = process.stderr
            for label, stream in streams.items():
                reader = threading.Thread(target=read_output, args=(label, stream), daemon=True)
                readers.append(reader)
                reader.start()
            deadline = time.monotonic() + timeout
            while len(complete) < len(readers) or process.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Go suite exceeded the overall time limit.")
                if process.poll() is not None:
                    # Even a successful parent can leave a pipe-holding child.
                    close_group()
                try:
                    label, message = messages.get(timeout=0.05)
                except queue.Empty:
                    continue
                if message is None:
                    complete.add(label)
                elif isinstance(message, BaseException):
                    raise RuntimeError("Cannot read Go output.") from message
                elif not retain(label, message):
                    raise RuntimeError("Go suite exceeded the raw JSON byte limit.")
        except BaseException as error:
            problem = error
        finally:
            if process and process.stdin and not process.stdin.closed:
                process.stdin.close()
            try:
                close_group()
            except OSError as error:
                problem = problem or error
            if process:
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired as error:
                        problem = problem or error
            # Drain any already captured failure detail without exceeding bounds.
            until = time.monotonic() + 3
            while readers and len(complete) < len(readers) and time.monotonic() < until:
                try:
                    label, message = messages.get(timeout=0.05)
                except queue.Empty:
                    continue
                if message is None:
                    complete.add(label)
                elif isinstance(message, BaseException):
                    problem = problem or RuntimeError("Cannot finish Go output capture.")
                    break
                else:
                    retain(label, message)
            stop.set()
            for reader in readers:
                reader.join(timeout=1)
            if any(reader.is_alive() for reader in readers) or len(complete) < len(readers):
                problem = problem or RuntimeError("Cannot finish the bounded Go output capture.")
            if process:
                if not any(reader.is_alive() for reader in readers):
                    process.stdout.close()
                    if process.stderr:
                        process.stderr.close()
    if problem:
        raise problem
    return process.returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, choices=tuple(MACHINES))
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args(argv)
    directory = args.evidence.resolve()
    if directory.exists():
        parser.error("Select a new evidence directory. Existing results were preserved.")
    directory.mkdir(parents=True, mode=0o700)
    raw_path = directory / "go-test.jsonl"
    diagnostics_path = directory / "go-stderr.log"
    report = {"schema": "asm-native-windows-verifier-v1", "target": args.target,
              "isa": args.target.removesuffix("-windows"), "os": "windows", "abi": ABIS[args.target],
              "started_utc": datetime.now(timezone.utc).isoformat(), "outcome": "error",
              "host": {"platform": platform.platform(), "machine": platform.machine(),
                       "cpu_identifier": os.environ.get("PROCESSOR_IDENTIFIER"),
                       "image_version": os.environ.get("ImageVersion")}}
    try:
        report.update(source_identity(args.source_commit))
        report["host"]["native_machine"] = native_machine()
        if report["host"]["native_machine"] != MACHINES[args.target]:
            raise RuntimeError("The verifier job is not running on its native Windows ISA.")
        environment = dict(os.environ, GOMAXPROCS="2", GOTOOLCHAIN="local", GOENV="off",
                           GOFLAGS="-mod=readonly", GOWORK="off", GOEXPERIMENT="")
        temporary = Path(environment["LOCALAPPDATA"]) / "Temp"
        if not temporary.is_absolute() or not temporary.is_dir():
            raise RuntimeError("The existing current-user LOCALAPPDATA/Temp directory is absent.")
        for name in ("TEMP", "TMP", "GOTMPDIR"):
            environment[name] = str(temporary)
        report["temporary_root"] = str(temporary)
        report["temporary_root_validation"] = (
            "Directory selection only. Mandatory native securefs tests check actual "
            "temporary ancestors, owner, ACL, and fixed local NTFS. No permissions are repaired.")
        executable = shutil.which("go.exe")
        if not executable or pe_machine(executable) != MACHINES[args.target]:
            raise RuntimeError("The native Go executable is missing or has the wrong PE architecture.")
        report["go_executable"] = {"path": executable, "sha256": digest(executable)}
        cwd = ROOT / "verifier"
        metadata = subprocess.run([executable, "env", "-json", "GOVERSION", "GOHOSTOS", "GOHOSTARCH", "GOOS", "GOARCH",
                                   "GOAMD64", "GOARM64", "GOTMPDIR"], cwd=cwd, env=environment,
                                  capture_output=True, text=True, check=True, timeout=30)
        report["go_environment"] = json.loads(metadata.stdout)
        expected_arch = "amd64" if args.target == "x86_64-windows" else "arm64"
        if (report["go_environment"].get("GOVERSION") != GO_VERSION or
                any(report["go_environment"].get(key) != "windows" for key in ("GOHOSTOS", "GOOS")) or
                any(report["go_environment"].get(key) != expected_arch for key in ("GOHOSTARCH", "GOARCH"))):
            raise RuntimeError("The native verifier requires exactly Go 1.27.3 for its selected Windows target.")
        report["python"] = sys.version
        report["gate_sha256"] = digest(__file__)
        report["test_binary_digests"] = {
            "status": "unavailable", "reason": "Go test controls its temporary executables; no duplicate build is used as execution evidence."}
        report["command"] = [executable, "test", "-p=2", "-count=1", "-timeout=180s", "-json", "./..."]
        started = time.monotonic()
        report["capture_complete"] = False
        code = capture(report["command"], cwd, environment, raw_path, stderr_path=diagnostics_path)
        report["capture_complete"] = True
        report["seconds"] = round(time.monotonic() - started, 6)
        report["exit_code"] = code
        report.update(summarize(raw_path.read_bytes(), code))
        report["post_execution_source"] = source_identity(args.source_commit)
        if report["post_execution_source"]["inputs_sha256"] != report["inputs_sha256"]:
            raise RuntimeError("Verifier input bytes changed during qualification.")
        returncode = 0 if report["required_cases_passed"] else 1
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        report["outcome"] = "error"
        print(f"Native verifier qualification failed: {error}")
        returncode = 2
    finally:
        if raw_path.exists():
            report["raw_output"] = {"file": raw_path.name, "bytes": raw_path.stat().st_size, "sha256": digest(raw_path)}
        if diagnostics_path.exists():
            report["diagnostics"] = {"file": diagnostics_path.name, "bytes": diagnostics_path.stat().st_size,
                                     "sha256": digest(diagnostics_path)}
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        (directory / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return returncode


if __name__ == "__main__":
    raise SystemExit(main())
