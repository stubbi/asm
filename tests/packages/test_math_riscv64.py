"""Build and exercise the RV64I math package.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import os
import json
from pathlib import Path
import platform
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "examples/math-riscv64"
sys.path.insert(0, str(ROOT / "tools"))
import registry


def command(variable, default):
    return shlex.split(os.environ.get(variable, default))


def checked_run(arguments, **kwargs):
    result = subprocess.run(arguments, capture_output=True, timeout=30, **kwargs)
    if result.returncode:
        raise AssertionError((result.args, result.returncode, result.stdout, result.stderr))
    return result


class MathRiscv64ArchiveTests(unittest.TestCase):
    def test_source_archive_has_a_usable_riscv_project(self):
        self.assertTrue(PACKAGE.is_dir(), "The RV64I math package is missing")
        archive = registry.make_archive(registry.collect_files(PACKAGE))
        files = registry.read_archive(archive)
        registry.validate_project(files, "stubbi/math", "0.6.0", "riscv64-linux")
        self.assertEqual(files["LICENSE"], (ROOT / "examples/math/LICENSE").read_bytes())
        self.assertIn("src/min.s", files)
        self.assertIn("tests/main.s", files)
        with self.assertRaisesRegex(registry.RegistryError, "target"):
            registry.validate_project(files, "stubbi/math", "0.6.0", "aarch64-linux")


class MathRiscv64NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assembler = command("RISCV64_AS", "riscv64-linux-gnu-as")
        cls.linker = command("RISCV64_LD", "riscv64-linux-gnu-ld")
        cls.compiler = command("RISCV64_CC", "")
        cls.rustc = command("RISCV64_RUSTC", "")
        if cls.rustc:
            required = [cls.rustc[0], cls.linker[0]]
        elif cls.compiler:
            required = [cls.compiler[0], cls.linker[0]]
        else:
            required = [cls.assembler[0], cls.linker[0]]
        missing = [tool for tool in required if not shutil.which(tool)]
        if missing:
            raise unittest.SkipTest("RV64I build tools are unavailable: " + ", ".join(missing))
        (ROOT / "build").mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="math-riscv64-", dir=ROOT / "build")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.work = Path(cls.temporary.name)
        cls.demo = cls.build(PACKAGE / "src/main.s", "demo")
        cls.tests = cls.build(PACKAGE / "tests/main.s", "tests")
        if "QEMU_RISCV64" in os.environ:
            cls.runner = command("QEMU_RISCV64", "")
        elif platform.system() == "Linux" and platform.machine() == "riscv64":
            cls.runner = []
        else:
            emulator = shutil.which("qemu-riscv64") or shutil.which("qemu-riscv64-static")
            cls.runner = [emulator] if emulator else None

    @classmethod
    def build(cls, source, name, *, machine_mode=False):
        obj = cls.work / (name + ".o")
        binary = cls.work / name
        environment = dict(os.environ)
        if cls.rustc:
            wrapper = cls.work / (name + ".rs")
            wrapper.write_text(
                '#![feature(no_core, rustc_attrs)]\n#![allow(internal_features)]\n'
                '#![no_core]\n#![no_main]\n'
                '#[rustc_builtin_macro]\nmacro_rules! global_asm { () => {} }\n'
                '#[rustc_builtin_macro]\nmacro_rules! include_str { () => {} }\n'
                f'global_asm!(include_str!({json.dumps(str(source))}), options(raw));\n')
            environment["RUSTC_BOOTSTRAP"] = "1"
            build = [*cls.rustc, "--target", "riscv64im-unknown-none-elf", "-C", "target-feature=-m,-zmmul",
                     "-C", "relocation-model=static", "--emit=obj", "-o", str(obj), str(wrapper)]
        elif cls.compiler:
            build = [*cls.compiler, "--target=riscv64-linux-gnu", "-march=rv64i", "-mabi=lp64",
                     "-c", "-I", str(PACKAGE), "-o", str(obj), str(source)]
        else:
            build = [*cls.assembler, "--fatal-warnings", "-march=rv64i", "-mabi=lp64",
                     "-I", str(PACKAGE), "-o", str(obj), str(source)]
        checked_run(build, cwd=PACKAGE, env=environment)
        layout = ["-Ttext=0x80000000", "-e", "_start"] if machine_mode else []
        checked_run([*cls.linker, *layout, "-z", "noexecstack", "--build-id=none", "-o", str(binary),
                     str(obj)], cwd=PACKAGE)
        return binary

    def run_binary(self, binary, **kwargs):
        if self.runner is None:
            self.skipTest("RV64I runtime is unavailable; set QEMU_RISCV64 or install QEMU user mode")
        return subprocess.run([*self.runner, str(binary)], cwd=PACKAGE,
                              stderr=subprocess.PIPE, timeout=15, **kwargs)

    def test_binaries_match_the_declared_target_and_have_no_executable_stack(self):
        for binary in (self.demo, self.tests):
            with self.subTest(binary=binary.name):
                data = binary.read_bytes()
                registry.validate_elf(data, "riscv64-linux")
                # RVC and floating-point ABI flags would violate RV64I + LP64.
                self.assertEqual(struct.unpack_from("<I", data, 48)[0], 0)
                self.assertRegex(data, rb"\x05rv64i[0-9]+p[0-9]+\x00")
                with self.assertRaisesRegex(registry.RegistryError, "target"):
                    registry.validate_elf(binary.read_bytes(), "aarch64-linux")

    def test_demo_prints_the_computed_example(self):
        result = self.run_binary(self.demo, stdout=subprocess.PIPE)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, b"min(12, 37) = 12\n", b""))

    def test_unsigned_boundaries_one_bit_inputs_and_calling_convention(self):
        result = self.run_binary(self.tests, stdout=subprocess.PIPE)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_machine_mode_callable_cases_with_semihosting(self):
        """This exercises the routine, separately from the Linux process tests."""
        source = (PACKAGE / "tests/main.s").read_text()
        # QEMU's bare-metal virt boot starts at the load address, not ELF e_entry.
        # Put the caller first without changing the function's source or cases.
        source = source.replace('.include "src/min.s"\n', "", 1)
        source = source.replace("_start:\n", "_start:\n    la sp, .Lmachine_stack_top\n", 1)
        source = source.replace("    li a7, SYS_EXIT\n    ecall\n", "    j .Lsemihost_exit\n")
        source += '\n.include "src/min.s"\n'
        self.run_machine_mode(source, "machine-caller")

    def test_write_loop_handles_injected_short_interrupted_zero_and_error_results(self):
        """Inject only the syscall result; execute the actual write-loop instructions."""
        main = (PACKAGE / "src/main.s").read_text()
        start = main.index(".type .Lwrite_all, @function")
        end = main.index(".size .Lwrite_all, .-.Lwrite_all")
        loop = main[start:end].replace("    ecall\n", "    jal t6, .Lwrite_fixture\n")
        # Each event is (descriptor, buffer offset, pending bytes, syscall result).
        scenarios = {
            "short-interrupted": (17, [(1, 0, 17, -4), (1, 0, 17, 3),
                                         (1, 3, 14, -4), (1, 3, 14, 14)], 0),
            "zero": (17, [(1, 0, 17, 0)], -1),
            "error": (17, [(1, 0, 17, -9)], -1),
            "partial-error": (17, [(1, 0, 17, 3), (1, 3, 14, -5)], -1),
            "overlong-result": (17, [(1, 0, 17, 18)], -1),
            "empty": (0, [], 0),
        }
        for name, (length, events, expected) in scenarios.items():
            with self.subTest(scenario=name):
                source = f'''
.option norelax
.equ SYS_WRITE, 64
.equ EINTR, 4
.section .text
.global _start
_start:
    la sp, .Lmachine_stack_top
    li a0, 1
    la a1, .Lbuffer
    li a2, {length}
    la a3, .Levents
    la a4, .Levents_end
    call .Lwrite_all
    li t0, {expected}
    bne a0, t0, .Lfixture_failure
    bne a3, a4, .Lfixture_failure
    li a0, 0
    j .Lsemihost_exit
.Lfixture_failure:
    li a0, 1
    j .Lsemihost_exit
{loop}
.Lwrite_fixture:
    bgeu a3, a4, .Lfixture_failure
    ld t4, 0(a3)
    bne a0, t4, .Lfixture_failure
    la t4, .Lbuffer
    ld t5, 8(a3)
    add t4, t4, t5
    bne a1, t4, .Lfixture_failure
    ld t4, 16(a3)
    bne a2, t4, .Lfixture_failure
    li t4, SYS_WRITE
    bne a7, t4, .Lfixture_failure
    ld a0, 24(a3)
    addi a3, a3, 32
    jr t6
.section .rodata
.Lbuffer:
    .ascii "min(12, 37) = 12\\n"
.balign 8
.Levents:
'''
                source += "".join("    .quad " + ", ".join(map(str, event)) + "\n" for event in events)
                source += ".Levents_end:\n"
                self.run_machine_mode(source, "write-" + name)

    def run_machine_mode(self, source, name):
        emulator = command("QEMU_SYSTEM_RISCV64", "qemu-system-riscv64")
        if not emulator or not shutil.which(emulator[0]):
            self.skipTest("RISC-V system emulation is unavailable")
        source += '''
.section .text
.balign 4
.Lsemihost_exit:
    la a1, .Lexit_block
    sd a0, 8(a1)
    li a0, 0x20
    .option push
    .option norvc
    .balign 4
    slli zero, zero, 0x1f
    ebreak
    srai zero, zero, 7
    .option pop
    j .Lsemihost_exit
.section .data
.balign 8
.Lexit_block:
    .quad 0x20026, 1
.section .bss
.balign 16
    .skip 4096
.Lmachine_stack_top:
'''
        caller = self.work / (name + ".s")
        caller.write_text(source)
        binary = self.build(caller, name, machine_mode=True)
        result = subprocess.run([*emulator, "-machine", "virt", "-cpu", "rv64", "-m", "32M",
                                 "-nographic", "-bios", "none", "-monitor", "none", "-serial", "none",
                                 "-semihosting-config", "enable=on,target=native", "-kernel", str(binary)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_unwritable_stdout_returns_failure_and_reports_the_problem(self):
        with self.demo.open("rb") as readonly:
            result = self.run_binary(self.demo, stdout=readonly)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"write failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
