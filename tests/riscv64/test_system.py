"""Host-side evidence guards for the full-system qualification runner.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import json
import importlib.util
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SystemEvidenceTests(unittest.TestCase):
    def test_source_refusal_prevents_generation_and_build(self):
        spec = importlib.util.spec_from_file_location("system_runner", ROOT / "tools/riscv64_system.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        script = getattr(module, "guest_qualification_commands", None)
        self.assertTrue(callable(script), "The pre-build guest source guard is absent")
        commit = "1" * 40
        for identity, accepted in (({"commit": "2" * 40, "clean": True}, False),
                                   ({"commit": commit, "clean": False}, False),
                                   ({"commit": commit, "clean": True}, True)):
            with self.subTest(identity=identity), tempfile.TemporaryDirectory() as temporary:
                work = Path(temporary)
                (work / "tools").mkdir()
                (work / "tools/riscv64_test.py").write_text(
                    "from pathlib import Path\n"
                    f"def source_identity(): return {identity!r}\n"
                    "if __name__ == '__main__': Path('qualification.marker').touch()\n")
                (work / "tools/riscv64.py").write_text(
                    "from pathlib import Path\nPath('generation.marker').touch()\n")
                (work / "Makefile").write_text("build/asm-riscv64-linux:\n\ttouch build.marker\n")
                result = subprocess.run(["/bin/bash", "-se"], input=script(commit), cwd=work,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                for marker in ("generation.marker", "build.marker", "qualification.marker"):
                    self.assertEqual((work / marker).exists(), accepted, (identity, marker))

    def test_root_module_metadata_cannot_omit_or_change_a_source(self):
        spec = importlib.util.spec_from_file_location("system_runner", ROOT / "tools/riscv64_system.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(callable(getattr(module, "bind_root_modules", None)), "Root source binding is absent")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "test_alpha.py").write_bytes(b"alpha")
            manifest = {"test_alpha": {"path": "test_alpha.py", "sha256": hashlib.sha256(b"alpha").hexdigest()}}
            module.bind_root_modules(manifest, path)
            (path / "test_beta.py").write_bytes(b"beta")
            with self.assertRaises(ValueError):
                module.bind_root_modules(manifest, path)
            (path / "test_beta.py").unlink()
            (path / "test_alpha.py").write_bytes(b"changed")
            with self.assertRaises(ValueError):
                module.bind_root_modules(manifest, path)

    def test_inherited_output_pipe_obeys_deadline_and_terminates_descendant(self):
        spec = importlib.util.spec_from_file_location("system_runner", ROOT / "tools/riscv64_system.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            runner = module.Runner(path, path)
            marker = path / "descendant-survived"
            code = ("import os,time; p=os.fork(); "
                    "os._exit(0) if p else None; print('descendant-ready',flush=True); time.sleep(2); "
                    f"open({str(marker)!r},'w').write('alive'); os._exit(0)")
            start = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run([sys.executable, "-c", code], "inherited-pipe.log", .5)
            self.assertLess(time.monotonic() - start, 1.5)
            self.assertIn(b"descendant-ready", (path / "inherited-pipe.log").read_bytes())
            time.sleep(2.1)
            self.assertFalse(marker.exists(), "Inherited-pipe descendant survived the deadline")

    def test_guest_startup_timeout_keeps_polling_within_the_boot_deadline(self):
        spec = importlib.util.spec_from_file_location("system_runner", ROOT / "tools/riscv64_system.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        class StartupRunner(module.Runner):
            attempts = 0
            output_limit = False

            def ssh(self, script, name, timeout=60, *, check=True):
                if script == "true\n":
                    self.attempts += 1
                    if self.output_limit:
                        return self.run([sys.executable, "-c", "print('x'*100000)"], name, 10,
                                        check=check, maximum_log_bytes=1024)
                    delay = "import time; time.sleep(1)" if self.attempts == 1 else "pass"
                    return self.run([sys.executable, "-c", delay], name,
                                    .05 if self.attempts == 1 else 10, check=check)
                return self.run([sys.executable, "-c", "pass"], name, 10)

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            runner = StartupRunner(path, path)
            runner.qemu = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                            start_new_session=True)
            try:
                try:
                    runner.ready()
                except (ValueError, subprocess.TimeoutExpired) as error:
                    self.fail(f"Transient startup timeout aborted the boot deadline: {error}")
                self.assertEqual(runner.attempts, 2)
                self.assertEqual(len(list(path.glob("ssh-readiness-*.log"))), 2)
            finally:
                runner.stop()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            runner = StartupRunner(path, path)
            runner.output_limit = True
            runner.qemu = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                            start_new_session=True)
            try:
                with self.assertRaisesRegex(ValueError, "output exceeds"):
                    runner.ready()
                self.assertEqual(runner.attempts, 1)
            finally:
                runner.stop()

    def test_unbounded_child_output_fails_and_retains_a_bounded_log(self):
        spec = importlib.util.spec_from_file_location("system_runner", ROOT / "tools/riscv64_system.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            runner = module.Runner(path, path)
            with self.assertRaises(ValueError):
                runner.run([sys.executable, "-c", "import sys; sys.stdout.write('x'*100000)"],
                           "noisy.log", 5, maximum_log_bytes=1024)
            self.assertLessEqual((path / "noisy.log").stat().st_size, 1024)
            with self.assertRaises(ValueError):
                runner.run([sys.executable, "-c", "import sys; sys.stderr.write('x'*100000)"],
                           "binary", 5, stderr_name="errors.log", maximum_log_bytes=1024)
            self.assertEqual((path / "binary").read_bytes(), b"")
            self.assertLessEqual((path / "errors.log").stat().st_size, 1024)

    def test_initial_report_preserves_unrun_checks_before_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            child = subprocess.run([sys.executable, str(ROOT / "tools/riscv64_system.py"),
                                    "--initialize-only", "--output", temporary,
                                    "--commit", "1" * 40], capture_output=True, text=True, timeout=10)
            self.assertEqual(child.returncode, 0, child.stderr)
            report = json.loads((Path(temporary) / "report.json").read_text())
            self.assertEqual(report["outcome"], "fail")
            self.assertFalse(report["native_qualified"])
            self.assertFalse(report["release_qualified"])
            self.assertTrue(report["checks"])
            self.assertEqual({item["outcome"] for item in report["checks"].values()}, {"not-run"})

    def test_guest_success_cannot_hide_wrong_artifact_or_source_or_skipped_checks(self):
        spec = importlib.util.spec_from_file_location("system_runner", ROOT / "tools/riscv64_system.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(callable(getattr(module, "bind_guest", None)), "Guest evidence binding is absent")
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "asm"
            artifact.write_bytes(b"artifact")
            report = {"schema": 2, "qualification_scope": "native-cli-behavior",
                      "target": "riscv64-linux", "outcome": "pass",
                      "execution_mode": "emulated", "emulation_kind": "system",
                      "native_qualified": False, "release_qualified": False,
                      "host": {"system": "Linux", "machine": "riscv64"},
                      "source": {"commit": "1" * 40, "clean": True},
                      "artifact": {"sha256": hashlib.sha256(b"artifact").hexdigest()},
                      "emulator_provenance": {"sha256": "2" * 64, "origin": "host-provided"},
                      "checks": {name: {"outcome": "pass"} for name in
                                 ("artifact", "runtime", "toolchain", "make_test", "focused_tests", "artifact_binding")}}
            for name in ("make_test", "focused_tests"):
                report["checks"][name].update(tests_run=1, skipped_checks=False, incomplete_checks=False,
                                              exit_code=0, timed_out=False)
            module.bind_guest(report, artifact, "1" * 40, "2" * 64)
            for field, value in (("outcome", "fail"), ("exit_code", 1), ("timed_out", True),
                                 ("incomplete_checks", True)):
                original = report["checks"]["make_test"][field]
                report["checks"]["make_test"][field] = value
                with self.assertRaises(ValueError):
                    module.bind_guest(report, artifact, "1" * 40, "2" * 64)
                report["checks"]["make_test"][field] = original
            for field, value in (("native_qualified", True), ("outcome", "fail")):
                changed = {**report, field: value}
                with self.assertRaises(ValueError):
                    module.bind_guest(changed, artifact, "1" * 40, "2" * 64)
            with self.assertRaises(ValueError):
                module.bind_guest(report, artifact, "3" * 40, "2" * 64)
            with self.assertRaises(ValueError):
                module.bind_guest(report, artifact, "1" * 40, "4" * 64)
            report["checks"]["make_test"]["skipped_checks"] = True
            with self.assertRaises(ValueError):
                module.bind_guest(report, artifact, "1" * 40, "2" * 64)
            report["checks"]["make_test"]["skipped_checks"] = False
            artifact.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                module.bind_guest(report, artifact, "1" * 40, "2" * 64)


if __name__ == "__main__":
    unittest.main()
