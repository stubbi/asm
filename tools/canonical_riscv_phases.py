#!/usr/bin/env python3
"""UNQUALIFIED canonical client-phase observations; never a release gate.

SPDX-License-Identifier: AGPL-3.0-or-later
Runtime assembly, SQL, TLS, admission, and policy remain unchanged.
"""
import argparse
import ast
import hashlib
import http.client
import io
import json
import math
import os
from pathlib import Path
import platform
import re
import stat
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = "cb0f3f7315fe2878660684a1fe6eea76ca65e5ae"
SDK_REVISION = "881208fcec32ec8fe4609747ca2c4d8b9065c49f"
SDK_FILES = ("tools/riscv64_combined.py", "tools/riscv64_server_observations.py", "tools/riscv64_reference_build.py")
DRIVER_FILES = ("tools/canonical_riscv_phases.py", "tools/canonical_riscv_trace.py", "tools/canonical_riscv_build.py", "tools/canonical_riscv_guest.py")
METHOD = "test_concurrent_exports_keep_independent_response_ownership"
ROUTES = ("/registry/v1/index.tsv", "/registry/v1/index-macos.tsv", "/registry/v1/index-all.tsv", "/registry/v1/index.json")
CGROUP_FILES = ("cpu.max", "cpu.stat", "memory.events", "memory.current", "memory.peak", "memory.max")
CPU_COUNTERS = frozenset(("usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec"))
MEMORY_COUNTERS = frozenset(("oom", "oom_kill"))
WORK = Path("/tmp/asm-canonical-evidence")
SCOPE = "UNQUALIFIED-canonical-riscv-client-phases"
MAXIMUM = 4194304
ERROR = "The bounded canonical diagnostic is incomplete."
IMAGE_ID = "sha256:ea55425e6daa994ad57c46862258368c192c6f1f44b146c8a7bf3d1758571ae1"
OWNER_LABEL = "org.asm.canonical-diagnostic.owner"
GUEST_PREFIX = b"ASM_CANONICAL_GUEST="


def need(condition, message=ERROR):
    if not condition:
        raise ValueError(message)


def object_json(data):
    def fields(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result)
            result[key] = value
        return result
    try:
        value = json.loads(data, object_pairs_hook=fields, parse_constant=lambda _: (_ for _ in ()).throw(ValueError(ERROR)))
    except (ValueError, UnicodeError, RecursionError):
        raise ValueError(ERROR) from None
    need(type(value) is dict)
    return value


class Budget:
    def __init__(self, started_ns, deadline_ns):
        need(type(started_ns) is int and type(deadline_ns) is int and started_ns > 0 and
             deadline_ns - started_ns == 600000000000 and started_ns <= time.monotonic_ns())
        self.started_ns, self.deadline_ns = started_ns, deadline_ns

    def remaining(self, cap, *, cleanup=False):
        left = (self.deadline_ns - time.monotonic_ns()) / 1000000000 - (0 if cleanup else 90)
        need(type(cap) in (int, float) and math.isfinite(cap) and cap > 0 and left > 0)
        return min(cap, left)


def budget_contract(receipt, budget):
    need(receipt.get("started_ns") == budget.started_ns and receipt.get("deadline_ns") == budget.deadline_ns and
         type(receipt.get("started_ns")) is int and type(receipt.get("deadline_ns")) is int)


