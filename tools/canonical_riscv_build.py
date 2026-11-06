"""Prepare an UNQUALIFIED canonical RISC-V diagnostic, without target execution.

SPDX-License-Identifier: AGPL-3.0-or-later
The caller supplies an isolated, exact retained SDK and digest-bound assets.
"""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
from types import SimpleNamespace

SDK_REVISION = "881208fcec32ec8fe4609747ca2c4d8b9065c49f"
SOURCE_REVISION = "cb0f3f7315fe2878660684a1fe6eea76ca65e5ae"
SDK_IDENTITIES = {
    "riscv64_reference_build.py": (24447, "eca97849a73ab615d1314932738702b28c3cd64fcea49973eb0afc4a76a73866"),
    "riscv64_server_observations.py": (50290, "00eb1984f937a02efc498ebd628cf37a6b7238522c0921e7f5456cff34decef8"),
    "riscv64_combined.py": (29315, "fb748cfbfb175c2eceb8c370e1b1835d7f9d7ef7fec4ed49889d0c8893f6d704"),
}
PUBLICATION_IDENTITIES = {
    "registry.py": (62974, "c8b1efa8802111b321c88b10834dc661fe584df4d9435deb4aab6e673e535077"),
    "release.py": (41820, "38fb4660ef8959543ea1f94687348e5a1c2cd87b62c51182fccbce79713845e8"),
}
SOURCE_IDENTITIES = {
    "server/riscv64/runtime.s": (43541, "ef3c7e7af3dd2c9e26d4c03f21a8edb4b53c65a223d188025293ea2dd6e7e309"),
    "server/riscv64/config.s": (27570, "6e1f630c1ae3b28d2435b3dc169dadf75059e21f05cb0e1f301c0a93db7dbb39"),
    "server/catalog/reader-guard.sql": (4934, "7f77767c3fa231e453b415369b5c12445afc9e6b468fb63ef4776ccc13a8cb6a"),
    "server/catalog/read-exports.sql": (246, "37ea0264466ba9f3bec67a0504d5e2fc6de72b43327d4d6434d4ebf9606e6578"),
    "server/abi-check.c": (4786, "0b89fd206614176c0d407ab764f55e12ddee0ed0caebc7693f1b905b5580e086"),
}
EXTRA_INPUTS = {
    "libssl": "usr/lib/riscv64-linux-gnu/libssl.so.3",
    "libcrypto": "usr/lib/riscv64-linux-gnu/libcrypto.so.3",
    "ea_libc": "usr/lib/riscv64-linux-gnu/libc.so.6",
    "ea_loader": "usr/lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1",
    "pg_config.h": "opt/asm/postgres/include/pg_config.h",
}
OUTPUTS = ("asm-hub", "abi-check", "canonical_libpq_trace.so", "libcanonical_provider.so", "canonical_trace_check")
BUILD_SECONDS = 120
COMMAND_SECONDS = 30
LOG_BYTES = 1024 * 1024
TOTAL_LOG_BYTES = 8 * LOG_BYTES
LIBRARY_BYTES = 16 * 1024 * 1024
DEPENDENCY_BYTES = 48 * 1024 * 1024
DEPENDENCY_RECORDS = 256


def _budget(deadline):
    if not math.isfinite(deadline) or time.monotonic() >= deadline:
        raise ValueError("The shared canonical build deadline expired.")


def _absent(path):
    if path.exists() or path.is_symlink():
        raise ValueError("The canonical build destination already exists; preserve it.")


def _read(path, maximum=256 * 1024):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum
                or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o022):
            raise ValueError("Use an owned, bounded, singly linked diagnostic input.")
        data = source.read(maximum + 1)
    if len(data) != info.st_size:
        raise ValueError("A canonical build input changed or exceeded its bound.")
    return data


def _source(root, relative):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("A canonical input root is not a direct directory.")
    path = root
    for part in PurePosixPath(relative).parts[:-1]:
        path /= part
        if path.is_symlink() or not path.is_dir():
            raise ValueError("A canonical source parent is not a direct directory.")
    return _read(path / PurePosixPath(relative).name)


