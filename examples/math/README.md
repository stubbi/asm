# Unsigned integer helpers

This package supplies `asm_u64_min` for Linux x86-64 with the System V ABI.
It returns the smaller of two unsigned 64-bit integers.
The input values use `rdi` and `rsi`.
The result uses `rax`.
The function changes `rax` and the arithmetic flags.
It does not access data memory or allocate stack storage.
The caller must supply a valid call frame.

## Run the example

From this directory, run:

```sh
asm run
asm test
```

The example prints `min(12, 37) = 12`.
The test covers equal values, zero, the largest value, reversed inputs, and the signed boundary.
These tests are not a formal proof.
This package makes no performance claim.

## Use the function

From a consuming project, add the exact version:

```sh
asm add stubbi/math@0.1.0 --target x86_64-linux
```

Include the source in your GNU assembler file:

```asm
.include "stubbi/math/0.1.0/x86_64-linux/src/min.s"
```

ASM adds `.asm/packages` to the assembler's include path.
Call `asm_u64_min` with the interface described above.
Include the file once in each linked program.
