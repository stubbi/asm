#!/usr/bin/env python3
"""Build a COPY-only diagnostic overlay; keep the RISC-V clients unchanged.

SPDX-License-Identifier: AGPL-3.0-or-later
The native backend changes architecture AND build. No application qualification
or pure QEMU cost follows. Docker operations run only in the reviewed CI job.
"""
import argparse
import hashlib
from itertools import islice
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import tempfile
import time
import uuid

from riscv64_combined import bounded_process
import riscv64_server_observations as observations

BASE_IMAGE = observations.IMAGE_ID
NATIVE_DIGEST = "sha256:751329300ebdcbde5461c14fac796c8840d13fc74cc49b9b94745b0285907961"
NATIVE_IMAGE = "docker.io/library/postgres@" + NATIVE_DIGEST
PREFIX = Path("/opt/asm/native-postgres")
ROOT = PREFIX / "rootfs"
BINDIR = PREFIX / "bin"
POSTGRES = ROOT / "usr/local/bin/postgres"
LOADER = Path("/lib/ld-musl-x86_64.so.1")
MUSL_PATH = Path("/etc/ld-musl-x86_64.path")
COLLISIONS = (PREFIX, LOADER, MUSL_PATH)
BASELINE = Path("/inputs/native-baseline-risc.json")
GUEST_MANIFEST = Path("/inputs/native-postgres-manifest.json")
TIMEZONE = Path("/usr/share/zoneinfo/UTC")
CGROUP = Path("/sys/fs/cgroup")
MANIFEST = Path(__file__).resolve().parent / "diagnostics/native_postgres_manifest.json"
MANIFEST_SHA = "23573aaf92cbd9315ce761299b33370f439ccb8a8bfe17a204532591cdf4e698"
RISC_FILES = {
    "server": Path("/inputs/asm-server-riscv64-linux"),
    "python": Path("/usr/bin/python3"),
    "libpq": Path("/opt/asm/postgres/lib/libpq.so.5"),
    "libmicrohttpd": Path("/opt/asm/mhd/lib/libmicrohttpd.so.12"),
    "postgres": Path("/opt/asm/postgres/bin/postgres"),
    "initdb": Path("/opt/asm/postgres/bin/initdb"),
    "psql": Path("/opt/asm/postgres/bin/psql"),
    "loader": Path("/lib/ld-linux-riscv64-lp64d.so.1"),
    **{name: Path("/lib/riscv64-linux-gnu/" + name) for name in
       ("libc.so.6", "libcrypto.so.3", "libssl.so.3", "libm.so.6", "libz.so.1", "libzstd.so.1", "libexpat.so.1")},
}
PINS = {
    "server": (33584, observations.SERVER_SHA),
    "python": (6400392, "8517cd237a0a8dea12fd5c773456db70d8f7262dcb35060f80640b8800c11fc6"),
    "libpq": (339112, observations.LIBRARIES["libpq"][1]),
    "libmicrohttpd": (942616, observations.LIBRARIES["libmicrohttpd"][1]),
}
LIMIT = 1024 * 1024


def _budget(deadline, cap=30):
    if not isinstance(deadline, (float, int)) or not math.isfinite(deadline):
        raise ValueError("The native diagnostic needs an absolute deadline.")
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError("The native diagnostic deadline expired.")
    return min(cap, remaining)


def _read(path, maximum, *, virtual=False):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
                raise ValueError("A native diagnostic file exceeds its bound.")
            data = stream.read(maximum + 1)
            if len(data) > maximum or (not virtual and len(data) != info.st_size):
                raise ValueError("A native diagnostic file changed while reading.")
            return data
    except OSError:
        raise ValueError("A native diagnostic file is unavailable.") from None


def _json(data):
    if len(data) > LIMIT:
        raise ValueError("Native metadata exceeds its bound.")
    return observations.load_json(data)


def asset_manifest():
    data = _read(MANIFEST, 32768)
    if hashlib.sha256(data).hexdigest() != MANIFEST_SHA:
        raise ValueError("The reviewed native image metadata changed.")
    return _json(data)