def bounded_file(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        need(stat.S_ISREG(info.st_mode) and info.st_size <= maximum)
        data = stream.read(maximum + 1)
    need(len(data) <= maximum)
    return data


def number(text):
    need(type(text) is str and re.fullmatch(r"[0-9]{1,20}\n?", text) is not None)
    result = int(text)
    need(result <= 2 ** 64 - 1)
    return result


def counters(text):
    result = {}
    for line in text.splitlines():
        fields = line.split()
        need(len(fields) == 2 and len(fields[0]) <= 40 and
             re.fullmatch(r"[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)*", fields[0]) is not None and fields[0] not in result)
        result[fields[0]] = number(fields[1])
    need(0 < len(result) <= 64)
    return result


def snapshot(directory, phase):
    files = {name: bounded_file(Path(directory) / name, 8192).decode("ascii") for name in CGROUP_FILES}
    value = {"phase": phase, "monotonic_ns": time.monotonic_ns(), "files": files}
    validate_snapshot(value)
    return value


def validate_snapshot(value):
    need(type(value) is dict and set(value) == {"phase", "monotonic_ns", "files"} and
         type(value["phase"]) is str and value["phase"] in {"before", "after"} and type(value["monotonic_ns"]) is int and value["monotonic_ns"] > 0)
    files = value["files"]
    need(type(files) is dict and set(files) == set(CGROUP_FILES))
    need(all(type(body) is str and 0 < len(body) <= 8192 for body in files.values()))
    quota = files["cpu.max"].split()
    need(len(quota) == 2 and (quota[0] == "max" or re.fullmatch(r"[0-9]{1,10}", quota[0])) and
         re.fullmatch(r"[0-9]{1,10}", quota[1]) and 0 < int(quota[1]) <= 1000000)
    need(files["memory.max"] == "max\n" or number(files["memory.max"]) >= 0)
    number(files["memory.current"])
    number(files["memory.peak"])
    need(CPU_COUNTERS <= counters(files["cpu.stat"]).keys())
    need(MEMORY_COUNTERS <= counters(files["memory.events"]).keys())


def snapshot_contract(before, after):
    validate_snapshot(before)
    validate_snapshot(after)
    need(before["phase"] == "before" and after["phase"] == "after" and after["monotonic_ns"] > before["monotonic_ns"])
    need(number(after["files"]["memory.peak"]) >= number(before["files"]["memory.peak"]))
    for name, required in (("cpu.stat", CPU_COUNTERS), ("memory.events", MEMORY_COUNTERS)):
        first, last = counters(before["files"][name]), counters(after["files"][name])
        need(all(last[key] >= first[key] for key in required))


def resource_assessment(before, after):
    """Keep observed failures visible; peak is cumulative, never an arm delta."""
    validate_snapshot(before)
    validate_snapshot(after)
    def configured(value):
        quota = value["files"]["cpu.max"].split()
        return quota[0] != "max" and int(quota[0]) == 2 * int(quota[1]) and value["files"]["memory.max"].strip() == "536870912"
    first, last = counters(before["files"]["memory.events"]), counters(after["files"]["memory.events"])
    return {"configured_budget": configured(before) and configured(after),
            "peak_exceeded_budget": any(number(value["files"]["memory.peak"]) > 536870912 for value in (before, after)),
            "current_exceeded_budget": any(number(value["files"]["memory.current"]) > 536870912 for value in (before, after)),
            "oom_delta": {key: last[key] - first[key] for key in sorted(first.keys() & last.keys() & {"oom", "oom_kill", "oom_group_kill"})},
            "memory_peak_scope": "container-lifetime-cumulative"}


def http_contract(records):
    fields = {"schema", "ordinal", "route", "status", "bytes", "sha256", "elapsed_ns", "transport",
              "bytes_equal", "media_ok", "cache_ok", "nosniff_ok", "lf_ok", "size_ok", "declared_bytes"}
    need(type(records) is list and len(records) == 8)
    for value in records:
        need(type(value) is dict and set(value) == fields and type(value["schema"]) is int and value["schema"] == 1)
        for name, low, high in (("ordinal", 1, 8), ("route", 1, 4), ("bytes", 0, MAXIMUM), ("elapsed_ns", 0, 2 ** 63 - 1)):
            need(type(value[name]) is int and low <= value[name] <= high)
        need(value["status"] is None or type(value["status"]) is int and 100 <= value["status"] <= 599)
        need(type(value["sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is not None)
        need(type(value["transport"]) is str and value["transport"] in {"complete", "timeout", "reset", "truncated", "protocol"})
        need(value["declared_bytes"] is None or type(value["declared_bytes"]) is int and 0 <= value["declared_bytes"] <= MAXIMUM)
        need(all(type(value[name]) is bool for name in ("bytes_equal", "media_ok", "cache_ok", "nosniff_ok", "lf_ok", "size_ok")))
    need(sorted(value["ordinal"] for value in records) == list(range(1, 9)))
    need(all(sum(value["route"] == route for value in records) == 2 for route in range(1, 5)))
    def accepted(value):
        return value["transport"] == "complete" and value["status"] == 200 and all(
            value[name] for name in ("bytes_equal", "media_ok", "cache_ok", "nosniff_ok", "lf_ok", "size_ok"))
    return {"requests": 8, "complete": sum(value["transport"] == "complete" for value in records),
            "application_passed": all(accepted(value) for value in records),
            "availability_failures": sum(not accepted(value) for value in records)}


def remaining(deadline):
    left = deadline - time.monotonic()
    if left <= 0:
        raise TimeoutError(ERROR)
    return left


class DeadlineReader(io.RawIOBase):
    def __init__(self, connection, maximum, deadline, inactivity=None):
        self.connection, self.deadline = connection, deadline
        self.inactivity = inactivity
        self.capacity, self.header_bytes, self.tail, self.done = 16384 + maximum + 1, 0, b"", False

    def readable(self):
        return True

    def readinto(self, target):
        left = remaining(self.deadline)
        self.connection.settimeout(left if self.inactivity is None else min(self.inactivity, left))
        need(self.capacity > 0)
        count = self.connection.recv_into(memoryview(target)[:min(len(target), self.capacity)])
        self.capacity -= count
        if count and not self.done:
            prefix = self.tail + bytes(memoryview(target)[:count])
            end = prefix.find(b"\r\n\r\n")
            self.header_bytes += count if end < 0 else end + 4 - len(self.tail)
            need(self.header_bytes <= 16384)
            self.done, self.tail = end >= 0, prefix[-3:]
        return count


def read_http(connection, *, maximum, deadline, observation, inactivity=None):
    need(type(maximum) is int and 0 <= maximum <= MAXIMUM)
    need(inactivity is None or type(inactivity) in (int, float) and math.isfinite(inactivity) and 0 < inactivity <= 3)
    class Source:
        def makefile(self, mode):
            need(mode == "rb")
            return io.BufferedReader(DeadlineReader(connection, maximum, deadline, inactivity), buffer_size=4096)
    response = http.client.HTTPResponse(Source())
    digest, body = hashlib.sha256(), bytearray()
    observation.update(bytes=0, sha256=digest.hexdigest())
    try:
        response.begin()
        observation["status"] = response.status
        lengths = response.headers.get_all("Content-Length", [])
        need(len(lengths) == 1 and lengths[0].isdigit() and response.length is not None and response.length <= maximum)
        observation["declared_bytes"] = response.length
        while response.length:
            remaining(deadline)
            chunk = response.read1(min(65536, maximum - len(body)))
            if not chunk:
                raise http.client.IncompleteRead(bytes(body), response.length)
            body.extend(chunk)
            digest.update(chunk)
            observation.update(bytes=len(body), sha256=digest.hexdigest())
            need(len(body) <= maximum)
        remaining(deadline)
        return response.status, dict(response.getheaders()), bytes(body)
    finally:
        response.close()


def identity(path):
    data = bounded_file(path, 64 * 1024 * 1024)
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def sdk_modules(sdk, *, readonly_guest=False):
    import canonical_riscv_build
    return canonical_riscv_build.load_sdk(Path(sdk) / "tools", readonly_guest=readonly_guest)


def prepare_context(destination, revision, sdk, budget):
    """Bind separate immutable canonical, diagnostic, and reviewed SDK inputs."""
    import registry
    import release
    budget.remaining(1)
    need(re.fullmatch(r"[0-9a-f]{40}", revision or "") is not None and release.resolve_commit(ROOT, "HEAD") == revision)
    need(not registry.git_output(ROOT, "status", "--porcelain").strip(), "Freeze the diagnostic source before materialization.")
    destination, sdk = Path(destination), Path(sdk)
    need(not destination.exists() and not destination.is_symlink() and destination.parent.is_dir())
    sdk_modules(sdk)
    sdk_source = registry.git_files(ROOT, SDK_REVISION, ".", list(SDK_FILES))
    need(set(sdk_source) == set(SDK_FILES))
    for name, (data, mode) in sdk_source.items():
        need(bounded_file(sdk / name, 256 * 1024) == data and mode == 0o644)
    selected = ["server", "tools/registry.py", "tools/registry_admin.py", "registry/packages",
                "experiments/assembly-server/local_postgres.py", "experiments/assembly-server/guard.sql",
                "experiments/assembly-server/fixtures/0001_registry.sql"]
    source = registry.git_files(ROOT, CANONICAL, ".", selected)
    runner = registry.git_files(ROOT, revision, ".", list(DRIVER_FILES))
    need(set(runner) == set(DRIVER_FILES))
    observer = registry.git_files(ROOT, revision, ".", ["tools/diagnostics/canonical_libpq_trace.c", "tests/riscv64/test_canonical_trace.py"])
    need(len(observer) == 2)
    original = ast.parse(source["server/test_runtime.py"][0])
    methods = [node.name for node in ast.walk(original) if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")]
    need(len(methods) == 16 and METHOD in methods)
    with tempfile.TemporaryDirectory(prefix=".asm-canonical-context-", dir=destination.parent) as temporary:
        stage = Path(temporary) / "context"
        stage.mkdir()
        for name, files in (("source", source), ("runner", runner), ("sdk", sdk_source)):
            release.materialize(files, stage / name)
            budget.remaining(1)
        (stage / "observer.c").write_bytes(observer["tools/diagnostics/canonical_libpq_trace.c"][0])
        (stage / "observer-test.py").write_bytes(observer["tests/riscv64/test_canonical_trace.py"][0])
        for path in (stage, *stage.rglob("*")):
            path.chmod(0o755 if path.is_dir() else 0o444)
        modules = sdk_modules(stage / "sdk")
        receipt = {"schema": 1, "scope": SCOPE, "qualification": "UNQUALIFIED", "canonical_revision": CANONICAL,
                   "diagnostic_revision": revision, "sdk_revision": SDK_REVISION,
                   "started_ns": budget.started_ns, "deadline_ns": budget.deadline_ns,
                   "trees": {name: modules.combined.tree_digest(stage / name) for name in ("source", "runner", "sdk")},
                   "observer": identity(stage / "observer.c"), "observer_test": identity(stage / "observer-test.py"),
                   "original_methods": sorted(methods), "source_rebuilt": True,
                   "failed_artifact_equality": "unestablished; original executable/image bytes not retained"}
        (stage / "input-manifest.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        (stage / "input-manifest.json").chmod(0o444)
        budget.remaining(1)
        release.publish_directory(stage, destination)
    budget.remaining(1)
    return receipt


def context_contract(context, budget=None, *, readonly_guest=False):
    context = Path(context)
    receipt = object_json(bounded_file(context / "input-manifest.json", 65536))
    need(receipt.get("schema") == 1 and type(receipt.get("schema")) is int and receipt.get("scope") == SCOPE and
         receipt.get("canonical_revision") == CANONICAL and receipt.get("sdk_revision") == SDK_REVISION and
         receipt.get("source_rebuilt") is True and receipt.get("qualification") == "UNQUALIFIED")
    if budget is not None:
        budget_contract(receipt, budget)
    modules = sdk_modules(context / "sdk", readonly_guest=readonly_guest)
    for name in ("source", "runner", "sdk"):
        need(modules.combined.tree_digest(context / name) == receipt["trees"][name])
    need(identity(context / "observer.c") == receipt["observer"] and identity(context / "observer-test.py") == receipt["observer_test"])
    return receipt, modules


def build_contract(context):
    context = Path(context)
    report = object_json(bounded_file(context / "canonical-build/manifest.json", 1024 * 1024))
    need(report.get("outcome") == "pass" and report.get("qualification") == "UNQUALIFIED" and report.get("source_revision") == CANONICAL)
    expected = {"asm-hub", "abi-check", "canonical_libpq_trace.so", "libcanonical_provider.so", "canonical_trace_check"}
    need(set(report["outputs"]) == expected)
    for name in expected:
        metadata = identity(context / "canonical-build" / name)
        need(all(report["outputs"][name].get(key) == item for key, item in metadata.items()))
    return report


def container_arguments(context, name, owner):
    mounted = str(Path(context).resolve())
    need("," not in mounted and "\0" not in mounted)
    return ["/usr/bin/docker", "create", "--pull=never", "--name", name, "--platform", "linux/riscv64",
            "--read-only", "--network", "none", "--user", "65532:65532", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--pids-limit", "128", "--memory", "512m", "--cpus", "2",
            "--label", OWNER_LABEL + "=" + owner,
            "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=256m,uid=65532,gid=65532,mode=0700",
            "--mount", "type=bind,src=" + mounted + ",dst=/inputs,readonly", "--workdir", "/tmp",
            "--env", "HOME=/nonexistent", "--env", "LC_ALL=C", "--env", "TZ=UTC", "--env", "QEMU_LD_PREFIX=/",
            "--entrypoint", "/usr/bin/python3", IMAGE_ID, "/inputs/runner/tools/canonical_riscv_phases.py",
            "--inside", "--context", "/inputs", "--output", str(WORK / "qualification.json")]


def container_contract(value, context, owner):
    config, host = value.get("Config", {}), value.get("HostConfig", {})
    need(value.get("Image") == IMAGE_ID and config.get("Labels", {}).get(OWNER_LABEL) == owner and
         config.get("User") == "65532:65532" and host.get("ReadonlyRootfs") is True and
         host.get("NetworkMode") == "none" and host.get("Memory") == 536870912 and
         host.get("NanoCpus") == 2000000000 and host.get("PidsLimit") == 128 and
         host.get("CapDrop") == ["ALL"] and host.get("SecurityOpt") == ["no-new-privileges"])
    permitted = {"PATH", "HOME", "PYTHONDONTWRITEBYTECODE", "PYTHONUNBUFFERED", "LC_ALL", "TZ", "QEMU_LD_PREFIX"}
    need(all(type(item) is str and item.split("=", 1)[0] in permitted for item in config.get("Env", [])))
    mounts = value.get("Mounts", [])
    binds = [item for item in mounts if item.get("Type") == "bind"]
    tmpfs = [item for item in mounts if item.get("Type") == "tmpfs"]
    need(len(mounts) in {1, 2} and len(binds) == 1 and len(binds) + len(tmpfs) == len(mounts) and
         binds[0].get("Source") == str(Path(context).resolve()) and binds[0].get("Destination") == "/inputs" and
         binds[0].get("RW") is False and all(item.get("Destination") == "/tmp" and
         item.get("Source", "") == "" and item.get("RW") is True for item in tmpfs))
    options = set(host.get("Tmpfs", {}).get("/tmp", "").split(","))
    need({"nosuid", "nodev", "noexec", "size=256m", "uid=65532", "gid=65532", "mode=0700"} <= options)


def container_state(value):
    state = value.get("State", {})
    need(all(type(state.get(name)) is bool for name in ("Running", "OOMKilled", "Dead")) and
         type(state.get("ExitCode")) is int and -(2 ** 31) <= state["ExitCode"] < 2 ** 31)
    return {name: state[name] for name in ("Running", "OOMKilled", "ExitCode", "Dead")}


def validate_transport_report(value):
    from canonical_riscv_guest import validate_guest_report
    return validate_guest_report(value)


def publish_stream(path, output):
    """Publish controlled records before tmpfs disappears; keep other raw bytes private."""
    from canonical_riscv_trace import PREFIX, ERROR_PREFIX, read_trace
    raw = bounded_file(path, 1024 * 1024)
    lines = raw.splitlines(keepends=True)
    frames = [line for line in lines if line.startswith(GUEST_PREFIX)]
    need(len(frames) == 1 and frames[0].endswith(b"\n") and len(frames[0]) <= 768 * 1024)
    need(all(GUEST_PREFIX not in line or line.startswith(GUEST_PREFIX) for line in lines))
    payload = frames[0][len(GUEST_PREFIX):-1]
    payload.decode("ascii")
    guest = validate_transport_report(object_json(payload))
    # The closed guest schema is checked before any report byte is published.
    with (Path(output) / "qualification.json").open("xb") as stream:
        stream.write(payload + b"\n")
    selected = b"".join(line for line in lines if line.startswith(PREFIX))
    rejected, records, controlled = None, [], b""
    try:
        need(ERROR_PREFIX not in raw and len(selected) <= 128 * 1024 and
             all(PREFIX not in line or line.startswith(PREFIX) for line in lines))
        with tempfile.TemporaryDirectory(prefix="asm-canonical-stream-") as temporary:
            trace = Path(temporary) / "trace.log"
            trace.write_bytes(selected)
            records, controlled = read_trace(trace)
        need(controlled == selected)
        with (Path(output) / "server_package.log").open("xb") as stream:
            stream.write(controlled)
    except (ValueError, OSError):
        rejected = {"bytes": len(selected), "sha256": hashlib.sha256(selected).hexdigest(),
                    "reason": "invalid-controlled-records"}
    with (Path(output) / "runtime.log").open("xb") as stream:
        stream.write(frames[0] + (controlled if rejected is None else b""))
    return guest, records, controlled, rejected


def guest_contract(guest, trace, records):
    need(guest.get("scope") == SCOPE and guest.get("qualification") == "UNQUALIFIED" and
         guest.get("canonical_revision") == CANONICAL and guest.get("collector_complete") is True and
         guest.get("cleanup_complete") is True and all(guest.get(name) is False for name in
         ("application_qualified", "native_qualified", "release_qualified")))
    need([value.get("label") for value in guest.get("arms", [])] == ["control", "traced"])
    for arm in guest["arms"]:
        summary = http_contract(arm["http"])
        need(json.dumps(arm["http_summary"], sort_keys=True) == json.dumps(summary, sort_keys=True))
        snapshot_contract(arm["before"], arm["after"])
        need(resource_assessment(arm["before"], arm["after"])["configured_budget"])
        need(type(arm["cohort_start_ns"]) is int and type(arm["cohort_end_ns"]) is int and
             0 < arm["cohort_start_ns"] < arm["cohort_end_ns"] < 2 ** 63)
    first, traced = guest["arms"]
    need(first["cohort_end_ns"] <= traced["cohort_start_ns"])
    section = guest["trace"]
    need(section["valid"] is True and section["complete"] is True and section["route_association"] == "unknown" and
         section["identity"] == {"bytes": len(trace), "sha256": hashlib.sha256(trace).hexdigest()})
    need(json.dumps(section["records"], sort_keys=True, separators=(",", ":")) ==
         json.dumps(records, sort_keys=True, separators=(",", ":")))
    start, end = traced["cohort_start_ns"], traced["cohort_end_ns"]
    selected = [value["id"] for value in records if start <= value["start_ns"] <= value["end_ns"] <= end]
    need(type(section["cohort_ids"]) is list and all(type(value) is int for value in section["cohort_ids"]) and
         len(selected) == 8 and section["cohort_ids"] == selected and
         all(start <= value["start_ns"] <= value["end_ns"] <= end or value["end_ns"] <= start or value["start_ns"] >= end
             for value in records))


def run_host(image_zip, mhd_source, sdk, context, output, revision, budget):
    """Charge preparation, target work, collection, cleanup, and output to one clock."""
    import canonical_riscv_build
    context, output = Path(context), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    need(not output.is_symlink() and output.stat().st_uid == os.getuid() and output.stat().st_mode & 0o022 == 0)
    report_path = output / "host-report.json"
    need(not report_path.exists() and not report_path.is_symlink())
    report = {"schema": 1, "scope": SCOPE, "qualification": "UNQUALIFIED", "collector_complete": False,
              "application_qualified": False, "native_qualified": False, "release_qualified": False,
              "canonical_revision": CANONICAL, "diagnostic_revision": revision, "original_16_12_gate": "not-run",
              "started_ns": budget.started_ns, "deadline_ns": budget.deadline_ns, "cleanup_complete": False,
              "guest_after_snapshot": "missing",
              "comparison_order": ["control", "traced"], "scope_limits": [
                  "Source-rebuilt bytes; equality to the failed executable and image is unestablished.",
                  "The reused image has different operating-system and library bytes.",
                  "Fixed order and caches are not controlled statistically.",
                  "Callback-thread CPU includes emulation and observer work.",
                  "memory.peak is container-lifetime cumulative, including both arms and setup."]}
    name, owner = "asm-canonical-" + uuid.uuid4().hex, uuid.uuid4().hex
    attempted, modules, command, stage = False, None, None, "context"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    with tempfile.TemporaryDirectory(prefix="asm-canonical-host-") as temporary:
        private = Path(temporary)
        docker_config = private / "docker"
        docker_config.mkdir(mode=0o700)
        raw_runtime = private / "runtime.raw"
        prefix = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "HOME=" + str(private),
                  "DOCKER_HOST=unix:///var/run/docker.sock", "DOCKER_CONFIG=" + str(docker_config)]
        try:
            budget.remaining(1)
            need(platform.system() == "Linux" and platform.machine() in {"x86_64", "aarch64"})
            inputs, modules = context_contract(context, budget)
            need(inputs["diagnostic_revision"] == revision)
            need(sdk_modules(sdk).combined.__file__ is not None)
            def command(arguments, cap=30, *, cleanup=False):
                return modules.combined.command([*prefix, *arguments], timeout=budget.remaining(cap, cleanup=cleanup))
            stage = "image-input"
            archive = private / "image.tar"
            observations = modules.observations
            observations.extract_zip_member(Path(image_zip), archive, "UNQUALIFIED-rebuilt-diagnostic.tar",
                observations.IMAGE_TAR_BYTES, observations.IMAGE_TAR_SHA, observations.IMAGE_ZIP_BYTES, observations.IMAGE_ZIP_SHA)
            config = observations.image_archive_contract(archive)
            budget.remaining(1)
            report["image"] = {"id": IMAGE_ID, "archive_bytes": observations.IMAGE_TAR_BYTES,
                               "archive_sha256": observations.IMAGE_TAR_SHA, "source_artifact": 13423240467}
            stage = "build"
            report["build"] = canonical_riscv_build.prepare_build(archive, context, sdk=context / "sdk/tools",
                mhd_source=Path(mhd_source), deadline=(budget.deadline_ns - 90000000000) / 1000000000,
                timeout=min(120, budget.remaining(120)), observer_sha256=inputs["observer"]["sha256"],
                observer_test_sha256=inputs["observer_test"]["sha256"])
            build_contract(context)
            for filename in (*canonical_riscv_build.OUTPUTS, "manifest.json"):
                source = context / "canonical-build" / filename
                modules.observations.retain_host_file(source, output / filename, limit=1024 * 1024)
                budget.remaining(1)
            stage = "image-load"
            command(["/usr/bin/docker", "load", "--input", archive], 120)
            info = json.loads(command(["/usr/bin/docker", "image", "inspect", IMAGE_ID]).stdout)[0]
            need(info["Id"] == IMAGE_ID and info["Architecture"] == "riscv64" and info["Os"] == "linux" and
                 info["RootFS"]["Layers"] == config["rootfs"]["diff_ids"] and info["Config"].get("Env", []) == config["config"].get("Env", []))
            report["image"]["layers"] = info["RootFS"]["Layers"]
            stage = "host-environment"
            report["host"] = platform.uname()._asdict()
            registration = bounded_file(Path("/proc/sys/fs/binfmt_misc/qemu-riscv64"), 8192)
            need(b"enabled\n" in registration and b"interpreter " in registration)
            report["binfmt"] = {"bytes": len(registration), "sha256": hashlib.sha256(registration).hexdigest(), "record": registration.decode("ascii")}
            report["qemu"] = command(["/usr/bin/qemu-riscv64-static", "--version"]).stdout.decode("ascii")
            report["qemu_binary"] = identity(Path("/usr/bin/qemu-riscv64-static"))
            report["host_libc"] = command(["/usr/bin/getconf", "GNU_LIBC_VERSION"]).stdout.decode("ascii")
            stage = "create"
            attempted = True
            command(container_arguments(context, name, owner))
            actual = json.loads(command(["/usr/bin/docker", "inspect", name]).stdout)[0]
            container_contract(actual, context, owner)
            report["container"] = {"id": actual["Id"], "image": actual["Image"], "limits": {
                key: actual["HostConfig"][key] for key in ("ReadonlyRootfs", "NetworkMode", "Memory", "NanoCpus", "PidsLimit", "CapDrop", "SecurityOpt")}}
            stage = "runtime"
            report["runtime"] = modules.combined.bounded_process([*prefix, "/usr/bin/docker", "start", "--attach", name],
                raw_runtime, timeout=budget.remaining(180), max_bytes=1024 * 1024)
            need(report["runtime"]["outcome"] == "pass")
        except (Exception, KeyboardInterrupt) as error:
            report.update(failure_stage=stage, failure_type=type(error).__name__)
        finally:
            if modules is not None:
                for filename in ("canonical-build-failure.json", "canonical-build-failure.log"):
                    source = context / filename
                    if source.exists() or source.is_symlink():
                        try:
                            budget.remaining(1, cleanup=True)
                            modules.observations.retain_host_file(source, output / filename, limit=1024 * 1024)
                            budget.remaining(1, cleanup=True)
                        except (Exception, KeyboardInterrupt) as error:
                            report["build_evidence_failure_type"] = type(error).__name__
                            report["collector_complete"] = False
            if attempted and modules is not None and command is not None:
                try:
                    actual = json.loads(command(["/usr/bin/docker", "inspect", name], 15, cleanup=True).stdout)[0]
                    need(actual.get("Image") == IMAGE_ID and actual.get("Config", {}).get("Labels", {}).get(OWNER_LABEL) == owner)
                    report["container_state_before_cleanup"] = container_state(actual)
                    need(raw_runtime.is_file())
                    budget.remaining(1, cleanup=True)
                    report["raw_runtime_identity"] = identity(raw_runtime)
                    guest, records, trace, rejected = publish_stream(raw_runtime, output)
                    after_count = sum("after" in arm for arm in guest.get("arms", []))
                    report["guest_after_snapshot"] = "retained" if after_count == 2 else "partial-retained" if after_count else "missing"
                    if rejected is not None:
                        report["rejected_trace"] = rejected
                        raise ValueError(ERROR)
                    guest_contract(guest, trace, records)
                    report["collector_complete"] = "failure_stage" not in report
                except (Exception, KeyboardInterrupt) as error:
                    report["collection_failure_type"] = type(error).__name__
                finally:
                    try:
                        actual = json.loads(command(["/usr/bin/docker", "inspect", name], 10, cleanup=True).stdout)[0]
                        need(actual.get("Image") == IMAGE_ID and actual.get("Config", {}).get("Labels", {}).get(OWNER_LABEL) == owner)
                        command(["/usr/bin/docker", "stop", "--time", "5", name], 15, cleanup=True)
                        command(["/usr/bin/docker", "rm", "--force", name], 15, cleanup=True)
                        report["cleanup_complete"] = True
                    except (Exception, KeyboardInterrupt) as error:
                        report["cleanup_failure_type"] = type(error).__name__
            else:
                report["cleanup_complete"] = not attempted
            report["collector_complete"] = report["collector_complete"] and report["cleanup_complete"]
            report["completed_ns"] = time.monotonic_ns()
            report["host_elapsed_ns"] = report["completed_ns"] - budget.started_ns
            if report["completed_ns"] > budget.deadline_ns:
                report.update(collector_complete=False, failure_stage="host-deadline")
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            after_write = time.monotonic_ns()
            if after_write > budget.deadline_ns:
                report.update(collector_complete=False, failure_stage="late-output", completed_ns=after_write,
                              host_elapsed_ns=after_write - budget.started_ns)
                # Do not retain success if the failure rewrite cannot complete.
                report_path.unlink()
                report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return 0 if report["collector_complete"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--prepare-context", type=Path)
    modes.add_argument("--run-image", action="store_true")
    modes.add_argument("--inside", action="store_true")
    parser.add_argument("--context", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--image-zip", type=Path)
    parser.add_argument("--mhd-source", type=Path)
    parser.add_argument("--started-ns", type=int)
    parser.add_argument("--deadline-ns", type=int)
    args = parser.parse_args()
    if args.inside:
        need(args.context is not None and args.output is not None)
        from canonical_riscv_guest import run_inside
        return run_inside(args.context, args.output)
    need(all(value is not None for value in (args.started_ns, args.deadline_ns, args.revision, args.sdk)))
    budget = Budget(args.started_ns, args.deadline_ns)
    if args.prepare_context is not None:
        prepare_context(args.prepare_context, args.revision, args.sdk, budget)
        return 0
    need(all(value is not None for value in (args.context, args.output, args.image_zip, args.mhd_source)))
    return run_host(args.image_zip, args.mhd_source, args.sdk, args.context, args.output, args.revision, budget)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Exception, KeyboardInterrupt):
        print(ERROR, file=sys.stderr)
        raise SystemExit(1)
