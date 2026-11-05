# Unsigned integer helpers

This project supplies `asm_u64_min` for seven targets.
The function returns the smaller of two unsigned 64-bit integers.
Every 64-bit input value is permitted.
One manifest declares the implementations under `targets/<target>/`.

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

Each target contains `src/min.s`, `src/main.s`, assembly tests, and its interface instructions.
The root manifest selects the example and primary test for each target.
An ABI defines register, stack, call, and data-layout rules.
The target instructions specify the applicable ABI and preserved registers.

## Run with Asm

Use an Asm CLI built from this checkout.
Published 0.5.0 binaries do not support this manifest extension.

Native execution requires Linux x86-64, Linux AArch64, or Apple Silicon with macOS 15 or later.
Linux builds require GNU Binutils.
macOS builds require Apple's Command Line Tools.
The following commands require an installed Asm CLI.

1. Open this project directory.
2. Run the native example.

```sh
asm run
```

Expected output:

```text
min(12, 37) = 12
```

3. Run the native assembly tests.

```sh
asm test
```

The test exits with status zero.
Asm reports `Passed targets/<native-target>/tests/main.s`.
These tests are not a formal proof.
This project makes no performance claim.

## Build another Linux target

Cross builds produce files without executing them.
Linux hosts require the matching GNU cross assembler and linker in `/usr/bin`.
macOS requires Homebrew LLVM and LLD for Linux cross builds.
Asm uses `/opt/homebrew/opt/llvm/bin/clang` and `/opt/homebrew/opt/lld/bin/ld.lld`.

1. Check the targets available from this CLI.

```sh
asm targets
```

2. Build the RISC-V64 Linux example.

```sh
asm build --target riscv64-linux
```

Asm reports `Built build/riscv64-linux/app`.

3. Build its assembly test without execution.

```sh
asm test --target riscv64-linux --no-run
```

Native run and test commands execute only the host target.
Use the target instructions for deliberate execution through QEMU or a matching machine.
Windows and Intel macOS implementations use direct build commands.

## Callable interfaces

Include the selected `targets/<target>/src/min.s` once in each linked program.
Assembly include paths resolve from the project root.
Independent consumers must retain the MIT license when they copy source.
Historical published versions retain their original source paths.

| Target | Inputs | Result | Instructions |
| --- | --- | --- | --- |
| Linux x86-64, System V AMD64 | `rdi`, `rsi` | `rax` | [x86_64-linux](targets/x86_64-linux/README.md) |
| Linux AArch64, AAPCS64 | `x0`, `x1` | `x0` | [aarch64-linux](targets/aarch64-linux/README.md) |
| Linux RISC-V64, RV64I/LP64 | `a0`, `a1` | `a0` | [riscv64-linux](targets/riscv64-linux/README.md) |
| Apple Silicon macOS, Apple arm64 | `x0`, `x1` | `x0` | [aarch64-macos](targets/aarch64-macos/README.md) |
| Intel macOS, System V AMD64 | `rdi`, `rsi` | `rax` | [x86_64-macos](targets/x86_64-macos/README.md) |
| Windows x86-64, Microsoft x64 | `rcx`, `rdx` | `rax` | [x86_64-windows](targets/x86_64-windows/README.md) |
| Windows AArch64, Microsoft ARM64 | `x0`, `x1` | `x0` | [aarch64-windows](targets/aarch64-windows/README.md) |

macOS assembly uses `_asm_u64_min` as its symbol name.
The other targets use `asm_u64_min`.
An object for one target is not interchangeable with another target's object.

## Qualification and license

From the repository root, run the package checks:

```sh
python3 -m unittest discover -s tests/packages -p 'test_math_*.py' -v
python3 -m unittest discover -s tests/packages -p test_macos_reference_io.py -v
```

The tests preserve unsigned-boundary, register, stack, and output-failure checks for each applicable target.
Missing tools or runtimes produce explicit skips.
Cross-assembly, emulated execution, and native execution establish separate results.
Detailed target instructions retain the earlier evidence and its limits.
The retained RISC-V digests describe the source before this relocation.

The implementations come from repository commit `48bc44d5490b332dfa87fa60ffa91296d9423cbe`.
Only project-relative assembly include paths changed.
The root manifest retains checkout version `0.5.0`.
This source-layout change is unreleased.
Publishing changed bytes requires a new package version.
Published versions, records, and qualification digests remain unchanged.

The project license is MIT.
See [LICENSE](LICENSE).
