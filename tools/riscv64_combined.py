#!/usr/bin/env python3
"""Qualify a candidate CLI against the extracted RISC-V server package.

SPDX-License-Identifier: AGPL-3.0-or-later
This is test infrastructure. Application behavior remains in assembly.
"""
import argparse
import ast
from datetime import datetime, timezone
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import selectors
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
HOSTED_REVISION = "4fe2c25277ed40a163b48b727ab814225d227cf8"
PACKAGE_REVISION = "04c93b3f0200173298d24f22a06393bc359a1af0"
SUITE_FILES = {"test_fixture.py": 2, "test_server.py": 14,
               "test_runtime_versions.py": 1, "test_package.py": 2}

LOG_BYTE_LIMIT = 4 * 1024 * 1024
RUNTIME_LOG_BYTE_LIMIT = 16 * 1024 * 1024
EVIDENCE_TOTAL_LIMIT = 128 * 1024 * 1024
EVIDENCE_LIMITS = {name + ".log": LOG_BYTE_LIMIT for name in
                   ("generated_source", "cli_build", "first_project", "native_link",
                    "prepare_package", "pack_package", "server_package")}
EVIDENCE_LIMITS.update({"qualification.json": 1024 * 1024,
                        "asm-riscv64-linux": 64 * 1024 * 1024,
                        "asm-server-riscv64-linux": 64 * 1024 * 1024,
                        "asm-server-source.tar.gz": 16 * 1024 * 1024})
EVIDENCE_FILE_LIMIT = len(EVIDENCE_LIMITS)
TAR_OVERHEAD_LIMIT = 64 * 1024


def bounded_process(arguments, log, *, cwd=None, timeout=30, max_bytes=LOG_BYTE_LIMIT):
    """Drain one merged pipe under byte/time limits, even after its leader exits.

    The caller owns log. A bound failure kills the original process group and
    keeps at most max_bytes of output. The deadline includes descendant pipes.
    """
    if timeout <= 0 or max_bytes < 0:
        raise ValueError("Use a positive deadline and a nonnegative byte limit.")
    started = time.monotonic()
    size = 0
    failure = None
    process = subprocess.Popen(list(map(str, arguments)), cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pipe_open = True
    completed = False
    try:
        with log.open("wb") as stream:
            while pipe_open or process.poll() is None:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    failure = "deadline"
                    break
                if not pipe_open:
                    time.sleep(min(0.01, remaining))
                    continue
                for key, _ in selector.select(min(0.1, remaining)):
                    data = os.read(key.fd, min(65536, max_bytes - size + 1))
                    if not data:
                        selector.unregister(process.stdout)
                        pipe_open = False
                        break
                    accepted = data[:max_bytes - size]
                    stream.write(accepted)
                    size += len(accepted)
                    if len(data) != len(accepted):
                        failure = "byte-limit"
                        break
                if failure:
                    break
            completed = True
    finally:
        if not completed or failure or process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        selector.close()
        process.stdout.close()
        process.wait(timeout=2)
    return {"outcome": "pass" if not failure and process.returncode == 0 else "fail",
            "exit_code": process.returncode, "failure": failure, "bytes": size,
            "seconds": round(time.monotonic() - started, 3)}


def collect_file(arguments, filename, destination, budget, *, max_bytes=None, timeout=20):
    """Receive one allowlisted regular tar member under host-enforced limits.

    The transport is bounded before parsing. Finalization occurs only after
    all member, file-count, and aggregate-byte checks pass.
    """
    if filename not in EVIDENCE_LIMITS or budget["files"] >= EVIDENCE_FILE_LIMIT:
        raise ValueError("The guest evidence file count or name exceeds its allowlist.")
    limit = EVIDENCE_LIMITS[filename] if max_bytes is None else min(max_bytes, EVIDENCE_LIMITS[filename])
    remaining = EVIDENCE_TOTAL_LIMIT - budget["bytes"]
    if remaining < 0:
        raise ValueError("The guest evidence exceeds its aggregate byte limit.")
    with tempfile.TemporaryDirectory(prefix=".asm-collect-", dir=destination) as temporary:
        base = Path(temporary)
        archive = base / "transport.tar"
        result = bounded_process(arguments, archive, timeout=timeout,
                                 max_bytes=min(limit, remaining) + TAR_OVERHEAD_LIMIT)
        if result["outcome"] != "pass":
            raise ValueError(f"Cannot collect {filename}: bounded transport failed ({result['failure'] or result['exit_code']}).")
        stage = base / "member"
        # Fixed short filenames need no tar extensions. Parse only the first
        # 512-byte header, so a hostile PAX length cannot allocate unbounded data.
        with archive.open("rb") as packed:
            header = packed.read(512)
            if len(header) != 512:
                raise ValueError("The guest evidence tar header is truncated.")
            member = tarfile.TarInfo.frombuf(header, encoding="utf-8", errors="strict")
            if (member.name != filename or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE)
                    or member.size < 0 or member.size > limit or member.size > remaining):
                raise ValueError(f"Cannot collect {filename}: unexpected member type, name, or size.")
            with stage.open("xb") as stream:
                left = member.size
                while left:
                    data = packed.read(min(65536, left))
                    if not data:
                        raise ValueError("The guest evidence tar member is truncated.")
                    stream.write(data)
                    left -= len(data)
            # Reject extra members and nonzero padding before finalization.
            trailing = 0
            while data := packed.read(65536):
                trailing += len(data)
                if any(data):
                    raise ValueError(f"Cannot collect {filename}: the archive contains extra members.")
            padding = (-member.size) % 512
            if trailing < padding + 1024 or (archive.stat().st_size % 512):
                raise ValueError("The guest evidence tar end records are truncated.")
        os.replace(stage, destination / filename)
        budget["bytes"] += member.size
        budget["files"] += 1


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(directory):
    entries = [(path.relative_to(directory).as_posix(), sha256(path))
               for path in sorted(directory.rglob("*")) if path.is_file()]
    return hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def elf_machine(data):
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("A guest executable must use little-endian ELF64.")
    kind, machine = struct.unpack_from("<HH", data, 16)
    if machine != 243 or kind not in (2, 3):
        raise ValueError("Use actual RISC-V guest executables, not host cross-tools.")
    return machine


