# Hello for RISC-V64 Linux

This implementation belongs to the [hello project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).

The program writes `Hello from asm!` and exits with status zero.
It uses Linux system calls and requires no C runtime.
The source targets little-endian RV64I with the LP64 ABI.
An ABI defines register, stack, call, and data-layout rules.

## Build with GNU Binutils

These commands require GNU RISC-V64 Linux cross-binutils.
On another Linux architecture, execution requires QEMU user-mode emulation.

1. Open this target directory.
2. Create the output directory.

```sh
mkdir -p build
```

3. Assemble and link the example and startup test.

```sh
riscv64-linux-gnu-as --fatal-warnings -march=rv64i -mabi=lp64 -o build/hello.o src/main.s
riscv64-linux-gnu-ld -z noexecstack --build-id=none -o build/hello build/hello.o
riscv64-linux-gnu-as --fatal-warnings -march=rv64i -mabi=lp64 -o build/tests.o tests/main.s
riscv64-linux-gnu-ld -z noexecstack --build-id=none -o build/tests build/tests.o
```

Successful build commands produce no output.

4. Run both programs through QEMU.

```sh
qemu-riscv64 ./build/hello
qemu-riscv64 ./build/tests
```

Some distributions name the emulator `qemu-riscv64-static`.
On RISC-V64 Linux, run each executable directly instead.

The example prints `Hello from asm!` and a newline.
The startup test produces no output and exits with status zero.
Emulated execution does not establish behavior on physical RISC-V64 hardware.

## Target and limits

The entry point is `_start`.
The example requests a 16-byte write with Linux system call 64.
It exits with system call 93.
Registers `a0`, `a1`, `a2`, and `a7` hold the call arguments and number.
Linker relaxation is disabled, so the program needs no global-pointer setup.
The example performs one write and does not check its result.
The startup test does not establish output-error or short-write handling.

The project [README](../../README.md) describes Asm cross builds from the project root.
A RISC-V64 Asm CLI host remains unavailable.
