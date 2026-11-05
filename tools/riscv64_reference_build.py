"""Build a bounded diagnostic interposer against pinned public headers.

SPDX-License-Identifier: AGPL-3.0-or-later
This module never runs the generated target files or qualifies an application.
"""
import ast
from datetime import datetime, timezone
import gzip
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import time
import zlib

import riscv64_server_observations as observations
from riscv64_combined import bounded_process

HEADERS = frozenset(("opt/asm/postgres/include/libpq-fe.h", "opt/asm/postgres/include/postgres_ext.h",
    "opt/asm/postgres/include/pg_config_ext.h"))
HEADER_BYTES = 512 * 1024
MHD_SOURCE_URL = "https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz"
MHD_SOURCE_SHA = "7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a"
MHD_SOURCE_BYTES = 2102293
MHD_SOURCE_MEMBER = "libmicrohttpd-1.0.3/src/include/microhttpd.h"
MHD_HEADER_SHA = "b59c296579ff7fb5dfdc213561ac5a29d9dfe21c1a88c055f975f7678b68f794"
MHD_HEADER_BYTES = 256144
MHD_ARCHIVE_BYTES = 8 * 1024 * 1024
MHD_EXPANDED_BYTES = 64 * 1024 * 1024
MHD_ENTRIES = 4096
SOURCE_BYTES = 256 * 1024
OUTPUT_BYTES = 1024 * 1024
TOOL_BYTES = 256 * 1024 * 1024
LAYER_ENTRIES = 200000
LAYER_BYTES = 256 * 1024 * 1024
BUILD_SECONDS = 120
COMMAND_SECONDS = 30
LOG_BYTES = 1024 * 1024
OUTPUTS = ("reference_libpq_trace.so", "libreference_provider.so", "reference_trace_check")
BUILD_SCOPE = "asm-reference-trace-build"


def _absent(path):
    if path.exists() or path.is_symlink():
        raise ValueError("The diagnostic destination already exists; preserve it.")


def _layer_name(entry):
    if entry.name in (".", "./") and entry.isdir():
        return None
    name = entry.name.removeprefix("./")
    return observations.portable_name(name)


def _affects_selected(name, selected=HEADERS):
    return any(name == item or item.startswith(name + "/") for item in selected)


def _header_whiteout(name, selected=HEADERS):
    path = PurePosixPath(name)
    if not path.name.startswith(".wh."):
        return False
    parent = path.parent.as_posix()
    if path.name == ".wh..wh..opq":
        return parent == "." or _affects_selected(parent, selected)
    target = (path.parent / path.name[4:]).as_posix()
    return _affects_selected(target, selected)


