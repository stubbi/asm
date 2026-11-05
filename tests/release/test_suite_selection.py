"""Keep native CLI qualification separate from cross-host package checks.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

from collections import Counter
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import release


class TestSuiteSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-test-selection-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        (self.directory / "Makefile").write_bytes((ROOT / "Makefile").read_bytes())
        self.events = self.directory / "executed"
        for relative, name in (("tests/test_first_cli.py", "first-cli"),
                               ("tests/test_second_cli.py", "second-cli"),
                               ("tests/macos/test_native.py", "macos-cli"),
                               ("tests/packages/test_reference.py", "package"),
                               ("tests/registry/test_format.py", "registry"),
                               ("tests/release/test_release.py", "release")):
            path = self.directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f'''import os
from pathlib import Path
import unittest

class FixtureTests(unittest.TestCase):
    def test_selected_case_runs(self):
        with Path(os.environ["ASM_SUITE_EVENTS"]).open("a") as stream:
            stream.write({name!r} + "\\n")
        self.assertNotEqual(os.environ.get("ASM_SUITE_FAIL"), {name!r}, "{name} gate failed")
''')
        # This package deliberately permits recursive discovery, as the real
        # reference-package directory does. Native CLI selection must exclude it.
        (self.directory / "tests/packages/__init__.py").write_text("")
        package = self.directory / "tests/packages/test_reference.py"
        with package.open("a") as stream:
            stream.write('''
    @unittest.skip("unsupported native Windows runtime on this fixture host")
    def test_cross_host_runtime(self):
        self.fail("an unsupported runtime must never execute")
''')
        (self.directory / "tests/site.test.cjs").write_text('''
const fs = require("node:fs");
const test = require("node:test");
test("site gate", () => {
  fs.appendFileSync(process.env.ASM_SUITE_EVENTS, "site\\n");
  if (process.env.ASM_SUITE_FAIL === "site") throw new Error("site gate failed");
});
''')

    def make(self, target, *, operating_system="Linux", fail=None, pythonpath=None):
        environment = dict(os.environ, ASM_SUITE_EVENTS=str(self.events))
        for name in ("MAKEFLAGS", "GNUMAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "ASM_SUITE_FAIL"):
            environment.pop(name, None)
        if fail is not None:
            environment["ASM_SUITE_FAIL"] = fail
        if pythonpath is not None:
            environment["PYTHONPATH"] = pythonpath
        # Exercise the actual recipes with small real unittest/Node suites.
        # The CLI build is outside this fixture's suite-selection contract.
        return subprocess.run(["make", "--no-print-directory", "-o", "build/asm",
                               f"HOST_OS={operating_system}", "HOST_ARCH=aarch64", "ARCH=aarch64",
                               f"PYTHON={sys.executable}", "TRUSTED_DISTRIBUTION=0", target],
                              cwd=self.directory, env=environment, capture_output=True,
                              text=True, timeout=30)

    def executed(self):
        return Counter(self.events.read_text().splitlines()) if self.events.exists() else Counter()

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))

    def test_linux_native_suite_runs_every_root_module_without_cross_host_skips(self):
        result = self.make("test")
        self.assert_success(result)
        self.assertEqual(self.executed(), Counter({"first-cli": 1, "second-cli": 1}))
        evidence = release.native_test_result((result.stdout + result.stderr).encode(), "tests")
        self.assertEqual(evidence["tests_run"], 2)
        self.assertEqual(evidence["skipped"], 0)

    def test_darwin_keeps_the_native_suite(self):
        result = self.make("test", operating_system="Darwin")
        self.assert_success(result)
        self.assertEqual(self.executed(), Counter({"macos-cli": 1}))
        evidence = release.native_test_result((result.stdout + result.stderr).encode())
        self.assertEqual(evidence["tests_run"], 1)
        self.assertEqual(evidence["skipped"], 0)

    def test_linux_suite_preserves_import_paths_with_spaces(self):
        result = self.make("test", pythonpath=str(self.directory / "extra modules"))
        self.assert_success(result)
        self.assertEqual(self.executed(), Counter({"first-cli": 1, "second-cli": 1}))

    def test_package_gate_runs_cases_and_keeps_unsupported_runtime_visible(self):
        result = self.make("package-test")
        self.assert_success(result)
        self.assertEqual(self.executed(), Counter({"package": 1}))
        self.assertIn("unsupported native Windows runtime", result.stderr)
        self.assertIn("OK (skipped=1)", result.stderr)
        with self.assertRaises(registry.RegistryError):
            release.native_test_result((result.stdout + result.stderr).encode(), "tests")

    def test_check_executes_cli_packages_and_all_existing_gates(self):
        result = self.make("check")
        self.assert_success(result)
        self.assertEqual(self.executed(), Counter({"first-cli": 1, "second-cli": 1,
                                                  "package": 1, "registry": 1,
                                                  "release": 1, "site": 1}))
        self.assertIn("unsupported native Windows runtime", result.stderr)

    def test_package_failure_fails_the_aggregate_check(self):
        result = self.make("check", fail="package")
        self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual(self.executed(), Counter({"first-cli": 1, "second-cli": 1, "package": 1}))
        self.assertIn("package gate failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
