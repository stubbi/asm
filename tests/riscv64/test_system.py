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
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SystemEvidenceTests(unittest.TestCase):
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
            report = {"schema": 1, "target": "riscv64-linux", "outcome": "pass",
                      "execution_mode": "emulated", "emulation_kind": "system",
                      "native_qualified": False, "release_qualified": False,
                      "host": {"system": "Linux", "machine": "riscv64"},
                      "source": {"commit": "1" * 40, "clean": True},
                      "artifact": {"sha256": hashlib.sha256(b"artifact").hexdigest()},
                      "emulator_provenance": {"sha256": "2" * 64, "origin": "host-provided"},
                      "checks": {name: {"outcome": "pass"} for name in
                                 ("artifact", "runtime", "toolchain", "make_test", "focused_tests", "artifact_binding")}}
            for name in ("make_test", "focused_tests"):
                report["checks"][name].update(tests_run=1, skipped_checks=False, exit_code=0)
            module.bind_guest(report, artifact, "1" * 40, "2" * 64)
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