def compiler_contract(target):
    if not re.fullmatch(r"riscv64-[a-z0-9_-]+", target):
        raise ValueError("The fixed guest compiler must target RISC-V64.")


def suite_contract(output, expected):
    counts = re.findall(r"^Ran (\d+) tests? in [0-9.]+s$", output, re.M)
    if (counts != [str(expected)] or not re.search(r"^OK\s*$", output, re.M)
            or re.search(r"\bskipped\b|^FAILED\b|^ERROR\b", output, re.M)):
        raise ValueError(f"Require all {expected} tests to pass without skips.")
    return expected


def result_contract(result):
    server = result.get("checks", {}).get("server_package", {})
    if (result.get("outcome") != "pass" or result.get("target") != "riscv64-linux"
            or result.get("execution") != "qemu-user" or result.get("native_qualified") is not False
            or result.get("release_qualified") is not False or server.get("outcome") != "pass"
            or server.get("tests_run") != 19 or server.get("tests_skipped") != 0):
        raise ValueError("The collected report lacks the scoped, complete 19-test server result.")


def command(arguments, *, cwd=None, timeout=30):
    with tempfile.TemporaryDirectory(prefix="asm-combined-command-") as temporary:
        log = Path(temporary) / "output"
        result = bounded_process(arguments, log, cwd=cwd, timeout=timeout)
        data = log.read_bytes()
        if result["outcome"] != "pass":
            raise ValueError(f"The bounded command failed ({result['failure'] or result['exit_code']}): {arguments[0]}")
        return subprocess.CompletedProcess(arguments, 0, stdout=data, stderr=b"")


