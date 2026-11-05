# Hello for AArch64 Linux

This implementation belongs to the [hello project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).

The program writes `Hello from asm!` and exits with status zero.
It uses Linux system calls and requires no C runtime.
The target is little-endian AArch64 Linux.

## Build with GNU Binutils

These commands require GNU AArch64 Linux cross-binutils.
On another Linux architecture, execution requires QEMU user-mode emulation.

1. Open this target directory.
2. Create the output directory.

```sh
mkdir -p build
```

3. Assemble and link the example and startup test.

```sh
aarch64-linux-gnu-as --fatal-warnings -o build/hello.o src/main.s
aarch64-linux-gnu-ld -z noexecstack --build-id=none -o build/hello build/hello.o
aarch64-linux-gnu-as --fatal-warnings -o build/tests.o tests/main.s
aarch64-linux-gnu-ld -z noexecstack --build-id=none -o build/tests build/tests.o
```

Successful build commands produce no output.

4. Run both programs through QEMU.

```sh
qemu-aarch64 ./build/hello
qemu-aarch64 ./build/tests
```

Some distributions name the emulator `qemu-aarch64-static`.
On AArch64 Linux, run each executable directly instead.

The example prints `Hello from asm!` and a newline.
The startup test produces no output and exits with status zero.
Emulated execution does not establish behavior on physical AArch64 hardware.

## Target and limits

The entry point is `_start`.
The example requests a 16-byte write with Linux system call 64.
It exits with system call 93.
Registers `x0`, `x1`, `x2`, and `x8` hold the system call arguments and number.
The example performs one write and does not check its result.
The startup test does not establish output-error or short-write handling.

The project [README](../../README.md) describes native Asm commands from the project root.
