# Native AArch64 CLI

This directory contains the Linux AArch64 implementation of asm.
The assembler emits ARMv8-A instructions directly.
The executable has no instruction interpreter or C runtime.
Transport, decompression, digest, and provenance checks use the same fixed external tools as the x86-64 implementation.

## Build

On Linux AArch64, run `make` with GNU binutils installed.
On another supported Linux host, install the AArch64 GNU cross-binutils package and run:

```sh
make ARCH=aarch64 build/asm-aarch64-linux
```

The build keeps each architecture's objects and executable in a separate path.
`make ARCH=aarch64 build/asm` selects the AArch64 executable as the local development command.

## Internal ABI

The internal ABI is explicit. It is not the C function-call ABI.
It requires a stack pointer aligned to 16 bytes at each instruction.

| Register | Use |
| --- | --- |
| `x0` to `x7` | Arguments and documented caller scratch |
| `x9` | Result |
| `x19` to `x24` | Preserved by returning routines |
| `x8`, `x10` to `x17`, NZCV | Scratch for every routine, in addition to its stated scratch registers |
| `x25` to `x29` | Unused and preserved |
| `x30` | Native link register |

`ARM_CALL` saves the caller's link register in a 16-byte frame around `BL`.
`ARM_SAVE` and `ARM_RESTORE` use one 16-byte stack slot for each preserved register.
The comments state a routine's local stack use. Nested call frames are additional.
Each syscall adapter uses 64 bytes; the alarm adapter uses 128 bytes.
Each adapter also has its caller's 16-byte `ARM_CALL` frame.

The parser preserves the existing depth, token, input, and string bounds.
Its native harness checks guard pages, read-only input, register preservation, stack balance, and cleared output on rejection.

## Linux ABI boundary

`platform.s` contains typed native syscall adapters.
There is no syscall-number interpreter.
The adapters return the kernel result in `x9` and preserve `x0` to `x7`.
Arguments four through six use `x6`, `x4`, and `x5` at this internal boundary.
The adapter places them in the kernel's required registers before `SVC`.

The adapters use `openat`, `newfstatat`, `mkdirat`, `unlinkat`, and `renameat` for path operations.
The fork adapter uses `clone` with `SIGCHLD` and no sharing flags.
The duplicate-descriptor adapter preserves the equal-descriptor behavior of `dup2`.
The alarm adapter uses `setitimer` and rounds the previous remaining time up to whole seconds.

The port uses the native 128-byte Linux `stat` layout.
The mode and link count are 32-bit fields at offsets 16 and 20.
UID and GID are 32-bit fields at offsets 24 and 28.
The 64-bit file size remains at offset 48.

Linux AArch64 open flags differ from Linux x86-64 flags.
`O_DIRECTORY` is 16384 and `O_NOFOLLOW` is 32768.
The constants were checked against `linux-libc-dev-arm64-cross` version `6.8.0-25.25cross1`.
The authoritative headers are `asm/fcntl.h`, `asm/unistd.h`, `asm/signal.h`, and `asm-generic/stat.h` in that package.

## Port review

Keep equivalent command behavior and failure boundaries on each native host.
When changing shared behavior, review both implementations and their native tests.
Check partial-register updates, signed and unsigned branches, overflow checks, stack frames, and target constants explicitly.
Do not copy architecture-specific syscall numbers, structure offsets, open flags, or ELF machine identifiers between implementations.

QEMU checks establish behavior for their tested inputs.
They do not establish native AArch64 performance or replace native host integration tests.
Measure native workloads before making a performance claim.