def prepare_context(destination, revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision) or revision == "0" * 40:
        raise ValueError("Use an exact nonzero candidate commit.")
    if command(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.decode().strip() != revision:
        raise ValueError("The candidate revision must match the workflow checkout.")
    destination.mkdir(parents=True, exist_ok=False)
    inputs = {"schema": 1, "candidate_revision": revision,
              "hosted_revision": HOSTED_REVISION, "package_revision": PACKAGE_REVISION,
              "archives": {}}
    selections = (("hosted", HOSTED_REVISION, ("containers/server.Dockerfile", ".dockerignore", "server", "LICENSE")),
                  ("package-source", PACKAGE_REVISION, ("experiments/assembly-server", "tools/registry.py", "LICENSE")),
                  ("candidate", revision, ()))
    for name, commit, paths in selections:
        archive = destination / (name + ".tar")
        with archive.open("wb") as stream:
            subprocess.run(["git", "archive", "--format=tar", commit, *paths], cwd=ROOT,
                           stdout=stream, check=True, timeout=60)
        target = destination / name
        target.mkdir()
        with tarfile.open(archive) as source:
            # Git commits are fixed inputs. Still reject links and special members.
            if any(not (member.isdir() or member.isfile()) for member in source.getmembers()):
                raise ValueError("Qualification source archives must contain regular files and directories.")
            source.extractall(target, filter="data")
        inputs["archives"][name] = {"commit": commit, "sha256": sha256(archive),
                                     "tree_sha256": tree_digest(target), "bytes": archive.stat().st_size}
    write_report(destination / "input-manifest.json", inputs)


def initial_report():
    return {"schema": 1, "scope": "riscv64-cli-extracted-server-package",
            "target": "riscv64-linux", "execution": "qemu-user", "outcome": "fail",
            "native_qualified": False, "release_qualified": False,
            "started_at": datetime.now(timezone.utc).isoformat(), "checks": {},
            "limits": ["User-mode emulation shares the host Linux kernel.",
                       "Full CLI kernel fault-injection qualification is separate.",
                       "The disposable build container has a writable root filesystem.",
                       "No native hardware, release, publication, or deployment qualification follows."]}


def test_count(path):
    return sum(isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_")
               for node in ast.walk(ast.parse(path.read_text())))


def inside(output):
    report = initial_report()
    stage = "guest_environment"
    try:
        report["host"] = platform.uname()._asdict()
        if platform.system() != "Linux" or platform.machine() != "riscv64" or os.geteuid() != 65532:
            raise ValueError("Use the RISC-V Linux guest as UID 65532.")
        inputs = json.loads(Path("/inputs/input-manifest.json").read_text())
        if inputs["hosted_revision"] != HOSTED_REVISION or inputs["package_revision"] != PACKAGE_REVISION:
            raise ValueError("The qualification input commits do not match the reviewed pins.")
        report["inputs"] = inputs
        for name in ("candidate", "package-source"):
            if tree_digest(Path("/inputs") / name) != inputs["archives"][name]["tree_sha256"]:
                raise ValueError("The image changed a recorded source context.")
        report["tools"] = {}
        for name in ("cc", "as", "ld", "readelf"):
            path = Path("/usr/bin") / name
            data = path.read_bytes()
            elf_machine(data)
            report["tools"][name] = {"path": str(path), "resolved_path": str(path.resolve()),
                                     "sha256": sha256(path), "elf_machine": 243,
                                     "version": command([path, "--version"]).stdout.decode().splitlines()[0]}
        target = command(["/usr/bin/cc", "-dumpmachine"]).stdout.decode().strip()
        compiler_contract(target)
        report["tools"]["cc"]["target"] = target
        report["libraries"] = {}
        for label, path, symbol, expected in (
                ("libmicrohttpd", "/opt/asm/mhd/lib/libmicrohttpd.so.12", "MHD_get_version", b"1.0.3"),
                ("libpq", "/opt/asm/postgres/lib/libpq.so.5", "PQlibVersion", 160015)):
            library = ctypes.CDLL(path)
            function = getattr(library, symbol)
            function.restype = ctypes.c_char_p if isinstance(expected, bytes) else ctypes.c_int
            if function() != expected:
                raise ValueError("The loaded libraries must be libmicrohttpd 1.0.3 and libpq 16.15.")
            elf_machine(Path(path).read_bytes())
            report["libraries"][label] = {"path": path, "sha256": sha256(Path(path)),
                                          "version": expected.decode() if isinstance(expected, bytes) else "16.15"}
        report["checks"][stage] = {"outcome": "pass"}
        work = Path("/work")
        candidate = work / "candidate"
        package_root = work / "package-source"
        shutil.copytree("/inputs/candidate", candidate)
        shutil.copytree("/inputs/package-source", package_root)
        source = package_root / "experiments/assembly-server"

        def run(name, arguments, *, cwd=candidate, expected=None, timeout=180):
            nonlocal stage
            stage = name
            log = output.parent / (name + ".log")
            check = bounded_process(arguments, log, cwd=cwd, timeout=timeout)
            check.update(command=list(map(str, arguments)), log_sha256=sha256(log))
            report["checks"][name] = check
            text = log.read_text(errors="replace")
            print(text, end="", flush=True)
            if check["outcome"] != "pass":
                raise ValueError(f"The {name} check failed ({check['failure'] or check['exit_code']}). Inspect its retained log.")
            if expected is not None:
                check["tests_run"] = suite_contract(text, expected)
                check["tests_skipped"] = 0
            check["outcome"] = "pass"

        run("generated_source", [sys.executable, "tools/riscv64.py", "--check"])
        run("cli_build", ["make", "ARCH=riscv64", "AS=/usr/bin/as", "LD=/usr/bin/ld"])
        artifact = candidate / "build/asm"
        spec = importlib.util.spec_from_file_location("riscv64_contract", candidate / "tools/riscv64_test.py")
        contract = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(contract)
        report["cli"] = contract.elf_contract(artifact)
        attributes = command(["/usr/bin/readelf", "-A", artifact]).stdout.decode()
        architecture = re.search(r'Tag_RISCV_arch: "([^"]+)"', attributes)
        if not architecture or not re.fullmatch(r"rv64i[0-9]+p[0-9]+_m[0-9]+p[0-9]+(?:_zmmul[0-9]+p[0-9]+)?", architecture[1]):
            raise ValueError("The candidate CLI must declare exactly RV64IM architecture attributes.")
        report["cli"]["architecture_attributes"] = attributes
        shutil.copy2(artifact, output.parent / "asm-riscv64-linux")
        environment = dict(os.environ, ASM_RISCV64_CLI=str(artifact), ASM_TEST_TARGET="riscv64-linux",
                           PYTHONPATH=str(candidate / "tests"))
        os.environ.update(environment)
        run("first_project", [sys.executable, "-m", "unittest", "discover", "-s", "tests/riscv64",
                              "-p", "test_native.py", "-v"], expected=3)
        native_count = test_count(candidate / "tests/test_native_link.py")
        if native_count < 10:
            raise ValueError("The candidate must retain the native library linking contract tests.")
        run("native_link", [sys.executable, "-m", "unittest", "test_native_link", "-v"], expected=native_count)
        for filename, count in SUITE_FILES.items():
            if test_count(source / filename) != count:
                raise ValueError("The pinned server package must retain all 19 reference tests.")
        run("prepare_package", [sys.executable, source / "package.py", "--target", "riscv64-linux",
                                "--output", work / "prepared"])
        archive = output.parent / "asm-server-source.tar.gz"
        run("pack_package", [sys.executable, package_root / "tools/registry.py", "pack", work / "prepared",
                             "--name", "stubbi/asm-server", "--version", "0.1.0", "--target", "riscv64-linux",
                             "--output", archive])
        extracted = work / "extracted"
        extracted.mkdir()
        with tarfile.open(archive) as packed:
            if any(not (member.isdir() or member.isfile()) for member in packed.getmembers()):
                raise ValueError("The packed server contains a link or special member.")
            packed.extractall(extracted, filter="data")
        report["source_archive"] = {"sha256": sha256(archive), "bytes": archive.stat().st_size}
        run("server_package", ["make", "-C", extracted, "test", f"ASM={artifact}", "TARGET=riscv64-linux",
                               "MHD_PREFIX=/opt/asm/mhd", "PG_PREFIX=/opt/asm/postgres"], expected=19)
        server = extracted / "build/app"
        data = server.read_bytes()
        elf_machine(data)
        if struct.unpack_from("<H", data, 16)[0] != 3 or struct.unpack_from("<I", data, 48)[0] != 5:
            raise ValueError("The server must use PIE and RV64GC/LP64D with RVC.")
        report["server"] = {"sha256": sha256(server), "bytes": len(data), "elf_machine": 243,
                            "elf_flags": 5, "isa": "RV64GC", "abi": "LP64D", "pie": True}
        shutil.copy2(server, output.parent / "asm-server-riscv64-linux")
        if sha256(artifact) != report["cli"]["sha256"]:
            raise ValueError("The candidate CLI bytes changed during package qualification.")
        report["outcome"] = "pass"
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, tarfile.TarError) as failure:
        report["error"] = str(failure)
        report["checks"][stage] = {**report["checks"].get(stage, {}), "outcome": "fail", "error": str(failure)}
    finally:
        # Keep generated bytes even when the runtime tests reject them.
        artifacts = (("asm-riscv64-linux", Path("/work/candidate/build/asm")),
                     ("asm-server-riscv64-linux", Path("/work/extracted/build/app")))
        for name, path in artifacts:
            if path.is_file():
                try:
                    if path.stat().st_size > EVIDENCE_LIMITS[name]:
                        raise ValueError("A generated artifact exceeds its evidence file limit.")
                    shutil.copy2(path, output.parent / name)
                    report.setdefault("retained_artifacts", {})[name] = {"sha256": sha256(path), "bytes": path.stat().st_size}
                except (OSError, ValueError) as failure:
                    report["outcome"] = "fail"
                    report["collection_error"] = str(failure)
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        write_report(output, report)
    return 0 if report["outcome"] == "pass" else 1


