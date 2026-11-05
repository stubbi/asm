"""Execute native RV64IM/LP64 ALU and private-ABI checks; never skip a missing runtime.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ASM = Path(os.environ.get("ASM_RISCV64_CLI", ROOT / "build/asm-riscv64-linux"))
PREPARED_OPERATIONS = '''.section .text
.global alu_mov32, alu_add32, alu_sub32, alu_lsr32, alu_udiv32
alu_mov32:
    mov w9, w0
    ret
alu_add32:
    add w9, w0, w1
    ret
alu_sub32:
    sub w9, w0, w1
    ret
alu_lsr32:
    lsr w9, w0, #1
    ret
alu_udiv32:
    udiv w9, w0, w1
    ret
'''


def build_harness(directory, assembler=None, linker=None):
    """Build actual native instructions. This helper also permits cross-assembly."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    assembler = assembler or os.environ.get("ASM_RISCV64_AS", os.environ.get("AS", "as"))
    linker = linker or os.environ.get("ASM_RISCV64_LD", os.environ.get("LD", "ld"))
    for executable in (assembler, linker):
        if shutil.which(str(executable)) is None:
            raise AssertionError(f"Required RISC-V tool is absent: {executable}")
    specification = importlib.util.spec_from_file_location("alu_riscv64_preparer", ROOT / "tools/riscv64.py")
    preparer = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(preparer)
    fixture = directory / "alu_operations.s"
    fixture.write_text(PREPARED_OPERATIONS)
    source = directory / "alu.s"
    source.write_text((ROOT / "tests/riscv64/alu_harness.s").read_text() + preparer.prepare(fixture))
    cli_object, harness_object = directory / "cli.o", directory / "alu.o"
    for input_path, output_path in ((ROOT / "cli/riscv64/asm.s", cli_object), (source, harness_object)):
        subprocess.run([str(assembler), "--fatal-warnings", "-march=rv64im", "-mabi=lp64", "-mno-relax",
                        "-o", str(output_path), str(input_path)], cwd=ROOT, check=True,
                       capture_output=True, text=True, timeout=60)
    executable = directory / "alu-harness"
    subprocess.run([str(linker), "--no-relax", "-z", "noexecstack", "-z", "relro", "-z", "now",
                    "--build-id=none", "-e", "alu_test_start", "-o", str(executable),
                    str(cli_object), str(harness_object)], cwd=ROOT, check=True,
                   capture_output=True, text=True, timeout=30)
    return executable


class Riscv64AluTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if platform.system() != "Linux" or platform.machine() != "riscv64":
            raise AssertionError("Required Linux riscv64 execution environment is absent; cross-assembly is not execution")
        if not ASM.is_file():
            raise AssertionError(f"Required RISC-V CLI artifact is absent: {ASM}")
        cls.temporary = tempfile.TemporaryDirectory(prefix="riscv64-alu-", dir=ROOT / "build")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.executable = build_harness(cls.temporary.name)
        header = cls.executable.read_bytes()[:64]
        if len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01":
            raise AssertionError("ALU harness must be little-endian ELF64")
        if struct.unpack_from("<HH", header, 16) != (2, 243) or struct.unpack_from("<I", header, 48)[0] != 0:
            raise AssertionError("ALU harness must declare ET_EXEC, EM_RISCV, and LP64 without extra ELF flags")

    def check_mode(self, mode):
        result = subprocess.run([str(self.executable), mode], capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, f"{mode}: assertion exit {result.returncode}; stderr={result.stderr!r}")
        self.assertEqual((result.stdout, result.stderr), (b"", b""))

    def test_64_bit_arithmetic_carry_overflow_and_logical_flags(self):
        self.check_mode("flags64")

    def test_32_bit_arithmetic_zero_extension_and_logical_flags(self):
        self.check_mode("flags32")

    def test_each_condition_for_every_nzcv_combination(self):
        self.check_mode("conditions")

    def test_unaligned_loads_stores_preserve_every_adjacent_byte_and_flags(self):
        self.check_mode("memory")

    def test_prepared_word_operations_ignore_upper_source_bits(self):
        self.check_mode("prepared")

    def test_public_functions_preserve_private_registers_stack_and_return_address(self):
        self.check_mode("abi")


if __name__ == "__main__":
    unittest.main()