def file_identity(path, *, maximum=256 * 1024 * 1024, machine=None, deadline=None):
    """Hash a bounded resolved regular file; report its declared ELF machine."""
    try:
        resolved = path.resolve(strict=True)
        descriptor = os.open(resolved, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        raise ValueError("A diagnostic executable is unavailable.") from None
    value, count = hashlib.sha256(), 0
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError("A diagnostic executable exceeds its bound.")
        first = stream.read(64)
        value.update(first)
        count += len(first)
        for data in iter(lambda: stream.read(131072), b""):
            if deadline is not None:
                _budget(deadline)
            count += len(data)
            if count > maximum:
                raise ValueError("A diagnostic executable exceeds its bound.")
            value.update(data)
        after = os.fstat(stream.fileno())
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if count != info.st_size or any(getattr(after, field) != getattr(info, field) for field in fields):
            raise ValueError("A diagnostic executable changed while reading.")
    record = {"bytes": count, "sha256": value.hexdigest(), "resolved_path": str(resolved)}
    if machine is not None:
        if len(first) != 64 or first[:7] != b"\x7fELF\x02\x01\x01" or struct.unpack_from("<H", first, 18)[0] != machine:
            raise ValueError("A diagnostic executable has the wrong ELF machine.")
        record["elf_machine"] = machine
    return record


def capture_risc(*, require_absent=False):
    if require_absent and any(os.path.lexists(path) for path in COLLISIONS):
        raise ValueError("The native overlay would replace a base-image path.")
    files = {}
    for name, path in RISC_FILES.items():
        record = file_identity(path, machine=243)
        if name in PINS and (record["bytes"], record["sha256"]) != PINS[name]:
            raise ValueError("A pinned RISC-V client changed.")
        files[str(path)] = record
    return {"schema": 1, "scope": "native-backend-risc-baseline", "outcome": "pass",
            "base_image": BASE_IMAGE, "files": files, "postgres": files[str(RISC_FILES["postgres"])],
            "psql": files[str(RISC_FILES["psql"])], "timezone": file_identity(TIMEZONE, maximum=65536),
            "overlay_paths_absent": require_absent}


def verify_risc():
    baseline = _json(_read(BASELINE, 65536))
    check_baseline(baseline)
    current = capture_risc()
    if (baseline.get("schema") != 1 or baseline.get("base_image") != BASE_IMAGE
            or baseline.get("overlay_paths_absent") is not True
            or any(current[key] != baseline.get(key) for key in ("files", "postgres", "psql", "timezone"))):
        raise ValueError("RISC-V bytes differ from the checked base image.")
    return current


def check_baseline(record):
    expected = {"schema", "scope", "outcome", "base_image", "files", "postgres", "psql", "timezone", "overlay_paths_absent"}
    if (set(record) != expected or type(record["schema"]) is not int or record["schema"] != 1
            or record["scope"] != "native-backend-risc-baseline" or record["outcome"] != "pass"
            or record["base_image"] != BASE_IMAGE or record["overlay_paths_absent"] is not True
            or not isinstance(record["files"], dict) or set(record["files"]) != set(map(str, RISC_FILES.values()))):
        raise ValueError("The RISC-V baseline evidence is incomplete.")
    def identity(value, maximum, machine=None):
        fields = {"bytes", "sha256", "resolved_path"} | ({"elf_machine"} if machine else set())
        if (not isinstance(value, dict) or set(value) != fields or type(value["bytes"]) is not int
                or not 0 < value["bytes"] <= maximum or not isinstance(value["sha256"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", value["sha256"])
                or not isinstance(value["resolved_path"], str) or not value["resolved_path"].startswith("/")
                or len(value["resolved_path"]) > 512 or any(c in value["resolved_path"] for c in "\n\r\0")
                or (machine and (type(value["elf_machine"]) is not int or value["elf_machine"] != machine))):
            raise ValueError("A RISC-V baseline file identity is malformed.")
    for name, path in RISC_FILES.items():
        metadata = record["files"][str(path)]
        identity(metadata, 256 * LIMIT, 243)
        if name in PINS and (metadata["bytes"], metadata["sha256"]) != PINS[name]:
            raise ValueError("A pinned RISC-V baseline file differs.")
    identity(record["timezone"], 65536)
    if any(record[key] != record["files"][str(RISC_FILES[key])] for key in ("postgres", "psql")):
        raise ValueError("A RISC-V baseline executable binding is inconsistent.")


def check_native_image(info, asset):
    if (info.get("Id") != asset["config"] or info.get("Architecture") != "amd64"
            or info.get("Os") != "linux" or info.get("RootFS", {}).get("Layers") != asset["rootfs_diff_ids"]):
        raise ValueError("The native image differs from the reviewed asset.")


def check_overlay(base, overlay):
    layers = base.get("RootFS", {}).get("Layers", [])
    added = overlay.get("RootFS", {}).get("Layers", [])
    if (base.get("Id") != BASE_IMAGE or overlay.get("Architecture") != "riscv64" or overlay.get("Os") != "linux"
            or not layers or len(added) <= len(layers) or added[:len(layers)] != layers
            or overlay.get("Config") != base.get("Config")):
        raise ValueError("The native overlay changed its base configuration or layers.")


def musl_path():
    return "\n".join(str(ROOT / path) for path in ("lib", "usr/local/lib", "usr/lib")) + "\n"


def wrapper(name):
    if name == "psql":
        return '#!/bin/sh\nexec /opt/asm/postgres/bin/psql "$@"\n'
    if name not in ("initdb", "postgres"):
        raise ValueError("No native diagnostic wrapper exists for that command.")
    return ("#!/bin/sh\nunset LD_LIBRARY_PATH LD_PRELOAD\n"
            + "asm_icu_data=\nfor asm_icu_dir in " + str(ROOT / "usr/share/icu") + "/*; do\n"
            + '  [ -d "$asm_icu_dir" ] || continue\n  [ -z "$asm_icu_data" ] || exit 111\n'
            + '  asm_icu_data=$asm_icu_dir\ndone\n[ -n "$asm_icu_data" ] || exit 111\n'
            + 'export ICU_DATA="$asm_icu_data"\n'
            + "export OPENSSL_MODULES=" + str(ROOT / "usr/lib/ossl-modules") + "\n"
            + "export OPENSSL_CONF=" + str(ROOT / "etc/ssl/openssl.cnf") + "\n"
            + "exec " + str(ROOT / "usr/local/bin" / name) + ' "$@"\n')


def overlay_recipe():
    return ("FROM --platform=linux/amd64 " + NATIVE_IMAGE + " AS native\nFROM --platform=linux/riscv64 " + BASE_IMAGE + "\n"
            "COPY --from=native / /opt/asm/native-postgres/rootfs/\n"
            "COPY --from=native /lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1\n"
            "COPY musl.path /etc/ld-musl-x86_64.path\n"
            "COPY wrappers/ /opt/asm/native-postgres/bin/\n")


def _docker(arguments, log, deadline, *, config, cap=30):
    result = bounded_process(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "HOME=/nonexistent",
                              "DOCKER_CONFIG=" + str(config), "docker", *arguments],
                             log, timeout=_budget(deadline, cap), max_bytes=LIMIT)
    _budget(deadline)
    if result["outcome"] != "pass":
        raise ValueError("A bounded native overlay operation failed.")
    return _read(log, LIMIT)


def prepare_native(context: Path, output: Path, deadline: float) -> dict:
    """Use the fixed prebuilt image; never compile or execute its entrypoint."""
    _budget(deadline)
    work_deadline = deadline - 5  # Reserve cleanup within the caller's allowance.
    _budget(work_deadline)
    destinations = [context / "native-baseline-risc.json", context / "native-postgres-manifest.json"]
    if any(os.path.lexists(path) for path in destinations):
        raise ValueError("A native overlay receipt destination already exists.")
    if not context.is_dir() or not output.is_dir() or "," in str(context.resolve()):
        raise ValueError("Use existing native diagnostic directories without mount separators.")
    asset = asset_manifest()
    name = "asm-native-baseline-" + uuid.uuid4().hex
    tag = "asm-native-overlay:" + uuid.uuid4().hex
    published = []
    with tempfile.TemporaryDirectory(prefix=".native-overlay-", dir=context.parent) as temporary:
        stage = Path(temporary)
        config = stage / "docker-config"
        config.mkdir()
        run = lambda args, label, cap=30: _docker(args, output / ("native-" + label + ".log"), work_deadline, config=config, cap=cap)
        run(["pull", "--platform=linux/amd64", NATIVE_IMAGE], "pull", 90)
        native = _json(run(["image", "inspect", NATIVE_IMAGE], "inspect-source"))[0]
        check_native_image(native, asset)
        base = _json(run(["image", "inspect", BASE_IMAGE], "inspect-base"))[0]
        if base.get("Id") != BASE_IMAGE or base.get("Architecture") != "riscv64" or base.get("Os") != "linux":
            raise ValueError("The retained RISC-V base image is unavailable.")
        created = False
        try:
            created = True
            run(["create", "--pull=never", "--name", name, "--platform=linux/riscv64", "--network=none",
                 "--user=65532:65532", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--pids-limit=256",
                 "--memory=2g", "--cpus=2", "--read-only", "--mount",
                 "type=bind,src=" + str(context.resolve()) + ",dst=/inputs,readonly", "--env", "LC_ALL=C",
                 "--env", "TZ=UTC", "--env", "QEMU_LD_PREFIX=/", "--entrypoint=/usr/bin/python3", BASE_IMAGE,
                 "/inputs/runner/tools/riscv64_reference_native.py", "--baseline"], "create-baseline")
            baseline = _json(run(["start", "--attach", name], "baseline", 30))
            check_baseline(baseline)
        finally:
            if created:
                _docker(["rm", "--force", name], output / "native-remove-baseline.log", deadline, config=config, cap=5)
        (stage / "Dockerfile").write_text(overlay_recipe())
        (stage / "musl.path").write_text(musl_path())
        (stage / "wrappers").mkdir()
        for command in ("initdb", "postgres", "psql"):
            path = stage / "wrappers" / command
            path.write_text(wrapper(command))
            path.chmod(0o555)
        # No credentials or socket are sent as build context. There is no RUN.
        shutil.rmtree(config)
        outside_config = stage.parent / (stage.name + "-docker-config")
        outside_config.mkdir()
        config = outside_config
        try:
            run(["build", "--platform=linux/riscv64", "--pull=false", "--network=none", "--progress=plain", "--tag", tag, str(stage)], "build-overlay", 60)
            overlay = _json(run(["image", "inspect", tag], "inspect-overlay"))[0]
            check_overlay(base, overlay)
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", overlay.get("Id", "")):
                raise ValueError("The native overlay image identity is malformed.")
            shutil.rmtree(outside_config)
            report = {"schema": 1, "scope": "native-backend-copy-overlay", "qualification": "UNQUALIFIED", "outcome": "pass",
                      "new_image_id": overlay["Id"], "overlay_tag": tag, "base_image_id": BASE_IMAGE,
                      "native_image": NATIVE_IMAGE, "native_config": asset["config"], "native_rootfs_diff_ids": asset["rootfs_diff_ids"],
                      "base_rootfs_diff_ids": base["RootFS"]["Layers"], "overlay_rootfs_diff_ids": overlay["RootFS"]["Layers"],
                      "base_config_sha256": hashlib.sha256(json.dumps(base["Config"], sort_keys=True).encode()).hexdigest(),
                      "dockerfile_sha256": hashlib.sha256(overlay_recipe().encode()).hexdigest(), "risc_baseline": baseline,
                      "limitations": ["Backend architecture and build differ.", "The original application remains unqualified."]}
            for destination, data in zip(destinations, [json.dumps(baseline, sort_keys=True).encode(), _read(MANIFEST, 32768)]):
                temporary_file = stage / destination.name
                temporary_file.write_bytes(data)
                temporary_file.chmod(0o444)
                os.link(temporary_file, destination)
                published.append(destination)
            _budget(work_deadline)
            return report
        except BaseException:
            for path in published:
                path.unlink()
            raise
        finally:
            if outside_config.exists():
                shutil.rmtree(outside_config)


def elf_metadata(path, machine):
    """Read bounded ELF64 headers only; never execute an inspection tool."""
    with path.open("rb") as stream:
        data = stream.read(64)
        if len(data) != 64 or data[:7] != b"\x7fELF\x02\x01\x01":
            raise ValueError("A native payload ELF header is malformed.")
        kind, actual = struct.unpack_from("<HH", data, 16)
        offset = struct.unpack_from("<Q", data, 32)[0]
        entry_size, count = struct.unpack_from("<HH", data, 54)
        size = os.fstat(stream.fileno()).st_size
        if actual != machine or kind not in (2, 3) or entry_size != 56 or count > 128 or offset + count * 56 > size:
            raise ValueError("A native payload ELF has the wrong architecture or bounds.")
        stream.seek(offset)
        headers = [struct.unpack("<IIQQQQQQ", stream.read(56)) for _ in range(count)]
        interpreter = None
        for p_type, flags, file_offset, _, _, file_size, _, _ in headers:
            if file_offset + file_size > size or (p_type == 1 and flags & 3 == 3):
                raise ValueError("A native ELF segment is out of bounds or writable executable.")
            if p_type == 3:
                if interpreter is not None or not 1 < file_size <= 256:
                    raise ValueError("A native ELF interpreter is ambiguous.")
                stream.seek(file_offset)
                raw = stream.read(file_size)
                if not raw.endswith(b"\0") or b"\0" in raw[:-1]:
                    raise ValueError("A native ELF interpreter is malformed.")
                interpreter = raw[:-1].decode("ascii")
            if p_type == 0x6474e551 and flags & 1:
                raise ValueError("A native ELF stack is executable.")
        return {"elf_machine": actual, "elf_type": kind, "interpreter": interpreter}


def parse_loader_list(text):
    result = []
    for line in text.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"\s*(?:[A-Za-z0-9_+.\-]+ => )?(/[^\s]+) \(0x[0-9a-fA-F]+\)\s*", line)
        if match is None:
            raise ValueError("The native dependency listing is malformed.")
        path = Path(match[1])
        try:
            resolved = path.resolve(strict=True)
        except OSError:
            raise ValueError("A native dependency is unavailable.") from None
        if path != LOADER and not resolved.is_relative_to(ROOT):
            raise ValueError("A native dependency resolved outside its private payload.")
        if resolved not in result:
            result.append(resolved)
        if len(result) > 128:
            raise ValueError("The native dependency count exceeds its bound.")
    if not result:
        raise ValueError("The native dependency listing is empty.")
    return result


def needed_libraries(path):
    """Read bounded DT_NEEDED names for static module closure checks."""
    elf_metadata(path, 62)
    with path.open("rb") as stream:
        header = stream.read(64)
        offset, = struct.unpack_from("<Q", header, 32)
        count, = struct.unpack_from("<H", header, 56)
        stream.seek(offset)
        headers = [struct.unpack("<IIQQQQQQ", stream.read(56)) for _ in range(count)]
        dynamic = [entry for entry in headers if entry[0] == 2]
        if not dynamic:
            return []
        if len(dynamic) != 1 or dynamic[0][5] > 262144 or dynamic[0][5] % 16:
            raise ValueError("A native dynamic table exceeds its bound.")
        stream.seek(dynamic[0][2])
        table = stream.read(dynamic[0][5])
        needed, strings, size, terminated = [], None, None, False
        for index in range(0, len(table), 16):
            tag, value = struct.unpack_from("<qQ", table, index)
            if tag == 0:
                terminated = True
                break
            if tag in (15, 29):  # DT_RPATH / DT_RUNPATH could alter this fixed search.
                raise ValueError("A selected native dependency overrides its private search path.")
            if tag == 1:
                needed.append(value)
            elif tag == 5:
                if strings is not None:
                    raise ValueError("Native string tables are ambiguous.")
                strings = value
            elif tag == 10:
                if size is not None:
                    raise ValueError("Native string table sizes are ambiguous.")
                size = value
        if not terminated or len(needed) > 128:
            raise ValueError("A native dynamic dependency table is malformed.")
        if not needed:
            return []
        if strings is None or size is None or not 0 < size <= 16 * LIMIT:
            raise ValueError("A native string table exceeds its bound.")
        segments = [entry for entry in headers if entry[0] == 1 and entry[3] <= strings and strings + size <= entry[3] + entry[5]]
        if len(segments) != 1:
            raise ValueError("A native string table has no unique file range.")
        stream.seek(segments[0][2] + strings - segments[0][3])
        data = stream.read(size)
        result = []
        for index in needed:
            if index >= len(data):
                raise ValueError("A native dependency string is out of bounds.")
            end = data.find(b"\0", index, min(len(data), index + 129))
            if end < 0:
                raise ValueError("A native dependency string is unterminated.")
            name = data[index:end].decode("ascii")
            if not re.fullmatch(r"[A-Za-z0-9_+.\-]{1,128}", name) or name in result:
                raise ValueError("A native dependency name is ambiguous.")
            result.append(name)
        return result


def dependency_closure(selected, deadline):
    """Verify selected modules' declared dependency bytes, not symbol loading."""
    pending, result = list(selected), {}
    while pending:
        _budget(deadline)
        path = pending.pop().resolve(strict=True)
        if not path.is_relative_to(ROOT) and path != LOADER.resolve(strict=True):
            raise ValueError("A native module dependency escaped its prefix.")
        if str(path) in result:
            continue
        if len(result) >= 128:
            raise ValueError("Native module dependency closure exceeds its bound.")
        names = needed_libraries(path)
        result[str(path)] = {**file_identity(path, machine=62, deadline=deadline), "needed": names}
        for name in names:
            candidates = [ROOT / directory / name for directory in ("lib", "usr/local/lib", "usr/lib")]
            chosen = next((candidate for candidate in candidates if candidate.is_file()), None)
            if chosen is None:
                raise ValueError("A selected native module dependency is unavailable.")
            pending.append(chosen)
    return result


def _icu_file():
    base = ROOT / "usr/share/icu"
    directories = list(islice(base.iterdir(), 2))
    if len(directories) != 1 or not directories[0].is_dir() or not re.fullmatch(r"[0-9]+\.[0-9]+", directories[0].name):
        raise ValueError("The native ICU data directory is missing or ambiguous.")
    data = list(islice(directories[0].iterdir(), 17))
    selected = [path for path in data if re.fullmatch(r"icudt[0-9]+l\.dat", path.name)]
    if len(data) > 16 or len(selected) != 1 or not selected[0].resolve(strict=True).is_relative_to(ROOT):
        raise ValueError("The native ICU data file is missing or ambiguous.")
    return selected[0]


def icu_data(deadline=None):
    return file_identity(_icu_file(), maximum=64 * LIMIT, deadline=deadline)


def _native_command(arguments, deadline, directory, *, limit=16384):
    log = directory / "command.log"
    result = bounded_process(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "LC_ALL=C", "TZ=UTC",
                              "OPENSSL_CONF=" + str(ROOT / "etc/ssl/openssl.cnf"),
                              "OPENSSL_MODULES=" + str(ROOT / "usr/lib/ossl-modules"),
                              "ICU_DATA=" + str(_icu_file().parent), *arguments],
                             log, timeout=_budget(deadline, 3), max_bytes=limit)
    _budget(deadline)
    if result["outcome"] != "pass":
        raise ValueError("The native backend preflight command failed.")
    return _read(log, limit)


