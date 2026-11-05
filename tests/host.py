"""Native-host fixtures shared by the CLI contract tests.

These values select equivalent programs and host-kernel fault-injection numbers.
ASM_TEST_TARGET selects explicit Linux or Intel Darwin fixtures.
It does not change or emulate the production executable.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import json
import os
from pathlib import Path
import platform

ROOT = Path(__file__).resolve().parents[1]
VERSION = json.loads((ROOT / "cli/commands.json").read_text())["version"]
MACHINE = platform.machine().lower()
IS_MACOS = platform.system() == "Darwin"
HOST_IS_ARM64 = MACHINE in {"aarch64", "arm64"}
TEST_TARGET = os.environ.get("ASM_TEST_TARGET")
IS_RISCV64 = MACHINE == "riscv64" or TEST_TARGET == "riscv64-linux"
IS_ARM64 = HOST_IS_ARM64 and not IS_RISCV64
if TEST_TARGET == "x86_64-macos":
    if not IS_MACOS:
        raise RuntimeError("The Intel Darwin suite requires macOS.")
    IS_ARM64 = False
elif TEST_TARGET in {"x86_64-linux", "aarch64-linux"}:
    native_linux = {"x86_64": "x86_64-linux", "amd64": "x86_64-linux",
                    "aarch64": "aarch64-linux", "arm64": "aarch64-linux",
                    "riscv64": "riscv64-linux"}.get(MACHINE)
    if platform.system() != "Linux" or TEST_TARGET != native_linux:
        raise RuntimeError(f"The explicit target {TEST_TARGET} does not match this native Linux host.")
elif TEST_TARGET == "riscv64-linux":
    # This explicit fixture selection also supports Linux user-mode emulation.
    # Kernel fault injection below still uses the actual Python host machine.
    if platform.system() != "Linux":
        raise RuntimeError("The RISC-V fixture suite requires Linux.")
elif TEST_TARGET:
    raise RuntimeError(f"Unsupported explicit test target: {TEST_TARGET}")
if MACHINE not in {"x86_64", "amd64", "aarch64", "arm64", "riscv64"}:
    raise RuntimeError(f"The native CLI tests do not support {MACHINE}.")
TARGET = "aarch64-linux" if IS_ARM64 else "x86_64-linux"
OTHER_TARGET = "x86_64-linux" if IS_ARM64 else "aarch64-linux"
TRIPLE = "aarch64-unknown-linux-gnu" if IS_ARM64 else "x86_64-unknown-linux-gnu"
ELF_MACHINE = 183 if IS_ARM64 else 62
ASM_FLAGS = [] if IS_ARM64 else ["--64"]
CLI_SOURCE = "cli/aarch64/asm.s" if IS_ARM64 else "cli/asm.s"
CLI_DIRECTORY = ROOT / ("cli/aarch64" if IS_ARM64 else "cli")
if IS_RISCV64:
    TARGET = "riscv64-linux"
    OTHER_TARGET = "aarch64-linux"
    TRIPLE = "riscv64-unknown-linux-gnu"
    ELF_MACHINE = 243
    ASM_FLAGS = ["-march=rv64i", "-mabi=lp64"]
    CLI_SOURCE = "cli/riscv64/asm.s"
    CLI_DIRECTORY = ROOT / "cli/riscv64"
if IS_MACOS:
    TARGET = "aarch64-macos" if IS_ARM64 else "x86_64-macos"
    OTHER_TARGET = "aarch64-linux" if IS_ARM64 else "x86_64-linux"
    TRIPLE = "arm64-apple-macos" if IS_ARM64 else "x86_64-apple-macos"
    CLI_SOURCE = "cli/macos/asm.s" if IS_ARM64 else "cli/macos/x86_64/asm.s"
MAC_ARCH = "arm64" if IS_ARM64 else "x86_64"
MAC_PREPARED = "build/macos/asm.s" if IS_ARM64 else "build/macos-x86_64/asm.s"

CLI_ASM_FLAGS = ["-march=rv64im", "-mabi=lp64"] if IS_RISCV64 else ASM_FLAGS

# Seccomp filters run in Python before exec, against the actual host kernel.
# Emulated guest syscall numbers must not be used to filter an x86 host.
GENERIC_SYSCALLS = HOST_IS_ARM64 or MACHINE == "riscv64"
SYS_RENAMEAT = (276 if GENERIC_SYSCALLS else 316) if IS_RISCV64 else (38 if GENERIC_SYSCALLS else 264)
SYS_SIGPROCMASK = 135 if GENERIC_SYSCALLS else 14
SYS_GETRLIMIT = 163 if GENERIC_SYSCALLS else 97
SYS_SETRLIMIT = 164 if GENERIC_SYSCALLS else 160


def program(body: str) -> str:
    if IS_MACOS:
        syntax = "" if IS_ARM64 else ".intel_syntax noprefix\n"
        frame = "" if IS_ARM64 else "push rbp\nmov rbp, rsp\n"
        return syntax + ".global _main\n.text\n_main:\n" + frame + body + "\n"
    syntax = ".option norelax\n" if IS_RISCV64 else "" if IS_ARM64 else ".intel_syntax noprefix\n"
    return syntax + ".global _start\n.text\n_start:\n" + body + '\n.section .note.GNU-stack,"",@progbits\n'


def exit_source(code: int) -> str:
    if IS_MACOS:
        return program(f"mov x0, #{code}\nbl _exit" if IS_ARM64 else f"mov edi, {code}\ncall _exit")
    if IS_RISCV64:
        return program(f"li a0, {code}\nli a7, 93\necall")
    return program(f"mov x0, #{code}\nmov x8, #93\nsvc #0" if IS_ARM64 else
                   f"mov edi, {code}\nmov eax, 60\nsyscall")


def argc_source() -> str:
    if IS_MACOS:
        return program("bl _exit" if IS_ARM64 else "call _exit")
    if IS_RISCV64:
        return program("ld a0, 0(sp)\nli a7, 93\necall")
    return program("ldr x0, [sp]\nmov x8, #93\nsvc #0" if IS_ARM64 else
                   "mov rdi, [rsp]\nmov eax, 60\nsyscall")


def illegal_source() -> str:
    return program(".word 0" if IS_RISCV64 else ".inst 0x00000000" if IS_ARM64 else "ud2")


def undefined_symbol_source() -> str:
    return program("call missing_symbol" if IS_RISCV64 else "bl missing_symbol" if IS_ARM64 else "call missing_symbol")
