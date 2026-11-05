"""Run the real qualification control flow against a local Docker test double.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests")]
from server_metrics_fixture import CASES, metrics
import test_postgres18_image as harness


def run(mode):
    constrained = mode.startswith("envelope-")
    declaration = harness.fixture.prepare(harness.fixture.PREPARATION, "a" * 40)
    schema = ROOT / "server/catalog/schema.sql"
    Path("server/catalog").mkdir(parents=True)
    Path("server/catalog/schema.sql").write_bytes(schema.read_bytes())
    migration = hashlib.sha384(schema.read_bytes()).hexdigest()
    base = {"Id": harness.fixture.CONFIG, "Architecture": "amd64", "Os": "linux", "Config": {"User": "26"},
            "RootFS": {"Layers": ["base"]}, "RepoDigests": [harness.fixture.DATABASE_IMAGE]}
    sidecar = {"Id": "sha256:" + "4" * 64, "Architecture": "amd64", "Os": "linux", "Config": {"User": "26:26"},
               "RootFS": {"Layers": ["base", "fixture"]}}
    images = {harness.fixture.DATABASE_IMAGE: base, harness.DATABASE: sidecar}
    for suite, names in harness.IMAGES.items():
        image = {"Id": "sha256:" + ("5" if suite == "operator" else "6") * 64, "Architecture": "amd64", "Os": "linux",
                 "RootFS": {"Layers": ["application"]}, "Config": {"User": "65532:65532",
                 "Entrypoint": harness.operator.ENTRYPOINT if suite == "operator" else ["/usr/local/bin/asm-hub"],
                 "Cmd": ["--help"] if suite == "operator" else ["serve"],
                 "Labels": {"org.opencontainers.image.revision": "a" * 40}}}
        for name, layers in zip(names, ([], ["original-tests"], ["original-tests", "pg18-tests"])):
            images[name] = copy.deepcopy(image)
            images[name]["RootFS"]["Layers"] += layers
    tool = bytearray(120)
    tool[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", tool, 16, 3, 62, 1)
    struct.pack_into("<Q", tool, 32, 64)
    struct.pack_into("<HHH", tool, 52, 64, 56, 1)
    struct.pack_into("<II", tool, 64, 0x6474E551, 6)
    tool_inventory = {name: {"sha256": hashlib.sha256(tool).hexdigest(), "bytes": len(tool)}
                      for name in ("test-metrics", "metrics-faults.so")}
    containers, removed = {}, []
    tool_reads = 0

    def docker(arguments, **options):
        nonlocal tool_reads
        if arguments[0] != "docker":
            raise AssertionError("Unexpected test executable.")
        operation = arguments[1]
        if operation == "info":
            body = b"linux/amd64\n"
        elif operation == "image":
            body = json.dumps([images[arguments[-1]]]).encode()
        elif operation == "create":
            identity = f"{len(containers) + 1:064x}"
            user = arguments[arguments.index("--user") + 1]
            name = arguments[arguments.index("--name") + 1]
            executable = arguments[arguments.index("--entrypoint") + 1] if "--entrypoint" in arguments else None
            memory = arguments[arguments.index("--memory") + 1]
            cpus = arguments[arguments.index("--cpus") + 1]
            image = next(value for value in arguments if value.startswith("sha256:"))
            value = {"Id": identity, "Name": "/" + name, "Image": image,
                     "Config": {"User": user, "Labels": {"asm.qualification.nonce": declaration["nonce"]}},
                     "HostConfig": {"ReadonlyRootfs": True, "NetworkMode": arguments[arguments.index("--network") + 1],
                         "PortBindings": {}, "CapDrop": ["ALL"], "CapAdd": None, "SecurityOpt": ["no-new-privileges"],
                         "Privileged": False, "PidsLimit": 128, "Memory": {"2g": 2147483648, "512m": 536870912, "256m": 268435456}[memory],
                         "NanoCpus": {"1": 1000000000, "2": 2000000000}[cpus]}, "Mounts": [],
                     "State": {"Running": True, "ExitCode": 0, "OOMKilled": False},
                     "probe": arguments[-1] if executable == "/bin/cat" else None,
                     "executable": executable, "arguments": arguments[arguments.index(image) + 1:],
                     "suite": arguments[arguments.index("--suite") + 1] if "--suite" in arguments else None}
            if constrained and user == "65532:65532":
                value["HostConfig"].update(MemorySwap=268435456, Tmpfs={"/tmp": "rw,nosuid,nodev,noexec,size=64m,uid=65532,gid=65532,mode=0700"})
            containers[identity] = value
            body = identity.encode()
        elif operation == "container":
            body = json.dumps([containers[arguments[-1]]]).encode()
        elif operation == "start":
            value = containers[arguments[-1]]
            if value["executable"] == "/usr/bin/stat":
                body = b"555:0:0\n" if "%a:%u:%g" in value["arguments"] else b"444:0:0:1024\n"
            elif value["executable"] == "/usr/bin/sha256sum":
                body = ("c" * 64 + "  /qualification/fixtures/connect-null.so\n").encode()
            elif value["probe"] and value["probe"].startswith("/qualification/server/"):
                tool_reads += 1
                body = bytes(tool) + (b"changed" if mode == "envelope-metrics-tool-change" and tool_reads > 2 else b"")
            elif value["probe"]:
                if mode == "terminate":
                    os.kill(os.getpid(), signal.SIGTERM)
                body = (Path(".postgres18-fixture/server") / Path(value["probe"]).name).read_bytes()
            elif value["suite"]:
                if mode == "envelope-timeout":
                    raise subprocess.TimeoutExpired(arguments, 180, output=b"retained bounded request evidence\n", stderr=b"controlled timeout\n")
                suite = value["suite"]
                database_id = value["HostConfig"]["NetworkMode"].split(":", 1)[1]
                report = {"schema": 1, "status": "pass", "scope": "selected-cnpg18-compatibility", "suite": suite,
                          "source_revision": "a" * 40, "tests_run": 23 if suite == "operator" else 22, "not_applicable": [],
                          "applicable_tests_skipped": 0, "client_libpq_version": 160015, "migration_sha384": migration,
                          "database": {"server_version_num": 180006, "data_directory": harness.fixture.DATA,
                              "nonce": declaration["nonce"], "system_identifier": str(7452238960987612345 + int(database_id, 16)),
                              "session_user": "asm_fixture_admin", "tls_protocol": "TLSv1.3"}}
                if suite != "operator":
                    report["metrics_test_tools"] = copy.deepcopy(tool_inventory)
                    report["cases"] = list(CASES["baseline" if suite == "http" else suite])
                if suite in {"http", "baseline"}:
                    report["metrics"] = metrics()
                    report["metrics"]["test_tools"] = copy.deepcopy(tool_inventory)
                if constrained:
                    counts = {"baseline": 22, "capacity": 12, "envelope": 3}
                    modules = {"baseline": "test_runtime.RuntimeTests", "capacity": "test_capacity.CapacityTests", "envelope": "test_envelope.EnvelopeTests"}
                    cases = [modules[suite].split(".")[0] + "." + name for name in CASES[suite]]
                    phases = ["before-suite"] + [phase + case for case in cases for phase in ("before:", "after:")] + ["after-suite"]
                    files = {"memory.max": "268435456\n", "memory.current": "48000000\n", "memory.peak": "64000000\n",
                        "memory.swap.max": "0\n", "memory.swap.current": "0\n", "cpu.max": "100000 100000\n",
                        "memory.events": "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n",
                        "memory.events.local": "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n",
                        "cpu.stat": "usage_usec 100\nuser_usec 60\nsystem_usec 40\nnr_periods 4\nnr_throttled 1\nthrottled_usec 1000\n"}
                    samples = [{"phase": phase, "monotonic_ns": number + 1, "files": dict(files)} for number, phase in enumerate(phases)]
                    requests = [{"path": "/health/ready", "valid_request": True, "status": 503, "body_bytes": 132, "outcome": "refused", "elapsed_ns": 1000}]
                    report.update(scope="selected-cnpg18-deployment-envelope", tests_run=counts[suite], profile="deployment-envelope",
                        measurement_scope="Qualification drivers and test tools share one constrained cgroup with the assembly runtime; PostgreSQL is separate.",
                        cgroup=samples, cases=cases, requests=requests, availability={"valid_requests": 1, "availability_failures": 1},
                        fixture={"path": "/qualification/fixtures/connect-null.so", "sha256": "c" * 64, "bytes": 1024, "mode": "0444", "uid": 0, "gid": 0})
                    if mode == "envelope-missing-sample":
                        report["cgroup"].pop()
                    elif mode == "envelope-fixture-change":
                        report["fixture"]["sha256"] = "d" * 64
                    elif mode == "envelope-fixture-type":
                        report["fixture"]["uid"] = False
                    elif mode == "envelope-availability-type":
                        report["availability"]["availability_failures"] = True
                    elif mode == "envelope-oom":
                        value["State"]["OOMKilled"] = True
                body = (harness.PREFIX + json.dumps(report) + "\n").encode()
            else:
                body = b""
        elif operation == "exec":
            if arguments[-1] == "/run/asm-postgres18/postgres.log":
                return SimpleNamespace(returncode=1 if mode == "envelope-log-fail" else 0,
                    stdout=b"canceling statement due to statement timeout\n" * 9, stderr=b"controlled owned file log\n")
            body = b"accepting connections\n"
        elif operation == "logs":
            return SimpleNamespace(returncode=1 if mode == "logs-fail" else 0, stdout=b"", stderr=b"controlled database log result\n")
        elif operation == "rm":
            if mode == "envelope-cleanup-fail":
                raise ValueError("Controlled owned cleanup failure.")
            removed.append(arguments[-1])
            body = b""
        else:
            raise AssertionError("Unexpected Docker operation: " + operation)
        return SimpleNamespace(returncode=0, stdout=body, stderr=b"")

    try:
        with patch.object(harness.platform, "system", return_value="Linux"), \
                patch.object(harness.platform, "machine", return_value="x86_64"), \
                patch.object(harness, "command", side_effect=docker), \
                patch.object(harness, "database_files", return_value={"postgres": "a" * 64}), \
                patch.object(harness.operator, "runtime_files", return_value={"psql": "b" * 64}), \
                patch.object(harness.server, "runtime_files", return_value={"asm-hub": "c" * 64}):
            harness.qualify(SimpleNamespace(revision="a" * 40, output="evidence", profile="deployment-envelope" if constrained else "compatibility"))
    except ValueError:
        return 1
    finally:
        Path("scenario-resources.json").write_text(json.dumps({"created": list(containers), "removed": removed}))
    return 0


if __name__ == "__main__":
    raise SystemExit(run(sys.argv[1]))
