# Unsigned integer helpers for AArch64 Linux

This implementation belongs to the [math project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).
Start the manual build commands below in this target directory.
The assembler include path points to the project root.

This source package is `math` version `0.6.0` for `aarch64-linux`.
It supplies `asm_u64_min` for the AArch64 instruction set and Linux LP64 ABI.
An ABI defines register, stack, call, and data-layout rules.
The routine uses baseline Armv8-A integer instructions.
It requires no optional CPU extension.

## Function contract

| Item | Contract |
| --- | --- |
| Inputs | `x0 = a`, `x1 = b`; every unsigned 64-bit value is permitted |
| Result | `x0 = min(a, b)`, using unsigned comparison |
| Failure values | None |
| Changed state | `x0` and the `NZCV` condition flags |
| Preserved state | All other registers and `SP` |
| Data memory | No access; no buffer or ownership requirements |
| Stack | No local storage; the caller supplies a 16-byte aligned `SP` |
| Return | The caller supplies a valid return address in `x30` |

The ELF symbol is `asm_u64_min`.
The macOS variant uses the Mach-O symbol `_asm_u64_min`.
A macOS object is not compatible with this Linux target.

The contract follows [Arm AAPCS64, release 2025Q4](https://github.com/ARM-software/abi-aa/blob/2025Q4/aapcs64/aapcs64.rst).
That reference was checked on 2026-11-05.

## Build with cross tools

These commands require a GNU AArch64 Linux cross assembler and linker.
They do not require an Asm cross-build command.

1. Open this target directory.
2. Create the output directory.

```sh
mkdir -p build
```

3. Assemble and link the example.

```sh
aarch64-linux-gnu-as -march=armv8-a -I ../.. -o build/main.o src/main.s
aarch64-linux-gnu-ld -z noexecstack --build-id=none -o build/math-demo build/main.o
```

4. Assemble and link the tests.

```sh
aarch64-linux-gnu-as -march=armv8-a -I ../.. -o build/tests.o tests/main.s
aarch64-linux-gnu-ld -z noexecstack --build-id=none -o build/math-tests build/tests.o
```

Successful build commands produce no output.
Run the resulting programs on AArch64 Linux or with QEMU user-mode emulation.
The test program produces no output and exits with status `0` when its checks pass.
A mismatch causes status `1`.

## Use the function

1. Copy `src/min.s` and its MIT license into the consuming project.
2. Include the source once in each linked program.

```asm
.include "src/min.s"
```

3. Put the two unsigned values in `x0` and `x1`.
4. Call `asm_u64_min`.
5. Read the result from `x0`.

## Evidence and limits

The assembly harness checks 16 literal cases.
They cover zero, maximum values, equal values, reversed inputs, the signed boundary, and one-bit values above 32 bits.
After each call, it checks `x19-x28`, the frame pointer, the stack pointer, `d8-d15`, and a stack canary.
A stack canary is a fixed value used to detect an unexpected stack write.
The demo retries interrupted writes and handles short writes.
The Python test also checks a failed output write.

On 2026-11-05, Apple clang 17.0.0 and LLD 22.1.6 assembled and linked the Linux demo and harness.
Linux execution was not run in that check.
Cross compilation does not establish runtime behavior.
These tests are not a formal proof.
This package makes no performance or publication claim.
The package, demo, and value checks are assembly.
Python only builds and checks test processes.
