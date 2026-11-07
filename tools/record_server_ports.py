#!/usr/bin/env python3
"""Retain exact port artifacts and the scope of a Linux qualification job.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import hashlib
import importlib.util
import json
import platform
from pathlib import Path
import re
import struct
import subprocess


ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    "x86_64-linux": {"isa": "x86-64", "os": "Linux", "server_abi": "System V AMD64 LP64", "cpu_baseline": "x86-64", "cpu_features": []},
    "aarch64-linux": {"isa": "AArch64", "os": "Linux", "server_abi": "AAPCS64 LP64", "cpu_baseline": "ARMv8-A", "cpu_features": []},
    "riscv64-linux": {"isa": "RV64I", "os": "Linux", "server_abi": "LP64D", "cpu_baseline": "RV64GC", "cpu_features": ["M", "A", "F", "D", "C", "Zicsr", "Zifencei"]},
}


def tool(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        return {"command": list(command), "exit_code": result.returncode, "output": result.stdout, "error": result.stderr}
    except OSError as error:
        return {"command": list(command), "exit_code": 127, "error": str(error)}
    except subprocess.TimeoutExpired:
        return {"command": list(command), "exit_code": 124, "error": "tool probe exceeded five seconds"}


def artifact(path, target, *, server=False):
    if not path.is_file():
        return {"status": "unrun", "reason": "artifact absent"}
    data = path.read_bytes()
    result = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    spec = importlib.util.spec_from_file_location("port_registry", ROOT / "tools/registry.py")
    registry = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(registry)
    registry.validate_elf(data, target)
    flags = struct.unpack_from("<I", data, 48)[0]
    result["elf_flags"] = flags
    if server:
        if struct.unpack_from("<H", data, 16)[0] != 3:
            raise ValueError("server must be PIE (ELF ET_DYN)")
        if target == "riscv64-linux":
            if flags & ~5 or flags & 6 != 4:
                raise ValueError("RISC-V server must use the declared LP64D ABI")
        elif flags:
            raise ValueError("unexpected server ELF flags")
        start = struct.unpack_from("<Q", data, 32)[0]
        count = struct.unpack_from("<H", data, 56)[0]
        headers = [struct.unpack_from("<IIQQQQQQ", data, start + index * 56) for index in range(count)]
        stacks = [header for header in headers if header[0] == 0x6474E551]
        if not stacks or any(header[1] & 1 for header in stacks):
            raise ValueError("server lacks an explicit non-executable stack")
        if not any(header[0] == 0x6474E552 and header[6] for header in headers):
            raise ValueError("server lacks RELRO")
        immediate = False
        for header in headers:
            if header[0] != 2:
                continue
            offset, length = header[2], header[5]
            if length % 16:
                raise ValueError("unaligned ELF dynamic table")
            for position in range(offset, offset + length, 16):
                tag, value = struct.unpack_from("<qQ", data, position)
                if not tag:
                    break
                immediate |= tag == 24 or tag == 30 and bool(value & 8) or tag == 0x6FFFFFFB and bool(value & 1)
        if not immediate:
            raise ValueError("server lacks immediate binding")
        result["hardening"] = ["PIE", "RELRO", "immediate binding", "non-executable stack"]
    result["status"] = "pass"
    return result


def tests(path, minimum):
    if not path.is_file():
        return {"status": "unrun", "reason": "test log absent"}
    try:
        data = path.read_bytes()
    except OSError as error:
        return {"status": "fail", "reason": str(error)}
    text = data.decode("utf-8", errors="replace")
    matches = list(re.finditer(r"^Ran (\d+) tests? in ([0-9]+(?:\.[0-9]+)?)s$", text, re.M))
    outcome = next((line for line in text[matches[-1].end():].splitlines() if line.strip()), "") if matches else ""
    passed = bool(matches) and outcome == "OK" and not re.search(r"^FAILED\b|skipped[ =]", text, re.M)
    count, seconds = (int(matches[-1][1]), float(matches[-1][2])) if matches else (0, None)
    return {"status": "pass" if passed and count >= minimum else "fail", "tests": count,
            "seconds": seconds, "log_sha256": hashlib.sha256(data).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=sorted(TARGETS), required=True)
    parser.add_argument("--execution", choices=("native", "qemu-user", "qemu-system"), required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--job-status", required=True)
    for name in ("asm", "reference", "hosted", "archive", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision) or args.revision == "0" * 40:
        parser.error("revision must be an exact nonzero source commit")
    report = {"schema": 1, "scope": "linux-server-ports", "source_revision": args.revision,
              "target": args.target, **TARGETS[args.target], "execution": args.execution,
              "host": platform.uname()._asdict(), "job_status": args.job_status,
              "status": "fail", "artifacts": {}, "tests": {}}
    expected_machine = {"x86_64-linux": "x86_64", "aarch64-linux": "aarch64", "riscv64-linux": "riscv64"}[args.target]
    report["host_match"] = {"status": "pass" if report["host"]["system"] == "Linux" and report["host"]["machine"] == expected_machine else "fail"}
    head = tool(("/usr/bin/git", "--no-replace-objects", "-C", str(ROOT), "rev-parse", "HEAD"))
    state = tool(("/usr/bin/git", "--no-replace-objects", "-C", str(ROOT), "status", "--porcelain"))
    source_ok = head["exit_code"] == 0 and head.get("output", "").strip() == args.revision and state["exit_code"] == 0 and not state.get("output")
    report["source_match"] = {"status": "pass" if source_ok else "fail", "head": head.get("output", "").strip(), "dirty": bool(state.get("output"))}
    errors = []
    for name, path in (("cli", args.asm), ("reference", args.reference), ("hosted", args.hosted)):
        try:
            report["artifacts"][name] = artifact(path, args.target, server=name != "cli")
        except (ValueError, OSError, struct.error) as error:
            report["artifacts"][name] = {"status": "fail", "reason": str(error)}
            errors.append(str(error))
    try:
        if args.archive.is_file():
            data = args.archive.read_bytes()
            spec = importlib.util.spec_from_file_location("port_archive_registry", ROOT / "tools/registry.py")
            registry = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(registry)
            registry.validate_project(registry.read_archive(data), "internal/asm-server", "0.1.0", args.target)
            report["artifacts"]["source_archive"] = {"status": "pass", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        else:
            report["artifacts"]["source_archive"] = {"status": "unrun", "reason": "source archive absent"}
    except (ValueError, OSError) as error:
        report["artifacts"]["source_archive"] = {"status": "fail", "reason": str(error)}
    directory = args.output.parent
    for name, minimum in (("native-link", 11), ("reference", 19), ("hosted", 28)):
        try:
            report["tests"][name] = tests(directory / (name + "-tests.log"), minimum)
        except (OSError, ValueError) as error:
            report["tests"][name] = {"status": "fail", "reason": str(error)}
    failure_log = directory / "build-failure-tests.log"
    try:
        failure_report = json.loads(failure_log.read_text().splitlines()[-1])
        if not isinstance(failure_report, dict) or failure_report.get("status") != "pass" or type(failure_report.get("tests")) is not int or failure_report["tests"] != 4:
            raise ValueError("build failure checks did not pass")
        report["tests"]["failure_preservation"] = failure_report
    except (OSError, ValueError, IndexError) as error:
        report["tests"]["failure_preservation"] = {"status": "fail", "reason": str(error)}
    for command in (("/usr/bin/cc", "--version"), ("/usr/bin/as", "--version"), ("/usr/bin/ld", "--version")):
        report.setdefault("tools", []).append(tool(command))
    all_checks = list(report["artifacts"].values()) + list(report["tests"].values()) + [report["host_match"], report["source_match"]]
    if args.job_status == "success" and not errors and all(value["status"] == "pass" for value in all_checks) and all(value["exit_code"] == 0 for value in report["tools"]):
        report["status"] = "pass"
    report["limits"] = ["No deployment, recovery, throughput, or physical-target performance qualification follows from these tests.",
                        "The execution mode is supplied by the CI job; it is not a hardware attestation."]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "target": args.target, "report": str(args.output)}))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
