# Hello on AArch64 Linux

This program writes `Hello from ASM.` and a newline to standard output. It then exits with status 0. It uses the Linux system-call interface and does not need a C runtime.

The source uses GNU assembler syntax. The target is little-endian, 64-bit AArch64 Linux. The current ASM CLI runs and builds on x86-64 Linux. It can fetch this package, but it does not build or run this target.

## Build with GNU Binutils

Run these commands from this directory with the AArch64 cross tools on your path:

```sh
mkdir -p build
aarch64-linux-gnu-as -o build/hello.o src/main.s
aarch64-linux-gnu-ld -z noexecstack -o build/hello build/hello.o
```

On AArch64 Linux, run `./build/hello`. On another Linux host with QEMU user-mode emulation, run `qemu-aarch64 ./build/hello`. Some distributions name that emulator `qemu-aarch64-static`.

The program's entry point is `_start`. This is a complete executable, not a callable library routine. It writes 16 bytes with Linux system call 64 and exits with system call 93. Registers `x0`, `x1`, `x2`, and `x8` hold the call arguments.
