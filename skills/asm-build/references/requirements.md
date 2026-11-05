# Behavior and target requirements

Use existing specifications and tests before requesting missing decisions.
Do not replace an explicit user choice with a default.

## Define observable behavior

1. Identify the person, task, and entry point: command, library call, service, or complete executable.
2. Define accepted inputs, encodings, length bounds, and numeric ranges.
3. Define outputs, formatting, ordering, exit codes, and file effects.
4. Specify invalid-input, unavailable-resource, and interrupted-operation behavior.
5. Identify existing files and state that failures must preserve.
6. Record representative acceptance cases and their expected results.
7. Identify external dependencies and the scope of permitted side effects.

Include empty inputs, boundaries, malformed inputs, and relevant operating-system failures.
Use temporary directories for file tests.
Use fixed seeds and resource limits for generated or hostile inputs.
Check standard output, standard error, exit codes, and file effects separately for commands.

## Resolve deployment requirements

1. Declare the ISA, operating system, ABI, object format, minimum OS, and CPU features independently.
2. Identify the assembler dialect, assembler, linker, runtime libraries, and their versions.
3. Record native hardware, emulators, and cross tools that are actually available.
4. Mark unknown target requirements as unresolved.
5. Explain unsupported targets before a download or build.

The ABI governs register arguments, return values, preserved registers, stack alignment, and data layout.
A system-call interface does not define a callable library interface.
A CPU architecture name does not imply optional instruction extensions.
The registry target field does not encode every extension or ABI revision.
Read `targets.json` for guidance; qualify each selected artifact separately.

For MCP planning, use the canonical target values below.
These calling conventions remain distinct from each operating system's system-call interface.

| Target | ISA | OS | ABI |
| --- | --- | --- | --- |
| `x86_64-linux` | `x86_64` | `linux` | `System V AMD64` |
| `aarch64-linux` | `aarch64` | `linux` | `AAPCS64` |
| `aarch64-macos` | `aarch64` | `macos` | `Apple arm64` |
| `riscv64-linux` | `riscv64` | `linux` | `LP64` |

For the reviewed RISC-V reference source, install GNU RISC-V cross-binutils and QEMU before these commands.
Its `src/main.s` defines `_start` and uses `.option norelax` to avoid an uninitialized global pointer.

```sh
mkdir -p build
riscv64-linux-gnu-as -march=rv64i -mabi=lp64 -o build/hello.o src/main.s
riscv64-linux-gnu-ld -z noexecstack -o build/hello build/hello.o
qemu-riscv64 ./build/hello
```

The reference prints `Hello from asm!` with a newline and exits with status zero.
These commands require reviewed source in a fresh build destination.
They demonstrate external cross-assembly and emulation, not a native RISC-V Asm CLI.

## Define routine contracts

1. Specify input registers, permitted values, pointer validity, alignment, lengths, and aliasing rules.
2. Specify output registers, status values, and memory effects on success and failure.
3. List changed registers, flags, preserved registers, stack use, and external-call alignment.
4. State buffer capacities, ownership, allocation, and lifetime requirements.
5. State system-call, calling-convention, thread, and runtime assumptions that affect behavior.

Keep invalid input from changing state before validation completes.
Use mature transport and cryptography implementations where those capabilities are required.
Pass argument arrays directly to fixed tools; do not construct shell commands from package data.

## Gate the next step

1. Resolve a missing decision before implementing behavior that depends on it.
2. Continue checks or implementation that do not depend on that decision.
3. Use a correct reference result before comparing candidate performance.
4. Keep unavailable execution and unrun tests visible.

A project is ready for implementation when its next change has an explicit contract and checkable acceptance cases.
It is not ready for a support claim while required target checks remain unavailable.

## Evidence to retain

- Behavior contract and acceptance inputs with expected results.
- Exact source revisions, dependency versions, artifact digests, and tool versions.
- Declared target requirements and actual execution environment.
- Test commands, exit codes, results, failures, and unrun cases.
- Visible-output commands and the observed output or file effect.

In an Asm checkout, follow its Makefile and repository instructions for required gates.
CLI changes require `make test`; verifier or trust-publication changes require `make verifier-test`.
Registry and site changes require their documented checks.
These platform gates are separate from a package's own `asm test`.
