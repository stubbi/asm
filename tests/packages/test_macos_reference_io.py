"""Execute unchanged macOS reference bodies against assembly write-result fixtures.

These fixtures qualify write-loop decisions, not real libSystem writes.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

try:
    from .macos_host import is_apple_silicon
except ImportError:
    from macos_host import is_apple_silicon

ROOT = Path(__file__).resolve().parents[2]

# Events contain the expected buffer offset, remaining length, result, and errno.
# Literal expectations are independent of the program's loop implementation.
def write_scenarios(length):
    return {
        "full": ([(0, length, length, 0)], 0, 0),
        "short-eintr": ([(0, length, 3, 0), (3, length - 3, -1, 4),
                         (3, length - 3, length - 3, 0)], 0, 1),
        "zero": ([(0, length, 0, 0)], 1, 0),
        "error": ([(0, length, -1, 9)], 1, 1),
        "partial-error": ([(0, length, 3, 0), (3, length - 3, -1, 5)], 1, 1),
        "oversize": ([(0, length, length + 1, 0)], 1, 0),
    }


ARM64_FIXTURE = r'''
/* Apple ARM64 test fixture. x18 is reserved and remains untouched.
 * _main uses a 16-byte aligned frame and preserves x29/x30.
 * The leaf write/error fixtures use only caller-saved registers.
 * Private fixture state validates the original body's calls and result.
 */
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _main
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _hello_main
    cmp w0, #EXPECTED_RESULT
    b.ne Lfailed
    adrp x9, Lfault@PAGE
    ldr w10, [x9, Lfault@PAGEOFF]
    cbnz w10, Lfailed
    adrp x9, Lcursor@PAGE
    ldr x10, [x9, Lcursor@PAGEOFF]
    cmp x10, #EVENT_COUNT
    b.ne Lfailed
    adrp x9, Lerrno_calls@PAGE
    ldr w10, [x9, Lerrno_calls@PAGEOFF]
    cmp w10, #EXPECTED_ERRNO_CALLS
    b.ne Lfailed
    mov w0, #0
    b Lreturn
Lfailed:
    mov w0, #1
Lreturn:
    ldp x29, x30, [sp], #16
    ret

.globl _write
_write:
    adrp x9, Lcursor@PAGE
    add x9, x9, Lcursor@PAGEOFF
    ldr x10, [x9]
    cmp x10, #EVENT_COUNT
    b.hs Lbad_write
    adrp x12, Levents@PAGE
    add x12, x12, Levents@PAGEOFF
    add x12, x12, x10, lsl #5
    cmp x0, #1
    b.ne Lbad_write
    ldr x13, [x12, #8]
    cmp x2, x13
    b.ne Lbad_write
    adrp x14, Lbuffer_base@PAGE
    add x14, x14, Lbuffer_base@PAGEOFF
    ldr x15, [x14]
    cbnz x10, Lhave_base
    str x1, [x14]
    mov x15, x1
Lhave_base:
    ldr x13, [x12]
    add x15, x15, x13
    cmp x1, x15
    b.ne Lbad_write
    ldr w13, [x12, #24]
    adrp x14, Lerrno@PAGE
    str w13, [x14, Lerrno@PAGEOFF]
    ldr x0, [x12, #16]
    add x10, x10, #1
    str x10, [x9]
    ret
Lbad_write:
    adrp x9, Lfault@PAGE
    mov w10, #1
    str w10, [x9, Lfault@PAGEOFF]
    mov x0, #0
    ret

.globl ___error
___error:
    adrp x9, Lerrno_calls@PAGE
    ldr w10, [x9, Lerrno_calls@PAGEOFF]
    add w10, w10, #1
    str w10, [x9, Lerrno_calls@PAGEOFF]
    adrp x0, Lerrno@PAGE
    add x0, x0, Lerrno@PAGEOFF
    ret
'''

X86_64_FIXTURE = r'''
/* macOS System V AMD64 test fixture.
 * _main saves RBP and aligns RSP to 16 bytes before calling the original body.
 * The leaf write/error fixtures change only caller-saved registers and flags.
 * All fixture data is private to this temporary executable.
 */
.intel_syntax noprefix
.section __TEXT,__text,regular,pure_instructions
.p2align 4
.globl _main
_main:
    push rbp
    mov rbp, rsp
    call _hello_main
    cmp eax, EXPECTED_RESULT
    jne Lfailed
    cmp dword ptr [rip + Lfault], 0
    jne Lfailed
    cmp qword ptr [rip + Lcursor], EVENT_COUNT
    jne Lfailed
    cmp dword ptr [rip + Lerrno_calls], EXPECTED_ERRNO_CALLS
    jne Lfailed
    xor eax, eax
    jmp Lreturn
Lfailed:
    mov eax, 1
Lreturn:
    pop rbp
    ret

.globl _write
_write:
    mov rcx, [rip + Lcursor]
    cmp rcx, EVENT_COUNT
    jae Lbad_write
    lea r8, [rip + Levents]
    mov r9, rcx
    shl r9, 5
    add r8, r9
    cmp edi, 1
    jne Lbad_write
    cmp rdx, [r8 + 8]
    jne Lbad_write
    mov r10, [rip + Lbuffer_base]
    test rcx, rcx
    jne Lhave_base
    mov [rip + Lbuffer_base], rsi
    mov r10, rsi
Lhave_base:
    add r10, [r8]
    cmp rsi, r10
    jne Lbad_write
    mov eax, [r8 + 24]
    mov [rip + Lerrno], eax
    mov rax, [r8 + 16]
    inc rcx
    mov [rip + Lcursor], rcx
    ret
Lbad_write:
    mov dword ptr [rip + Lfault], 1
    xor eax, eax
    ret

.globl ___error
___error:
    inc dword ptr [rip + Lerrno_calls]
    lea rax, [rip + Lerrno]
    ret
'''


def fixture_source(arch, events, expected_result, errno_calls):
    constants = (f".equ EVENT_COUNT, {len(events)}\n"
                 f".equ EXPECTED_RESULT, {expected_result}\n"
                 f".equ EXPECTED_ERRNO_CALLS, {errno_calls}\n")
    body = ARM64_FIXTURE if arch == "arm64" else X86_64_FIXTURE
    data = '''
.section __DATA,__data
.p2align 3
Lcursor: .quad 0
Lbuffer_base: .quad 0
Lerrno: .long 0
Lerrno_calls: .long 0
Lfault: .long 0
.section __TEXT,__const
.p2align 3
Levents:
'''
    data += "".join("    .quad " + ", ".join(map(str, event)) + "\n" for event in events)
    return constants + body + data + ".subsections_via_symbols\n"


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS and Apple clang")
class MacReferenceIoTests(unittest.TestCase):
    def require_runtime(self, arch):
        apple_silicon = is_apple_silicon()
        if arch == "arm64" and not apple_silicon:
            self.skipTest("ARM64 execution requires Apple Silicon")
        if arch == "x86_64" and apple_silicon:
            probe = subprocess.run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"],
                                   capture_output=True, timeout=10)
            if probe.returncode:
                self.skipTest("Intel execution requires Rosetta on Apple Silicon")
        return "Rosetta translation" if arch == "x86_64" and apple_silicon else "native"

    def compile(self, arguments, cwd=None):
        result = subprocess.run(["/usr/bin/clang", *arguments], capture_output=True, timeout=30, cwd=cwd)
        self.assertEqual(result.returncode, 0, (result.args, result.stdout, result.stderr))

    def exercise(self, target, arch, kind="hello"):
        mode = self.require_runtime(arch)
        source = ROOT / "examples" / kind / "targets" / f"{target}-macos" / "src/main.s"
        with tempfile.TemporaryDirectory(prefix="macos-hello-io-") as temporary:
            work = Path(temporary)
            body = work / "body.o"
            common = ["-arch", arch, "-mmacosx-version-min=15.0"]
            # Only the entry-point name changes. The package body is not rewritten.
            self.compile([*common, "-x", "assembler-with-cpp", "-D_main=_hello_main",
                          "-c", str(source), "-o", str(body)], cwd=ROOT / "examples" / kind)
            digests = {}
            for name, (events, expected_result, errno_calls) in write_scenarios(16 if kind == "hello" else 17).items():
                with self.subTest(target=target, scenario=name):
                    fixture = work / (name + ".s")
                    fixture.write_text(fixture_source(arch, events, expected_result, errno_calls))
                    output = work / name
                    self.compile([*common, "-Wl,-no_uuid", "-o", str(output), str(body), str(fixture)])
                    result = subprocess.run([str(output)], capture_output=True, timeout=10)
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""),
                                     (name, result.returncode, result.stdout, result.stderr))
                    digests[name] = hashlib.sha256(output.read_bytes()).hexdigest()
            print(f"{kind}-{target}-macos injected write results: {mode}; "
                  f"source_sha256={hashlib.sha256(source.read_bytes()).hexdigest()}; "
                  f"artifact_sha256={json.dumps(digests, sort_keys=True)}")

    def test_apple_silicon_injected_write_results(self):
        self.exercise("aarch64", "arm64")

    def test_intel_injected_write_results(self):
        self.exercise("x86_64", "x86_64")


    def test_apple_silicon_math_injected_write_results(self):
        self.exercise("aarch64", "arm64", "math")

    def test_intel_math_injected_write_results(self):
        self.exercise("x86_64", "x86_64", "math")


if __name__ == "__main__":
    unittest.main()
