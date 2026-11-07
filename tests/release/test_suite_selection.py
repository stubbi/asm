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

SITE_PYTHON = ("test_site", "test_site_routes", "test_site_dependencies", "test_package_pages", "test_package_activity", "test_discovery",
               "test_discovery_metadata", "test_download_data", "test_registry_explore", "test_registry_stats",
               "test_release_blog", "test_blog_posts", "test_site_docs", "test_count_format", "test_repository_stars",
               "test_target_metadata", "test_artifact_delivery", "test_serve_site", "test_bootstrap", "test_trusted_site")
SITE_NODE = (("site.test.cjs", "site"), ("package-demo.test.cjs", "site-demo"),
             ("package-navigation.test.cjs", "site-package-navigation"), ("discovery.test.cjs", "site-discovery"),
             ("navigation.test.cjs", "site-navigation"), ("repository-stars.test.cjs", "site-stars"))


class TestSuiteSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-test-selection-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        (self.directory / "Makefile").write_bytes((ROOT / "Makefile").read_bytes())
        self.events = self.directory / "executed"
        fixtures = [("tests/test_first_cli.py", "first-cli"), ("tests/test_second_cli.py", "second-cli"),
                    ("tests/macos/test_native.py", "macos-cli"), ("tests/packages/test_reference.py", "package"),
                    ("tests/registry/test_format.py", "registry"), ("tests/release/test_release.py", "release")]
        fixtures.extend(("tests/" + module + ".py", "site-python:" + module) for module in SITE_PYTHON)
        for relative, name in fixtures:
            path = self.directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            class_name = {"test_bootstrap": "BootstrapGenerationTests", "test_trusted_site": "TrustedSiteTests"}.get(path.stem, "FixtureTests")
            path.write_text(f'''import os
from pathlib import Path
import unittest

class {class_name}(unittest.TestCase):
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
        for filename, name in SITE_NODE:
            (self.directory / "tests" / filename).write_text(f'''
const fs = require("node:fs");
const test = require("node:test");
test({name!r}, () => {{
  fs.appendFileSync(process.env.ASM_SUITE_EVENTS, {name!r} + "\\n");
  if (process.env.ASM_SUITE_FAIL === {name!r}) throw new Error({name!r} + " gate failed");
}});
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

    def site_python_events(self):
        return Counter({"site-python:" + module: 1 for module in SITE_PYTHON})

    def linux_events(self):
        return Counter({"first-cli": 1, "second-cli": 1}) + self.site_python_events()

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))

    def test_linux_native_suite_runs_every_root_module_without_cross_host_skips(self):
        result = self.make("test")
        self.assert_success(result)
        self.assertEqual(self.executed(), self.linux_events())
        evidence = release.native_test_result((result.stdout + result.stderr).encode(), "tests")
        self.assertEqual(evidence["tests_run"], 2 + len(SITE_PYTHON))
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
        self.assertEqual(self.executed(), self.linux_events())

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
        self.assertEqual(self.executed(), self.linux_events() + self.site_python_events() +
                         Counter({"package": 1, "registry": 1, "release": 1}) + Counter({name: 1 for _, name in SITE_NODE}))
        self.assertIn("unsupported native Windows runtime", result.stderr)

    def test_site_target_executes_every_shared_page_and_behavior_gate_once(self):
        result = self.make("site-test")
        self.assert_success(result)
        self.assertEqual(self.executed(), self.site_python_events() + Counter({name: 1 for _, name in SITE_NODE}))

    def test_site_python_failure_stops_check_before_registry_and_release_gates(self):
        result = self.make("check", operating_system="Darwin", fail="site-python:test_discovery")
        self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual(self.executed(), Counter({"macos-cli": 1, "package": 1}) + self.site_python_events() +
                         Counter({name: 1 for _, name in SITE_NODE}))
        self.assertIn("site-python:test_discovery gate failed", result.stderr)

    def test_package_failure_fails_the_aggregate_check(self):
        result = self.make("check", fail="package")
        self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual(self.executed(), self.linux_events() + Counter({"package": 1}))
        self.assertIn("package gate failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
