"""Check the server's distributable source package without network access.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "experiments/assembly-server"
SPEC = importlib.util.spec_from_file_location("asm_registry", ROOT / "tools/registry.py")
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)


class ServerPackageTests(unittest.TestCase):
    def test_server_source_package_contains_standalone_build_and_test_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            archives = []
            for filename in ("first.tar.gz", "second.tar.gz"):
                output = Path(temporary) / filename
                result = subprocess.run(
                    [sys.executable, str(ROOT / "tools/registry.py"), "pack", str(SOURCE),
                     "--name", "owner/asm-server", "--version", "0.1.0",
                     "--target", "x86_64-linux", "--output", str(output)],
                    cwd=temporary, capture_output=True, text=True, timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                archives.append(output.read_bytes())

            self.assertEqual(archives[0], archives[1])
            files = registry.read_archive(archives[0])
            registry.validate_project(files, "owner/asm-server", "0.1.0", "x86_64-linux")
            required = {
                "asm.toml", "LICENSE", "README.md", "DEPENDENCIES.md", "Makefile",
                "server.s", "abi-check.c", "guard.sql", "search.sql",
                "local_postgres.py", "package.py", "test_package.py", "test_fixture.py", "test_server.py", "test_runtime_versions.py",
                "fixtures/0001_registry.sql", "fixtures/p00.json",
            }
            self.assertTrue(required <= files.keys(), required - files.keys())
            self.assertEqual(files["LICENSE"], (ROOT / "LICENSE").read_bytes())
            self.assertFalse(any(path.startswith("build/") for path in files))


if __name__ == "__main__":
    unittest.main()