def extract_headers(archive: Path, destination: Path, *, archive_bytes=None, archive_sha=None, image_id=None) -> dict:
    """Publish three PostgreSQL headers after full bounded image validation.

    Optional identity values support tiny test fixtures. The build entry point
    always uses the fixed retained-image pins. Selected overlay ambiguity fails.
    No layer file is extracted by its supplied path.
    """
    _absent(destination)
    observations.verify_file(archive, observations.IMAGE_TAR_BYTES if archive_bytes is None else archive_bytes,
                              observations.IMAGE_TAR_SHA if archive_sha is None else archive_sha)
    config = observations.image_archive_contract(archive, observations.IMAGE_ID if image_id is None else image_id)
    wanted_layers = ["blobs/sha256/" + value.removeprefix("sha256:") for value in config["rootfs"]["diff_ids"]]
    contents, receipt = {}, {}
    entries, expanded = 0, 0
    with tarfile.open(archive, "r:") as outer:
        for layer_name in wanted_layers:
            member = outer.getmember(layer_name)
            with tarfile.open(fileobj=outer.extractfile(member), mode="r|*") as layer:
                for entry in layer:
                    entries += 1
                    expanded += entry.size
                    if entries > LAYER_ENTRIES or entry.size < 0 or expanded > LAYER_BYTES:
                        raise ValueError("The image layers exceed the header inspection bound.")
                    name = _layer_name(entry)
                    if name is None:
                        continue
                    if _header_whiteout(name):
                        raise ValueError("A selected header or parent has an ambiguous whiteout.")
                    if _affects_selected(name) and name not in HEADERS and not entry.isdir():
                        raise ValueError("A selected header parent is not a regular directory.")
                    if name not in HEADERS:
                        continue
                    if name in contents or not entry.isfile() or not 0 < entry.size <= HEADER_BYTES:
                        raise ValueError("A selected header is duplicated, linked, absent, or oversized.")
                    data = layer.extractfile(entry).read(HEADER_BYTES + 1)
                    if len(data) != entry.size:
                        raise ValueError("A selected header has truncated bytes.")
                    contents[name] = data
                    receipt[PurePosixPath(name).name] = {"image_path": name, "layer": layer_name,
                        "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    if set(contents) != HEADERS:
        raise ValueError("The retained image does not supply all three PostgreSQL public headers.")
    if not destination.parent.is_dir() or destination.parent.is_symlink():
        raise ValueError("Use an existing private header parent directory.")
    with tempfile.TemporaryDirectory(prefix=".asm-headers-", dir=destination.parent) as temporary:
        stage = Path(temporary) / "include"
        stage.mkdir(mode=0o700)
        for name, data in contents.items():
            path = stage / PurePosixPath(name).name
            path.write_bytes(data)
            path.chmod(0o444)
        _absent(destination)
        os.rename(stage, destination)
    return receipt


def _read_regular(path, maximum):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum:
            raise ValueError("A diagnostic file is not a bounded regular file.")
        data = source.read(maximum + 1)
    if len(data) != info.st_size or len(data) > maximum:
        raise ValueError("A diagnostic file changed or exceeded its byte bound.")
    return data


def extract_mhd_header(archive: Path, destination: Path, *, archive_bytes=None,
                       archive_sha=None, header_bytes=None, header_sha=None) -> dict:
    """Publish one exact, unchanged public header from the pinned GNU source.

    Expected-identity overrides support tiny synthetic tests only. The build
    entry point uses the fixed archive and selected-header size and SHA-256.
    No supplied archive path becomes an output path. No source is executed.
    """
    _absent(destination)
    if not destination.parent.is_dir() or destination.parent.is_symlink():
        raise ValueError("Use an existing private header parent directory.")
    data = _read_regular(archive, MHD_ARCHIVE_BYTES)
    actual_sha = hashlib.sha256(data).hexdigest()
    expected_size = MHD_SOURCE_BYTES if archive_bytes is None else archive_bytes
    expected_sha = MHD_SOURCE_SHA if archive_sha is None else archive_sha
    if len(data) != expected_size or actual_sha != expected_sha:
        raise ValueError("The MHD source archive does not match its pinned size and SHA-256.")
    # Bound the entire expanded stream, including tar metadata and gzip CRC.
    expanded = io.BytesIO()
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data), mode="rb") as compressed:
            while chunk := compressed.read(min(131072, MHD_EXPANDED_BYTES - expanded.tell() + 1)):
                if expanded.tell() + len(chunk) > MHD_EXPANDED_BYTES:
                    raise ValueError("The MHD source archive exceeds its expanded-byte bound.")
                expanded.write(chunk)
    except (OSError, EOFError, zlib.error):
        raise ValueError("The MHD source archive is not a complete gzip stream.") from None
    expanded.seek(0)
    selected = (MHD_SOURCE_MEMBER,)
    seen, contents = set(), None
    with tarfile.open(fileobj=expanded, mode="r:") as packed:
        for index, entry in enumerate(packed, 1):
            if index > MHD_ENTRIES or entry.size < 0:
                raise ValueError("The MHD source archive exceeds its entry bound.")
            name = _layer_name(entry)
            if name is None:
                continue
            if name in seen or _header_whiteout(name, selected):
                raise ValueError("The MHD source archive has an ambiguous path or whiteout.")
            seen.add(name)
            if _affects_selected(name, selected) and name != MHD_SOURCE_MEMBER and not entry.isdir():
                raise ValueError("An MHD source header parent is not a direct directory.")
            if name != MHD_SOURCE_MEMBER:
                continue
            if not entry.isfile() or not 0 < entry.size <= HEADER_BYTES:
                raise ValueError("The MHD source header is linked, absent, or oversized.")
            contents = packed.extractfile(entry).read(HEADER_BYTES + 1)
            if len(contents) != entry.size:
                raise ValueError("The MHD source header has truncated bytes.")
        if any(expanded.getbuffer()[packed.offset:]):
            raise ValueError("The MHD source archive has ambiguous trailing bytes.")
    expected_header_size = MHD_HEADER_BYTES if header_bytes is None else header_bytes
    expected_header_sha = MHD_HEADER_SHA if header_sha is None else header_sha
    if (contents is None or len(contents) != expected_header_size
            or hashlib.sha256(contents).hexdigest() != expected_header_sha):
        raise ValueError("The MHD source header does not match its pinned size and SHA-256.")
    with tempfile.TemporaryDirectory(prefix=".asm-mhd-header-", dir=destination.parent) as temporary:
        stage = Path(temporary) / "microhttpd.h"
        stage.write_bytes(contents)
        stage.chmod(0o444)
        _absent(destination)
        os.rename(stage, destination)
    return {"source_url": MHD_SOURCE_URL, "archive_sha256": actual_sha, "archive_bytes": len(data),
            "archive_member": MHD_SOURCE_MEMBER, "bytes": len(contents),
            "sha256": hashlib.sha256(contents).hexdigest()}


