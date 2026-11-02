# Hello for Linux x86_64

This program writes `Hello from asm!` and exits with status 0.
It uses Linux system calls and GNU assembler syntax.
It requires no C runtime.

## Build and run

First, build the Asm CLI from the repository root:

```sh
make
cd examples/hello
../../build/asm build
../../build/asm run
```

The build command reports `Built build/app`.
The program writes:

```text
Hello from asm!
```

Run the example tests:

```sh
../../build/asm test
```

If you download this source package separately, use your installed `asm` command.
Run `asm build`, `asm run`, and `asm test` from the package directory.

## Target

- Architecture: x86-64.
- Operating system: Linux.
- Object format: ELF64, little-endian.
- Interface: the Linux x86-64 system call convention.
- Build tools: GNU `as` and `ld` from binutils.

The license is MIT. See [LICENSE](LICENSE).
