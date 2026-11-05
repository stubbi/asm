#!/usr/bin/env python3
"""Observe the retained, failed RISC-V server without rebuilding its libraries.

SPDX-License-Identifier: AGPL-3.0-or-later
This is test orchestration. It cannot qualify an application or a release.
"""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import uuid
import zipfile

import riscv64_combined as combined

ROOT = Path(__file__).resolve().parents[1]
BASE_REVISION = combined.PACKAGE_REVISION
CANDIDATE_REVISION = "66f432bb129c0c56922ec8edfa657e82b4fb9851"
TESTED_REVISION = "08baae84b06ddfac88406f43c5c8c44f6875a901"
IMAGE_ZIP_BYTES = 84388798
IMAGE_ZIP_SHA = "e3e47e75585b85ab148ae8b596d73b6eca9dbedc0f1f7e6a2f0493e845b55817"
IMAGE_TAR_BYTES = 136752640
IMAGE_TAR_SHA = "c71b64abbd1720cdf9ff320251ab5d723362f3144be5ec7eb243b4d1fe7848b5"
IMAGE_ID = "sha256:ea55425e6daa994ad57c46862258368c192c6f1f44b146c8a7bf3d1758571ae1"
SERVER_ZIP_BYTES = 27690874
SERVER_ZIP_SHA = "bc398de445a950e65f6cf1690dac89610129cf4c2ccc16b0ebb1997d4ff44136"
SERVER_BYTES = 33584
SERVER_SHA = "3e0bce8b6d9be340be5dfabbdd39fda064d7c9dd46287432561d315603ba93c9"
LIBRARIES = {
    "libmicrohttpd": ("/opt/asm/mhd/lib/libmicrohttpd.so.12", "3f759debbcfa026bd8c6578daefa258462675060cf02714f2eb931e7e1170fcd"),
    "libpq": ("/opt/asm/postgres/lib/libpq.so.5", "f7f8a045c71ec49ef3ac017b6224fd21e2a78a1595209ed3af2138a87e14fd4a"),
}
JSON_LIMIT = 1024 * 1024
ZIP_ENTRY_LIMIT = 128
ZIP_EXPANDED_LIMIT = 256 * 1024 * 1024
INSIDE_WORK = Path("/tmp/asm-observations")


def load_json(data):
    def fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("A diagnostic JSON record contains a duplicate field.")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=fields)


def load_object(data):
    value = load_json(data)
    if not isinstance(value, dict):
        raise ValueError("A diagnostic JSON record must be an object.")
    return value


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(131072), b""):
            value.update(data)
    return value.hexdigest()


def verify_file(path, size, expected):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size != size or digest(path) != expected:
        raise ValueError("Retained input bytes do not match their exact size and SHA-256.")


def portable_name(name):
    path = PurePosixPath(name)
    if (not name or len(name) > 256 or not name.isascii() or "\\" in name or "\0" in name
            or path.is_absolute() or any(part in ("", ".", "..") for part in name.rstrip("/").split("/"))):
        raise ValueError("The retained archive contains a noncanonical path.")
    return name.rstrip("/")


def extract_zip_member(archive, output, member_name, size, expected, archive_size, archive_sha):
    """Verify the whole ZIP before copying one bounded regular member atomically."""
    verify_file(archive, archive_size, archive_sha)
    with zipfile.ZipFile(archive) as packed:
        entries = packed.infolist()
        if len(entries) > ZIP_ENTRY_LIMIT or sum(item.file_size for item in entries) > ZIP_EXPANDED_LIMIT:
            raise ValueError("The retained ZIP exceeds its file or expanded-byte bound.")
        names = set()
        for entry in entries:
            name = portable_name(entry.filename)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if name in names or kind not in (0, stat.S_IFREG, stat.S_IFDIR) or entry.flag_bits & 1:
                raise ValueError("The retained ZIP contains a duplicate, link, special, or encrypted member.")
            names.add(name)
        choices = [item for item in entries if item.filename == member_name]
        if len(choices) != 1 or choices[0].is_dir() or choices[0].file_size != size:
            raise ValueError("The selected retained ZIP member has the wrong name or size.")
        output.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".asm-member-", dir=output.parent)
        try:
            value, count = hashlib.sha256(), 0
            with os.fdopen(descriptor, "wb") as destination, packed.open(choices[0]) as source:
                while data := source.read(131072):
                    count += len(data)
                    if count > size:
                        raise ValueError("The retained ZIP member exceeds its declared bound.")
                    value.update(data)
                    destination.write(data)
            if count != size or value.hexdigest() != expected:
                raise ValueError("The retained ZIP member differs from its recorded digest.")
            if output.exists() or output.is_symlink():
                raise ValueError("The retained member destination already exists.")
            os.replace(temporary, output)
        finally:
            Path(temporary).unlink(missing_ok=True)


