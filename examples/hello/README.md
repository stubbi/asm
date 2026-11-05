# Hello

This project writes `Hello from asm!` and a newline.
One manifest declares seven implementations of the same package.
Each target directory contains its source, tests when available, and platform instructions.

```text
asm.toml
LICENSE
targets/
  x86_64-linux/
  aarch64-linux/
  riscv64-linux/
  aarch64-macos/
  x86_64-macos/
  x86_64-windows/
  aarch64-windows/
```

Each implementation starts at `targets/<target>/src/main.s`.
The root manifest selects the source and optional test for each target.
A target declaration does not establish CLI host support or native qualification.

## Run with Asm

Use Asm 0.6.0 or later.
Earlier binaries do not support this manifest extension.

Native execution requires Linux x86-64, Linux AArch64, or Apple Silicon with macOS 15 or later.
Linux builds require GNU Binutils.
macOS builds require Apple's Command Line Tools.
The following commands require an installed Asm CLI.

1. Open this project directory.
2. Run the native implementation.

```sh
asm run
```

Expected output:

```text
Hello from asm!
```

3. Run the native startup test.

```sh
asm test
```

The test exits with status zero.
Asm reports `Passed targets/<native-target>/tests/main.s`.
These startup tests do not establish complete output or failure handling.
The package checks below cover those properties for the macOS implementations.

## Build another Linux target

Cross builds produce a file for another target without executing it.
Linux hosts require the matching GNU cross assembler and linker in `/usr/bin`.
macOS requires Homebrew LLVM and LLD for Linux cross builds.
Asm uses `/opt/homebrew/opt/llvm/bin/clang` and `/opt/homebrew/opt/lld/bin/ld.lld`.

1. Check the targets available from this CLI.

```sh
asm targets
```

2. Build the RISC-V64 Linux implementation.

```sh
asm build --target riscv64-linux
```

Asm reports `Built build/riscv64-linux/app`.
The source requires RV64I instructions and the LP64 ABI.
An ABI defines calls, register use, and data layout.
Use the target's manual instructions to run the file deliberately on Linux or through QEMU.

`asm run` and ordinary `asm test` execute only the native host target.
Windows and Intel macOS implementations use the direct build commands below.

## Target instructions

| Target | Instructions | Qualification boundary |
| --- | --- | --- |
| Linux x86-64 | [x86_64-linux](targets/x86_64-linux/README.md) | Linux process startup and greeting |
| Linux AArch64 | [aarch64-linux](targets/aarch64-linux/README.md) | Separate native or emulated Linux execution |
| Linux RISC-V64 | [riscv64-linux](targets/riscv64-linux/README.md) | RV64I/LP64; no RISC-V Asm CLI host |
| Apple Silicon macOS | [aarch64-macos](targets/aarch64-macos/README.md) | Native macOS process and injected write-result tests |
| Intel macOS | [x86_64-macos](targets/x86_64-macos/README.md) | Rosetta evidence is separate from physical Intel qualification |
| Windows x86-64 | [x86_64-windows](targets/x86_64-windows/README.md) | PE inspection is separate from native Windows execution |
| Windows AArch64 | [aarch64-windows](targets/aarch64-windows/README.md) | PE inspection is separate from native Windows execution |

From the repository root, run the package checks:

```sh
python3 -m unittest discover -s tests/packages -p 'test_hello_*.py' -v
python3 -m unittest discover -s tests/packages -p test_macos_reference_io.py -v
```

Missing platform tools or runtimes produce explicit skips.
A successful cross build does not establish native execution.

## Source and license

The platform implementations come from repository commit `48bc44d5490b332dfa87fa60ffa91296d9423cbe`.
The assembly includes now use paths relative to this project root.
The previous checkout's AArch64 Linux, RISC-V64 Linux, and Apple Silicon startup tests remain in their target directories.
The Intel macOS implementation has no manifest test; its package checks exercise output and failures.

The root manifest declares version `0.6.0`.
Its Linux source archives contain all seven implementations.
The release supplies hello executables for the three Linux targets only.
Earlier published versions, records, and qualification digests remain unchanged.

The project license is MIT.
See [LICENSE](LICENSE).
