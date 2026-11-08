"""Check the production smoke gate's isolation and bounded failure evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/check_published_install.py"
sys.path.insert(0, str(ROOT / "tools"))


class PublishedInstallTests(unittest.TestCase):
    def module(self):
        specification = importlib.util.spec_from_file_location("published_install", SCRIPT)
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        return module

    def test_wrong_native_host_fails_before_network_and_retains_evidence(self):
        wrong = "x86_64-linux" if platform.system() == "Darwin" else "aarch64-macos"
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "evidence.json"
            result = subprocess.run([sys.executable, str(SCRIPT), "--expected-target", wrong,
                                     "--output", str(evidence)], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            value = json.loads(evidence.read_text())
            self.assertEqual(value["status"], "error")
            self.assertIn("native host", value["error"])
            self.assertEqual(value["commands"], [])

    def test_clean_environment_excludes_credentials_and_tool_configuration(self):
        module = self.module()
        with patch.dict(os.environ, {"GH_TOKEN": "secret", "GITHUB_TOKEN": "secret",
                                    "GH_HOST": "example.invalid", "CURL_CA_BUNDLE": "bad",
                                    "PYTHONPATH": "bad", "https_proxy": "http://proxy.invalid:8080"}, clear=True):
            environment = module.clean_environment(Path("/tmp/private-home"))
        self.assertEqual(set(environment), {"HOME", "PATH", "LC_ALL", "https_proxy"})
        self.assertEqual(environment["HOME"], "/tmp/private-home")
        self.assertEqual(environment["https_proxy"], "http://proxy.invalid:8080")

    def test_unbounded_or_control_character_proxy_is_refused(self):
        module = self.module()
        for value in ("x" * 2049, "http://proxy.invalid/\nvalue"):
            with self.subTest(value=value[:20]), patch.dict(os.environ, {"https_proxy": value}, clear=True):
                with self.assertRaisesRegex(ValueError, "proxy"):
                    module.clean_environment(Path("/tmp/private-home"))

    def test_command_timeout_retains_observed_output_and_exit(self):
        module = self.module()
        evidence = {"commands": []}
        with tempfile.TemporaryDirectory() as directory:
            started = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                module.command([sys.executable, "-c", "import time; print('started', flush=True); time.sleep(10)"],
                               cwd=Path(directory), environment=module.clean_environment(Path(directory)),
                               evidence=evidence, timeout=0.8, deadline=started + 5)
            self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(evidence["commands"][0]["stdout"], "started\n")
        self.assertTrue(evidence["commands"][0]["timed_out"])
        self.assertIsInstance(evidence["commands"][0]["exit_code"], int)

    def test_command_output_limit_stops_the_child_and_retains_failure(self):
        module = self.module()
        evidence = {"commands": []}
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "output limit"):
                module.command([sys.executable, "-c", "print('x' * 100000)"],
                               cwd=Path(directory), environment=module.clean_environment(Path(directory)),
                               evidence=evidence, timeout=5, deadline=time.monotonic() + 5, output_limit=32)
        self.assertTrue(evidence["commands"][0]["output_limit_exceeded"])
        self.assertLessEqual(len(evidence["commands"][0]["stdout"]), 32)

    def test_observer_failure_and_interruption_kill_and_wait_for_the_child(self):
        module = self.module()
        real_popen = subprocess.Popen
        for failure in (OSError("observer failed"), KeyboardInterrupt()):
            processes = []
            evidence = {"commands": []}
            def start(*arguments, **options):
                process = real_popen(*arguments, **options)
                processes.append(process)
                return process
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as directory:
                with patch.object(module.subprocess, "Popen", side_effect=start), \
                        patch.object(module.selectors.DefaultSelector, "select", side_effect=failure):
                    with self.assertRaises(type(failure)):
                        module.command([sys.executable, "-c", "import time; time.sleep(30)"],
                                       cwd=Path(directory), environment=module.clean_environment(Path(directory)),
                                       evidence=evidence, timeout=5, deadline=time.monotonic() + 5)
                process = processes[0]
                survived = process.poll() is None
                if survived:
                    os.killpg(process.pid, module.signal.SIGKILL)
                    process.wait(timeout=5)
                self.assertFalse(survived, "The child survived a failure in its output observer.")
                self.assertIsInstance(evidence["commands"][0]["exit_code"], int)

    def test_corrupt_installed_bytes_are_refused_before_execution(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "asm"
            executable.write_bytes(b"corrupted")
            executable.chmod(0o755)
            artifact = {"bytes": 9, "sha256": "0" * 64, "kind": "executable", "target": "x86_64-linux"}
            with self.assertRaisesRegex(module.registry.RegistryError, "SHA-256 mismatch"):
                module.installed_identity(executable, {}, artifact)

    def test_installed_symlink_is_refused_without_following_it(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "other"
            target.write_bytes(b"preserve this file")
            executable = Path(directory) / "asm"
            executable.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "unsafe ownership, mode, or links"):
                module.installed_identity(executable, {}, {"bytes": 18})
            self.assertEqual(target.read_bytes(), b"preserve this file")


if __name__ == "__main__":
    unittest.main()
