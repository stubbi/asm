#!/usr/bin/env python3
"""Qualify the native RISC-V CLI without treating emulation as native evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def elf_contract(path):
    """Check the static RV64IM/LP64 CLI container, including segment bounds."""
    if path.stat().st_size > 67108864:
        raise ValueError("CLI exceeds the 64 MiB artifact limit")
    data = path.read_bytes()
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("CLI must be a little-endian ELF64 executable")
    kind, machine = struct.unpack_from("<HH", data, 16)
    if kind != 2 or machine != 243:
        raise ValueError("CLI must declare ET_EXEC and EM_RISCV")
    flags = struct.unpack_from("<I", data, 48)[0]
    if flags != 0:
        raise ValueError("The CLI requires LP64 without compressed or additional ELF feature flags")
    phoff = struct.unpack_from("<Q", data, 32)[0]
    ehsize, phsize, phcount = struct.unpack_from("<HHH", data, 52)
    if ehsize != 64 or phsize != 56 or not 1 <= phcount <= 128:
        raise ValueError("CLI has an invalid program-header table")
    if phoff > len(data) or phcount * phsize > len(data) - phoff:
        raise ValueError("CLI program headers exceed the artifact")
    stack_seen = False
    for number in range(phcount):
        entry = struct.unpack_from("<IIQQQQQQ", data, phoff + number * phsize)
        segment, permissions, offset, _, _, file_size, memory_size, _ = entry
        if offset > len(data) or file_size > len(data) - offset or (segment == 1 and file_size > memory_size):
            raise ValueError("CLI segment exceeds its file or memory bounds")
        if segment == 3:
            raise ValueError("CLI must not require a dynamic interpreter")
        if segment == 0x6474E551:
            stack_seen = True
            if permissions & 1:
                raise ValueError("CLI stack must not be executable")
    if not stack_seen:
        raise ValueError("CLI must declare a non-executable GNU stack")
    return {"sha256": digest(path), "bytes": len(data), "elf_machine": machine,
            "elf_flags": flags, "isa": "RV64IM", "abi": "LP64",
            "os": "Linux", "required_cpu_features": ["M"]}


def source_identity():
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=ROOT, timeout=15)
    paths = git("ls-files", "-c", "-o", "--exclude-standard", "-z").split(b"\0")
    entries = []
    for raw in sorted(set(paths) - {b""}):
        relative = os.fsdecode(raw)
        path = ROOT / relative
        if path.is_symlink():
            entries.append({"path": relative, "symlink": os.readlink(path)})
        elif path.is_file():
            entries.append({"path": relative, "sha256": digest(path), "bytes": path.stat().st_size})
        else:
            entries.append({"path": relative, "absent": True})
    encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    status = git("status", "--porcelain=v1").decode()
    return {"commit": git("rev-parse", "HEAD").decode().strip(), "clean": not status,
            "status": status.splitlines(), "manifest_sha256": hashlib.sha256(encoded).hexdigest(),
            "manifest": entries}


def system_emulator_provenance(path, commit):
    """Read bounded host-provided evidence; it never configures guest execution."""
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise ValueError("System emulator provenance must be a regular file of at most 64 KiB")

    def unique_fields(pairs):
        result = {}
        for name, value in pairs:
            if name in result:
                raise ValueError("System emulator provenance has duplicate fields")
            result[name] = value
        return result

    record = json.loads(path.read_bytes(), object_pairs_hook=unique_fields)
    if (not isinstance(record, dict) or type(record.get("schema")) is not int or record["schema"] != 1
            or record.get("execution_mode") != "emulated" or record.get("emulation_kind") != "system"):
        raise ValueError("System emulator provenance has the wrong schema or execution scope")
    hexadecimal = lambda value, count: isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % count, value)
    source = record.get("source")
    if (not isinstance(source, dict) or source.get("commit") != commit
            or not hexadecimal(commit, 40) or not hexadecimal(source.get("bundle_sha256"), 64)):
        raise ValueError("System emulator provenance does not bind the guest source")
    emulator = record.get("emulator")
    if (not isinstance(emulator, dict) or not hexadecimal(emulator.get("sha256"), 64)
            or not isinstance(emulator.get("path"), str) or not emulator["path"].startswith("/")
            or not isinstance(emulator.get("version"), str) or not emulator["version"]
            or not isinstance(emulator.get("arguments"), list)
            or not all(isinstance(item, str) and len(item) <= 4096 for item in emulator["arguments"])):
        raise ValueError("System emulator provenance needs an exact emulator identity")
    images = record.get("images")
    if not isinstance(images, dict):
        raise ValueError("System emulator provenance needs pinned guest images")
    for name in ("rootfs", "kernel", "initrd"):
        image = images.get(name)
        if (not isinstance(image, dict) or not hexadecimal(image.get("sha256"), 64)
                or not isinstance(image.get("url"), str) or not image["url"].startswith("https://")
                or type(image.get("bytes")) is not int or not 0 < image["bytes"] <= 2147483648):
            raise ValueError("System emulator provenance needs pinned guest images")
    return {"sha256": digest(path), "origin": "host-provided", "host_provided": True, "record": record}


def run(command, log, *, environment=None, timeout=30):
    start = time.monotonic()
    with log.open("wb") as stream:
        child = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=stream,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
    output = log.read_text(errors="replace")
    skipped = bool(re.search(r"(?:skipped=[1-9]|\bskipped ['\"])", output))
    return {"command": list(map(str, command)), "exit_code": child.returncode,
            "outcome": "pass" if child.returncode == 0 and not timed_out and not skipped else "fail",
            "seconds": round(time.monotonic() - start, 3), "timed_out": timed_out,
            "skipped_checks": skipped, "log": str(log), "log_sha256": digest(log)}


def tool_identity(path):
    result = subprocess.run([str(path), "--version"], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise ValueError(f"Required tool failed: {path}")
    return {"path": str(path), "resolved_path": str(path.resolve()), "sha256": digest(path),
            "version": result.stdout.splitlines()[0]}


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asm", required=True, type=Path)
    parser.add_argument("--execution-mode", choices=("native", "emulated"), required=True)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--emulation-kind", choices=("user", "system"), default="user")
    parser.add_argument("--emulator-provenance", type=Path)
    parser.add_argument("--suite-timeout", type=int, default=1200)
    args = parser.parse_args(arguments)
    artifact = args.asm.resolve()
    evidence = args.evidence.resolve()
    evidence.parent.mkdir(parents=True, exist_ok=True)
    logs = evidence.parent / (evidence.stem + "-logs")
    logs.mkdir(exist_ok=True)
    names = ("artifact", "runtime", "toolchain", "make_test", "focused_tests", "artifact_binding")
    report = {"schema": 1, "target": "riscv64-linux", "execution_mode": args.execution_mode,
              "emulation_kind": args.emulation_kind if args.execution_mode == "emulated" else None,
              "started_at": datetime.now(timezone.utc).isoformat(), "outcome": "fail",
              "native_qualified": False, "release_qualified": False,
              "host": {"system": platform.system(), "machine": platform.machine(),
                       "release": platform.release(), "python": platform.python_version()},
              "emulation_environment": {name: os.environ[name] for name in
                                        ("QEMU_CPU", "QEMU_LD_PREFIX") if name in os.environ},
              "checks": {name: {"outcome": "not-run"} for name in names},
              "release_gates": {name: "not-run" for name in
                                ("registry", "verifier", "site", "release", "published_install")}}
    current = "artifact"
    try:
        report["artifact"] = {"path": str(artifact), **elf_contract(artifact)}
        report["checks"][current] = {"outcome": "pass"}
        report["source"] = source_identity()
        current = "runtime"
        if platform.system() != "Linux":
            raise ValueError("RISC-V Linux qualification requires a Linux runtime")
        if args.execution_mode == "native" and platform.machine().lower() != "riscv64":
            raise ValueError("Native qualification requires a RISC-V64 host")
        if args.emulation_kind == "system":
            if args.execution_mode != "emulated" or platform.machine().lower() != "riscv64" or os.geteuid() != 0:
                raise ValueError("Full-system checks require root Linux RISC-V64 guest Python and emulated scope")
            if args.emulator_provenance is None:
                raise ValueError("Full-system checks require host-provided emulator provenance")
            report["emulator_provenance"] = system_emulator_provenance(args.emulator_provenance,
                                                                      report["source"]["commit"])
            report["emulator"] = report["emulator_provenance"]["record"]["emulator"]
        elif args.execution_mode == "emulated":
            report["emulator"] = tool_identity(Path("/usr/bin/qemu-riscv64"))
        report["checks"][current] = run([str(artifact), "targets", "--json"], logs / "runtime.log")
        if report["checks"][current]["outcome"] != "pass":
            raise ValueError("Direct RISC-V execution failed; install the native runtime or explicit binfmt handler")
        targets = json.loads((logs / "runtime.log").read_text())
        if targets != {"host": "riscv64-linux", "targets": ["x86_64-linux", "aarch64-linux", "riscv64-linux"]}:
            raise ValueError("The CLI reported the wrong host contract")
        current = "toolchain"
        report["tools"] = {name: tool_identity(Path("/usr/bin") / name) for name in ("as", "ld", "cc", "readelf")}
        attributes = subprocess.check_output(["/usr/bin/readelf", "-A", str(artifact)], text=True, timeout=15)
        report["artifact"]["architecture_attributes"] = attributes
        architecture = re.search(r'Tag_RISCV_arch: "([^"]+)"', attributes)
        if not architecture or not re.fullmatch(r"rv64i[0-9]+p[0-9]+_m[0-9]+p[0-9]+(?:_zmmul[0-9]+p[0-9]+)?", architecture[1]):
            raise ValueError("CLI attributes must declare exactly RV64IM")
        compiler_target = subprocess.check_output(["/usr/bin/cc", "-dumpmachine"], text=True, timeout=15).strip()
        report["tools"]["cc"]["target"] = compiler_target
        if not compiler_target.startswith("riscv64-"):
            raise ValueError("The fixed C compiler must target RISC-V64")
        with tempfile.TemporaryDirectory(prefix="asm-riscv64-probe-") as temporary:
            work = Path(temporary)
            source = work / "probe.s"
            source.write_text('.global _start\n.text\n_start:\nli a0, 0\nli a7, 93\necall\n.section .note.GNU-stack,"",@progbits\n')
            subprocess.run(["/usr/bin/as", "-march=rv64i", "-mabi=lp64", "--fatal-warnings",
                            "-o", str(work / "probe.o"), str(source)], check=True, timeout=20)
            subprocess.run(["/usr/bin/ld", "-z", "noexecstack", "--build-id=none", "-o",
                            str(work / "probe"), str(work / "probe.o")], check=True, timeout=20)
            report["toolchain_probe"] = elf_contract(work / "probe")
            report["toolchain_probe"]["isa"] = "RV64I"
            report["toolchain_probe"]["required_cpu_features"] = []
            report["checks"][current] = run([str(work / "probe")], logs / "toolchain.log")
        if report["checks"][current]["outcome"] != "pass":
            raise ValueError("The fixed assembler/linker paths did not produce an executable RV64I/LP64 program")
        # A sysroot prefix also rewrites open("/") and invalidates descriptor walks.
        # The disposable runner exposes the real target loader/library paths.
        if (args.execution_mode == "emulated" and args.emulation_kind == "user"
                and os.environ.get("QEMU_LD_PREFIX") != "/"):
            raise ValueError("Emulated filesystem checks require QEMU_LD_PREFIX=/")
        with tempfile.TemporaryDirectory(prefix="asm-riscv64-c-probe-") as temporary:
            work = Path(temporary)
            source = work / "probe.c"
            source.write_text('#include <stdio.h>\nint main(void) { puts("riscv64 libc probe"); return 0; }\n')
            program = work / "probe"
            subprocess.run(["/usr/bin/cc", "-march=rv64gc", "-mabi=lp64d", "-fPIE", "-pie",
                            "-Wl,-z,noexecstack,-z,relro,-z,now", "-o", str(program), str(source)],
                           check=True, timeout=30)
            header = program.read_bytes()[:64]
            if (header[:7] != b"\x7fELF\x02\x01\x01"
                    or struct.unpack_from("<HH", header, 16) != (3, 243)
                    or struct.unpack_from("<I", header, 48)[0] != 5):
                raise ValueError("C-linked probe must declare RV64GC/LP64D with RVC")
            report["linked_toolchain_probe"] = {"sha256": digest(program), "isa": "RV64GC", "abi": "LP64D",
                                                "elf_flags": 5, "os": "Linux"}
            linked = run([str(program)], logs / "linked-toolchain.log")
            report["linked_toolchain_probe"]["execution"] = linked
            if linked["outcome"] != "pass" or (logs / "linked-toolchain.log").read_bytes() != b"riscv64 libc probe\n":
                raise ValueError("The real target loader/library paths did not execute the RV64GC/LP64D probe")
        environment = dict(os.environ, ASM_TEST_TARGET="riscv64-linux", ASM_RISCV64_CLI=str(artifact),
                           ASM_RISCV64_EXECUTION_MODE=args.execution_mode)
        current = "make_test"
        report["checks"][current] = run(["make", "test", "ARCH=riscv64", f"PYTHON={sys.executable}"],
                                        logs / "make-test.log", environment=environment, timeout=args.suite_timeout)
        current = "focused_tests"
        report["checks"][current] = run([sys.executable, "-m", "unittest", "discover", "-s",
                                        "tests/riscv64", "-p", "test_*.py", "-v"],
                                        logs / "focused-tests.log", environment=environment, timeout=args.suite_timeout)
        for check, filename in (("make_test", "make-test.log"), ("focused_tests", "focused-tests.log")):
            counts = re.findall(r"Ran ([0-9]+) tests? in", (logs / filename).read_text(errors="replace"))
            report["checks"][check]["tests_run"] = sum(map(int, counts))
            if not counts or not sum(map(int, counts)):
                report["checks"][check]["outcome"] = "fail"
                report["checks"][check]["error"] = "Required suite ran no observable tests"
        current = "artifact_binding"
        final = elf_contract(artifact)
        if final["sha256"] != report["artifact"]["sha256"] or digest(ROOT / "build/asm") != final["sha256"]:
            raise ValueError("The full suite did not use the recorded artifact bytes")
        if source_identity()["manifest_sha256"] != report["source"]["manifest_sha256"]:
            raise ValueError("Source files changed during qualification")
        report["checks"][current] = {"outcome": "pass"}
        if all(check["outcome"] == "pass" for check in report["checks"].values()):
            report["outcome"] = "pass"
            report["native_qualified"] = args.execution_mode == "native" and report["source"]["clean"]
    except (OSError, ValueError, subprocess.SubprocessError) as failure:
        report["checks"][current] = {**report["checks"][current], "outcome": "fail", "error": str(failure)}
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    evidence.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"RISC-V {args.execution_mode} qualification: {report['outcome']}; evidence: {evidence}")
    return 0 if report["outcome"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
