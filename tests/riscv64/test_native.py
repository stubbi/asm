"""Required RISC-V CLI behavior. A missing executable is a failure.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ASM = Path(os.environ.get("ASM_RISCV64_CLI", ROOT / "build/asm-riscv64-linux"))


class Riscv64CliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ASM.is_file():
            raise AssertionError(f"Required RISC-V CLI is absent: {ASM}")
        header = ASM.read_bytes()[:64]
        if len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01":
            raise AssertionError("Required CLI must be a little-endian ELF64 executable")
        if struct.unpack_from("<H", header, 18)[0] != 243:
            raise AssertionError("Required CLI must declare ELF EM_RISCV")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-riscv64-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)

    def cli(self, *arguments, cwd=None, code=0):
        result = subprocess.run([str(ASM), *map(str, arguments)], cwd=cwd or self.work,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        return result

    def test_host_is_riscv64_with_the_declared_linux_build_targets(self):
        self.assertEqual(json.loads(self.cli("targets", "--json").stdout),
                         {"host": "riscv64-linux", "targets": ["x86_64-linux", "aarch64-linux", "riscv64-linux"]})

    def test_first_project_runs_and_tests(self):
        project = self.work / "first project 世界"
        self.cli("new", project)
        self.assertEqual(self.cli("run", cwd=project).stdout, "Hello from asm!\n")
        self.assertTrue(json.loads(self.cli("test", "--json", cwd=project).stdout)["ok"])
        header = (project / "build/app").read_bytes()[:64]
        self.assertEqual(struct.unpack_from("<H", header, 18)[0], 243)
        # The freestanding template uses RV64I and the soft-float LP64 ABI.
        self.assertEqual(struct.unpack_from("<I", header, 48)[0] & 7, 0)

    def test_unsupported_target_preserves_existing_output(self):
        project = self.work / "project"
        self.cli("new", project)
        self.cli("build", cwd=project)
        previous = (project / "build/app").read_bytes()
        self.cli("build", "--target", "aarch64-linux", cwd=project, code=2)
        self.assertEqual((project / "build/app").read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()
