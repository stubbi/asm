#!/usr/bin/env python3
"""Build GNU foreign-target tools that execute in the RISC-V Linux guest.

Only disposable CI builds use this provider. It adds no CLI runtime backend.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import struct
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
VERSION = "2.47"
SOURCE_URL = "https://ftp.gnu.org/gnu/binutils/binutils-2.47.tar.bz2"
SOURCE_SHA256 = "3068128c75cda9f898ccb4211d360246e8e195ffcc9dfb655b23ae23a54800e8"
# Primary packaging source checked 2026-11-05; downloaded GNU bytes also checked.
HASH_REFERENCE = "https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/b/binutils.rb"
TARGETS = ("x86_64-linux-gnu", "aarch64-linux-gnu")
TOOL_NAMES = tuple(target + "-" + tool for target in TARGETS for tool in ("as", "ld"))
TOOL_LIMIT = 67108864


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def tool_contract(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or not 64 <= path.stat().st_size <= TOOL_LIMIT:
        raise ValueError("A guest tool must be a bounded regular executable")
    with path.open("rb") as stream:
        header = stream.read(64)
    if (header[:7] != b"\x7fELF\x02\x01\x01" or struct.unpack_from("<H", header, 16)[0] not in (2, 3)
            or struct.unpack_from("<H", header, 18)[0] != 243
            or struct.unpack_from("<I", header, 48)[0] != 5):
        raise ValueError("Guest tools must be RISC-V64 ELF executables with the LP64D/RVC ABI")
    return {"sha256": digest(path), "bytes": path.stat().st_size, "elf_machine": 243, "elf_flags": 5,
            "isa": "RV64GC", "abi": "LP64D"}


def extract_source(archive, destination):
    """Validate all source members before extraction into a new private directory."""
    with tarfile.open(archive) as source:
        members = source.getmembers()
        if not 0 < len(members) <= 65536:
            raise ValueError("Binutils source exceeds its member count bound")
        names, expanded = set(), 0
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or not path.parts or path.parts[0] != "binutils-" + VERSION
                    or any(part in (".", "..") for part in path.parts)
                    or member.name in names or not (member.isfile() or member.isdir())
                    or not 0 <= member.size <= 33554432):
                raise ValueError("Binutils source contains an invalid member")
            names.add(member.name)
            expanded += member.size
            if expanded > 1073741824:
                raise ValueError("Expanded binutils source exceeds 1 GiB")
        source.extractall(destination, members=members, filter="data")


def validate_manifest(directory):
    directory = Path(directory)
    path = directory / "manifest.json"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1048576:
        raise ValueError("Guest tool manifest must be a regular file within 1 MiB")

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Guest tool manifest contains duplicate fields")
            result[key] = value
        return result

    result = json.loads(path.read_bytes(), object_pairs_hook=unique)
    if (type(result.get("schema")) is not int or result["schema"] != 1
            or result.get("scope") != "riscv64-guest-binutils"
            or result.get("outcome") != "pass" or result.get("host") != "riscv64-linux-gnu"
            or result.get("source", {}).get("version") != VERSION
            or result.get("source", {}).get("sha256") != SOURCE_SHA256
            or set(result.get("tools", {})) != set(TOOL_NAMES)):
        raise ValueError("The guest tools do not match the reviewed source and complete target set")
    if (directory / "bin").is_symlink():
        raise ValueError("Guest tool directory must not be a symlink")
    for name in TOOL_NAMES:
        expected = result["tools"][name]
        if expected.get("file") != "bin/" + name:
            raise ValueError("Guest tool paths must use fixed filenames")
        actual = tool_contract(directory / "bin" / name)
        if any(expected.get(key) != value for key, value in actual.items()):
            raise ValueError("Guest tool bytes differ from their manifest")
    return result


def build(output):
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    logs = output / "logs"
    logs.mkdir(exist_ok=True)
    report = {"schema": 1, "scope": "riscv64-guest-binutils", "outcome": "fail",
              "host": "riscv64-linux-gnu", "targets": list(TARGETS), "tools": {},
              "guest_execution": "not-run", "native_qualified": False, "release_qualified": False,
              "started_at": datetime.now(timezone.utc).isoformat(),
              "source": {"version": VERSION, "url": SOURCE_URL, "sha256": SOURCE_SHA256,
                         "hash_reference": HASH_REFERENCE, "checked_at": "2026-11-05"}}

    def save():
        (output / "manifest.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    save()
    try:
        if (platform.system() != "Linux" or platform.machine() not in ("x86_64", "amd64")
                or os.environ.get("GITHUB_ACTIONS") != "true"):
            raise ValueError("Guest tool builds require a disposable x86-64 Linux GitHub Actions host")
        spec = importlib.util.spec_from_file_location("riscv_system_bounds", ROOT / "tools/riscv64_system.py")
        system = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(system)
        with tempfile.TemporaryDirectory(prefix="asm-guest-binutils-", dir="/tmp") as temporary:
            private = Path(temporary)
            runner = system.Runner(logs, private)
            runner.deadline = time.monotonic() + 840
            archive = output / "binutils-source.tar.bz2"
            runner.run(["/usr/bin/curl", "--disable", "--fail", "--location", "--proto", "=https",
                        "--proto-redir", "=https", "--connect-timeout", "20", "--max-time", "300",
                        "--max-filesize", "67108864", "--output", archive, SOURCE_URL], "download.log", 320)
            if digest(archive) != SOURCE_SHA256:
                raise ValueError("The downloaded binutils source digest differs")
            extract_source(archive, private)
            source = private / ("binutils-" + VERSION)
            licenses = output / "licenses"
            licenses.mkdir(exist_ok=True)
            for path in source.glob("COPYING*"):
                if path.is_file():
                    shutil.copy2(path, licenses / path.name)
            compiler = "/usr/bin/riscv64-linux-gnu-gcc"
            runner.run([compiler, "--version"], "compiler-version.log")
            runner.run([compiler, "-dumpmachine"], "compiler-target.log")
            if (logs / "compiler-target.log").read_text().strip() != "riscv64-linux-gnu":
                raise ValueError("The build compiler must emit RISC-V64 Linux executables")
            report["compiler"] = {"path": compiler, "sha256": digest(Path(compiler)),
                                  "version": (logs / "compiler-version.log").read_text().splitlines()[0]}
            binaries = output / "bin"
            binaries.mkdir(exist_ok=True)
            for target in TARGETS:
                work = private / ("build-" + target)
                work.mkdir()
                configure = [source / "configure", "--build=x86_64-linux-gnu", "--host=riscv64-linux-gnu",
                             "--target=" + target, "--prefix=/usr", "--disable-nls", "--disable-werror",
                             "--disable-gdb", "--disable-gdbserver", "--disable-gprofng", "--disable-gprof",
                             "--disable-gold", "--disable-libctf", "--enable-ld", "--disable-shared",
                             "--enable-static", "--without-zstd", "--without-system-zlib"]
                # Commands receive only fixed toolchain settings and direct argv.
                environment = ["/usr/bin/env", "-i", "--chdir=" + str(work), "PATH=/usr/bin:/bin", "HOME=" + str(private), "LC_ALL=C",
                               "CC=" + compiler, "CXX=/usr/bin/riscv64-linux-gnu-g++",
                               "CC_FOR_BUILD=/usr/bin/gcc", "CXX_FOR_BUILD=/usr/bin/g++",
                               "CFLAGS_FOR_BUILD=-O2", "CXXFLAGS_FOR_BUILD=-O2",
                               "CFLAGS=-O2 -march=rv64gc -mabi=lp64d", "CXXFLAGS=-O2 -march=rv64gc -mabi=lp64d"]
                runner.run([*environment, *configure],
                           "configure-" + target + ".log", 180)
                runner.run([*environment, "/usr/bin/make", "-C", work, "-j2", "MAKEINFO=true", "all-gas", "all-ld"],
                           "build-" + target + ".log", 600)
                for tool, relative in (("as", "gas/as-new"), ("ld", "ld/ld-new")):
                    name = target + "-" + tool
                    destination = binaries / name
                    shutil.copy2(work / relative, destination)
                    destination.chmod(0o755)
                    report["tools"][name] = {"file": "bin/" + name, **tool_contract(destination)}
                report.setdefault("configure_arguments", {})[target] = list(map(str, configure))
                save()
            report["outcome"] = "pass"
            save()
            validate_manifest(output)
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as failure:
        report["outcome"] = "fail"
        report["error"] = str(failure)
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report["logs"] = {path.name: {"sha256": digest(path), "bytes": path.stat().st_size}
                          for path in logs.iterdir() if path.is_file()}
        save()
    print(f"RISC-V guest binutils build: {report['outcome']}; evidence: {output / 'manifest.json'}")
    return 0 if report["outcome"] == "pass" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    return build(parser.parse_args().output)


if __name__ == "__main__":
    raise SystemExit(main())
