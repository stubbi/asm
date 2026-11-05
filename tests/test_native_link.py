"""Observable native-library build checks.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from host import IS_ARM64, IS_MACOS, TARGET, MAC_ARCH, exit_source


ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build/asm"


def main_source():
    if IS_MACOS and not IS_ARM64:
        return ('.intel_syntax noprefix\n.global _main\n.text\n_main:\n'
                'push rbp\nmov rbp, rsp\nlea rdi, [rip + message]\ncall _puts\n'
                'xor eax, eax\npop rbp\nret\n'
                '.data\nmessage: .asciz "native linked"\n')
    if IS_MACOS:
        return ('.global _main\n.text\n_main:\n'
                'stp x29, x30, [sp, #-16]!\nmov x29, sp\n'
                'adrp x0, message@PAGE\nadd x0, x0, message@PAGEOFF\nbl _puts\n'
                'mov w0, #0\nldp x29, x30, [sp], #16\nret\n'
                '.data\nmessage: .asciz "native linked"\n')
    if TARGET == "riscv64-linux":
        return ('.attribute arch, "rv64gc"\n.attribute stack_align, 16\n'
                '.global main\n.text\nmain:\naddi sp, sp, -16\nsd ra, 8(sp)\n'
                'la a0, message\ncall puts\nli a0, 0\nld ra, 8(sp)\n'
                'addi sp, sp, 16\nret\n.section .rodata\n'
                'message: .asciz "native linked"\n.section .note.GNU-stack,"",@progbits\n')
    if IS_ARM64:
        return ('.global main\n.text\nmain:\n'
                'stp x29, x30, [sp, #-16]!\nmov x29, sp\n'
                'adrp x0, message\nadd x0, x0, :lo12:message\nbl puts\n'
                'mov w0, #0\nldp x29, x30, [sp], #16\nret\n'
                '.section .rodata\nmessage: .asciz "native linked"\n'
                '.section .note.GNU-stack,"",@progbits\n')
    return ('.intel_syntax noprefix\n.global main\n.text\nmain:\n'
            'push rbp\nmov rbp, rsp\nlea rdi, [rip + message]\ncall puts\n'
            'xor eax, eax\npop rbp\nret\n'
            '.section .rodata\nmessage: .asciz "native linked"\n'
            '.section .note.GNU-stack,"",@progbits\n')


class NativeLinkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-native-", dir=ROOT / "build")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.manifest = self.work / "asm.toml"
        self.base = ('[package]\nname = "native"\nversion = "0.1.0"\n'
                     f'[build]\nsource = "main.s"\ntarget = "{TARGET}"\n')
        self.manifest.write_text(self.base + 'link = "c"\nlibraries = "m"\n')
        (self.work / "main.s").write_text(main_source())

    def cli(self, *arguments, success=True, env=None):
        result = subprocess.run([str(ASM), *arguments], cwd=self.work, env=env,
                                capture_output=True, text=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        else:
            self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
        return result

    def _assert_hardened(self, data):
        # Constants: glibc 2.40 elf/elf.h and Apple SDK mach-o/loader.h.
        if data[:4] == b"\xcf\xfa\xed\xfe":
            flags = struct.unpack_from("<I", data, 24)[0]
            self.assertTrue(flags & 0x200000, "Mach-O lacks MH_PIE")
            self.assertFalse(flags & 0x20000, "Mach-O permits executable stacks")
            return
        self.assertEqual(data[:6], b"\x7fELF\x02\x01", "Expected little-endian ELF64")
        self.assertEqual(struct.unpack_from("<H", data, 16)[0], 3, "ELF must use ET_DYN")
        offset = struct.unpack_from("<Q", data, 32)[0]
        size, count = struct.unpack_from("<HH", data, 54)
        self.assertEqual(size, 56, "Unexpected ELF64 program-header size")
        self.assertLessEqual(offset + size * count, len(data))
        headers = [struct.unpack_from("<IIQQQQQQ", data, offset + size * index)
                   for index in range(count)]
        stacks = [header for header in headers if header[0] == 0x6474E551]  # PT_GNU_STACK
        self.assertTrue(stacks, "ELF lacks an explicit stack policy")
        self.assertTrue(all(not header[1] & 1 for header in stacks), "ELF stack has PF_X")
        self.assertTrue(any(header[0] == 0x6474E552 and header[6] for header in headers),
                        "ELF lacks nonempty PT_GNU_RELRO")
        immediate = False
        for header in headers:
            if header[0] != 2:  # PT_DYNAMIC
                continue
            start, length = header[2], header[5]
            self.assertEqual(length % 16, 0)
            self.assertLessEqual(start + length, len(data))
            for position in range(start, start + length, 16):
                tag, value = struct.unpack_from("<qQ", data, position)
                if tag == 0:  # DT_NULL
                    break
                immediate |= (tag == 24 or (tag == 30 and bool(value & 8))
                              or (tag == 0x6FFFFFFB and bool(value & 1)))
        self.assertTrue(immediate, "ELF lacks immediate binding")

    def test_c_abi_build_and_run_have_real_libc_output(self):
        self.cli("build")
        self._assert_hardened((self.work / "build/app").read_bytes())
        result = subprocess.run([str(self.work / "build/app")], capture_output=True,
                                text=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, "native linked\n", ""))
        self.assertEqual(self.cli("run").stdout, "native linked\n")
        (self.work / "tests").mkdir()
        (self.work / "tests/main.s").write_text(main_source())
        self.assertIn("native linked\n", self.cli("test").stdout)

    def test_include_and_library_paths_with_spaces_are_direct_arguments(self):
        include = self.work / "header files"
        library = self.work / "library files"
        include.mkdir()
        library.mkdir()
        (include / "native.h").write_text('#define NATIVE_VALUE 7\n')
        (self.work / "check.c").write_text(
            '#include <native.h>\n_Static_assert(NATIVE_VALUE == 7, "wrong header");\n')
        source = library / "fixture.c"
        source.write_text('int native_value(void) { return 7; }\n')
        output = library / ("libasmfixture.dylib" if IS_MACOS else "libasmfixture.so")
        mode = (["-dynamiclib", "-Wl,-install_name,@rpath/libasmfixture.dylib"] if IS_MACOS
                else ["-shared", "-fPIC", "-Wl,-soname,libasmfixture.so"])
        subprocess.run(["/usr/bin/cc", *(["-arch", MAC_ARCH] if IS_MACOS else []), *mode, "-o", str(output), str(source)],
                       check=True, capture_output=True, timeout=20)
        assembly = main_source()
        call = ("bl _native_value" if IS_ARM64 else "call _native_value") if IS_MACOS else ("bl native_value" if IS_ARM64 else "call native_value")
        marker = "li a0, 0" if TARGET == "riscv64-linux" else ("mov w0, #0" if IS_ARM64 else "xor eax, eax")
        assembly = assembly.replace(marker, call + "\n" + marker)
        (self.work / "main.s").write_text(assembly)
        self.manifest.write_text(self.base + 'link = "c"\nlibraries = "asmfixture"\ncheck = "check.c"\n')
        result = self.cli("run", "--include-dir", str(include), "--library-dir", str(library))
        self.assertEqual(result.stdout, "native linked\n")

    def test_bad_manifest_and_options_preserve_existing_binary(self):
        self.cli("build")
        binary = self.work / "build/app"
        before = binary.read_bytes()
        fields = ['link = "shell"', 'link = ""', 'libraries = "m"',
                  'check = "check.c"', 'link = "c"\nlink = "c"',
                  'link = "c"\nlibraries = "m  c"', 'link = "c"\nlibraries = "-m"',
                  'link = "c"\nlibraries = "m/evil"', 'link = "c"\nlibraries = "m "',
                  'link = "c"\nlibraries = "' + " ".join(["m"] * 9) + '"',
                  'link = "c"\ncheck = "../check.c"', 'link = "c"\ncheck = "check.s"',
                  'link = "c"\ncheck = "caf\u00e9.c"']
        for field in fields:
            with self.subTest(field=field):
                self.manifest.write_text(self.base + field + "\n")
                self.cli("build", success=False)
                self.assertEqual(binary.read_bytes(), before)
        self.manifest.write_text(self.base + 'link = "c"\n')
        for arguments in [("--include-dir",), ("--library-dir", "relative"),
                          ("--include-dir", "/bad:path"), ("--library-dir", "/bad,path"),
                          ("--include-dir", "/" + "a" * 255),
                          tuple(["--include-dir", str(self.work)] * 9)]:
            with self.subTest(arguments=arguments):
                self.cli("build", *arguments, success=False)
                self.assertEqual(binary.read_bytes(), before)
        self.cli("clean", "--library-dir", str(self.work), success=False)
        self.manifest.write_text(self.base)
        self.cli("build", "--include-dir", str(self.work), success=False)
        self.assertEqual(binary.read_bytes(), before)

    def test_failed_check_or_missing_library_preserves_existing_binary(self):
        self.cli("build")
        binary = self.work / "build/app"
        before = binary.read_bytes()
        (self.work / "check.c").write_text('_Static_assert(0, "must reject");\n')
        self.manifest.write_text(self.base + 'link = "c"\ncheck = "check.c"\n')
        self.cli("build", success=False)
        self.assertEqual(binary.read_bytes(), before)
        self.manifest.write_text(self.base + 'link = "c"\nlibraries = "asmdoesnotexist"\n')
        self.cli("build", success=False)
        self.assertEqual(binary.read_bytes(), before)
        self.assertFalse(list((self.work / "build").glob(".asm-*")))

    def test_checker_filename_cannot_select_a_compiler_response_file(self):
        self.cli("build")
        binary = self.work / "build/app"
        before = binary.read_bytes()
        (self.work / "@response.c").write_text('_Static_assert(0, "must reject");\n')
        (self.work / "response.c").write_text('--version\n')
        self.manifest.write_text(self.base + 'link = "c"\ncheck = "@response.c"\n')
        result = self.cli("build", success=False)
        self.assertEqual(result.stdout, "")
        self.assertIn("invalid or missing asm.toml", result.stderr)
        self.assertEqual(binary.read_bytes(), before)
        self.assertFalse(list((self.work / "build").glob(".asm-*")))

    def test_source_components_cannot_select_assembler_response_files(self):
        self.cli("build")
        binary = self.work / "build/app"
        before = binary.read_bytes()
        for linked in (False, True):
            for path in ("@main.s", "src/@main.s"):
                with self.subTest(c_abi=linked, path=path):
                    source = self.work / path
                    source.parent.mkdir(exist_ok=True)
                    source.write_text(main_source() if linked else exit_source(23))
                    manifest = self.base.replace('source = "main.s"', f'source = "{path}"')
                    self.manifest.write_text(manifest + ('link = "c"\n' if linked else ''))
                    result = self.cli("build", success=False)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("invalid or missing asm.toml", result.stderr)
                    self.assertEqual(binary.read_bytes(), before)
                    self.assertFalse(list((self.work / "build").glob(".asm-*")))
        (self.work / "main@literal.s").write_text(main_source())
        self.manifest.write_text(self.base.replace('source = "main.s"', 'source = "main@literal.s"')
                                 + 'link = "c"\n')
        self.assertEqual(self.cli("run").stdout, "native linked\n")

    def test_inactive_target_response_file_inputs_preserve_existing_binary(self):
        self.cli("build")
        binary = self.work / "build/app"
        before = binary.read_bytes()
        foreign = "aarch64-linux" if TARGET == "x86_64-linux" else "x86_64-linux"
        selected = ('[package]\nname = "native"\nversion = "0.1.0"\n'
                    f'[target.{TARGET}]\nsource = "main.s"\nlink = "c"\n')
        for fields in ('source = "src/@main.s"\n',
                       'source = "src/main.s"\ntest = "tests/@main.s"\n',
                       'source = "src/main.s"\nlink = "c"\ncheck = "abi/@check.c"\n'):
            with self.subTest(fields=fields):
                self.manifest.write_text(selected + f'[target.{foreign}]\n' + fields)
                result = self.cli("build", success=False)
                self.assertEqual(result.stdout, "")
                self.assertIn("invalid or missing asm.toml", result.stderr)
                self.assertEqual(binary.read_bytes(), before)
                self.assertFalse(list((self.work / "build").glob(".asm-*")))

    def test_hidden_c_checker_is_compiled_without_execution(self):
        (self.work / ".c").write_text(
            '#include <stdio.h>\nint main(void) {\n'
            'FILE *file = fopen("checker-executed", "w");\n'
            'if (file) { fclose(file); }\nreturn 9;\n}\n')
        self.manifest.write_text(self.base + 'link = "c"\ncheck = ".c"\n')
        self.cli("build")
        self.assertFalse((self.work / "checker-executed").exists())

    def test_response_file_checker_is_rejected_before_compilation(self):
        self.cli("build")
        before = (self.work / "build/app").read_bytes()
        (self.work / "literal.c").write_text("-x c /dev/null\n")
        for name in ["@literal.c", "nested/@literal.c"]:
            checker = self.work / name
            checker.parent.mkdir(exist_ok=True)
            checker.write_text('_Static_assert(sizeof(void *) == 8, "LP64");\n')
            self.manifest.write_text(self.base + f'link = "c"\ncheck = "{name}"\n')
            result = self.cli("build", success=False)
            self.assertIn("invalid or missing asm.toml", result.stderr)
            self.assertEqual((self.work / "build/app").read_bytes(), before)

    def test_compiler_ignores_ambient_tool_and_include_configuration(self):
        poisoned = self.work / "poisoned"
        poisoned.mkdir()
        (poisoned / "stdlib.h").write_text('#error ambient header was selected\n')
        (self.work / "check.c").write_text('#include <stdlib.h>\n_Static_assert(sizeof(int) >= 2, "int");\n')
        self.manifest.write_text(self.base + 'link = "c"\ncheck = "check.c"\n')
        env = {**os.environ, "GCC_EXEC_PREFIX": str(poisoned) + "/",
               "COMPILER_PATH": str(poisoned), "LIBRARY_PATH": str(poisoned),
               "CPATH": str(poisoned), "C_INCLUDE_PATH": str(poisoned), "PATH": str(poisoned),
               "SDKROOT": str(poisoned / "missing-sdk")}
        self.cli("build", env=env)


if __name__ == "__main__":
    unittest.main()