def run_image(image, build_image, output):
    output.mkdir(parents=True, exist_ok=True)
    report = initial_report()
    name = "asm-riscv64-combined-" + uuid.uuid4().hex
    labels = {}
    try:
        images = [json.loads(command(["docker", "image", "inspect", item]).stdout)[0]
                  for item in (build_image, image)]
        base, derived = images
        for item in images:
            if item["Architecture"] != "riscv64" or item["Os"] != "linux":
                raise ValueError("Both local images must declare Linux RISC-V64.")
        layers = base["RootFS"]["Layers"]
        if derived["RootFS"]["Layers"][:len(layers)] != layers:
            raise ValueError("The qualification image must extend the exact hosted build stage.")
        labels = derived["Config"].get("Labels", {})
        if labels.get("build.asm.hosted-build-id") != base["Id"]:
            raise ValueError("The inherited build image ID does not match its recorded identity.")
        write_report(output / "images.json", {"hosted_build": base, "qualification": derived})
        runtime = bounded_process(
            ["docker", "run", "--pull=never", "--name", name,
             "--platform", "linux/riscv64", "--network", "none", "--user", "65532:65532",
             "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "256",
             "--memory", "2g", "--cpus", "2", derived["Id"]],
            output / "runtime.log", timeout=600, max_bytes=RUNTIME_LOG_BYTE_LIMIT)
        report["runtime"] = runtime
        if runtime["outcome"] != "pass":
            raise ValueError("The combined qualification failed. Inspect runtime.log and the guest report.")
    except (OSError, ValueError, subprocess.SubprocessError) as failure:
        report["error"] = str(failure)
    finally:
        # Collect from the stopped writable layer, including failed test logs.
        try:
            command(["docker", "stop", "--time", "5", name], timeout=15)
            budget = {"bytes": 0, "files": 0}
            collection_errors = {}
            collected = set()
            deadline = time.monotonic() + 90
            for filename in ("qualification.json", *[item for item in EVIDENCE_LIMITS if item != "qualification.json"]):
                try:
                    collect_file(["docker", "cp", name + ":/work/evidence/" + filename, "-"],
                                 filename, output, budget, timeout=min(20, deadline - time.monotonic()))
                    collected.add(filename)
                except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as failure:
                    collection_errors[filename] = str(failure)
            report["collection"] = {**budget, "errors": collection_errors, "collected": sorted(collected),
                                    "byte_limit": EVIDENCE_TOTAL_LIMIT, "file_limit": EVIDENCE_FILE_LIMIT}
            if collection_errors:
                report["collection_error"] = "Some allowlisted guest evidence was absent or exceeded its bounds."
            required = {"qualification.json", "asm-riscv64-linux", "asm-server-riscv64-linux", "asm-server-source.tar.gz"}
            missing = required - collected
            if missing:
                raise ValueError("Current collection did not supply required evidence: " + ", ".join(sorted(missing)))
            guest = output / "qualification.json"
            result = json.loads(guest.read_text())
            result_contract(result)
            for filename, field in (("asm-riscv64-linux", "cli"), ("asm-server-riscv64-linux", "server"),
                                    ("asm-server-source.tar.gz", "source_archive")):
                if sha256(output / filename) != result.get(field, {}).get("sha256"):
                    raise ValueError("A collected artifact differs from its recorded digest.")
            report["guest_outcome"] = result.get("outcome")
            report["inputs"] = result.get("inputs", {})
            if result.get("inputs", {}).get("candidate_revision") != labels.get("build.asm.candidate-revision"):
                raise ValueError("The guest source revision differs from the qualification image label.")
            if "error" not in report and not collection_errors:
                report["outcome"] = "pass"
        except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError,
                subprocess.SubprocessError) as failure:
            report["collection_error"] = str(failure)
        if "images" in locals():
            report["hosted_build_image_id"] = images[0]["Id"]
            report["qualification_image_id"] = images[1]["Id"]
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        write_report(output / "combined-report.json", report)
        try:
            command(["docker", "rm", "--force", name], timeout=15)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass  # The report above already retains the runtime or collection failure.
    return 0 if report["outcome"] == "pass" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--prepare-context", type=Path)
    mode.add_argument("--inside", action="store_true")
    mode.add_argument("--run-image")
    parser.add_argument("--build-image")
    parser.add_argument("--revision")
    parser.add_argument("--output", type=Path, default=Path("/work/evidence/qualification.json"))
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.discover(str(ROOT / "tests/riscv64"), pattern="test_combined.py")
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.prepare_context:
        if not args.revision:
            parser.error("Supply --revision with --prepare-context.")
        prepare_context(args.prepare_context, args.revision)
        return 0
    if args.inside:
        return inside(args.output)
    if not args.build_image:
        parser.error("Supply the local --build-image used by the qualification image.")
    return run_image(args.run_image, args.build_image, args.output)


if __name__ == "__main__":
    raise SystemExit(main())