def _identity(data):
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def _guest_sdk_read(path):
    """Read one pinned SDK file from the guest's read-only input mount only."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 256 * 1024
                or info.st_nlink != 1 or info.st_mode & 0o222
                or not os.fstatvfs(source.fileno()).f_flag & os.ST_RDONLY):
            raise ValueError("Use a bounded, singly linked SDK file on the read-only guest input mount.")
        data = source.read(256 * 1024 + 1)
    if len(data) != info.st_size:
        raise ValueError("A guest SDK input changed or exceeded its byte bound.")
    return data


def load_sdk(directory, *, readonly_guest=False):
    """Load only the three pinned helpers, without importing ambient names.

    Materialize these files from SDK_REVISION in a private caller-owned context.
    Temporary import aliases are restored. Call this from the isolated builder.
    The guest-only mode permits host ownership on read-only pinned input files.
    It does not permit guest compilation or change host input ownership checks.
    """
    directory = Path(directory)
    if type(readonly_guest) is not bool:
        raise ValueError("Select the explicit host or read-only guest SDK mode.")
    if readonly_guest:
        if (platform.system() != "Linux" or platform.machine() != "riscv64"
                or os.getuid() != 65532 or os.geteuid() != 65532 or not directory.is_absolute()):
            raise ValueError("The read-only SDK mode requires the fixed non-root RISC-V guest.")
        for parent in (directory, *directory.parents):
            if parent.is_symlink() or not parent.is_dir():
                raise ValueError("A guest SDK parent is not a direct directory.")
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Use a direct retained SDK directory.")
    sources = {}
    for name, (size, digest) in SDK_IDENTITIES.items():
        data = _guest_sdk_read(directory / name) if readonly_guest else _read(directory / name)
        if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("The retained SDK differs from its pinned source bytes.")
        sources[name.removesuffix(".py")] = data
    saved, loaded = {}, {}
    try:
        for name in ("riscv64_combined", "riscv64_server_observations", "riscv64_reference_build"):
            saved[name] = sys.modules.get(name)
            spec = importlib.util.spec_from_file_location(name, directory / (name + ".py"))
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            # Execute the verified bytes. Do not use an unchecked cached pyc.
            exec(compile(sources[name], str(directory / (name + ".py")), "exec"), module.__dict__)
            loaded[name] = module
    finally:
        for name, module in saved.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module
    return SimpleNamespace(reference=loaded["riscv64_reference_build"],
                           observations=loaded["riscv64_server_observations"],
                           combined=loaded["riscv64_combined"])


def extract_dependencies(archive, destination, sdk, *, deadline):
    """Resolve selected sonames inside the bounded, digest-pinned EA image.

    A soname is regular or has one relative basename link to a regular payload.
    Later regular replacements retain their identities. Ambiguous overlays refuse.
    No supplied tar name is used as an output path.
    The exact image digest binds TLS, libc, loader, and pg_config.h bytes.
    """
    _budget(deadline)
    _absent(destination)
    observations, reference = sdk.observations, sdk.reference
    observations.verify_file(archive, observations.IMAGE_TAR_BYTES, observations.IMAGE_TAR_SHA)
    config = observations.image_archive_contract(archive, observations.IMAGE_ID)
    selected = {name: path.lstrip("/") for name, (path, _) in observations.LIBRARIES.items()}
    selected.update(EXTRA_INPUTS)
    targets = tuple(selected.values())
    seen, history, total, entries, expanded, records = {}, {}, 0, 0, 0, 0

    def family(name):
        return next((path for path in targets if name == path or
                     (path != selected["pg_config.h"] and re.fullmatch(re.escape(path) + r"\.[0-9]+(?:\.[0-9]+)*", name))), None)

    with tarfile.open(archive, "r:") as outer:
        for diff_id in config["rootfs"]["diff_ids"]:
            _budget(deadline)
            if re.fullmatch(r"sha256:[0-9a-f]{64}", diff_id) is None:
                raise ValueError("The image layer identity is not canonical.")
            layer_name = "blobs/sha256/" + diff_id[7:]
            changeset = set()
            member = outer.getmember(layer_name)
            if not member.isfile() or member.size > reference.LAYER_BYTES:
                raise ValueError("An image layer exceeds its byte bound.")
            with outer.extractfile(member) as stream:
                digest = hashlib.sha256()
                while chunk := stream.read(131072):
                    _budget(deadline)
                    digest.update(chunk)
                if digest.hexdigest() != diff_id[7:]:
                    raise ValueError("An image layer differs from its recorded content identity.")
                stream.seek(0)
                with tarfile.open(fileobj=stream, mode="r|") as layer:
                    for entry in layer:
                        _budget(deadline)
                        entries += 1
                        expanded += entry.size
                        if entries > reference.LAYER_ENTRIES or entry.size < 0 or expanded > reference.LAYER_BYTES:
                            raise ValueError("The dependency inspection exceeds its layer bounds.")
                        name = reference._layer_name(entry)
                        if name is None:
                            continue
                        whiteout = PurePosixPath(name)
                        whiteout_target = str(whiteout.parent / whiteout.name.removeprefix(".wh."))
                        if reference._header_whiteout(name, targets) or (whiteout.name.startswith(".wh.") and family(whiteout_target)):
                            raise ValueError("A selected dependency has an ambiguous whiteout.")
                        parent = reference._affects_selected(name, targets) and name not in targets
                        if parent and not entry.isdir():
                            raise ValueError("A selected dependency parent is not a direct directory.")
                        if family(name) is None:
                            continue
                        records += 1
                        if records > DEPENDENCY_RECORDS:
                            raise ValueError("The selected dependency inventory exceeds its record bound.")
                        if name in changeset:
                            raise ValueError("A selected dependency is duplicated within one image changeset.")
                        changeset.add(name)
                        if entry.issym() and name in targets and name != selected["pg_config.h"]:
                            if "/" in entry.linkname or "\\" in entry.linkname or not entry.linkname.isascii():
                                raise ValueError("A selected soname link escapes its fixed library directory.")
                            target = str(PurePosixPath(name).parent / entry.linkname)
                            if target == name or family(target) != name:
                                raise ValueError("A selected soname does not name one fixed regular payload.")
                            previous = seen.get(name, {})
                            if previous and previous.get("target") != target:
                                # Runtime COPY can dereference a soname before
                                # qualification restores its identical link.
                                old = previous.get("data")
                                if old is None or seen.get(target, {}).get("data") != old:
                                    raise ValueError("A later selected soname changes its link semantics.")
                            seen[name] = {"target": target, "layer": layer_name}
                            history.setdefault(name, []).append({"type": "symlink", "target": target, "layer": layer_name})
                        elif entry.isfile() and 0 < entry.size <= LIBRARY_BYTES:
                            if name in seen and "data" not in seen[name]:
                                raise ValueError("A later selected dependency changes its file type.")
                            total += entry.size
                            if total > DEPENDENCY_BYTES:
                                raise ValueError("Selected dependency bytes exceed their aggregate bound.")
                            data = layer.extractfile(entry).read(LIBRARY_BYTES + 1)
                            if len(data) != entry.size:
                                raise ValueError("A selected dependency is truncated.")
                            seen[name] = {"data": data, "layer": layer_name}
                            history.setdefault(name, []).append({"type": "regular", "layer": layer_name, **_identity(data)})
                        else:
                            raise ValueError("A selected dependency is linked, special, or oversized.")
    contents, receipt = {}, {}
    for label, path in selected.items():
        item = seen.get(path, {})
        payload_path = item.get("target", path)
        payload = seen.get(payload_path, {})
        data = payload.get("data")
        if data is None:
            raise ValueError("The retained image lacks a selected regular dependency.")
        digest = hashlib.sha256(data).hexdigest()
        if label in observations.LIBRARIES and digest != observations.LIBRARIES[label][1]:
            raise ValueError("A selected library differs from its exact EA payload digest.")
        if label == "pg_config.h":
            if len(data) > reference.HEADER_BYTES or re.findall(rb"^#define PG_VERSION_NUM ([0-9]+)$", data, re.M) != [b"160015"]:
                raise ValueError("The retained PostgreSQL configuration header has the wrong version.")
        elif (len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01"
              or struct.unpack_from("<HHI", data, 16) != (3, 243, 1) or struct.unpack_from("<I", data, 48)[0] != 5):
            raise ValueError("A selected library has the wrong RISC-V target or LP64D ABI.")
        contents[PurePosixPath(path).name] = data
        receipt[label] = {"image_path": path, "payload_path": payload_path, "layer": payload["layer"],
                          **_identity(data), "output_name": PurePosixPath(path).name,
                          "selected_history": {name: values for name, values in history.items() if family(name) == path}}
    _budget(deadline)
    with tempfile.TemporaryDirectory(prefix=".asm-canonical-deps-", dir=destination.parent) as temporary:
        stage = Path(temporary) / "dependencies"
        stage.mkdir(mode=0o700)
        for name, data in contents.items():
            (stage / name).write_bytes(data)
            (stage / name).chmod(0o444)
        _publish(stage, destination)
    return receipt


def _publish(stage, destination):
    # Host-only: reuse exact cb0 helpers from the checkout that runs the builder.
    # The guest's standalone copied builder only loads the SDK; it never publishes.
    tools = Path(__file__).resolve().parent
    sources, saved, loaded = {}, {}, {}
    for name, (size, digest) in PUBLICATION_IDENTITIES.items():
        data = _read(tools / name)
        if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("The host publication helper differs from the pinned cb0 source bytes.")
        sources[name.removesuffix(".py")] = data
    try:
        for name in ("registry", "release"):
            saved[name] = sys.modules.get(name)
            spec = importlib.util.spec_from_file_location(name, tools / (name + ".py"))
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            exec(compile(sources[name], str(tools / (name + ".py")), "exec"), module.__dict__)
            loaded[name] = module
        loaded["release"].publish_directory(stage, destination)
    finally:
        for name, module in saved.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module


def import_contract(symbols, versions, dynamic, *, provided_versions):
    undefined = sorted(set(re.findall(r"\bUND\s+([^\s]+)", symbols)))
    required = sorted(set(re.findall(r"GLIBC_[0-9]+(?:\.[0-9]+)+", symbols + versions)))
    if set(required) - set(provided_versions):
        raise ValueError("The output requires GLIBC versions absent from the exact EA providers.")
    needed = re.findall(r"\(NEEDED\).*\[([^\]]+)\]", dynamic)
    if len(needed) != len(set(needed)) or any("/" in name for name in needed):
        raise ValueError("The output has an ambiguous or path-based shared-library import.")
    return {"needed": sorted(needed), "undefined_symbols": undefined, "required_glibc_versions": required,
            "dynamic": dynamic, "version_info": versions}


def interpreter_contract(path, *, shared):
    """Retain one fixed PT_INTERP for executables; shared mocks have none.

    Call after the reused full ELF structural contract, before publication.
    This does not establish that the interpreter exists in the eventual guest.
    """
    data = _read(path, LOG_BYTES)
    offset = struct.unpack_from("<Q", data, 32)[0]
    width, count = struct.unpack_from("<HH", data, 54)
    found = []
    if width != 56 or not 1 <= count <= 128 or offset + width * count > len(data):
        raise ValueError("The ELF interpreter has invalid program-header bounds.")
    for index in range(count):
        kind, _, start, _, _, size, _, _ = struct.unpack_from("<IIQQQQQQ", data, offset + width * index)
        if kind == 3:
            if not 1 < size <= 256 or start + size > len(data):
                raise ValueError("The ELF interpreter exceeds its byte bound.")
            found.append(data[start:start + size])
    expected = [] if shared else [b"/lib/ld-linux-riscv64-lp64d.so.1\0"]
    if found != expected:
        raise ValueError("The ELF output lacks the fixed LP64D interpreter contract.")
    return None if shared else expected[0][:-1].decode("ascii")


def prepare_build(image_archive, context, *, sdk, mhd_source, observer_sha256, observer_test_sha256,
                  deadline, compiler=Path("/usr/bin/riscv64-linux-gnu-gcc"), timeout=120):
    """Build five files under the caller's remaining absolute work deadline.

    context/source holds exact cb0 source; observer.c and observer-test.py have
    caller-reviewed digests. The latter supplies literal PROVIDER/DRIVER mocks.
    No generated executable is invoked. All final files remain UNQUALIFIED.
    """
    if (type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= BUILD_SECONDS
            or type(deadline) not in (int, float) or not math.isfinite(deadline)):
        raise ValueError("Use a finite absolute deadline and a build budget of at most 120 seconds.")
    context, compiler = Path(context), Path(compiler)
    if context.is_symlink() or not context.is_dir():
        raise ValueError("Use a direct existing canonical build context.")
    context = context.resolve()
    destination = context / "canonical-build"
    for path in (destination, context / "canonical-build-failure.json", context / "canonical-build-failure.log"):
        _absent(path)
    started = time.monotonic()
    deadline = min(deadline, started + timeout)
    stage = Path(tempfile.mkdtemp(prefix=".asm-canonical-build-", dir=context))
    report = {"schema": 1, "scope": "asm-canonical-riscv-build", "outcome": "fail",
              "qualification": "UNQUALIFIED", "target_execution": "not-run", "source_revision": SOURCE_REVISION,
              "target": "riscv64-linux", "isa": "RV64GC", "abi": "LP64D", "commands": [], "outputs": {},
              "sources": {}, "sdk_revision": SDK_REVISION,
              "sdk": {name: {"bytes": size, "sha256": digest} for name, (size, digest) in SDK_IDENTITIES.items()},
              "publication_helpers": {name: {"revision": SOURCE_REVISION, "bytes": size, "sha256": digest}
                                      for name, (size, digest) in PUBLICATION_IDENTITIES.items()},
              "limits": {"build_seconds": timeout, "command_seconds": COMMAND_SECONDS,
                         "log_bytes": LOG_BYTES, "total_log_bytes": TOTAL_LOG_BYTES,
                         "dependency_bytes": DEPENDENCY_BYTES, "dependency_records": DEPENDENCY_RECORDS},
              "limits_of_evidence": ["Source-rebuilt candidate; original failed executable bytes were not retained.",
                  "No target program was executed. Guest ABI, version, loader, and forwarding checks remain required.",
                  "The compiler, its host dependencies, and the caller-owned context remain trusted."]}
    phase, last_log, published = "source", None, False
    inputs, tools, total_logs = {}, {}, 0
    try:
        _budget(deadline)
        builder_source = _read(Path(__file__).resolve())
        report["builder"] = _identity(builder_source)
        sdk = load_sdk(sdk)
        reference, observations = sdk.reference, sdk.observations
        report["image"] = {"bytes": observations.IMAGE_TAR_BYTES, "sha256": observations.IMAGE_TAR_SHA, "id": observations.IMAGE_ID}
        for relative, (size, digest) in SOURCE_IDENTITIES.items():
            data = _source(context / "source", relative)
            if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("A canonical input differs from the exact cb0 source bytes.")
            inputs["source/" + relative] = data
        for name, digest in (("observer.c", observer_sha256), ("observer-test.py", observer_test_sha256)):
            data = _source(context, name)
            if type(digest) is not str or re.fullmatch("[0-9a-f]{64}", digest) is None or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("An observer input differs from its reviewed source identity.")
            inputs[name] = data
        fixtures = reference._test_sources(inputs["observer-test.py"])
        for name, data in inputs.items():
            path = stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o444)
        report["sources"] = {name: {**_identity(data), "mode": "0444"} for name, data in inputs.items()}
        for name, data in (("provider.c", fixtures["PROVIDER"]), ("driver.c", fixtures["DRIVER"])):
            (stage / name).write_bytes(data)
            (stage / name).chmod(0o444)
            report["sources"][name] = {**_identity(data), "mode": "0444"}
        phase = "dependencies"
        report["libraries"] = extract_dependencies(Path(image_archive), stage / "dependencies", sdk, deadline=deadline)
        _budget(deadline)
        phase = "headers"
        report["headers"] = reference.extract_headers(Path(image_archive), stage / "include")
        report["headers"]["microhttpd.h"] = reference.extract_mhd_header(Path(mhd_source), stage / "include/microhttpd.h")
        os.rename(stage / "dependencies/pg_config.h", stage / "include/pg_config.h")
        report["headers"]["pg_config.h"] = report["libraries"].pop("pg_config.h")
        for name in ("home", "tmp"):
            (stage / name).mkdir(mode=0o700)

        def command(label, arguments, *, cwd=stage, maximum=LOG_BYTES):
            nonlocal last_log, total_logs
            _budget(deadline)
            remaining = min(COMMAND_SECONDS, deadline - time.monotonic())
            bound = min(maximum, TOTAL_LOG_BYTES - total_logs)
            if bound <= 0:
                raise ValueError("Canonical build logs exceed their aggregate bound.")
            last_log = stage / (label + ".log")
            args = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "LC_ALL=C", "LANG=C",
                    "HOME=" + str(stage / "home"), "TMPDIR=" + str(stage / "tmp"), *map(str, arguments)]
            result = sdk.combined.bounded_process(args, last_log, cwd=cwd, timeout=remaining, max_bytes=bound)
            total_logs += result["bytes"]
            report["commands"].append({"label": label, "arguments": args, **result, "log_sha256": observations.digest(last_log)})
            _budget(deadline)
            if result["outcome"] != "pass":
                raise ValueError("A bounded canonical build command failed.")
            return last_log.read_text(encoding="utf-8", errors="strict")

        phase = "compiler"
        report["compiler"] = reference._identity(compiler)
        report["compiler"]["version"] = command("compiler-version", [compiler, "--version"], maximum=16384).splitlines()[0]
        target = command("compiler-target", [compiler, "-dumpmachine"], maximum=1024).strip()
        if target != "riscv64-linux-gnu":
            raise ValueError("The compiler must target riscv64-linux-gnu.")
        report["compiler"]["target"] = target
        for name in ("cc1", "as", "ld", "collect2"):
            path = command("tool-" + name, [compiler, "-print-prog-name=" + name], maximum=4096).strip()
            tools[name] = reference._identity(Path(path))
        readelf = compiler.parent / "riscv64-linux-gnu-readelf"
        tools["readelf"] = reference._identity(readelf)
        tools["readelf"]["version"] = command("readelf-version", [readelf, "--version"], maximum=16384).splitlines()[0]
        report["compiler"]["subtools"] = tools
        report["compiler"]["target_inputs"] = {}
        for name in ("Scrt1.o", "crti.o", "crtn.o", "crtbeginS.o", "crtendS.o", "libgcc.a", "libgcc_s.so.1",
                     "libc.so", "libc.so.6", "libpthread.a", "libdl.a", "ld-linux-riscv64-lp64d.so.1"):
            path = command("target-" + name, [compiler, "-march=rv64gc", "-mabi=lp64d", "-print-file-name=" + name], maximum=4096).strip()
            report["compiler"]["target_inputs"][name] = reference._identity(Path(path))
        provided_versions = set()
        report["ea_glibc"] = {}
        for label in ("ea_libc", "ea_loader"):
            name = report["libraries"][label]["output_name"]
            versions = command(label + "-versions", [readelf, "--version-info", "--wide", stage / "dependencies" / name])
            definitions = versions.split("Version needs section", 1)[0]
            provided_versions.update(re.findall(r"Name:\s+(GLIBC_[0-9]+(?:\.[0-9]+)+)", definitions))
            report["ea_glibc"][label] = versions
        if not provided_versions:
            raise ValueError("The exact EA providers have no inspectable GLIBC definitions.")
        report["ea_glibc"]["provided_versions"] = sorted(provided_versions)
        for label, item in report["libraries"].items():
            dynamic = command(label + "-dynamic", [readelf, "--dynamic", "--wide", stage / "dependencies" / item["output_name"]])
            sonames = re.findall(r"\(SONAME\).*\[([^\]]+)\]", dynamic)
            if sonames != [item["output_name"]]:
                raise ValueError("An exact EA library has an unexpected or absent soname.")
            item["dynamic"] = dynamic
        phase = "compile"
        flags = [compiler, "-march=rv64gc", "-mabi=lp64d", "-Wl,-z,noexecstack", "-Wl,-z,relro", "-Wl,-z,now"]
        cflags = [*flags, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread", "-I", stage / "include"]
        dependencies = stage / "dependencies"
        linked = [dependencies / "libmicrohttpd.so.12", dependencies / "libpq.so.5",
                  "-Wl,-rpath-link," + str(dependencies), "-Wl,-rpath,/opt/asm/mhd/lib",
                  "-Wl,-rpath,/opt/asm/postgres/lib", "-pthread"]
        build_commands = (
            [*flags, "-g", "-fPIE", "-pie", "-x", "assembler-with-cpp", '-DASM_SOURCE_REVISION="' + SOURCE_REVISION + '"',
             "riscv64/runtime.s", "riscv64/config.s", "-o", stage / OUTPUTS[0], "-x", "none", *linked],
            [*cflags, "-fPIE", "-pie", stage / "source/server/abi-check.c", "-o", stage / OUTPUTS[1], *linked],
            [*cflags, "-fPIC", "-shared", stage / "observer.c", "-o", stage / OUTPUTS[2], "-Wl,-soname," + OUTPUTS[2], "-ldl"],
            [*cflags, "-fPIC", "-shared", stage / "provider.c", "-o", stage / OUTPUTS[3], "-Wl,-soname," + OUTPUTS[3], "-ldl"],
            [*cflags, "-fPIE", "-pie", stage / "driver.c", stage / OUTPUTS[3], "-Wl,-rpath,/inputs/canonical-build", "-o", stage / OUTPUTS[4]],
        )
        for index, args in enumerate(build_commands):
            name = OUTPUTS[index]
            phase = "compile-" + name
            command("compile-" + str(index), args, cwd=stage / "source/server")
            metadata = reference.elf_contract(stage / name, shared=index in (2, 3))
            metadata["interpreter"] = interpreter_contract(stage / name, shared=index in (2, 3))
            attributes = command("attributes-" + str(index), [readelf, "-A", stage / name], maximum=16384)
            metadata["architecture"] = reference._architecture(attributes)
            symbols = command("symbols-" + str(index), [readelf, "--dyn-syms", "--wide", stage / name])
            versions = command("versions-" + str(index), [readelf, "--version-info", "--wide", stage / name])
            dynamic = command("dynamic-" + str(index), [readelf, "--dynamic", "--wide", stage / name])
            metadata["imports"] = import_contract(symbols, versions, dynamic, provided_versions=provided_versions)
            expected = {"libmicrohttpd.so.12", "libpq.so.5"} if index < 2 else ({"libcanonical_provider.so"} if index == 4 else set())
            if not expected <= set(metadata["imports"]["needed"]):
                raise ValueError("A diagnostic output lacks an expected exact-provider import.")
            metadata["mode"] = "0555"
            report["outputs"][name] = metadata
            (stage / name).chmod(0o555)
        phase = "final-inputs"
        for name, data in inputs.items():
            if _source(stage, name) != data or _source(context, name) != data:
                raise ValueError("A canonical build source changed during compilation.")
        for name, data in (("provider.c", fixtures["PROVIDER"]), ("driver.c", fixtures["DRIVER"])):
            if _source(stage, name) != data:
                raise ValueError("A canonical forwarding fixture changed during compilation.")
        for label, item in {**report["libraries"], "pg_config.h": report["headers"]["pg_config.h"]}.items():
            path = stage / ("include" if label == "pg_config.h" else "dependencies") / item["output_name"]
            if _identity(_read(path, LIBRARY_BYTES))["sha256"] != item["sha256"]:
                raise ValueError("A canonical dependency changed during compilation.")
        for name, item in report["headers"].items():
            if _identity(_read(stage / "include" / name))["sha256"] != item["sha256"]:
                raise ValueError("A canonical public header changed during compilation.")
        for item in (report["compiler"], *tools.values(), *report["compiler"]["target_inputs"].values()):
            if reference._identity(Path(item["path"]))["sha256"] != item["sha256"]:
                raise ValueError("A canonical compiler input changed during compilation.")
        if _read(Path(__file__).resolve()) != builder_source:
            raise ValueError("The canonical builder changed during compilation.")
        _budget(deadline)
        report.update(outcome="pass", seconds=round(time.monotonic() - started, 3), recorded_at=datetime.now(timezone.utc).isoformat())
        (stage / "manifest.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        (stage / "manifest.json").chmod(0o444)
        stage.chmod(0o755)
        _publish(stage, destination)
        published = True
        _budget(deadline)
        return report
    except (OSError, ValueError, KeyError, TypeError, SyntaxError, IndexError, struct.error,
            tarfile.TarError, subprocess.SubprocessError) as error:
        if published:
            os.rename(destination, stage)
        report.update(outcome="fail", stage=phase, exception_type=type(error).__name__,
                      seconds=round(time.monotonic() - started, 3), recorded_at=datetime.now(timezone.utc).isoformat())
        final_log = last_log.read_bytes()[:LOG_BYTES] if last_log is not None and last_log.is_file() else b""
        for suffix, data in (("json", (json.dumps(report, indent=2, sort_keys=True) + "\n").encode()), ("log", final_log)):
            if len(data) > LOG_BYTES:
                raise ValueError("Canonical build failure evidence exceeds its byte bound.") from None
            path = context / ("canonical-build-failure." + suffix)
            with path.open("xb") as output:
                output.write(data)
            path.chmod(0o444)
        raise ValueError("Canonical build failed at " + phase + "; inspect canonical-build-failure.json.") from None
    finally:
        if stage.exists():
            shutil.rmtree(stage)
