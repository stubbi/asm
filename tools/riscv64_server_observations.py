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
import math
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


def retain_host_file(source, destination, *, limit=JSON_LIMIT):
    """Retain one bounded regular host artifact without replacing a destination."""
    try:
        descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        raise ValueError("Cannot open a regular host artifact.") from None
    temporary = None
    try:
        with os.fdopen(descriptor, "rb") as original:
            info = os.fstat(original.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
                raise ValueError("A host artifact exceeds its regular-file or byte bound.")
            descriptor, temporary = tempfile.mkstemp(prefix=".asm-host-evidence-", dir=destination.parent)
            count, value = 0, hashlib.sha256()
            with os.fdopen(descriptor, "wb") as copied:
                while data := original.read(65536):
                    count += len(data)
                    if count > limit:
                        raise ValueError("A host artifact exceeds its byte bound.")
                    copied.write(data)
                    value.update(data)
            if count != info.st_size:
                raise ValueError("A host artifact changed during retention.")
        try:
            os.link(temporary, destination)
        except FileExistsError:
            raise ValueError("The retained host artifact destination already exists.") from None
        return {"bytes": count, "sha256": value.hexdigest()}
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


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


def initial_report(*, phase_probe=False, query_candidate=False):
    report = {"schema": 1, "scope": "retained-riscv64-reference-server-observations",
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
    if phase_probe:
        report.update(scope="retained-riscv64-reference-server-phase-probe",
                      comparison_order=["direct", "proxy"],
                      query_cost_probe={"scope": "UNQUALIFIED-database-query-cost", "after_original_cohorts": True})
    if query_candidate:
        report.update(scope="retained-riscv64-query-candidate", comparison_order=["A1", "B1", "B2", "A2"])
        report.pop("query_cost_probe", None)
        report["not_run"].append({"file": "test_server.py", "tests": 14, "outcome": "not-run",
                                 "reason": "This scoped SQL comparison does not run HTTP acceptance methods."})
        for section in report["not_run"]:
            section["reason"] = "This scoped SQL comparison does not run the original acceptance methods."
    return report


def sanitized_phase_summary(guest, observation, *, query_candidate=False):
    """Return bounded numeric readback without bodies, configuration, or errors."""
    from riscv64_reference_trace import RANGES, ENUMS

    def integer(value, low, high):
        return value if type(value) is int and low <= value <= high else None

    def mapping(value):
        return value if isinstance(value, dict) else {}

    tests = mapping(guest.get("server_tests"))
    if query_candidate or guest.get("scope") == "retained-riscv64-query-candidate":
        benchmark = mapping(observation.get("query_candidate"))
        waves = benchmark.get("waves", [])
        counts = []
        if isinstance(waves, list) and len(waves) <= 4:
            for label, wave in zip(("A1", "B1", "B2", "A2"), waves):
                if isinstance(wave, dict) and wave.get("label") == label:
                    counts.append({"label": label, "successful": integer(wave.get("successful"), 0, 16)})
        return {"schema": 1, "scope": "reference-query-candidate-summary", "qualification": "UNQUALIFIED",
                "original_19_test_gate": "fail", "original_methods_not_run": 19, "tests_run": 0,
                "exit_code": integer(tests.get("exit_code"), -255, 255), "cohorts": [], "waves": counts,
                "measurement": benchmark.get("outcome") if benchmark.get("outcome") in ("pass", "fail") else "inconclusive"}
    summary = {"schema": 1, "scope": "reference-phase-probe-summary", "qualification": "UNQUALIFIED",
               "original_19_test_gate": "fail", "tests_run": integer(tests.get("tests_run"), 0, 14),
               "exit_code": integer(tests.get("exit_code"), -255, 255), "cohorts": []}
    comparison = mapping(observation.get("controlled_search_comparison"))
    arms = comparison.get("arms", [])
    arms = arms if isinstance(arms, list) and len(arms) <= 2 else []
    waves = [("original-proxy", "main", mapping(observation.get("simultaneous_searches")).get("records", []))]
    for label in ("direct", "proxy"):
        arm = next((item for item in arms if isinstance(item, dict) and item.get("label") == label), {})
        waves.append((label, label, arm.get("records", [])))
    phases = mapping(observation.get("phase_traces"))
    numeric = ("id", "index", "kind", "first_api", "first_return", "first_errno", "connect_poll",
               "sends", "poll_return", "poll_errno", "poll_revents", "poll_timeout", "poll_timeouts", "status")
    for label, key, records in waves:
        section = mapping(phases.get(key))
        cohort = {"label": label, "association": "complete" if section.get("association") == "complete"
                  else "inconclusive", "http": [], "traces": []}
        for row in records[:16] if isinstance(records, list) else []:
            if not isinstance(row, dict) or integer(row.get("index"), 1, 16) is None:
                continue
            elapsed = row.get("elapsed_seconds")
            elapsed = (round(elapsed * 1000000) if type(elapsed) in (int, float) and math.isfinite(elapsed)
                       and 0 <= elapsed <= 180 else None)
            cohort["http"].append({"index": row["index"], "status": integer(row.get("status"), 100, 599),
                                   "elapsed_us": elapsed})
        associations = mapping(section.get("cohort_record_ids"))
        selected = set(associations.values()) if all(
            integer(value, 1, 256) is not None for value in associations.values()) else set()
        values = section.get("records", [])
        for row in values if isinstance(values, list) and len(values) <= 256 else []:
            if (not isinstance(row, dict) or integer(row.get("index"), 1, 16) is None
                    or (selected and row.get("id") not in selected)):
                continue
            trace = {}
            for name in numeric:
                value = row.get(name)
                if name in RANGES and integer(value, *RANGES[name]) is not None:
                    trace[name] = value
                elif name in ENUMS and type(value) is int and value in ENUMS[name]:
                    trace[name] = value
            state = row.get("sqlstate", "")
            trace["sqlstate"] = state if type(state) is str and re.fullmatch(r"[A-Z0-9]{5}|", state) else ""
            cohort["traces"].append(trace)
            if len(cohort["traces"]) == 16:
                break
        summary["cohorts"].append(cohort)
    if len(json.dumps(summary, separators=(",", ":"))) > 16384:
        for cohort in summary["cohorts"]:
            cohort["traces"] = []
        summary["details_omitted"] = True
    return summary


def publish_phase_summary(report, output):
    """Make small failure readback available even if full collection is incomplete."""
    collected = report.get("collection", {}).get("collected", [])
    documents = []
    for filename in ("qualification.json", "observations/qualification.json"):
        value = {}
        if filename in collected:
            try:
                path = output / filename
                if path.is_file() and path.stat().st_size <= JSON_LIMIT:
                    value = load_object(path.read_bytes())
            except (OSError, ValueError, TypeError, RecursionError):
                pass
        documents.append(value)
    summary = sanitized_phase_summary(*documents,
        query_candidate=report.get("scope") == "retained-riscv64-query-candidate")
    permitted = {"archive-inputs", "trace-build", "image-load", "server-artifact", "image-inspection",
                 "registration", "container-create", "container-inspection", "runtime", "collection", "cleanup",
                 "host-evidence"}
    stage = report.get("failure_stage")
    summary["host"] = {"failure_stage": stage if stage in permitted else "unknown",
                       "collection_complete": set(collected) == {
                           "qualification.json", "observations/qualification.json", "server_package.log"}
                       and not report.get("collection", {}).get("errors"),
                       "trace_built": report.get("trace_build", {}).get("outcome") == "pass",
                       "container_recorded": "container" in report,
                       "cleanup_reported_error": "cleanup_error" in report}
    print("ASM_REFERENCE_SUMMARY=" + json.dumps(summary, separators=(",", ":")), flush=True)
    combined.write_report(output / "phase-summary.json", summary)


def finish_host_report(report, output, *, started, deadline, phase_probe):
    """Keep late evidence I/O from publishing a passing bounded result."""
    def check_time():
        report["host_elapsed_seconds"] = round(time.monotonic() - started, 3)
        if time.monotonic() > deadline:
            report.update(host_deadline_exceeded=True, outcome="fail",
                          error="The shared 600-second host deadline was exceeded.")

    report["operation_seconds_limit"] = 510
    check_time()
    if phase_probe:
        try:
            publish_phase_summary(report, output)
        except (OSError, ValueError, TypeError, AttributeError, RecursionError):
            report["summary_error"] = "The bounded diagnostic summary could not be retained."
    check_time()
    if any(key in report for key in ("error", "collection_error", "cleanup_error", "host_evidence_error", "summary_error")):
        report["outcome"] = "fail"
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    destination = output / "UNQUALIFIED-host-report.json"
    combined.write_report(destination, report)
    if time.monotonic() > deadline and report["outcome"] == "pass":
        check_time()
        try:
            destination.unlink()
            combined.write_report(destination, report)
        except OSError:
            # If removal also fails, stale bytes can remain. The CI failure is
            # authoritative; this bounded marker is only best-effort evidence.
            try:
                with (output / "host-finalization-failure.json").open("x") as marker:
                    marker.write(json.dumps({"schema": 1, "scope": "reference-host-finalization",
                        "outcome": "fail", "qualification": "UNQUALIFIED",
                        "reason": "host-deadline-exceeded", "host_report_valid": False}) + "\n")
            except OSError:
                pass
            raise


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


def _materialize_context(destination, revision, fixture_revision, repository, phase_probe=False, query_candidate=False):
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
    driver_names = {"tools/riscv64_combined.py", "tools/riscv64_server_observations.py"}
    if phase_probe:
        driver_names.update({"tools/diagnostics/reference_libpq_trace.c", "tools/riscv64_reference_trace.py",
                             "tools/riscv64_reference_build.py", "tools/riscv64_reference_suite.py",
                             "tools/riscv64_reference_performance.py",
                             "tests/riscv64/test_reference_trace.py"})
    if query_candidate:
        driver_names.update({"tools/diagnostics/reference_search_candidate.sql",
                             "tools/diagnostics/reference_search_cases.py"})
    driver = registry.git_files(repository, revision, ".", sorted(driver_names))
    if set(driver) != driver_names:
        raise ValueError("The workflow commit lacks the complete diagnostic driver.")
    destination.mkdir()
    release.materialize(fixture, destination / "source")
    release.materialize(driver, destination / "runner")
    receipt = {
        "schema": 2, "qualification": "UNQUALIFIED", "revision": revision, "fixture_revision": fixture_revision,
        "base_revision": BASE_REVISION, "source_tree_sha256": combined.tree_digest(destination / "source"),
        "runner_tree_sha256": combined.tree_digest(destination / "runner"), "test_methods": methods,
        "source_files": len(fixture), "assertions_unchanged": True}
    if phase_probe:
        receipt["phase_probe"] = True
    if query_candidate:
        receipt["query_candidate"] = True
    combined.write_report(destination / "input-manifest.json", receipt)
    (destination / "input-manifest.json").chmod(0o444)


def prepare_context(destination, revision, fixture_revision, *, phase_probe=False, query_candidate=False):
    worker = ("import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); "
              "from riscv64_server_observations import _materialize_context; "
              "_materialize_context(Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5]), sys.argv[6] == '1', sys.argv[7] == '1')")
    with tempfile.TemporaryDirectory(prefix="asm-observations-source-") as temporary:
        log = Path(temporary) / "source.log"
        result = combined.bounded_process([sys.executable, "-c", worker, str(Path(__file__).resolve().parent),
            str(destination.absolute()), revision, fixture_revision, str(ROOT), "1" if phase_probe else "0",
            "1" if query_candidate else "0"], log, timeout=120)
        if result["outcome"] != "pass":
            raise ValueError("Cannot materialize the exact diagnostic source: " + log.read_text(errors="replace")[-2048:])


def library_contract(path, expected):
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 16 * 1024 * 1024 or digest(path) != expected:
        raise ValueError("A runtime library differs from the failed PR42 library bytes.")
    combined.elf_machine(path.read_bytes())
    return {"path": str(path), "resolved_path": str(path.resolve()), "bytes": info.st_size, "sha256": expected,
            "comparison_to_failed_run": "exact-byte-match"}


def run_server_suite(source, log, *, phase_probe=False, query_candidate=False):
    arguments = [sys.executable, "-m", "unittest", "test_server.ServerTests", "-v"]
    if phase_probe:
        arguments = [sys.executable, Path(__file__).with_name("riscv64_reference_suite.py"),
                     "--source", source, "--registration", source.parent / "binfmt-registration.json",
                     "--trace-directory", source.parent / "trace", "--deadline", str(time.monotonic() + 180),
                     "--query-candidate" if query_candidate else "--query-cost-probe"]
    result = combined.bounded_process(arguments, log, cwd=source, timeout=180)
    text = log.read_text(errors="replace")
    counts = re.findall(r"^Ran (\d+) tests? in [0-9.]+s$", text, re.M)
    result.update(tests_run=int(counts[0]) if len(counts) == 1 else None,
                  tests_skipped=None if re.search(r"\bskipped\b", text) else 0,
                  log_sha256=digest(log))
    if query_candidate:
        summaries = [line.removeprefix("ASM_REFERENCE_SQL=") for line in text.splitlines()
                     if line.startswith("ASM_REFERENCE_SQL=")]
        try:
            if len(summaries) != 1:
                raise ValueError("The SQL comparison summary is missing or ambiguous.")
            summary = load_object(summaries[0])
            if (set(summary) != {"schema", "scope", "outcome", "tests_run", "http_methods_not_run", "errors"}
                    or type(summary["schema"]) is not int or summary["schema"] != 1
                    or summary.get("scope") != "UNQUALIFIED-query-candidate" or summary.get("outcome") != "pass"
                    or type(summary.get("tests_run")) is not int or summary["tests_run"] != 0
                    or type(summary.get("http_methods_not_run")) is not int or summary["http_methods_not_run"] != 14
                    or summary.get("errors") != []):
                raise ValueError("The SQL comparison failed or has an incorrect scope.")
            result.update(tests_run=0, http_methods_not_run=14)
        except (ValueError, TypeError, KeyError):
            result.update(outcome="fail", contract_error="The scoped SQL comparison is incomplete or failed.")
    elif result["outcome"] == "pass":
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


def trace_smoke(trace_directory, output):
    """Check the built RISC-V interposer with its exact forwarding fixture."""
    from riscv64_reference_build import elf_contract
    from riscv64_reference_suite import error_type, read_object, trace_library
    from riscv64_reference_trace import ERROR_PREFIX, read_records

    report = {"scope": "diagnostic-interposer-forwarding", "qualification": "UNQUALIFIED", "outcome": "fail"}
    temporary = tempfile.TemporaryDirectory(prefix=".asm-trace-check-", dir=output)
    log = Path(temporary.name) / "output.log"
    try:
        library, _ = trace_library(trace_directory)
        manifest = read_object(trace_directory / "manifest.json")
        for filename in ("reference_libpq_trace.so", "libreference_provider.so", "reference_trace_check"):
            actual = elf_contract(trace_directory / filename, shared=filename != "reference_trace_check")
            entry = manifest["outputs"][filename]
            if (type(entry) is not dict or set(entry) != set(actual)
                    or any(type(entry[key]) is not type(value) or entry[key] != value for key, value in actual.items())):
                raise ValueError("The forwarding fixture differs from its build receipt.")
        arguments = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "HOME=/nonexistent", "LC_ALL=C", "TZ=UTC",
                     "QEMU_LD_PREFIX=/", "LD_LIBRARY_PATH=" + str(trace_directory),
                     "LD_PRELOAD=" + str(library), trace_directory / "reference_trace_check"]
        report["process"] = combined.bounded_process(arguments, log, timeout=30, max_bytes=65536)
        if report["process"]["outcome"] != "pass":
            raise ValueError("The diagnostic forwarding fixture failed.")
        records = read_records(log)
        if len(records) != 1 or records[0]["index"] != 5 or records[0]["kind"] != 2:
            raise ValueError("The diagnostic forwarding record is incomplete.")
        report.update(outcome="pass", records=records)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError) as error:
        report["failure_type"] = error_type(error)
    finally:
        if log.is_file() and log.stat().st_size <= 65536:
            data = log.read_bytes()
            report.update(output_bytes=len(data), output_sha256=hashlib.sha256(data).hexdigest(),
                          producer_error_marker=ERROR_PREFIX in data)
        # Retain only validated records and the output identity. The control
        # log is not an allowlisted application artifact or raw error channel.
        temporary.cleanup()
    return report