def _source(context, relative):
    path = context
    parts = PurePosixPath(relative).parts
    for part in parts[:-1]:
        path /= part
        if path.is_symlink() or not path.is_dir():
            raise ValueError("A diagnostic source parent is not a direct directory.")
    return _read_regular(path / parts[-1], SOURCE_BYTES)


def _test_sources(data):
    selected = {}
    for node in ast.parse(data).body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
            continue
        name = node.targets[0].id
        if name not in ("PROVIDER", "DRIVER"):
            continue
        if name in selected:
            raise ValueError("The diagnostic test source has duplicate fixture constants.")
        value = ast.literal_eval(node.value)
        if type(value) is not str or not value or "\0" in value or len(value.encode()) > SOURCE_BYTES:
            raise ValueError("The diagnostic fixture source is not a bounded literal.")
        selected[name] = value.encode()
    if selected.keys() != {"PROVIDER", "DRIVER"}:
        raise ValueError("The diagnostic fixture source is incomplete.")
    return selected


def elf_contract(path: Path, *, shared=True) -> dict:
    """Check structural RV64GC/LP64D container bounds without executing it.

    The ELF flags establish RVC and double-float ABI, not the full ISA.
    The build separately checks the declared architecture with readelf.
    """
    data = _read_regular(path, OUTPUT_BYTES)
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("The diagnostic output must be little-endian ELF64.")
    kind, machine, version, _, offset, _, flags, header, width, count = struct.unpack_from("<HHIQQQIHHH", data, 16)
    if (machine != 243 or version != 1 or flags != 5 or kind not in ((3,) if shared else (2, 3))
            or header != 64 or width != 56 or not 1 <= count <= 128 or offset < 64
            or offset + count * width > len(data)):
        raise ValueError("The diagnostic output has the wrong target, ABI, or program-header bounds.")
    stacks, loads = [], 0
    for index in range(count):
        segment, permissions, start, _, _, size, memory, _ = struct.unpack_from("<IIQQQQQQ", data, offset + index * width)
        if segment == 1:
            loads += 1
            if size > memory or start + size > len(data) or permissions & 3 == 3:
                raise ValueError("A diagnostic load segment is invalid or writable and executable.")
        if segment == 0x6474e551:
            stacks.append(permissions)
    if not loads or len(stacks) != 1 or stacks[0] & 1:
        raise ValueError("The diagnostic output needs one non-executable GNU stack.")
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "elf_machine": machine,
            "elf_type": kind, "elf_flags": flags, "nx_stack": True, "no_rwx": True}


def _identity(path):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError("Use an absolute, fixed compiler or subordinate tool path.")
    resolved = path.resolve(strict=True)
    info = resolved.stat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= TOOL_BYTES:
        raise ValueError("The selected compiler tool is not a bounded regular file.")
    return {"path": str(path), "resolved_path": str(resolved), "bytes": info.st_size,
            "sha256": observations.digest(resolved)}


def _architecture(text):
    found = re.findall(r'Tag_RISCV_arch:\s*"([^"]+)"', text)
    if len(found) != 1 or not found[0].startswith("rv64"):
        raise ValueError("The compiler output lacks one declared RISC-V architecture.")
    tokens = found[0][4:].split("_")
    extensions = set()
    for token in tokens:
        value = re.fullmatch(r"([a-z]+)[0-9]+p[0-9]+", token)
        if value is None:
            raise ValueError("The compiler output architecture is not canonical.")
        extensions.add(value[1])
    if (not {"i", "m", "a", "f", "d", "c", "zicsr", "zifencei"} <= extensions
            or extensions - {"i", "m", "a", "f", "d", "c", "zicsr", "zifencei", "zmmul", "zaamo", "zalrsc"}):
        raise ValueError("The compiler output declares features beyond the selected RV64GC target.")
    return found[0]


