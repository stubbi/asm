# Use a source package

This example calls a function from `stubbi/math@0.2.0`.
It runs on Linux x86-64.
Install Asm and run `asm doctor` before you start.

## Create the project

```sh
asm new minimum
cd minimum
asm add stubbi/math@0.2.0 --target x86_64-linux
```

Asm checks the archive and extracts its source.
It writes the exact version, target, URL, size, and digest to `asm.lock`.
The source is under `.asm/packages/stubbi/math/0.2.0/x86_64-linux`.

## Call the function

Replace `src/main.s` with this complete program:

```asm
.intel_syntax noprefix
.include "stubbi/math/0.2.0/x86_64-linux/src/min.s"

.section .text
.global _start
_start:
    mov edi, 12
    mov esi, 37
    call asm_u64_min
    cmp rax, 12
    jne .Lfailure
    mov eax, 1
    mov edi, 1
    lea rsi, [rip + message]
    mov edx, message_end - message
    syscall
    mov eax, 60
    xor edi, edi
    syscall
.Lfailure:
    mov eax, 60
    mov edi, 1
    syscall

.section .rodata
message: .ascii "min(12, 37) = 12\n"
message_end:
.section .note.GNU-stack,"",@progbits
```

The function takes two unsigned 64-bit integers in `RDI` and `RSI`.
It returns the smaller value in `RAX`.
Read the [function contract](../examples/math/README.md) before other uses.

## Check and run

```sh
asm lock
asm run --locked
```

The program prints:

```text
min(12, 37) = 12
```

`asm lock` checks each locked archive and its extracted source files.
`asm run --locked` checks dependencies, builds the program, and runs it.
It requires `asm.lock` to exist.
An altered dependency causes an error before assembly.

## Restore the same selection

Commit `asm.toml`, `asm.lock`, and your source files.
Exclude `build/` and `.asm/` from version control.
In another checkout, run:

```sh
asm sync
asm run --locked
```

Sync uses the exact URLs and digests in the lock file.
It does not choose newer versions.
The artifacts must still be available at those URLs.

## Change a selection

Use `asm update owner/name@X.Y.Z` with the exact version that you intend to review.
Update your explicit include path when the version changes.
Run your program and tests before committing the new lock file.

Use `asm remove stubbi/math` to remove the selection.
Remove its include and function calls from your source too.
The command retains cached files.

The current resolver supports direct source dependencies.
It does not resolve transitive dependencies or version ranges.
A lock file checks declared packages; GNU assembler can still read other local files.