def inspect_native(output: Path, deadline: float) -> dict:
    """Check bytes and run only bounded native metadata commands, never SQL."""
    deadline = min(deadline, time.monotonic() + 20)
    _budget(deadline)
    asset = asset_manifest()
    copyright_path = MANIFEST.parent / "native_postgres.COPYRIGHT"
    copyright = file_identity(copyright_path, maximum=16384, deadline=deadline)
    if copyright["sha256"] != asset["copyright_sha256"]:
        raise ValueError("The retained PostgreSQL copyright notice changed.")
    if _read(GUEST_MANIFEST, 32768) != _read(MANIFEST, 32768):
        raise ValueError("The host and guest native asset bindings differ.")
    verify_risc()
    for name in ("postgres", "initdb", "psql"):
        if _read(BINDIR / name, 4096) != wrapper(name).encode():
            raise ValueError("A native backend wrapper differs from its trusted source.")
    if _read(MUSL_PATH, 4096) != musl_path().encode():
        raise ValueError("The native loader search path differs from the private path.")
    loader = file_identity(LOADER, machine=62, deadline=deadline)
    original_loader = file_identity(ROOT / "lib/ld-musl-x86_64.so.1", machine=62, deadline=deadline)
    if (loader["sha256"], loader["bytes"]) != (original_loader["sha256"], original_loader["bytes"]):
        raise ValueError("The global native interpreter differs from its source payload.")
    selected, dependencies = {}, {}
    data_identity = icu_data(deadline)
    with tempfile.TemporaryDirectory(prefix="asm-native-metadata-") as temporary:
        directory = Path(temporary)
        for name in ("postgres", "initdb", "pg_config"):
            path = ROOT / "usr/local/bin" / name
            metadata = elf_metadata(path, 62)
            if metadata["interpreter"] != str(LOADER):
                raise ValueError("A native PostgreSQL tool uses another interpreter.")
            selected[name] = {**file_identity(path, machine=62, deadline=deadline), **metadata}
            listing = _native_command([str(LOADER), "--list", str(path)], deadline, directory)
            for dependency in parse_loader_list(listing.decode("ascii")):
                if str(dependency) not in dependencies:
                    dependencies[str(dependency)] = file_identity(dependency, machine=62, deadline=deadline)
            version = _native_command([str(path), "--version"], deadline, directory)
            expected = ("PostgreSQL 16.15" if name == "pg_config" else name + " (PostgreSQL) 16.15") + "\n"
            if version != expected.encode():
                raise ValueError("A native PostgreSQL tool has another version.")
        pg_config = str(ROOT / "usr/local/bin/pg_config")
        configure = _native_command([pg_config, "--configure"], deadline, directory)
        flags = configure.decode("ascii")
        if not all(flag in flags for flag in ("--with-llvm", "--with-icu", "--with-openssl")):
            raise ValueError("Native build flags differ from the selected official build.")
        for option, relative in (("--sharedir", "usr/local/share/postgresql"), ("--pkglibdir", "usr/local/lib/postgresql")):
            actual = _native_command([pg_config, option], deadline, directory).decode("ascii").strip()
            if actual != str(ROOT / relative):
                raise ValueError("A native package-data path escaped its relocated prefix.")
    # Only the fixture's PL/pgSQL module is required. Other native features
    # remain untested; their conformance is outside this diagnostic spike.
    required = ROOT / "usr/local/share/postgresql/postgres.bki"
    package_data = file_identity(required, maximum=4 * LIMIT, deadline=deadline)
    module_closure = dependency_closure([ROOT / "usr/local/lib/postgresql/plpgsql.so"], deadline)
    _budget(deadline)
    report = {"schema": 1, "scope": "native-postgres-preflight", "outcome": "pass", "qualification": "UNQUALIFIED",
              "asset_config": asset["config"], "bindir": str(BINDIR), "postgres": selected["postgres"], "initdb": selected["initdb"],
              "pg_config": selected["pg_config"], "loader": loader, "dependencies": dependencies,
              "configure": {"bytes": len(configure), "sha256": hashlib.sha256(configure).hexdigest(), "with_llvm": True, "with_icu": True, "with_openssl": True},
              "payload": {"postgres_bki": package_data},
              "selected_module_static_closure": module_closure, "copyright": copyright, "icu_data": data_identity,
              "module_scope": "Only required PL/pgSQL has static needed closure. Symbol loading remains a runtime gate.",
              "unused_modules": "not-tested",
              "timezone": verify_risc()["timezone"], "limits": ["Architecture and build both differ.", "JIT availability is not inferred from configure flags."]}
    encoded = json.dumps(report, sort_keys=True).encode()
    if len(encoded) > LIMIT:
        raise ValueError("Native metadata exceeds its report bound.")
    _budget(deadline)
    return report


def resource_snapshot():
    result = {"cpu": {}, "available": False}
    try:
        text = _read(CGROUP / "cpu.stat", 4096, virtual=True).decode("ascii")
        for line in text.splitlines():
            fields = line.split()
            if len(fields) == 2 and fields[0] in {"usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec"} and re.fullmatch(r"[0-9]{1,20}", fields[1]):
                result["cpu"][fields[0]] = int(fields[1])
        for file, key in (("memory.current", "memory_current"), ("memory.peak", "memory_peak")):
            value = _read(CGROUP / file, 128, virtual=True).decode("ascii").strip()
            if re.fullmatch(r"[0-9]{1,20}", value):
                result[key] = int(value)
        result["available"] = (len(result["cpu"]) == 6 and "memory_current" in result and "memory_peak" in result)
    except (OSError, ValueError, UnicodeError):
        pass
    result["captured_monotonic"] = time.monotonic()
    result["memory_peak_scope"] = "whole-cgroup-lifetime-not-reset"
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", action="store_true", required=True)
    parser.parse_args()
    try:
        print(json.dumps(capture_risc(require_absent=True), sort_keys=True))
    except BaseException:
        print('{"outcome":"fail","scope":"native-backend-risc-baseline"}')
        raise SystemExit(1)
