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

The [server package record](server-package-evidence.json) retains native Linux x86-64 and ARM64 qualification.
Each target passed eight native-link tests, 19 extracted-package tests, 11 hosted-runtime tests, and four failure-preservation checks.
The reference package built through the recorded native Asm CLI.
The record binds the CLI, archive, both executables, test logs, toolchain, and exact checkout commit.
Downloaded artifact bytes independently matched their recorded digests.

The record also retains the schema-prefix regression: four readiness failures on each target, followed by both corrected suites passing.
Literal temporary-schema prefixes now prevent wildcard exclusions from hiding reader CREATE privileges.
The migration bytes and checksum remain unchanged.

The clean Apple Silicon checkout passed 225 CLI tests, 60 registry tests, and both verifier race-test packages.
Seven evidence-parser regressions passed separately; they do not establish server execution.
These results apply to their recorded commits and artifacts.
They do not establish a release, deployment, or performance result.

The [earlier checkpoint](native-linking-evidence.json) retains failed attempts and then-unrun gates.
It predates the server ports and response-file rejection.
Its crossassembly results do not replace the later native Linux results.

## Target coverage

The [shared coverage audit](target-coverage.md) and [architecture acceptance gates](architecture-gates.md) define the wider platform work.
This section covers native linking and the assembly server only.
All native-linking additions remain unreleased.

| CLI host target | ISA | OS | C ABI for linked projects | CPU requirement | Current CLI evidence |
| --- | --- | --- | --- | --- | --- |
| `x86_64-linux` | x86-64 | Linux | System V AMD64, LP64 | No additional instruction extension introduced | Native GNU build and eight C ABI regressions passed |
| `aarch64-linux` | AArch64 | Linux | AAPCS64, LP64 | ARMv8-A | Native GNU build and eight C ABI regressions passed |
| `aarch64-macos` | AArch64 | macOS 15+ | Apple arm64, LP64 | Apple Silicon | Native build, execution, and CLI tests passed |

The package must declare any additional library ABI, runtime, and CPU requirements.
Linux kernel and libc minimums for this extension remain unqualified.
These CLI results do not qualify a server on the same ISA.
The Linux native-link tests inspect PIE, RELRO, immediate binding, and the non-executable stack.
The recorded jobs used GNU compiler and binutils tools.
The macOS tests check the corresponding Mach-O build and execution contract.

The reference server now has x86-64, AArch64, and RV64GC/LP64D source implementations.
Target-specific manifests and header assertions accompany those sources.
The x86-64 and ARM64 suites passed in the recorded native jobs.
The RISC-V reference package still requires its separate extracted-build execution gate.
The hosted foundation also has target-specific runtime and configuration sources, with its separate TLS suite.
These source ports do not establish deployment qualification or new released support.
Neither server has a macOS or Windows implementation.
Intel macOS and Windows CLI expansion also remain outside this native-linking qualification.

## ARM64 server implementation and qualification

`experiments/assembly-server/aarch64/server.s` implements the reference server with AAPCS64 calls and Linux AArch64 system calls.
`server/aarch64/runtime.s` and `config.s` implement the hosted foundation with its existing TLS policy.
All three files passed local crossassembly and the recorded native Linux ARM64 runtime suites.

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
