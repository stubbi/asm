# Unsigned integer helpers for Apple Silicon macOS

This implementation belongs to the [math project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).
Start the manual build commands below in this target directory.
The assembler include path points to the project root.

This source package is `math` checkout version `0.5.0` for `aarch64-macos`.
It supplies `asm_u64_min` for AArch64, macOS 15 or later, and the Apple arm64 ABI.
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
| Preserved state | All other registers and `SP`; reserved `x18` is untouched |
| Data memory | No access; no buffer or ownership requirements |
| Stack | No local storage; the caller supplies a 16-byte aligned `SP` |
| Return | The caller supplies a valid return address in `x30` |

The C interface name is `asm_u64_min`.
The Mach-O assembly symbol is `_asm_u64_min`.
Use `bl _asm_u64_min` in Apple assembly.
The Linux variant exports the ELF symbol `asm_u64_min`.
A Linux object is not compatible with this macOS target.

The contract follows [Arm AAPCS64, release 2025Q4](https://github.com/ARM-software/abi-aa/blob/2025Q4/aapcs64/aapcs64.rst).
Apply [Apple's arm64 rules](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms), including reserved `x18` and valid frame records.
Apple documents the [underscore symbol prefix](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/DynamicLibraryDesignGuidelines.html).
These references were checked on 2026-11-05.

## Build with Apple clang

These commands require Apple clang on Apple Silicon macOS 15 or later.
The demo uses libSystem for output.

1. Open this target directory.
2. Create the output directory.

```sh
mkdir -p build
```

3. Build the example and tests.

```sh
clang -arch arm64 -mmacosx-version-min=15.0 -Wl,-no_uuid src/main.s -I ../.. -o build/math-demo
clang -arch arm64 -mmacosx-version-min=15.0 -Wl,-no_uuid tests/main.s -I ../.. -o build/math-tests
```

Successful build commands produce no output.

4. Run the example.

```sh
./build/math-demo
```

The example prints `min(12, 37) = 12` and a newline.

5. Run the tests.

```sh
./build/math-tests
```

The test program produces no output and exits with status `0` when its checks pass.
A mismatch causes status `1`.

## Use the function

1. Copy `src/min.s` and its MIT license into the consuming project.
2. Include the source once in each linked program.

```asm
.include "src/min.s"
```

3. Put the two unsigned values in `x0` and `x1`.
4. Call `_asm_u64_min`.
5. Read the result from `x0`.

## Evidence and limits

The assembly harness checks 16 literal cases.
They cover zero, maximum values, equal values, reversed inputs, the signed boundary, and one-bit values above 32 bits.
After each call, it checks `x19-x28`, the frame pointer, the stack pointer, `d8-d15`, and a stack canary.
A stack canary is a fixed value used to detect an unexpected stack write.
The demo retries interrupted writes and handles short writes.
The Python test also checks a failed output write.

On 2026-11-05, the demo and harness passed on Apple Silicon macOS 15.6.1 with Apple clang 17.0.0.
The native Asm `run` and `test` commands also passed.
This result applies to that target and the tested cases.
It does not establish Linux behavior.
These tests are not a formal proof.
This package makes no performance or publication claim.
The package, demo, and value checks are assembly.
Python only builds and checks test processes.

## Write-loop qualification

From the repository root, run:

```sh
python3 -m unittest discover -s tests/packages -p test_macos_reference_io.py -v
```

Assembly fixtures inject complete, short, interrupted, zero-progress, failed, and oversized write results.
They execute the unchanged program body and check buffer progress, retry behavior, and exit status.
These fixtures check loop decisions; the ordinary process tests exercise real libSystem output.