def image_archive_contract(archive, expected_id=IMAGE_ID):
    """Read bounded image metadata without extracting or loading any layer."""
    metadata, names = {}, set()
    options = {"fileobj": archive, "mode": "r|"} if hasattr(archive, "read") else {"name": archive, "mode": "r:"}
    with tarfile.open(**options) as packed:
        for index, entry in enumerate(packed):
            name = portable_name(entry.name)
            if index >= ZIP_ENTRY_LIMIT or name in names or not (entry.isfile() or entry.isdir()):
                raise ValueError("The image archive has duplicate or special members.")
            names.add(name)
            if name in ("manifest.json", "blobs/sha256/" + expected_id.removeprefix("sha256:")):
                if not entry.isfile() or entry.size > JSON_LIMIT:
                    raise ValueError("The image metadata exceeds its byte limit.")
                metadata[name] = packed.extractfile(entry).read(JSON_LIMIT + 1)
    config_name = "blobs/sha256/" + expected_id.removeprefix("sha256:")
    if config_name not in metadata or "manifest.json" not in metadata:
        raise ValueError("The image archive lacks its exact recorded configuration.")
    if "sha256:" + hashlib.sha256(metadata[config_name]).hexdigest() != expected_id:
        raise ValueError("The image configuration does not match the recorded image ID.")
    manifests = load_json(metadata["manifest.json"])
    config = load_object(metadata[config_name])
    if (not isinstance(manifests, list) or len(manifests) != 1 or not isinstance(manifests[0], dict)
            or not isinstance(config, dict) or manifests[0].get("Config") != config_name
            or config.get("architecture") != "riscv64" or config.get("os") != "linux"):
        raise ValueError("Require the recorded single Linux RISC-V64 image.")
    permitted = {"PATH", "HOME", "PYTHONDONTWRITEBYTECODE", "PYTHONUNBUFFERED"}
    environment, rootfs = config.get("config"), config.get("rootfs")
    if (not isinstance(environment, dict) or not isinstance(rootfs, dict)
            or not isinstance(environment.get("Env", []), list)
            or any(not isinstance(item, str) or item.split("=", 1)[0] not in permitted
                   for item in environment.get("Env", []))):
        raise ValueError("The image supplies an unexpected environment variable or preload.")
    layers = rootfs.get("diff_ids", [])
    if not isinstance(layers, list) or any(not isinstance(item, str) for item in layers):
        raise ValueError("The image layer list is malformed.")
    if manifests[0].get("Layers") != ["blobs/sha256/" + item.removeprefix("sha256:") for item in layers]:
        raise ValueError("The image manifest and configuration disagree about their layers.")
    if any(name not in names for name in manifests[0]["Layers"]):
        raise ValueError("The image archive lacks a recorded layer.")
    return config


def initial_report():
    return {"schema": 1, "scope": "retained-riscv64-reference-server-observations",
            "qualification": "UNQUALIFIED", "outcome": "fail", "execution": "qemu-user", "target": "riscv64-linux",
            "application_qualified": False, "native_qualified": False, "release_qualified": False,
            "original_19_test_gate": "fail", "original_run": 42042426725,
            "candidate_revision": CANDIDATE_REVISION, "tested_revision": TESTED_REVISION,
            "base_package_revision": BASE_REVISION,
            "server": {"sha256": SERVER_SHA, "bytes": SERVER_BYTES},
            "started_at": datetime.now(timezone.utc).isoformat(),
            "not_run": [{"file": name, "tests": count, "outcome": "not-run",
                         "reason": "The reused diagnostic image has no compiler; this run covers ServerTests only."}
                        for name, count in combined.SUITE_FILES.items() if name != "test_server.py"],
            "limits": {"cpu": 2, "memory_bytes": 2 * 1024 ** 3, "pids": 256,
                       "network": "none", "uid": 65532, "host_seconds": 600, "suite_seconds": 180,
                       "attached_runtime_seconds_cap": 600, "cleanup_reserve_seconds": 90},
            "scope_limits": ["The original 19-test gate remains failed regardless of this diagnostic outcome.",
                             "The image has different unqualified runtime tools and system libraries.",
                             "The observer adds work and can affect measured timing."]}


