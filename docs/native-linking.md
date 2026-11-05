# Native library builds

Status: implementation contract for source builds.
Published Asm 0.4.0 binaries do not support this extension.

## Purpose

An assembly package can call established native libraries without a generated application backend.
The first consumer is the experimental Linux x86-64 server.
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
Build-source and checker path components cannot start with `@`, which compilers can interpret as response-file input.
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

The [5 November 2026 record](native-linking-evidence.json) identifies the checked artifacts, passing tests, failed attempts, and unrun gates.
Native macOS behavior passed; Linux crossassembly does not establish Linux execution.
The extracted Linux server's build and runtime tests remain unrun because local storage failed during dependency setup.

## Target coverage

The [shared coverage audit](target-coverage.md) defines the wider architecture work.
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
Linux native-library builds still need execution through the six shared tests on each Linux host.
The existing x86-64 and ARM64 CI jobs discover those tests through `make check`.
Their configuration is not evidence that a run passed.

The current server declares Linux x86-64 and the System V AMD64 LP64 ABI.
Its source has cross-assembled, but the new extracted-package build and 17 server tests remain unrun.
It has no ARM64, RISC-V64, macOS, or Windows implementation or deployment qualification.
Intel macOS and Windows CLI expansion also remain outside this native-linking qualification.

## Remaining ARM64 server port

The port must preserve the existing x86-64 package and its failure behavior.
Changing the manifest target alone cannot translate its assembly or ABI assertions.

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

## Remaining RISC-V64 port

The existing RV64I/LP64 hello example does not establish a native CLI or server.
A full port needs an explicit ISA, C ABI, runtime minimum, PIC, and linker-relaxation policy.
RV64GC/LP64D is a candidate for native-library work, not an accepted support declaration.

1. Select and document the ISA extensions, operating system, ABI, CPU requirements, and toolchain independently.
2. Port every CLI module and syscall adapter before enabling a RISC-V architecture branch.
3. Port native-link arguments, compiler environments, staging, publication validation, and failure preservation.
4. Replace x86-or-ARM assumptions in host fixtures and target-specific build selection.
5. Review native ELF flags for the selected ABI and ISA; do not copy the existing zero-flags rule.
6. Add RISC-V server assembly, target-header assertions, and runtime-version preload fixtures.
7. Qualify pinned dependencies, the extracted package, and full CLI and server suites on the selected target.
8. Keep emulator results separate from native qualification and physical performance measurements.

The Makefile currently rejects RISC-V CLI builds before output creation.
Its source selection and verifier mapping also need explicit branches before that guard can change.
Release and installer changes belong to the separate release workstream after target qualification.
The [RISC-V psABI](https://riscv-non-isa.github.io/riscv-elf-psabi-doc/) defines ABI and ELF distinctions.
Version 2.0-rc0, dated 4 November 2026, was inspected on 5 November 2026.
The [GNU assembler 2.47 options](https://sourceware.org/binutils/docs/as/RISC_002dV_002dOptions.html) define ISA, ABI, PIC, and relaxation controls.