def inside(output, *, phase_probe=False, query_candidate=False):
    report = initial_report(phase_probe=phase_probe, query_candidate=query_candidate)
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
                or inputs.get("assertions_unchanged") is not True or len(inputs.get("test_methods", [])) != 14
                or inputs.get("phase_probe", False) is not phase_probe
                or inputs.get("query_candidate", False) is not query_candidate):
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
        if phase_probe:
            report["trace_check"] = trace_smoke(context / "trace", output.parent)
            if report["trace_check"]["outcome"] != "pass":
                raise ValueError("The diagnostic forwarding check failed before the server suite.")
        build.mkdir(mode=0o700)
        report["server_tests"] = run_server_suite(context / "source", output.parent / "server_package.log",
                                                 phase_probe=phase_probe, query_candidate=query_candidate)
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


def run_image(image_zip, server_zip, context, output, *, phase_probe=False, mhd_source=None, query_candidate=False):
    started = time.monotonic()
    host_deadline = started + 600
    operation_deadline = host_deadline - 90
    def remaining(cap, deadline, phase):
        seconds = min(cap, deadline - time.monotonic())
        if seconds <= 0:
            raise ValueError("The shared host " + phase + " deadline elapsed.")
        return seconds
    output.mkdir(parents=True, exist_ok=True)
    report = initial_report(phase_probe=phase_probe, query_candidate=query_candidate)
    name = "asm-reference-observations-" + uuid.uuid4().hex
    created = False
    stage = "archive-inputs"
    try:
        if phase_probe and mhd_source is None:
            raise ValueError("The phase probe requires the pinned MHD header source archive.")
        # Temporary archive bytes are retained only until Docker has loaded the
        # verified image. The host never expands unneeded runtime archives.
        with tempfile.TemporaryDirectory(prefix="asm-observations-image-") as temporary:
            archive = Path(temporary) / "image.tar"
            extract_zip_member(image_zip, archive, "UNQUALIFIED-rebuilt-diagnostic.tar", IMAGE_TAR_BYTES,
                               IMAGE_TAR_SHA, IMAGE_ZIP_BYTES, IMAGE_ZIP_SHA)
            image_config = image_archive_contract(archive)
            report["image"] = {"id": IMAGE_ID, "archive_sha256": IMAGE_TAR_SHA,
                               "config": image_config, "source_run": 42035969713, "source_artifact": 13423240467}
            if phase_probe:
                stage = "trace-build"
                from riscv64_reference_build import prepare_trace
                report["trace_build"] = prepare_trace(archive, context,
                    timeout=remaining(120, operation_deadline, "operation"), mhd_source=mhd_source)
                combined.write_report(output / "trace-build-manifest.json", report["trace_build"])
                for filename in ("reference_libpq_trace.so", "libreference_provider.so", "reference_trace_check"):
                    artifact = context / "trace" / filename
                    if artifact.stat().st_size > JSON_LIMIT:
                        raise ValueError("A diagnostic helper exceeds its retained byte limit.")
                    retained = retain_host_file(artifact, output / filename)
                    expected = report["trace_build"].get("outputs", {}).get(filename, {})
                    if retained != {key: expected.get(key) for key in ("bytes", "sha256")}:
                        raise ValueError("A retained helper differs from its build receipt.")
            stage = "image-load"
            combined.command(["docker", "load", "--input", archive],
                             timeout=remaining(120, operation_deadline, "operation"))
        stage = "server-artifact"
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
        stage = "image-inspection"
        info = load_json(combined.command(["docker", "image", "inspect", IMAGE_ID],
            timeout=remaining(30, operation_deadline, "operation")).stdout)[0]
        if (info["Id"] != IMAGE_ID or info["Architecture"] != "riscv64" or info["Os"] != "linux"
                or info["RootFS"]["Layers"] != image_config["rootfs"]["diff_ids"]
                or info["Config"].get("Env", []) != image_config["config"].get("Env", [])):
            raise ValueError("The loaded image differs from its checked archive configuration.")
        mounted = str(context.resolve())
        if "," in mounted:
            raise ValueError("The diagnostic context path cannot contain a mount separator.")
        if phase_probe:
            stage = "registration"
            from riscv64_reference_suite import capture_registration
            report["binfmt_registration"] = capture_registration(context, run_id=os.environ.get("GITHUB_RUN_ID", ""))
            combined.write_report(output / "binfmt-registration.json", report["binfmt_registration"])
        create = ["docker", "create", "--pull=never", "--name", name, "--platform", "linux/riscv64",
                  "--network", "none", "--user", "65532:65532", "--cap-drop", "ALL",
                  "--security-opt", "no-new-privileges", "--pids-limit", "256", "--memory", "2g", "--cpus", "2",
                  "--mount", "type=bind,src=" + mounted + ",dst=/inputs,readonly",
                  "--workdir", "/work", "--env", "LC_ALL=C", "--env", "TZ=UTC", "--env", "QEMU_LD_PREFIX=/",
                  "--entrypoint", "/usr/bin/python3", IMAGE_ID,
                  "/inputs/runner/tools/riscv64_server_observations.py", "--inside", "--output",
                  str(INSIDE_WORK / "evidence/qualification.json")]
        if phase_probe:
            create.append("--phase-probe")
        if query_candidate:
            create.append("--query-candidate")
        stage = "container-create"
        create_timeout = remaining(30, operation_deadline, "operation")
        created = True
        combined.command(create, timeout=create_timeout)
        stage = "container-inspection"
        container = load_json(combined.command(["docker", "inspect", name],
            timeout=remaining(30, operation_deadline, "operation")).stdout)[0]
        container_contract(container, mounted)
        report["container"] = {"image": container["Image"], "config": container["Config"], "host_config": container["HostConfig"]}
        stage = "runtime"
        report["runtime"] = combined.bounded_process(["docker", "start", "--attach", name], output / "runtime.log",
            timeout=remaining(600, operation_deadline, "operation"), max_bytes=combined.RUNTIME_LOG_BYTE_LIMIT)
        if report["runtime"]["outcome"] != "pass":
            report["error"] = "The retained-server diagnostic failed; inspect the scoped test and observation records."
            report["failure_stage"] = stage
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError,
            subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile) as error:
        report["error"] = str(error)
        report["failure_stage"] = stage
    finally:
        if phase_probe:
            for filename in ("trace-build-failure.json", "trace-build-failure.log"):
                failure_file = context / filename
                try:
                    if failure_file.exists() or failure_file.is_symlink():
                        retain_host_file(failure_file, output / filename)
                except (OSError, ValueError) as error:
                    report["host_evidence_error"] = str(error)
                    report.setdefault("failure_stage", "host-evidence")
                    report["outcome"] = "fail"
        if created:
            errors, collected, budget = {}, set(), {"bytes": 0, "files": 0}
            try:
                combined.command(["docker", "stop", "--time", "5", name],
                                 timeout=remaining(15, host_deadline, "cleanup"))
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                errors["stop"] = str(error)
                report.setdefault("failure_stage", "cleanup")
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
                    report.setdefault("failure_stage", "collection")
            report["collection"] = {**budget, "errors": errors, "collected": sorted(collected)}
            if not errors and len(collected) == 3:
                try:
                    guest = load_object((output / "qualification.json").read_text())
                    if (guest.get("qualification") != "UNQUALIFIED" or guest.get("outcome") != "pass"
                            or any(guest.get(key) is not False for key in
                                   ("application_qualified", "native_qualified", "release_qualified"))
                            or guest.get("original_19_test_gate") != "fail"
                            or guest.get("server_tests", {}).get("tests_run") != (0 if query_candidate else 14)
                            or (query_candidate and (guest.get("scope") != "retained-riscv64-query-candidate"
                                or guest.get("server_tests", {}).get("http_methods_not_run") != 14))
                            or guest.get("server_tests", {}).get("tests_skipped") != 0
                            or digest(output / "observations/qualification.json") != guest.get("observation", {}).get("sha256")
                            or digest(output / "server_package.log") != guest.get("server_tests", {}).get("log_sha256")):
                        raise ValueError("The guest diagnostic is failed, incomplete, or incorrectly scoped.")
                    if "error" not in report and report.get("runtime", {}).get("outcome") == "pass":
                        report["outcome"] = "pass"
                except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
                    report["collection_error"] = str(error)
                    report.setdefault("failure_stage", "collection")
            else:
                report["collection_error"] = "Current bounded collection did not supply all three diagnostic records."
            try:
                combined.command(["docker", "rm", "--force", name],
                                 timeout=remaining(15, host_deadline, "cleanup"))
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                report["cleanup_error"] = str(error)
                report.setdefault("failure_stage", "cleanup")
                report["outcome"] = "fail"
        finish_host_report(report, output, started=started, deadline=host_deadline, phase_probe=phase_probe)
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
    parser.add_argument("--phase-probe", action="store_true")
    parser.add_argument("--query-candidate", action="store_true")
    parser.add_argument("--mhd-source", type=Path)
    args = parser.parse_args()
    if args.query_candidate and not args.phase_probe:
        parser.error("The SQL comparison requires the reviewed phase-probe inputs.")
    if args.self_test:
        suite = unittest.defaultTestLoader.discover(str(ROOT / "tests/riscv64"), pattern="test_server_observations.py")
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.prepare_context:
        if not args.revision or not args.fixture_revision:
            parser.error("Supply --revision and --fixture-revision with --prepare-context.")
        prepare_context(args.prepare_context, args.revision, args.fixture_revision, phase_probe=args.phase_probe,
                        query_candidate=args.query_candidate)
        return 0
    if args.inside:
        return inside(args.output, phase_probe=args.phase_probe, query_candidate=args.query_candidate)
    if not all((args.image_zip, args.server_zip, args.context)):
        parser.error("Supply --image-zip, --server-zip, and --context with --run-image.")
    if args.phase_probe and args.mhd_source is None:
        parser.error("Supply --mhd-source with the phase probe.")
    return run_image(args.image_zip, args.server_zip, args.context, args.output,
                     phase_probe=args.phase_probe, mhd_source=args.mhd_source, query_candidate=args.query_candidate)


if __name__ == "__main__":
    raise SystemExit(main())
