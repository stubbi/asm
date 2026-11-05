"""Exercise the server's standalone target preparation boundary.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "experiments/assembly-server"
SPEC = importlib.util.spec_from_file_location("server_ports_registry", ROOT / "tools/registry.py")
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)
TARGET_SOURCES = {
    "x86_64-linux": "server.s",
    "aarch64-linux": "aarch64/server.s",
    "riscv64-linux": "riscv64/server.s",
}


class ServerPortPackageTests(unittest.TestCase):
    def prepare(self, source, target, output):
        return subprocess.run(
            [sys.executable, str(source / "package.py"), "--target", target, "--output", str(output)],
            capture_output=True, text=True, timeout=20,
        )

    def test_each_prepared_target_is_a_valid_standalone_asm_source_package(self):
        original = (SOURCE / "asm.toml").read_bytes()
        with tempfile.TemporaryDirectory(prefix="asm-server-ports-") as temporary:
            for target, declared_source in TARGET_SOURCES.items():
                with self.subTest(target=target):
                    output = Path(temporary) / target
                    result = self.prepare(SOURCE, target, output)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    manifest = tomllib.loads((output / "asm.toml").read_text())
                    self.assertEqual(manifest["build"]["target"], target)
                    self.assertEqual(manifest["build"]["source"], declared_source)
                    files = registry.collect_files(output)
                    archive = registry.make_archive(files)
                    contents = registry.read_archive(archive)
                    registry.validate_project(contents, "owner/asm-server", "0.1.0", target)
                    self.assertIn("fixtures/0001_registry.sql", contents)
                    self.assertIn("test_runtime_versions.py", contents)
                    self.assertIn("test_package.py", contents)
                    self.assertEqual(contents["LICENSE"], (ROOT / "LICENSE").read_bytes())
        self.assertEqual((SOURCE / "asm.toml").read_bytes(), original)

    def test_existing_destination_and_unsupported_target_preserve_files(self):
        with tempfile.TemporaryDirectory(prefix="asm-server-existing-") as temporary:
            output = Path(temporary) / "existing"
            output.mkdir()
            marker = output / "user-file"
            marker.write_bytes(b"retain this file\n")
            result = self.prepare(SOURCE, "aarch64-linux", output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_bytes(), b"retain this file\n")
            self.assertEqual([path.name for path in output.iterdir()], ["user-file"])
            absent = Path(temporary) / "unsupported"
            result = self.prepare(SOURCE, "aarch64-macos", absent)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(absent.exists())

    def test_source_link_is_rejected_without_exposing_linked_bytes(self):
        with tempfile.TemporaryDirectory(prefix="asm-server-link-") as temporary:
            base = Path(temporary)
            source = base / "source"
            shutil.copytree(SOURCE, source, ignore=shutil.ignore_patterns("build", "__pycache__"))
            outside = base / "outside.s"
            outside.write_bytes(b"private test sentinel\n")
            (source / "linked.s").symlink_to(outside)
            output = base / "package"
            result = self.prepare(source, "x86_64-linux", output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertEqual(outside.read_bytes(), b"private test sentinel\n")


if __name__ == "__main__":
    unittest.main()
