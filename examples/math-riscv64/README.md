# Unsigned integer helpers for RISC-V64 Linux

This package supplies `asm_u64_min` for little-endian RISC-V64 Linux.
It uses RV64I instructions and the LP64 ABI, which defines calls and data layout.
It requires no optional instruction extensions or C runtime.
This source package declares `riscv64-linux`; it does not add a RISC-V64 Asm CLI host.

## Interface

`asm_u64_min` returns the smaller of two unsigned 64-bit integers.
All 64-bit input values are valid.

| Property | Contract |
| --- | --- |
| Inputs | `a0` contains the first value; `a1` contains the second value. |
| Result | `a0` contains the unsigned minimum. There is no failure value. |
| Changed registers | `a0` only. All other registers remain unchanged. |
| Stack | No local storage or stack changes. The caller aligns `sp` to 16 bytes. |
| Memory | No data memory access, buffers, or ownership transfer. |
| Call | `ra` contains a valid return address. No system call is used. |

The [RISC-V psABI specification](https://riscv-non-isa.github.io/riscv-elf-psabi-doc/) defines the integer calling convention.
The applicable rules were checked on 2026-11-05.

## Build and run on Linux

These commands require GNU RISC-V64 Binutils.
They build the example and its native assembly caller test.

1. From this package directory, build both executables:

```sh
mkdir -p build
riscv64-linux-gnu-as -march=rv64i -mabi=lp64 -I . -o build/math.o src/main.s
riscv64-linux-gnu-ld -z noexecstack --build-id=none -o build/math build/math.o
riscv64-linux-gnu-as -march=rv64i -mabi=lp64 -I . -o build/math-test.o tests/main.s
riscv64-linux-gnu-ld -z noexecstack --build-id=none -o build/math-test build/math-test.o
```

2. On RISC-V64 Linux, run both executables:

```sh
./build/math
./build/math-test
```

On another Linux architecture, QEMU user mode supplies a RISC-V64 Linux process environment.
The emulator can be named `qemu-riscv64-static` on some distributions.

```sh
qemu-riscv64 ./build/math
qemu-riscv64 ./build/math-test
```

The example's specified output is `min(12, 37) = 12` followed by a newline.
The caller test's specified result is no output and exit status 0.
Linux process execution has not been run in the local qualification environment.

The example retries interrupted writes and completes short writes.
An output error causes exit status 1 and a diagnostic on standard error when available.
An error can follow partial output.

## Use the function

1. Copy `src/min.s` and `LICENSE` into the consuming project's source tree.
2. Include the source once in the linked program:

```asm
.include "src/min.s"
```

3. Put the two values in `a0` and `a1`.
4. Call `asm_u64_min`.
5. Read the unsigned result from `a0`.

The package manifest uses prospective `math` version `0.6.0` and target `riscv64-linux`.
This source addition does not establish that the registry has published that version.
Earlier published package versions retain their original bytes and licenses.

## Validation and limits

The native assembly caller checks 457 input pairs.
They cover zero, equal values, reversed inputs, the largest unsigned value, the signed boundary, and all 64 one-bit values.
Each pair also checks `s0`–`s11`, `gp`, `tp`, stack alignment, stack contents, and the unchanged stack pointer.
These tests are not a formal proof.
This package makes no performance claim.

From the repository root, run the package checks:

```sh
python3 -m unittest discover -s tests/packages -p test_math_riscv64.py -v
```

The checks use GNU RISC-V64 Binutils by default.
`RISCV64_AS` and `RISCV64_LD` select alternative tool commands.
`RISCV64_CC` selects a Clang driver with a RISC-V backend.
`QEMU_RISCV64` selects the Linux process runner.
Missing tools produce explicit skips.

`RISCV64_RUSTC` selects Rust's LLVM assembler as an optional build tool.
The test creates a temporary assembly-only wrapper; the package remains native assembly.
This workaround needs `RUSTC_BOOTSTRAP=1`, which the test limits to its compiler child.
It disables the target's `M` and `Zmmul` multiplication extensions and emits only an object file.
It does not introduce a package runtime or backend.

The separate QEMU system test uses machine mode and semihosting to exit.
Semihosting lets an emulated program request a debugger operation.
The test reuses the assembly caller cases and supplies its own aligned stack.
It does not exercise Linux system calls or qualify the Linux demonstration.
`QEMU_SYSTEM_RISCV64` selects the system emulator.

Separate scenarios inject syscall results into the actual write loop.
They cover interrupted calls, short writes, zero progress, errors after partial output, an oversized result, and an empty range.
These checks validate loop behavior; they do not execute Linux writes.

The [RISC-V semihosting specification](https://github.com/riscv-non-isa/riscv-semihosting) defines the call sequence.
The [QEMU invocation reference](https://www.qemu.org/docs/master/system/invocation.html) defines the emulator options.
These sources were checked on 2026-11-05.

## Local qualification on 2026-11-05

The host was Apple Silicon with macOS 15.6.1.
The tools were Rust 1.97.1, LLVM and LLD 22.1.6, and QEMU 9.2.0.
Rust's compiler commit was `8bab26f4f68e0e26f0bb7960be334d5b520ea452`.

The following command ran from the repository root:

```sh
RISCV64_RUSTC=rustc \
RISCV64_LD="$(rustc --print sysroot)/lib/rustlib/aarch64-apple-darwin/bin/gcc-ld/ld.lld" \
python3 -m unittest discover -s tests/packages -p test_math_riscv64.py -v
```

Four tests passed.
Three Linux process tests reported explicit skips because no Linux runtime was available.
The callable cases and all six injected write-loop scenarios passed in machine-mode emulation.
Both Linux executables passed structural ELF checks and declared RV64I with LP64.
Their Linux execution remains unrun.

| Local artifact | SHA-256 |
| --- | --- |
| Assembled Linux example | `014eb0b69a3a775af22d7cf5080c15a216014cc0333ff180d9ae5a362213eb44` |
| Assembled Linux caller test | `29ac421b0252906a99df8e37506ff6d274530af56e243f8690d2e486ceaeb8c9` |
| Executed machine-mode caller | `270868bd20b2b69e4b53b7e40cd23e7fb649d8fd7bdf6ec3ab91083eec4f317a` |

These are local validation artifacts, not published release artifacts.
The test rejected deliberate signed-comparison and interrupted-write regressions in temporary source copies.

Earlier attempts exposed three limitations.
Apple Clang 17 had no RISC-V backend.
The initial LLVM caller used an unsupported forward-expression immediate.
The initial machine-mode harness started at the library function and timed out after 15 seconds.
The current caller uses an end pointer, and the machine-mode harness places its entry point at the load address.
