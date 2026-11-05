# Unsigned integer helpers for Linux x86-64

This implementation belongs to the [math project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).

`asm_u64_min` returns the smaller of two unsigned 64-bit integers.
All 64-bit input values are valid.
It uses the Linux x86-64 System V ABI.
An ABI defines register, stack, call, and data-layout rules.

## Function contract

| Item | Contract |
| --- | --- |
| Inputs | `rdi = a`, `rsi = b` |
| Result | `rax = min(a, b)`, using unsigned comparison |
| Failure values | None |
| Changed state | `rax` and arithmetic flags |
| Preserved state | All other registers; the caller's stack pointer is restored after return |
| Data memory | No data access; `RET` reads the caller's return address |
| Stack | No local storage; the caller supplies a valid call frame |

## Build and run directly

These commands require GNU Binutils on Linux x86-64.
The assembler include path points to the project root.

1. Open this target directory.
2. Create the output directory.

```sh
mkdir -p build
```

3. Assemble and link the example and tests.

```sh
as --64 --fatal-warnings -I ../.. -o build/math.o src/main.s
ld -z noexecstack --build-id=none -o build/math build/math.o
as --64 --fatal-warnings -I ../.. -o build/tests.o tests/main.s
ld -z noexecstack --build-id=none -o build/tests build/tests.o
```

Successful build commands produce no output.

4. Run the example and tests.

```sh
./build/math
./build/tests
```

The example prints `min(12, 37) = 12` and a newline.
The tests produce no output and exit with status zero.
The eight value cases cover zero, equality, reversed inputs, maximum values, and the signed boundary.
They do not establish a formal proof or performance result.
The example performs one output write and does not check its result.

## Use the function

1. Copy `src/min.s` and `../../LICENSE` into the consuming project.
2. Include the source once in each linked program.

```asm
.include "src/min.s"
```

3. Put the unsigned input values in `rdi` and `rsi`.
4. Call `asm_u64_min`.
5. Read the result from `rax`.

The project [README](../../README.md) describes Asm commands from the project root.
