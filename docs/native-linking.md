# Native library builds

Status: implementation contract for source builds.
Published Asm 0.5.0 binaries do not support this extension.

## Purpose

An assembly package can call established native libraries without a generated application backend.
The first consumer is the experimental Linux server package.
Dependable reuse requires explicit inputs, retained ABI checks, and understandable failures.

## Manifest

The existing four required manifest fields remain unchanged.
These optional quoted strings belong to `[build]`:

```toml
link = "c"
libraries = "microhttpd pq pthread"
check = "abi-check.c"
```

`link = "c"` selects the system C ABI and startup objects.
Without `link`, Asm retains its existing standalone build.
Other link values are errors.
`libraries` and `check` require `link = "c"`.
Duplicate fields and explicitly empty strings are errors.

`libraries` contains at most eight names separated by one ASCII space.
Each name matches `[a-z][a-z0-9_-]{0,30}`.
Leading, repeated, and trailing spaces are errors.
Each name becomes one `-lNAME` argument.
The field cannot contain linker flags or paths.

`check` names a relative `.c` file using the existing source-path rules.
Source and checker path components cannot start with `@` or `-`.
Compilers can interpret these names as options, including generated frontend metadata.
Source archives must include that file.
Archive paths retain the registry's stricter portable-path rules and 240-byte limit.
Asm compiles it with `-fsyntax-only`, C11, and warnings as errors.
Asm does not execute the checker or add it to the application.
The server retains its header assertions and checks library versions in assembly before opening a listener.

## Local library installations

`build`, `run`, and `test` accept repeated `--include-dir PATH` and `--library-dir PATH` options.
Each option accepts at most eight absolute paths, each containing at most 255 printable ASCII characters.
Paths cannot contain a colon or comma.
These options require `link = "c"`.
They are errors on other commands.

Include directories apply to the compile-only check.
Library directories supply explicit search paths and runtime search paths.
Machine-local paths do not become package metadata.
Asm does not download or install native libraries.

## Tool execution and failure behavior

The CLI implements parsing, validation, arguments, and process control in assembly.
It invokes fixed assembler and `/usr/bin/cc` paths with direct arguments.
It constructs no shell command and invokes no Makefile or package hook.
Compiler children receive only fixed `PATH=/usr/bin:/bin` and `LC_ALL=C` environment entries.
Ambient compiler, loader, and include-path settings cannot override these inputs.

Linux linking uses PIE, RELRO, immediate binding, and a non-executable stack.
macOS linking uses the Apple ABI, PIE, and the existing macOS deployment minimum.
The existing private build stage and final rename remain in use.
Invalid fields, unsupported targets, failed checks, and linker failures retain the previous executable.
The ordinary standalone build remains unchanged.

## C dependency boundary

Calling a C library from assembly retains that library as a runtime dependency.
The server's HTTP and PostgreSQL libraries remain external dependencies.
Its C checker supplies build evidence and is not an application backend.
A separate assembly protocol package requires its own contract, security review, and qualification evidence.
This build extension does not qualify such a replacement or change the architecture's transport and cryptography requirements.

## Validation record

The [earlier 5 November 2026 record](native-linking-evidence.json) retains the first implementation checkpoint.
It predates the server ports and response-file rejection.
It identifies its own artifacts, passing tests, failed attempts, and unrun gates.
Native macOS behavior passed; Linux crossassembly does not establish Linux execution.
The extracted Linux server's build and runtime tests remain unrun because local storage failed during dependency setup.

## Target coverage

The [architecture acceptance gates](architecture-gates.md) define the wider platform work.
This section covers native linking and the assembly server only.
All native-linking additions remain unreleased.

| CLI host target | ISA | OS | C ABI for linked projects | CPU requirement | Current CLI evidence |
| --- | --- | --- | --- | --- | --- |
| `x86_64-linux` | x86-64 | Linux | System V AMD64, LP64 | No additional instruction extension introduced | Cross-built ELF; container and stack checks passed; runtime unrun |
| `aarch64-linux` | AArch64 | Linux | AAPCS64, LP64 | ARMv8-A | Cross-built ELF; container and stack checks passed; runtime unrun |
| `aarch64-macos` | AArch64 | macOS 15+ | Apple arm64, LP64 | Apple Silicon | Native build, execution, and CLI tests passed |

The package must declare any additional library ABI, runtime, and CPU requirements.
Linux kernel and libc minimums for this extension remain unqualified.
These CLI results do not qualify a server on the same ISA.
The cross-build used Clang and LLD, not the canonical GNU release toolchain.
The Linux ELF checks cover CLI executables; C ABI project execution remains unrun.
Linux native-library builds still need execution through the eight shared tests on each Linux host.
The existing x86-64 and ARM64 CI jobs discover those tests through `make check`.
Their configuration is not evidence that a run passed.

The reference server now has x86-64, AArch64, and RV64GC/LP64D source implementations.
Target-specific manifests and header assertions accompany those sources.
Their shared HTTP, PostgreSQL, runtime-version, and failure suites require separate execution evidence for each target.
The hosted foundation also has target-specific runtime and configuration sources, with its separate TLS suite.
These source ports do not establish deployment qualification or new released support.
Neither server has a macOS or Windows implementation.
Intel macOS and Windows CLI expansion also remain outside this native-linking qualification.

