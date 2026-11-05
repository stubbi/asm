# Unsigned integer helpers for Intel macOS

This implementation belongs to the [math project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).
Start the manual build commands below in this target directory.
The assembler include path points to the project root.

This source package is `math` version `0.6.0` for `x86_64-macos`.
It supplies `asm_u64_min` for x86-64, macOS 15 or later, and Apple's ordinary C calling convention.
That convention follows the System V AMD64 ABI for these arguments.
An ABI defines register, stack, call, and data-layout rules.
The routine requires no optional CPU extension.

## Function contract

| Item | Contract |
| --- | --- |
| Inputs | `rdi = a`, `rsi = b`; every unsigned 64-bit value is permitted |
| Result | `rax = min(a, b)`, using unsigned comparison |
| Failure values | None |
| Changed state | `rax` and arithmetic flags |
| Preserved state | All other registers; the caller's stack pointer is restored after return |
| Data memory | No data buffer access; `RET` reads the caller's return address |
| Stack | No local storage; align `rsp` to 16 bytes before `CALL` |
| Entry frame | `rsp` is 8 modulo 16, with a valid return address at `[rsp]` |

The C interface name is `asm_u64_min`.
The Mach-O assembly symbol is `_asm_u64_min`.
Use `call _asm_u64_min` in Apple assembly.
Linux ELF objects are not compatible with this macOS target.

The contract follows [Apple's Intel ABI rules](https://developer.apple.com/documentation/xcode/writing-64-bit-intel-code-for-apple-platforms).
The [System V AMD64 specification](https://gitlab.com/x86-psABIs/x86-64-ABI/-/blob/master/x86-64-ABI/low-level-sys-info.tex) defines the ordinary register and stack rules.
Apple documents the [underscore symbol prefix](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/DynamicLibraryDesignGuidelines.html).
These online references were checked on 2026-11-05.

## Build with Apple clang

These commands require Apple's Command Line Tools and macOS 15 or later.
The Command Line Tools supply Apple clang and the macOS SDK.
The demo uses libSystem for output.
On Apple Silicon, execution also requires Rosetta.
The current Asm CLI does not provide an Intel macOS host build.

1. Open this target directory.
2. Create the output directory.

```sh
mkdir -p build
```

3. Build the example.

```sh
clang -arch x86_64 -mmacosx-version-min=15.0 -Wl,-no_uuid src/main.s -I ../.. -o build/math-demo
```

4. Build the assembly tests.

```sh
clang -arch x86_64 -mmacosx-version-min=15.0 -Wl,-no_uuid tests/main.s -I ../.. -o build/math-tests
```

Successful build commands produce no output.

## Run on Intel macOS

1. Run the example.

```sh
./build/math-demo
```

Expected output:

```text
min(12, 37) = 12
```

2. Run the tests.

```sh
./build/math-tests
```

The test program produces no output and exits with status `0` when its checks pass.
A mismatch causes status `1`.
Execution on physical Intel hardware was not run during the local check below.

## Run under Rosetta

Rosetta translates Intel macOS programs on Apple Silicon.

1. Run the example under Rosetta.

```sh
/usr/bin/arch -x86_64 ./build/math-demo
```

Output:

```text
min(12, 37) = 12
```

2. Run the tests under Rosetta.

```sh
/usr/bin/arch -x86_64 ./build/math-tests
```

The test program produces no output and exits with status `0` when its checks pass.

## Use the function

1. Copy `src/min.s` and its MIT license into the consuming project.
2. Include the source once in each linked program.

```asm
.include "src/min.s"
```

3. Put the two unsigned values in `rdi` and `rsi`.
4. Call `_asm_u64_min`.
5. Read the result from `rax`.

## Evidence and limits

The assembly harness checks 16 literal cases.
They cover zero, maximum values, equal values, reversed inputs, the signed boundary, and one-bit values above 32 bits.
After each call, it checks `rbx`, `rbp`, `r12-r15`, the stack pointer, and a stack canary.
A stack canary is a fixed value used to detect an unexpected stack write.
The demo retries interrupted writes and handles short writes.
The Python test also checks a failed output write.

On 2026-11-05, Apple clang 17.0.0 built the demo and harness on Apple Silicon macOS 15.6.1.
Both programs passed under explicit Rosetta execution.
This result does not establish execution on physical Intel hardware.
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