def prepare_trace(image_archive: Path, context: Path,
                  compiler: Path = Path("/usr/bin/riscv64-linux-gnu-gcc"), *, timeout=120,
                  mhd_source: Path = None) -> dict:
    """Stage and atomically publish only diagnostic build outputs and receipts.

    Supply the pinned MHD source archive and a trusted compiler in CI.
    The generated driver must pass a separate guest check before package tests.
    A failed attempt retains bounded metadata and its final compiler log.
    """
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= BUILD_SECONDS:
        raise ValueError("Use a positive diagnostic build budget of at most 120 seconds.")
    if context.is_symlink() or not context.is_dir():
        raise ValueError("Use a direct existing diagnostic context directory.")
    context = context.resolve()
    destination = context / "trace"
    _absent(destination)
    for filename in ("trace-build-failure.json", "trace-build-failure.log"):
        _absent(context / filename)
    started = time.monotonic()
    deadline = started + timeout
    report = {"schema": 1, "scope": BUILD_SCOPE, "qualification": "UNQUALIFIED",
              "outcome": "fail", "target": "riscv64-linux", "isa": "RV64GC", "abi": "LP64D",
              "target_execution": "not-run", "commands": [], "outputs": {}, "architecture_attributes": {},
              "limits": {"build_seconds": timeout, "command_seconds": COMMAND_SECONDS, "log_bytes": LOG_BYTES},
              "image": {"bytes": observations.IMAGE_TAR_BYTES, "sha256": observations.IMAGE_TAR_SHA,
                        "id": observations.IMAGE_ID},
              "limits_of_evidence": ["No application or target program was executed by this build.",
                  "The selected compiler, its libraries, and the CI workspace remain trusted.",
                  "Native hardware and release qualification do not follow."]}
    stage = Path(tempfile.mkdtemp(prefix=".asm-reference-build-", dir=context))
    phase = "source"
    last_log = None
    published = False

    def check_budget():
        if time.monotonic() >= deadline:
            raise ValueError("The shared diagnostic build deadline expired.")

    try:
        phase = "mhd-source"
        if mhd_source is None:
            raise ValueError("Supply the pinned MHD source archive for its public header.")
        mhd_receipt = extract_mhd_header(mhd_source, stage / "microhttpd.h")
        check_budget()
        phase = "source"
        c_source = _source(context, "runner/tools/diagnostics/reference_libpq_trace.c")
        test_source = _source(context, "runner/tests/riscv64/test_reference_trace.py")
        fixtures = _test_sources(test_source)
        inputs = {"reference_libpq_trace.c": c_source, "provider.c": fixtures["PROVIDER"], "driver.c": fixtures["DRIVER"]}
        report["sources"] = {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                             for name, data in {**inputs, "test_reference_trace.py": test_source}.items()}
        for name, data in inputs.items():
            (stage / name).write_bytes(data)
        phase = "headers"
        report["headers"] = extract_headers(image_archive, stage / "include")
        os.rename(stage / "microhttpd.h", stage / "include/microhttpd.h")
        report["headers"]["microhttpd.h"] = mhd_receipt
        check_budget()
        (stage / "home").mkdir(mode=0o700)
        (stage / "tmp").mkdir(mode=0o700)

        def tool(label, arguments, limit=LOG_BYTES):
            nonlocal last_log
            remaining = min(COMMAND_SECONDS, deadline - time.monotonic())
            if remaining <= 0:
                raise ValueError("The shared diagnostic build deadline expired.")
            log = stage / (label + ".log")
            last_log = log
            args = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "LC_ALL=C", "LANG=C",
                    "HOME=" + str(stage / "home"), "TMPDIR=" + str(stage / "tmp"), *map(str, arguments)]
            result = bounded_process(args, log, cwd=stage, timeout=remaining, max_bytes=limit)
            report["commands"].append({"label": label, "arguments": args, **result,
                                       "log_sha256": observations.digest(log)})
            if result["outcome"] != "pass":
                raise ValueError("The diagnostic compiler check failed; inspect its bounded build log.")
            return log.read_text(encoding="utf-8", errors="strict")

        phase = "compiler"
        report["compiler"] = _identity(compiler)
        version = tool("compiler-version", [compiler, "--version"], 16384)
        report["compiler"]["version"] = version.splitlines()[0][:512]
        target = tool("compiler-target", [compiler, "-dumpmachine"], 1024).strip()
        if target != "riscv64-linux-gnu":
            raise ValueError("The diagnostic compiler must target riscv64-linux-gnu.")
        report["compiler"]["target"] = target
        report["compiler"]["subtools"] = {}
        for name in ("cc1", "as", "ld", "collect2"):
            value = tool("tool-" + name, [compiler, "-print-prog-name=" + name], 4096).strip()
            if "\n" in value or "\0" in value:
                raise ValueError("A compiler tool path is ambiguous.")
            report["compiler"]["subtools"][name] = _identity(Path(value))
        readelf = compiler.parent / "riscv64-linux-gnu-readelf"
        report["compiler"]["subtools"]["readelf"] = _identity(readelf)
        report["compiler"]["subtools"]["readelf"]["version"] = tool("readelf-version", [readelf, "--version"], 16384).splitlines()[0][:512]
        flags = [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", "-pthread",
                 "-march=rv64gc", "-mabi=lp64d", "-I", stage / "include",
                 "-Wl,-z,noexecstack", "-Wl,-z,relro", "-Wl,-z,now"]
        commands = ((OUTPUTS[0], [*flags, "-shared", stage / "reference_libpq_trace.c", "-o", stage / OUTPUTS[0],
                                  "-Wl,-soname," + OUTPUTS[0], "-ldl"]),
                    (OUTPUTS[1], [*flags, "-shared", stage / "provider.c", "-o", stage / OUTPUTS[1],
                                  "-Wl,-soname," + OUTPUTS[1], "-ldl"]),
                    (OUTPUTS[2], [*flags, "-pie", stage / "driver.c", stage / OUTPUTS[1],
                                  "-Wl,-rpath,/inputs/trace", "-o", stage / OUTPUTS[2]]))
        for index, (name, args) in enumerate(commands):
            phase = "compile-" + name
            tool("compile-" + str(index), args)
            phase = "elf-" + name
            metadata = elf_contract(stage / name, shared=index < 2)
            phase = "attributes-" + name
            attributes = tool("attributes-" + str(index), [readelf, "-A", stage / name], 16384)
            report["architecture_attributes"][name] = {"architecture": _architecture(attributes), "output": attributes}
            report["outputs"][name] = metadata
            (stage / name).chmod(0o555)
        phase = "final-inputs"
        check_budget()
        for name, data in inputs.items():
            if (stage / name).read_bytes() != data:
                raise ValueError("A diagnostic input changed during compilation.")
        check_budget()
        report["outcome"] = "pass"
        report["seconds"] = round(time.monotonic() - started, 3)
        report["recorded_at"] = datetime.now(timezone.utc).isoformat()
        phase = "receipt"
        (stage / "manifest.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        check_budget()
        phase = "publication"
        stage.chmod(0o755)
        _absent(destination)
        check_budget()
        os.rename(stage, destination)
        published = True
        check_budget()
        return report
    except (OSError, ValueError, SyntaxError, TypeError, KeyError, IndexError,
            tarfile.TarError, struct.error, subprocess.SubprocessError) as error:
        if published:
            # Nothing consumes this directory until the function returns.
            # Restore the private stage when publication itself used the budget.
            os.rename(destination, stage)
        final = report["commands"][-1] if report["commands"] else {}
        report.update(outcome="fail", stage=phase, error="The diagnostic build did not complete.",
                      exception_type=type(error).__name__, last_exit_code=final.get("exit_code"),
                      last_failure=final.get("failure"), seconds=round(time.monotonic() - started, 3),
                      recorded_at=datetime.now(timezone.utc).isoformat())
        log_bytes = b""
        if last_log is not None and last_log.is_file() and not last_log.is_symlink():
            with last_log.open("rb") as stream:
                log_bytes = stream.read(LOG_BYTES)
        metadata = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode()
        if len(metadata) > LOG_BYTES:
            raise ValueError("The diagnostic build failure metadata exceeds its byte bound.") from None
        for filename, data in (("trace-build-failure.json", metadata), ("trace-build-failure.log", log_bytes)):
            path = context / filename
            _absent(path)
            with tempfile.NamedTemporaryFile(prefix=".asm-build-failure-", dir=context, delete=False) as output:
                temporary = Path(output.name)
                output.write(data)
            try:
                _absent(path)
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
        raise ValueError(f"Diagnostic build failed at {phase}; exit {final.get('exit_code')}. Inspect trace-build-failure.json.") from None
    finally:
        if stage.exists():
            shutil.rmtree(stage)
