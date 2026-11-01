# Hello on AArch64 Linux

This program writes `Hello from asm!` and a newline to standard output.
It then exits with status 0.
It uses Linux system calls and GNU assembler syntax.
It requires no C runtime.

## Run with ASM

On Linux ARM64, install ASM and GNU Binutils.
Run this command from the package directory:

```sh
asm run
```

ASM builds the program before it runs it.
The program prints:

```text
Hello from asm!
```

For a repository checkout on Linux ARM64, run these commands from the repository root:

```sh
make &&
cd examples/hello-aarch64 &&
../../build/asm run
```

## Cross-assemble with GNU Binutils

On Linux x86-64, install AArch64 GNU cross-binutils and QEMU user emulation.
Run these commands from this package directory:

```sh
mkdir -p build &&
aarch64-linux-gnu-as -o build/hello.o src/main.s &&
aarch64-linux-gnu-ld -z noexecstack -o build/hello build/hello.o &&
qemu-aarch64 ./build/hello
```

The output is the same.
Some distributions name the emulator `qemu-aarch64-static`.

## Target and interface

The target is little-endian, 64-bit AArch64 Linux.
The entry point is `_start`.
The program writes 16 bytes with Linux system call 64 and exits with system call 93.
Registers `x0`, `x1`, `x2`, and `x8` hold the system call arguments and number.

The license is MIT.
See [LICENSE](LICENSE).
