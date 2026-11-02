# Hello on RISC-V Linux

This program writes `Hello from asm!` and a newline to standard output. It then exits with status 0. It uses the Linux system-call interface and does not need a C runtime.

The source uses GNU assembler syntax. The build below targets little-endian RV64I with the LP64 ABI. The current Asm CLI runs and builds on x86-64 Linux. It can fetch this package, but it does not build or run this target.

## Build with GNU Binutils

Run these commands from this directory with the RISC-V cross tools on your path:

```sh
mkdir -p build
riscv64-linux-gnu-as -march=rv64i -mabi=lp64 -o build/hello.o src/main.s
riscv64-linux-gnu-ld -z noexecstack -o build/hello build/hello.o
```

On RV64 Linux, run `./build/hello`. On another Linux host with QEMU user-mode emulation, run `qemu-riscv64 ./build/hello`. Some distributions name that emulator `qemu-riscv64-static`.

The program's entry point is `_start`. This is a complete executable, not a callable library routine. It writes 16 bytes with Linux system call 64 and exits with system call 93. Registers `a0`, `a1`, `a2`, and `a7` hold the call arguments. Linker relaxation is disabled so that this small program does not require a global-pointer setup.