def container_contract(container, source=None):
    config, host = container.get("Config", {}), container.get("HostConfig", {})
    permitted = {"PATH", "HOME", "PYTHONDONTWRITEBYTECODE", "PYTHONUNBUFFERED", "LC_ALL", "TZ", "QEMU_LD_PREFIX"}
    if (container.get("Image") != IMAGE_ID or config.get("User") != "65532:65532"
            or any(item.split("=", 1)[0] not in permitted for item in config.get("Env", []))
            or host.get("NetworkMode") != "none" or host.get("Memory") != 2147483648
            or host.get("NanoCpus") != 2000000000 or host.get("PidsLimit") != 256
            or host.get("CapDrop") != ["ALL"] or host.get("SecurityOpt") != ["no-new-privileges"]):
        raise ValueError("The created diagnostic container has the wrong identity, environment, or resource boundary.")
    mounts = container.get("Mounts", [])
    if (len(mounts) != 1 or mounts[0].get("Destination") != "/inputs" or mounts[0].get("RW") is not False
            or mounts[0].get("Type") != "bind" or (source is not None and mounts[0].get("Source") != source)):
        raise ValueError("The diagnostic inputs must be the single readonly bind mount.")


def assertion_contract(base, fixture):
    def methods(data):
        tree = ast.parse(data)
        return {node.name: [ast.dump(call, include_attributes=False) for call in ast.walk(node)
                            if isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                            and call.func.attr.startswith("assert")]
                for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")}
    original, changed = methods(base), methods(fixture)
    if len(original) != 14 or original != changed:
        raise ValueError("The diagnostic must retain all 14 original methods and their assertions.")
    return sorted(original)


def _materialize_context(destination, revision, fixture_revision, repository):
    import registry
    import release
    for commit in (revision, fixture_revision, BASE_REVISION):
        if not re.fullmatch(r"[0-9a-f]{40}", commit) or commit == "0" * 40:
            raise ValueError("Use exact nonzero Git commits for all diagnostic inputs.")
        if release.resolve_commit(repository, commit) != commit:
            raise ValueError("A diagnostic input does not resolve to its exact commit.")
    if release.resolve_commit(repository, "HEAD") != revision:
        raise ValueError("The diagnostic revision must match the workflow checkout.")
    source_path = "experiments/assembly-server"
    base = registry.git_files(repository, BASE_REVISION, source_path)
    fixture = registry.git_files(repository, fixture_revision, source_path)
    tracked = registry.git_output(repository, "ls-tree", "-r", "--name-only", "-z", fixture_revision,
                                  "--", source_path).split(b"\0")
    expected = {name.decode("ascii").removeprefix(source_path + "/") for name in tracked if name}
    if len(fixture) != 33 or set(fixture) != expected or set(base) != set(fixture):
        raise ValueError("The complete 33-file reference source must be retained.")
    if any(base[name] != fixture[name] for name in base if name != "test_server.py"):
        raise ValueError("Only test_server.py may differ from the failed package input.")
    if base["test_server.py"][1] != fixture["test_server.py"][1]:
        raise ValueError("The diagnostic changed the reference test file mode.")
    if base["test_server.py"][0] == fixture["test_server.py"][0]:
        raise ValueError("Select the reviewed observation fixture, not the unchanged failed test source.")
    methods = assertion_contract(base["test_server.py"][0], fixture["test_server.py"][0])
    for filename, count in combined.SUITE_FILES.items():
        if sum(isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
               for node in ast.walk(ast.parse(fixture[filename][0]))) != count:
            raise ValueError("The diagnostic source must retain all 19 original tests.")
    driver = registry.git_files(repository, revision, ".", ["tools/riscv64_combined.py", "tools/riscv64_server_observations.py"])
    if set(driver) != {"tools/riscv64_combined.py", "tools/riscv64_server_observations.py"}:
        raise ValueError("The workflow commit lacks the complete diagnostic driver.")
    destination.mkdir()
    release.materialize(fixture, destination / "source")
    release.materialize(driver, destination / "runner")
    combined.write_report(destination / "input-manifest.json", {
        "schema": 2, "qualification": "UNQUALIFIED", "revision": revision, "fixture_revision": fixture_revision,
        "base_revision": BASE_REVISION, "source_tree_sha256": combined.tree_digest(destination / "source"),
        "runner_tree_sha256": combined.tree_digest(destination / "runner"), "test_methods": methods,
        "source_files": len(fixture), "assertions_unchanged": True})
    (destination / "input-manifest.json").chmod(0o444)


def prepare_context(destination, revision, fixture_revision):
    worker = ("import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); "
              "from riscv64_server_observations import _materialize_context; "
              "_materialize_context(Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5]))")
    with tempfile.TemporaryDirectory(prefix="asm-observations-source-") as temporary:
        log = Path(temporary) / "source.log"
        result = combined.bounded_process([sys.executable, "-c", worker, str(Path(__file__).resolve().parent),
            str(destination.absolute()), revision, fixture_revision, str(ROOT)], log, timeout=120)
        if result["outcome"] != "pass":
            raise ValueError("Cannot materialize the exact diagnostic source: " + log.read_text(errors="replace")[-2048:])


def library_contract(path, expected):
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 16 * 1024 * 1024 or digest(path) != expected:
        raise ValueError("A runtime library differs from the failed PR42 library bytes.")
    combined.elf_machine(path.read_bytes())
    return {"path": str(path), "resolved_path": str(path.resolve()), "bytes": info.st_size, "sha256": expected,
            "comparison_to_failed_run": "exact-byte-match"}


def run_server_suite(source, log):
    result = combined.bounded_process([sys.executable, "-m", "unittest", "test_server.ServerTests", "-v"],
                                      log, cwd=source, timeout=180)
    text = log.read_text(errors="replace")
    counts = re.findall(r"^Ran (\d+) tests? in [0-9.]+s$", text, re.M)
    result.update(tests_run=int(counts[0]) if len(counts) == 1 else None,
                  tests_skipped=None if re.search(r"\bskipped\b", text) else 0,
                  log_sha256=digest(log))
    if result["outcome"] == "pass":
        try:
            combined.suite_contract(text, 14)
        except ValueError as error:
            result.update(outcome="fail", contract_error=str(error))
    return result


def retain_observation(build, output):
    # The single ServerTests class creates one private causal record. Never
    # collect PostgreSQL files, connection URLs, server logs, or arbitrary globs.
    paths = list(build.glob("reference-causal-*/diagnostic.json"))
    if len(paths) != 1:
        raise ValueError("Require exactly one bounded causal observation record.")
    source = paths[0]
    info = source.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > JSON_LIMIT or source.parent.is_symlink():
        raise ValueError("The causal observation is not a bounded regular file.")
    data = source.read_bytes()
    record = load_object(data)
    if (type(record.get("schema")) is not int or record["schema"] != 1 or record.get("qualification") != "UNQUALIFIED"
            or record.get("scope") != "reference-server-causal-diagnostic"
            or record.get("base_commit") != BASE_REVISION
            or not isinstance(record.get("runtime"), dict) or record["runtime"].get("sha256") != SERVER_SHA
            or record.get("runtime", {}).get("bytes") != SERVER_BYTES):
        raise ValueError("The causal observation is not bound to the failed server and fixture base.")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    return {"path": "observations/qualification.json", "sha256": digest(output), "bytes": len(data)}


def runtime_inventory(binary, prior, directory):
    """Retain dependencies actually named by ldd, with unknown baseline explicit."""
    inventory = {"baseline_tools": prior.get("tools", {}), "current": {}, "ldd": {}}
    paths = {Path(sys.executable).resolve(), Path("/opt/asm/postgres/bin/postgres"), Path("/opt/asm/postgres/bin/initdb")}
    for name, executable in (("server", binary), ("postgres", Path("/opt/asm/postgres/bin/postgres")),
                             ("python", Path(sys.executable).resolve())):
        log = directory / (".ldd-" + name)
        result = combined.bounded_process(["/usr/bin/ldd", executable], log, timeout=20, max_bytes=131072)
        if result["outcome"] != "pass":
            raise ValueError("Cannot identify the reused image's runtime dependencies.")
        text = log.read_text(errors="strict")
        inventory["ldd"][name] = text
        paths.update(Path(item) for item in re.findall(r"(?<!\S)(/[^\s()]+)", text))
        log.unlink()
    if len(paths) > 64:
        raise ValueError("The runtime dependency inventory exceeds its file bound.")
    prior_libraries = {value["sha256"] for value in prior.get("libraries", {}).values()}
    for path in sorted(paths):
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 64 * 1024 * 1024:
            raise ValueError("A runtime dependency exceeds its byte bound.")
        sha = digest(path)
        inventory["current"][str(path)] = {"resolved_path": str(path.resolve()), "sha256": sha, "bytes": info.st_size,
            "comparison_to_failed_run": "exact-byte-match" if sha in prior_libraries else "not-recorded-in-failed-run"}
    inventory["differences"] = ["The failed build image retained compiler tool hashes, not all system runtime hashes.",
                                "This reused image has no compiler; runtime and system-tool equality is unestablished.",
                                "Only the retained server, libmicrohttpd and libpq have exact failed-run byte bindings."]
    return inventory


def inside(output):
    report = initial_report()
    build = INSIDE_WORK / "build"
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        report["host"] = platform.uname()._asdict()
        if platform.system() != "Linux" or platform.machine() != "riscv64" or os.geteuid() != 65532:
            raise ValueError("Use the RISC-V Linux guest as UID 65532.")
        if os.environ.get("LD_PRELOAD") or any(key.startswith(("PG", "GITHUB_", "GH_TOKEN")) for key in os.environ):
            raise ValueError("The diagnostic environment contains a preload or ambient credentials/configuration.")
        context = Path("/inputs")
        inputs = load_object((context / "input-manifest.json").read_text())
        if (type(inputs.get("schema")) is not int or inputs["schema"] != 2
                or inputs.get("base_revision") != BASE_REVISION or inputs.get("source_files") != 33
                or inputs.get("assertions_unchanged") is not True or len(inputs.get("test_methods", [])) != 14):
            raise ValueError("The diagnostic source receipt is incomplete.")
        for name in ("source", "runner"):
            if combined.tree_digest(context / name) != inputs[name + "_tree_sha256"]:
                raise ValueError("The readonly diagnostic source differs from its exact Git receipt.")
        report["inputs"] = inputs
        binary = context / "asm-server-riscv64-linux"
        verify_file(binary, SERVER_BYTES, SERVER_SHA)
        combined.elf_machine(binary.read_bytes())
        report["libraries"] = {name: library_contract(Path(path), sha) for name, (path, sha) in LIBRARIES.items()}
        prior = load_object((context / "failed-qualification.json").read_text())
        for name, value in report["libraries"].items():
            if prior.get("libraries", {}).get(name, {}).get("sha256") != value["sha256"]:
                raise ValueError("The failed-run receipt disagrees with a required library digest.")
        environment = {"ASM_PROTO_BINARY": str(binary), "ASM_PROTO_BUILD_DIR": str(build),
                       "ASM_PROTO_LIBPQ": LIBRARIES["libpq"][0], "ASM_PROTO_PG_BINDIR": "/opt/asm/postgres/bin",
                       "LD_LIBRARY_PATH": "/opt/asm/mhd/lib:/opt/asm/postgres/lib", "LC_ALL": "C", "TZ": "UTC"}
        os.environ.update(environment)
        report["runtime_environment"] = {key: os.environ.get(key) for key in
            ("PATH", "HOME", "PYTHONDONTWRITEBYTECODE", "PYTHONUNBUFFERED", "QEMU_LD_PREFIX", "LD_LIBRARY_PATH", "LC_ALL", "TZ")}
        report["runtime_inventory"] = runtime_inventory(binary, prior, output.parent)
        build.mkdir(mode=0o700)
        report["server_tests"] = run_server_suite(context / "source", output.parent / "server_package.log")
        report["observation"] = retain_observation(build, output.parent / "observations/qualification.json")
        for name in ("source", "runner"):
            if combined.tree_digest(context / name) != inputs[name + "_tree_sha256"]:
                raise ValueError("The diagnostic source changed during the test run.")
        verify_file(binary, SERVER_BYTES, SERVER_SHA)
        if report["server_tests"]["outcome"] == "pass":
            report["outcome"] = "pass"
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        combined.write_report(output, report)
    return 0 if report["outcome"] == "pass" else 1


def run_image(image_zip, server_zip, context, output):
    started = time.monotonic()
    host_deadline = started + 600
    operation_deadline = host_deadline - 90
    def remaining(cap, deadline, phase):
        seconds = min(cap, deadline - time.monotonic())
        if seconds <= 0:
            raise ValueError("The shared host " + phase + " deadline elapsed.")
        return seconds
    output.mkdir(parents=True, exist_ok=True)
    report = initial_report()
    name = "asm-reference-observations-" + uuid.uuid4().hex
    created = False
    try:
        # Temporary archive bytes are retained only until Docker has loaded the
        # verified image. The host never expands unneeded runtime archives.
        with tempfile.TemporaryDirectory(prefix="asm-observations-image-") as temporary:
            archive = Path(temporary) / "image.tar"
            extract_zip_member(image_zip, archive, "UNQUALIFIED-rebuilt-diagnostic.tar", IMAGE_TAR_BYTES,
                               IMAGE_TAR_SHA, IMAGE_ZIP_BYTES, IMAGE_ZIP_SHA)
            image_config = image_archive_contract(archive)
            report["image"] = {"id": IMAGE_ID, "archive_sha256": IMAGE_TAR_SHA,
                               "config": image_config, "source_run": 42035969713, "source_artifact": 13423240467}
            combined.command(["docker", "load", "--input", archive],
                             timeout=remaining(120, operation_deadline, "operation"))
        extract_zip_member(server_zip, context / "asm-server-riscv64-linux", "asm-server-riscv64-linux",
                           SERVER_BYTES, SERVER_SHA, SERVER_ZIP_BYTES, SERVER_ZIP_SHA)
        # This small report is selected from the already verified failed-run ZIP.
        with zipfile.ZipFile(server_zip) as packed:
            entry = packed.getinfo("qualification.json")
            if entry.file_size > JSON_LIMIT:
                raise ValueError("The failed-run qualification receipt exceeds its byte limit.")
            prior = packed.read(entry)
        prior_report = load_object(prior)
        if prior_report.get("retained_artifacts", {}).get("asm-server-riscv64-linux", {}).get("sha256") != SERVER_SHA:
            raise ValueError("The failed-run report is not bound to the retained server.")
        (context / "failed-qualification.json").write_bytes(prior)
        (context / "failed-qualification.json").chmod(0o444)
        (context / "asm-server-riscv64-linux").chmod(0o555)
        for path in (context, *[item for item in context.rglob("*") if item.is_dir()]):
            path.chmod(0o755)
        info = load_json(combined.command(["docker", "image", "inspect", IMAGE_ID],
            timeout=remaining(30, operation_deadline, "operation")).stdout)[0]
        if (info["Id"] != IMAGE_ID or info["Architecture"] != "riscv64" or info["Os"] != "linux"
                or info["RootFS"]["Layers"] != image_config["rootfs"]["diff_ids"]
                or info["Config"].get("Env", []) != image_config["config"].get("Env", [])):
            raise ValueError("The loaded image differs from its checked archive configuration.")
        mounted = str(context.resolve())
        if "," in mounted:
            raise ValueError("The diagnostic context path cannot contain a mount separator.")
        create = ["docker", "create", "--pull=never", "--name", name, "--platform", "linux/riscv64",
                  "--network", "none", "--user", "65532:65532", "--cap-drop", "ALL",
                  "--security-opt", "no-new-privileges", "--pids-limit", "256", "--memory", "2g", "--cpus", "2",
                  "--mount", "type=bind,src=" + mounted + ",dst=/inputs,readonly",
                  "--workdir", "/work", "--env", "LC_ALL=C", "--env", "TZ=UTC", "--env", "QEMU_LD_PREFIX=/",
                  "--entrypoint", "/usr/bin/python3", IMAGE_ID,
                  "/inputs/runner/tools/riscv64_server_observations.py", "--inside", "--output",
                  str(INSIDE_WORK / "evidence/qualification.json")]
        create_timeout = remaining(30, operation_deadline, "operation")
        created = True
        combined.command(create, timeout=create_timeout)
        container = load_json(combined.command(["docker", "inspect", name],
            timeout=remaining(30, operation_deadline, "operation")).stdout)[0]
        container_contract(container, mounted)
        report["container"] = {"image": container["Image"], "config": container["Config"], "host_config": container["HostConfig"]}
        report["runtime"] = combined.bounded_process(["docker", "start", "--attach", name], output / "runtime.log",
            timeout=remaining(600, operation_deadline, "operation"), max_bytes=combined.RUNTIME_LOG_BYTE_LIMIT)
        if report["runtime"]["outcome"] != "pass":
            report["error"] = "The retained-server diagnostic failed; inspect the scoped test and observation records."
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError,
            subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile) as error:
        report["error"] = str(error)
    finally:
        if created:
            errors, collected, budget = {}, set(), {"bytes": 0, "files": 0}
            try:
                combined.command(["docker", "stop", "--time", "5", name],
                                 timeout=remaining(15, host_deadline, "cleanup"))
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                errors["stop"] = str(error)
            # All three transports share 60 seconds and leave the final 15
            # seconds for removal. Setup, attached execution, and cleanup share
            # one 600-second budget; the guest suite still has its own 180 cap.
            collection_deadline = min(time.monotonic() + 60, host_deadline - 15)
            for relative in ("qualification.json", "server_package.log", "observations/qualification.json"):
                try:
                    destination = output / Path(relative).parent
                    destination.mkdir(parents=True, exist_ok=True)
                    combined.collect_file(["docker", "cp", name + ":" + str(INSIDE_WORK / "evidence" / relative), "-"],
                        Path(relative).name, destination, budget,
                        timeout=remaining(20, collection_deadline, "collection"))
                    collected.add(relative)
                except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
                    errors[relative] = str(error)
            report["collection"] = {**budget, "errors": errors, "collected": sorted(collected)}
            if not errors and len(collected) == 3:
                try:
                    guest = load_object((output / "qualification.json").read_text())
                    if (guest.get("qualification") != "UNQUALIFIED" or guest.get("outcome") != "pass"
                            or any(guest.get(key) is not False for key in
                                   ("application_qualified", "native_qualified", "release_qualified"))
                            or guest.get("original_19_test_gate") != "fail"
                            or guest.get("server_tests", {}).get("tests_run") != 14
                            or guest.get("server_tests", {}).get("tests_skipped") != 0
                            or digest(output / "observations/qualification.json") != guest.get("observation", {}).get("sha256")
                            or digest(output / "server_package.log") != guest.get("server_tests", {}).get("log_sha256")):
                        raise ValueError("The guest diagnostic is failed, incomplete, or incorrectly scoped.")
                    if "error" not in report and report.get("runtime", {}).get("outcome") == "pass":
                        report["outcome"] = "pass"
                except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
                    report["collection_error"] = str(error)
            else:
                report["collection_error"] = "Current bounded collection did not supply all three diagnostic records."
            try:
                combined.command(["docker", "rm", "--force", name],
                                 timeout=remaining(15, host_deadline, "cleanup"))
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                report["cleanup_error"] = str(error)
                report["outcome"] = "fail"
        report["host_elapsed_seconds"] = round(time.monotonic() - started, 3)
        report["operation_seconds_limit"] = 510
        if time.monotonic() > host_deadline:
            report["host_deadline_exceeded"] = True
            report["outcome"] = "fail"
            report["error"] = "The shared 600-second host deadline was exceeded."
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        combined.write_report(output / "UNQUALIFIED-host-report.json", report)
    return 0 if report["outcome"] == "pass" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--prepare-context", type=Path)
    mode.add_argument("--run-image", action="store_true")
    mode.add_argument("--inside", action="store_true")
    parser.add_argument("--revision")
    parser.add_argument("--fixture-revision")
    parser.add_argument("--image-zip", type=Path)
    parser.add_argument("--server-zip", type=Path)
    parser.add_argument("--context", type=Path)
    parser.add_argument("--output", type=Path, default=INSIDE_WORK / "evidence/qualification.json")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.discover(str(ROOT / "tests/riscv64"), pattern="test_server_observations.py")
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.prepare_context:
        if not args.revision or not args.fixture_revision:
            parser.error("Supply --revision and --fixture-revision with --prepare-context.")
        prepare_context(args.prepare_context, args.revision, args.fixture_revision)
        return 0
    if args.inside:
        return inside(args.output)
    if not all((args.image_zip, args.server_zip, args.context)):
        parser.error("Supply --image-zip, --server-zip, and --context with --run-image.")
    return run_image(args.image_zip, args.server_zip, args.context, args.output)


if __name__ == "__main__":
    raise SystemExit(main())
