"""Local mock-only contracts for the canonical diagnostic driver.

SPDX-License-Identifier: AGPL-3.0-or-later
No application, PostgreSQL, RISC-V executable, or container runs here.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("canonical_phase_driver", ROOT / "tools/canonical_riscv_phases.py")
driver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver)

# Exact cpu.stat sample retained from profile42111348191, before-suite.
CPU_STAT = ("usage_usec 161753\nuser_usec 130413\nsystem_usec 31339\nnice_usec 0\n"
            "core_sched.force_idle_usec 0\nnr_periods 2\nnr_throttled 0\nthrottled_usec 0\n"
            "nr_bursts 0\nburst_usec 0\n")


def http_records():
    return [{"schema": 1, "ordinal": index + 1, "route": index % 4 + 1, "status": 200,
             "bytes": 2, "sha256": hashlib.sha256(b"x\n").hexdigest(), "elapsed_ns": 1000000,
             "transport": "complete", "bytes_equal": True, "media_ok": True, "cache_ok": True,
             "nosniff_ok": True, "lf_ok": True, "size_ok": True, "declared_bytes": 2}
            for index in range(8)]


class CanonicalPhaseContracts(unittest.TestCase):
    def host_fixture(self, base, *, bad_trace=False, runtime_failed=False, late_runtime=False, build_failed=False,
                     oom_killed=False, missing_stream=False, extra_mount=None):
        sys.path.insert(0, str(ROOT / "tools"))
        import canonical_riscv_build
        fixture_spec = importlib.util.spec_from_file_location("canonical_guest_fixture", ROOT / "tests/riscv64/test_canonical_guest.py")
        fixture = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(fixture)
        guest, raw = fixture.complete_report()
        if bad_trace:
            raw = b"ASM_CANONICAL_TRACE=PRIVATE_PROVIDER_TEXT_MUST_NOT_BE_PUBLISHED\n"
            guest["trace"]["identity"] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        context, output = base / "context", base / "output"
        context.mkdir()
        state, commands = {}, []
        def command(arguments, **kwargs):
            values = list(map(str, arguments))
            commands.append((values, kwargs["timeout"]))
            if "create" in values:
                state["owner"] = values[values.index("--label") + 1].split("=", 1)[1]
            if "inspect" in values:
                if "image" in values:
                    result = [{"Id": driver.IMAGE_ID, "Architecture": "riscv64", "Os": "linux", "RootFS": {"Layers": []}, "Config": {"Env": []}}]
                else:
                    result = [{"Id": "owned-container", "Image": driver.IMAGE_ID,
                               "State": {"Running": False, "OOMKilled": oom_killed, "Dead": False,
                                         "ExitCode": 137 if oom_killed else 1 if runtime_failed else 0,
                                         "Error": "PRIVATE_PROVIDER_TEXT_MUST_NOT_BE_PUBLISHED"},
                               "Config": {"Labels": {driver.OWNER_LABEL: state["owner"]}, "User": "65532:65532", "Env": []},
                               "HostConfig": {"ReadonlyRootfs": True, "NetworkMode": "none", "Memory": 536870912,
                                              "NanoCpus": 2000000000, "PidsLimit": 128, "CapDrop": ["ALL"],
                                              "SecurityOpt": ["no-new-privileges"], "Tmpfs": {"/tmp": "rw,nosuid,nodev,noexec,size=256m,uid=65532,gid=65532,mode=0700"}},
                               "Mounts": [{"Source": str(context.resolve()), "Destination": "/inputs", "RW": False, "Type": "bind"}]}]
                    if extra_mount is not None:
                        result[0]["Mounts"].append(extra_mount)
                return SimpleNamespace(stdout=json.dumps(result).encode())
            return SimpleNamespace(stdout=b"controlled tool version\n")
        def run(arguments, log, **kwargs):
            commands.append((list(map(str, arguments)), kwargs["timeout"]))
            log.write_bytes(b"PRIVATE_UNCONTROLLED_GUEST_STDERR\n" if missing_stream else
                            b"ASM_CANONICAL_GUEST=" + json.dumps(guest).encode() + b"\n" + raw)
            if late_runtime:
                clock["now"] = budget.deadline_ns + 1
            return {"outcome": "fail" if runtime_failed else "pass", "exit_code": 1 if runtime_failed else 0}
        def collect(arguments, filename, destination, limits, **kwargs):
            raise AssertionError("Stopped-container tmpfs evidence no longer exists.")
        def retain(source, destination, **kwargs):
            data = source.read_bytes()
            need = len(data) <= kwargs.get("limit", 1048576)
            self.assertTrue(need)
            with destination.open("xb") as stream:
                stream.write(data)
            return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        config = {"rootfs": {"diff_ids": []}, "config": {"Env": []}}
        observations = SimpleNamespace(IMAGE_TAR_BYTES=1, IMAGE_TAR_SHA="a" * 64, IMAGE_ZIP_BYTES=1, IMAGE_ZIP_SHA="b" * 64,
            extract_zip_member=lambda archive, output, *args: output.write_bytes(b"x"), image_archive_contract=lambda archive: config,
            retain_host_file=retain)
        modules = SimpleNamespace(observations=observations, combined=SimpleNamespace(__file__="controlled SDK",
                                     command=command, bounded_process=run, collect_file=collect))
        def build(archive, context, **kwargs):
            if build_failed:
                (context / "canonical-build-failure.json").write_text('{"outcome":"fail"}\n')
                (context / "canonical-build-failure.log").write_bytes(b"controlled compiler failure\n")
                raise ValueError("Controlled build failure.")
            target = context / "canonical-build"
            target.mkdir()
            for name in (*canonical_riscv_build.OUTPUTS, "manifest.json"):
                (target / name).write_bytes(b"controlled artifact bytes")
            return {"outcome": "pass"}
        original_file, original_identity = driver.bounded_file, driver.identity
        def read(path, maximum):
            if str(path).startswith("/proc/sys/fs/binfmt_misc/"):
                return b"enabled\ninterpreter /fixed/qemu\n"
            return original_file(path, maximum)
        def identify(path):
            return {"bytes": 1, "sha256": "c" * 64} if str(path) == "/usr/bin/qemu-riscv64-static" else original_identity(path)
        original_ns = time.monotonic_ns
        now = original_ns()
        clock = {"now": now}
        budget = driver.Budget(now, now + 600000000000)
        with patch.object(driver, "context_contract", return_value=(guest["inputs"], modules)), \
                patch.object(driver, "sdk_modules", return_value=modules), patch.object(driver, "build_contract", return_value={}), \
                patch.object(driver, "bounded_file", side_effect=read), patch.object(driver, "identity", side_effect=identify), \
                patch.object(driver.platform, "system", return_value="Linux"), patch.object(driver.platform, "machine", return_value="x86_64"), \
                patch.object(driver.time, "monotonic_ns", side_effect=(lambda: clock["now"]) if late_runtime else original_ns), \
                patch.object(canonical_riscv_build, "prepare_build", side_effect=build):
            result = driver.run_host(base / "image.zip", base / "mhd.tar.gz", base / "sdk", context, output,
                                     guest["diagnostic_revision"], budget)
        return result, json.loads((output / "host-report.json").read_text()), commands, output

    def test_mock_host_charges_late_runtime_and_cleanup_to_original_clock(self):
        with tempfile.TemporaryDirectory() as directory:
            result, report, _, _ = self.host_fixture(Path(directory), late_runtime=True)
            self.assertEqual(result, 1)
            self.assertFalse(report["collector_complete"])
            self.assertFalse(report["cleanup_complete"])
            self.assertGreater(report["host_elapsed_ns"], 600000000000)

    def test_late_output_invalidates_success_before_a_failing_rewrite(self):
        original_ns, original_write, original_unlink = time.monotonic_ns, Path.write_text, Path.unlink
        for failure in (None, "rewrite", "unlink"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                clock = {"now": original_ns()}
                def write(path, text, *args, **kwargs):
                    value = json.loads(text) if path.name == "host-report.json" else None
                    if value is not None and value.get("failure_stage") == "late-output" and failure == "rewrite":
                        raise OSError("Controlled late receipt rewrite failure.")
                    result = original_write(path, text, *args, **kwargs)
                    if value is not None and value.get("collector_complete") is True:
                        clock["now"] = value["deadline_ns"] + 1
                    return result
                def unlink(path, *args, **kwargs):
                    if path.name == "host-report.json" and failure == "unlink":
                        raise OSError("Controlled late receipt invalidation failure.")
                    return original_unlink(path, *args, **kwargs)
                with patch.object(driver.time, "monotonic_ns", side_effect=lambda: clock["now"]), \
                        patch.object(Path, "write_text", new=write), patch.object(Path, "unlink", new=unlink):
                    if failure is None:
                        result, report, _, _ = self.host_fixture(base)
                        self.assertEqual(result, 1)
                        self.assertFalse(report["collector_complete"])
                        self.assertEqual(report["failure_stage"], "late-output")
                    else:
                        with self.assertRaises(OSError):
                            self.host_fixture(base)
                if failure == "rewrite":
                    self.assertFalse((base / "output/host-report.json").exists())

    def test_mock_host_retains_bounded_build_failure_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            result, report, _, output = self.host_fixture(Path(directory), build_failed=True)
            self.assertEqual(result, 1)
            self.assertEqual(report["failure_stage"], "build")
            self.assertEqual((output / "canonical-build-failure.log").read_bytes(), b"controlled compiler failure\n")
            self.assertEqual(json.loads((output / "canonical-build-failure.json").read_text()), {"outcome": "fail"})

    def test_mock_host_retains_oom_state_when_guest_cannot_emit_after_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            result, report, _, output = self.host_fixture(Path(directory), runtime_failed=True, oom_killed=True, missing_stream=True)
            self.assertEqual(result, 1)
            self.assertEqual(report["container_state_before_cleanup"],
                             {"Running": False, "OOMKilled": True, "ExitCode": 137, "Dead": False})
            self.assertEqual(report["guest_after_snapshot"], "missing")
            self.assertFalse((output / "qualification.json").exists())
            self.assertTrue(all(b"PRIVATE_" not in path.read_bytes() for path in output.iterdir() if path.is_file()))

    def test_mock_host_accepts_only_the_fixed_optional_tmpfs_mount(self):
        for mount, expected in (({"Type": "tmpfs", "Source": "", "Destination": "/tmp", "RW": True}, 0),
                                ({"Type": "volume", "Source": "/private", "Destination": "/evidence", "RW": True}, 1)):
            with self.subTest(mount=mount), tempfile.TemporaryDirectory() as directory:
                result, _, _, _ = self.host_fixture(Path(directory), extra_mount=mount)
                self.assertEqual(result, expected)

    def test_mock_host_joins_controlled_records_and_keeps_runtime_cap_180(self):
        with tempfile.TemporaryDirectory() as directory:
            result, report, commands, output = self.host_fixture(Path(directory))
            self.assertEqual(result, 0)
            self.assertTrue(report["collector_complete"])
            self.assertTrue(report["cleanup_complete"])
            attached = [timeout for arguments, timeout in commands if "--attach" in arguments]
            self.assertEqual(len(attached), 1)
            self.assertLessEqual(attached[0], 180)
            self.assertTrue((output / "server_package.log").is_file())

    def test_mock_host_never_publishes_invalid_provider_text(self):
        with tempfile.TemporaryDirectory() as directory:
            result, report, commands, output = self.host_fixture(Path(directory), bad_trace=True)
            self.assertEqual(result, 1)
            self.assertFalse(report["collector_complete"])
            self.assertTrue(report["cleanup_complete"])
            self.assertEqual(report["rejected_trace"]["reason"], "invalid-controlled-records")
            self.assertFalse((output / "server_package.log").exists())
            self.assertTrue(all(b"PRIVATE_PROVIDER_TEXT" not in path.read_bytes() for path in output.iterdir() if path.is_file()))

    def test_mock_host_retains_collection_after_runtime_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            result, report, commands, output = self.host_fixture(Path(directory), runtime_failed=True)
            self.assertEqual(result, 1)
            self.assertEqual(report["failure_stage"], "runtime")
            self.assertTrue(report["cleanup_complete"])
            self.assertTrue((output / "qualification.json").is_file())
            self.assertTrue((output / "server_package.log").is_file())

    def test_actual_materialization_freezes_modes_before_receipt_hashes(self):
        sys.path.insert(0, str(ROOT / "tools"))
        import registry
        import release
        import riscv64_combined
        methods = [driver.METHOD] + ["test_fixture_" + str(index) for index in range(15)]
        source = {"server/test_runtime.py": (("class RuntimeTests:\n" + "".join(
            "    def " + name + "(self): pass\n" for name in methods)).encode(), 0o644)}
        sdk_source = {name: (b"# exact mock SDK bytes\n", 0o644) for name in driver.SDK_FILES}
        runner = {name: (b"# exact mock driver bytes\n", 0o644) for name in driver.DRIVER_FILES}
        observer = {"tools/diagnostics/canonical_libpq_trace.c": (b"/* observer */\n", 0o644),
                    "tests/riscv64/test_canonical_trace.py": (b"# typed fixtures\n", 0o644)}
        def files(repository, revision, path, includes):
            if revision == driver.SDK_REVISION:
                return sdk_source
            if revision == driver.CANONICAL:
                return source
            return observer if "tools/diagnostics/canonical_libpq_trace.c" in includes else runner
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            release.materialize(sdk_source, base / "sdk")
            with patch.object(driver, "sdk_modules", return_value=SimpleNamespace(combined=riscv64_combined)), \
                    patch.object(registry, "git_files", side_effect=files), \
                    patch.object(registry, "git_output", return_value=b""), \
                    patch.object(release, "resolve_commit", return_value="a" * 40):
                now = time.monotonic_ns()
                budget = driver.Budget(now, now + 600000000000)
                driver.prepare_context(base / "context", "a" * 40, base / "sdk", budget)
                receipt, _ = driver.context_contract(base / "context", budget)
                self.assertEqual(receipt["diagnostic_revision"], "a" * 40)
                path = base / "context/source/server/test_runtime.py"
                self.assertEqual(path.stat().st_mode & 0o777, 0o444)
                path.chmod(0o644)
                with self.assertRaises(ValueError):
                    driver.context_contract(base / "context", budget)

    def test_container_arguments_keep_original_resource_and_isolation_bounds(self):
        values = driver.container_arguments(Path("/owned/context"), "owned-id", "abc")
        self.assertEqual(values[values.index("--memory") + 1], "512m")
        self.assertEqual(values[values.index("--cpus") + 1], "2")
        self.assertEqual(values[values.index("--pids-limit") + 1], "128")
        self.assertIn("--read-only", values)
        self.assertIn("/tmp:rw,nosuid,nodev,noexec,size=256m,uid=65532,gid=65532,mode=0700", values)
        self.assertEqual(values[values.index("--network") + 1], "none")
        self.assertIn("type=bind,src=/owned/context,dst=/inputs,readonly", values)
        self.assertNotIn("--privileged", values)

    def test_shared_budget_keeps_cleanup_reserve_and_rejects_reset(self):
        with patch.object(driver.time, "monotonic_ns", return_value=100000000000):
            budget = driver.Budget(1000000000, 601000000000)
            self.assertEqual(budget.remaining(600), 411)
            self.assertEqual(budget.remaining(120), 120)
            self.assertEqual(budget.remaining(600, cleanup=True), 501)
            with self.assertRaises(ValueError):
                driver.Budget(1000000000, 701000000000)
        with patch.object(driver.time, "monotonic_ns", return_value=601000000001):
            with self.assertRaises(ValueError):
                budget.remaining(1, cleanup=True)

    def test_collector_retains_all_refusals_without_qualifying_the_workload(self):
        values = http_records()
        for value in values[:6]:
            value.update(status=503, bytes_equal=False, media_ok=False)
        result = driver.http_contract(values)
        self.assertEqual(result, {"requests": 8, "complete": 8, "application_passed": False, "availability_failures": 6})
        self.assertEqual(driver.http_contract(http_records())["application_passed"], True)

    def test_cohort_rejects_missing_duplicate_or_ambiguous_records(self):
        samples = [http_records()[:-1], http_records() + [http_records()[0]]]
        for field, value in (("ordinal", True), ("route", 0), ("status", True),
                             ("bytes", 4194305), ("sha256", "not-a-digest"),
                             ("elapsed_ns", -1), ("transport", "provider text"), ("cache_ok", 1)):
            changed = http_records()
            changed[0][field] = value
            samples.append(changed)
        for values in samples:
            with self.subTest(values=values[0]), self.assertRaises(ValueError):
                driver.http_contract(values)

    def test_resource_snapshots_keep_cumulative_peak_and_nonzero_oom_values(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            values = {"cpu.max": "200000 100000\n", "cpu.stat": CPU_STAT,
                      "memory.events": "oom 1\noom_kill 0\n", "memory.current": "1000\n",
                      "memory.peak": "2000\n", "memory.max": "536870912\n"}
            for name, text in values.items():
                (base / name).write_text(text)
            before = driver.snapshot(base, "before")
            (base / "memory.current").write_text("800\n")
            (base / "memory.peak").write_text("3000\n")
            (base / "cpu.stat").write_text(CPU_STAT.replace("usage_usec 161753", "usage_usec 161763"))
            after = driver.snapshot(base, "after")
            driver.snapshot_contract(before, after)
            self.assertEqual(after["files"]["memory.peak"], "3000\n")
            self.assertEqual(before["files"]["memory.events"], "oom 1\noom_kill 0\n")

    def test_resource_snapshot_rejects_duplicate_counters_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for name, text in {"cpu.max": "200000 100000\n", "cpu.stat": CPU_STAT,
                               "memory.events": "oom 0\noom_kill 0\n", "memory.current": "1\n", "memory.peak": "1\n",
                               "memory.max": "536870912\n"}.items():
                (base / name).write_text(text)
            for name, text in (("memory.events", "oom 0\noom 1\n"),
                               ("cpu.stat", "x" * 8193)):
                old = (base / name).read_bytes()
                (base / name).write_text(text)
                with self.subTest(name=name), self.assertRaises(ValueError):
                    driver.snapshot(base, "before")
                (base / name).write_bytes(old)

    def test_real_dotted_cpu_keys_and_memory_overshoot_remain_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            values = {"cpu.max": "200000 100000\n", "cpu.stat": CPU_STAT + "example.gauge 2\n",
                      "memory.events": "oom 1\noom_kill 1\n", "memory.current": "540000000\n",
                      "memory.peak": "550000000\n", "memory.max": "536870912\n"}
            for name, text in values.items():
                (base / name).write_text(text)
            before = driver.snapshot(base, "before")
            (base / "cpu.stat").write_text(CPU_STAT + "example.gauge 1\n")
            after = driver.snapshot(base, "after")
            driver.snapshot_contract(before, after)
            assessment = driver.resource_assessment(before, after)
            self.assertTrue(assessment["configured_budget"])
            self.assertTrue(assessment["peak_exceeded_budget"])
            self.assertIn("core_sched.force_idle_usec 0", before["files"]["cpu.stat"])
            (base / "cpu.max").write_text("300000 100000\n")
            changed = driver.snapshot(base, "after")
            self.assertFalse(driver.resource_assessment(before, changed)["configured_budget"])

    def test_http_reader_keeps_partial_digest_and_absolute_deadline(self):
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nfirst")
            observation = {}
            with self.assertRaises(TimeoutError):
                driver.read_http(reader, maximum=10, deadline=time.monotonic() + 0.05, observation=observation)
            self.assertEqual(observation["bytes"], 5)
            self.assertEqual(observation["sha256"], hashlib.sha256(b"first").hexdigest())

    def test_http_reader_keeps_inactivity_timeout_with_a_larger_outer_deadline(self):
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nfirst")
            observation, started = {}, time.monotonic()
            with self.assertRaises(TimeoutError):
                driver.read_http(reader, maximum=10, deadline=started + 0.5, inactivity=0.03, observation=observation)
            self.assertEqual(observation["bytes"], 5)
            self.assertLess(time.monotonic() - started, 0.2)

    def test_http_reader_refuses_oversized_body_and_preserves_exact_bytes(self):
        for declared, body, maximum, accepted in ((2, b"x\n", 2, True), (3, b"", 2, False)):
            reader, writer = socket.socketpair()
            with reader, writer:
                writer.sendall(f"HTTP/1.1 200 OK\r\nContent-Length: {declared}\r\n\r\n".encode() + body)
                observation = {}
                if accepted:
                    code, _, result = driver.read_http(reader, maximum=maximum, deadline=time.monotonic() + 0.5,
                                                       observation=observation)
                    self.assertEqual((code, result), (200, b"x\n"))
                else:
                    with self.assertRaises(ValueError):
                        driver.read_http(reader, maximum=maximum, deadline=time.monotonic() + 0.5,
                                         observation=observation)

    def test_budget_receipt_cannot_reset_or_expand_the_shared_deadline(self):
        with patch.object(driver.time, "monotonic_ns", return_value=1000000000):
            budget = driver.Budget(1000000000, 601000000000)
            driver.budget_contract({"started_ns": 1000000000, "deadline_ns": 601000000000}, budget)
            with self.assertRaises(ValueError):
                driver.budget_contract({"started_ns": 2000000000, "deadline_ns": 602000000000}, budget)


if __name__ == "__main__":
    unittest.main()