## ARM64 server implementation and qualification

`experiments/assembly-server/aarch64/server.s` implements the reference server with AAPCS64 calls and Linux AArch64 system calls.
`server/aarch64/runtime.s` and `config.s` implement the hosted foundation with its existing TLS policy.
All three files passed local crossassembly; native Linux execution remains a separate gate.
The following requirements govern qualification and future changes.

1. Add AArch64 source and target-specific package inputs beside `experiments/assembly-server/server.s` and `asm.toml`.
2. Declare ARMv8-A, Linux, AAPCS64 LP64, runtime minimums, and additional CPU requirements separately.
3. Port C calls, callbacks, variadic startup, return registers, callee-saved registers, and stack frames.
4. Replace x86 system calls, open flags, and `stat` offsets in configuration handling.
5. Assert the selected target headers and layouts in a target-specific `abi-check.c`.
6. Preserve pinned libraries, assembly runtime-version rejection, SQL, deadlines, ownership, signals, and shutdown behavior.
7. Add AArch64 preload fixtures to `test_runtime_versions.py` without weakening the x86 cases.
8. Build the pinned dependencies and extracted package through the native ARM64 CLI as an ordinary user.
9. Run all server tests and inspect the resulting ELF, hardening, dependencies, and file-preservation failures.
10. Record source and artifact digests, toolchain, kernel, library versions, and native or emulated execution before declaring support.

The server uses the C ABI, not the CLI's internal `x9` result convention.
Its HTTP callback and PostgreSQL calls need their own argument review.
The [AAPCS64 2025Q1 specification](https://github.com/ARM-software/abi-aa/blob/2025Q1/aapcs64/aapcs64.rst) and pinned target headers govern that review.
The ABI source was checked on 5 November 2026; it does not establish a minimum supported kernel.

## RISC-V64 server implementation and CLI integration

`experiments/assembly-server/riscv64/server.s` and `server/riscv64/{runtime,config}.s` implement native RV64 server instructions.
These servers select little-endian RV64GC and the LP64D C ABI.
Their headers require the declared integer, atomic, compressed, and double-precision floating-point features.
Local LLVM assembly checks produced ELF machine 243 with flags 5: compressed instructions and double-float ABI.
GNU linkage and runtime execution still require target-specific qualification.
The existing RV64I/LP64 hello example does not establish this native-library ABI or server behavior.

The independently owned RISC-V CLI port must select `-march=rv64gc -mabi=lp64d` for `link = "c"` projects.
Its freestanding profile must remain distinct.
Until that CLI integration passes, the RISC-V reference package's extracted `asm build` gate remains open.
The hosted foundation uses its direct native compiler build and can qualify independently.

1. Select and document the ISA extensions, operating system, ABI, CPU requirements, and toolchain independently.
2. Port every CLI module and syscall adapter before enabling a RISC-V architecture branch.
3. Port native-link arguments, compiler environments, staging, publication validation, and failure preservation.
4. Replace x86-or-ARM assumptions in host fixtures and target-specific build selection.
5. Review native ELF flags for the selected ABI and ISA; do not copy the existing zero-flags rule.
6. Add RISC-V server assembly, target-header assertions, and runtime-version preload fixtures.
7. Qualify pinned dependencies, the extracted package, and full CLI and server suites on the selected target.
8. Keep emulator results separate from native qualification and physical performance measurements.

The RISC-V CLI implementation is maintained on a separate branch.
Its native-library integration needs the same compiler argument rejection and runtime checks before qualification.
Release and installer changes belong to the separate release workstream after target qualification.
The [RISC-V psABI](https://riscv-non-isa.github.io/riscv-elf-psabi-doc/) defines ABI and ELF distinctions.
Version 2.0-rc0, dated 4 November 2026, was inspected on 5 November 2026.
The [GNU assembler 2.47 options](https://sourceware.org/binutils/docs/as/RISC_002dV_002dOptions.html) define ISA, ABI, PIC, and relaxation controls.

## Prepare a target-specific reference package

Use Python 3.11 or later to prepare source without changing the checkout's x86-64 manifest:

```sh
python3 experiments/assembly-server/package.py \
  --target aarch64-linux --output build/server-aarch64-source
```

The new directory contains a standalone `asm.toml` with the selected source and target.
Run `asm build` there on the matching Linux host, with the required native library paths.
`--target riscv64-linux` prepares the RISC-V source tree; it does not supply a RISC-V CLI or execute a build.
The helper rejects existing destinations, source links, special files, and nonportable paths.
Preparation runs no package code.

The source-only hosted handoff is `codex/server-runtime-ports`, commits `e3fabf00` and `3d2d0f45`, based on public main `78c6c91`.
It contains no image, installer, or release changes.
The native-package workflow separately exercises current Linux x86-64 and ARM64 CLI builds and both server suites.
The hosted image workflow owns native x86-64/ARM64 and explicitly emulated RISC-V image qualification.
