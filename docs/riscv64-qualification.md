# RISC-V64 CLI qualification

This development harness checks the RISC-V64 Linux CLI through its public commands.
It does not add a released host or qualify release distribution.
The user outcome is the same completed project and package tasks on an independently checked target.
The governing principles are dependable reuse and trust earned through evidence.

## Target contracts

| Artifact | ISA | Operating system | ABI | Required CPU features |
| --- | --- | --- | --- | --- |
| Native assembly CLI | RV64IM | Linux | LP64 | Integer multiplication and division, extension M |
| Freestanding starter | RV64I | Linux | LP64 | Base integer instructions |
| Project linked with C libraries | RV64GC | Linux | LP64D | General-purpose extensions and compressed instructions |

The Linux minimum version is not qualified by this harness.
The CLI uses direct Linux system calls and fixed external tool paths.
The harness records the actual kernel and tool versions for each run.

The private CLI calling convention returns results in `t0`.
Returning routines preserve `s0` through `s5`, `sp`, `gp`, and `tp`.
Other saved-register names are private scratch registers.
Every stack reservation preserves 16-byte alignment.
This convention differs from the public RISC-V C ABI.
A C wrapper must preserve all registers required by the public ABI.

The archive and release-metadata harnesses check the private preservation contract.
Metadata fixtures place read-only input immediately before an inaccessible guard page.
Every truncation, malformed corpus, and parser bound retains the existing assertions.

## Run on a RISC-V64 Linux host

GNU assembler, GNU linker, a C compiler, Python 3, and Make are required.
The fixed `/usr/bin/as`, `/usr/bin/ld`, and `/usr/bin/cc` tools must target RISC-V64.
The normal CLI suite also needs its documented transport and verification fixtures.

1. Build the executable with `make ARCH=riscv64 build/asm-riscv64-linux`.
2. Run the qualification command below.
3. Read the JSON result and retained logs.

```sh
python3 tools/riscv64_test.py --asm build/asm-riscv64-linux --execution-mode native --evidence build/riscv64-qualification.json
```

The expected final line contains `qualification: pass` when all required checks pass.
A missing tool, failed command, timeout, changed artifact, or skipped check produces a failure.
The command retains the failed check and leaves later checks marked `not-run`.

The runner executes `make test ARCH=riscv64` and the focused RISC-V tests.
The complete suite covers project creation, builds, execution, archives, registry inputs, dependencies, publication requests, installed programs, and update recovery.
These tests include unsupported targets, corrupt artifacts, network failures, and existing destinations.
Tests create private transport and verification fixtures.
Those fixtures do not establish real release-signature verification.

Some cross-user checks require a root test process.
Run those checks in an isolated machine or the disposable CI job.
A skipped check prevents this runner from reporting complete qualification.

## Emulated Linux qualification

The workflow uses QEMU user-mode emulation on an isolated Ubuntu runner.
A registered binary-format handler allows Python and the CLI to execute RISC-V ELF files directly.
The workflow selects GNU cross-tools at the CLI's fixed paths.
It installs RISC-V libc headers and startup objects for the linked-project tests.
These path changes apply only to that disposable runner.
They must not be applied to a person's workstation.

`ASM_TEST_TARGET=riscv64-linux` selects equivalent assembly fixtures for the guest target.
The override is accepted only on Linux.
It does not implement CLI commands or change production executable bytes.
Fault-injection filters still use actual host-kernel syscall numbers.
An emulation difference that prevents a required assertion remains a failed check.
QEMU can combine distinct guest resource-limit operations into the host `prlimit64` call.
Complete syscall-failure qualification can therefore require a full-system guest or a native host.

The workflow runs the suite as root in a protected copy below `/tmp`.
This includes real cross-user checks without trusting a writable checkout ancestor.
The repository token has read-only contents permission.
The checkout does not retain credentials.
The workflow has no publication, deployment, or signing step.

The `--execution-mode emulated` result always has `native_qualified: false`.
A native claim also requires a clean source tree and the complete native runtime result.
An operator must identify a full-system emulator as emulated, even when its guest reports `riscv64`.
Host architecture detection alone cannot prove physical hardware execution.

## Evidence and limits

The JSON record contains the source commit, complete source-file digest manifest, executable digest, host, tool versions, commands, and log digests.
It retains exact exit codes, timeouts, skipped-check detection, and unrun release gates.
The executable must remain unchanged and match `build/asm`, which the normal suite executes.
Source files must also remain unchanged during the run.

Keep output under the ignored `build` directory.
An evidence file inside the source tree would otherwise change the recorded source during qualification.
Retain the executable and logs with the JSON record.
A digest identifies bytes; it does not establish their publisher or safety.

Registry, bundled-verifier, website, release, and published-installation gates remain separate.
The runner always reports `release_qualified: false`.
Passing emulated checks cannot authorize a native support claim or a release.

On 5 November 2026, the initial required test failed because the RISC-V CLI executable was absent.
The Apple Clang installation exposed no RISC-V target.
No Linux user-mode execution was available on that macOS host.
These observations are retained in the [initial evidence record](riscv64-qualification-initial.json).

## Primary references

The [RISC-V ABI specification](https://riscv-non-isa.github.io/riscv-elf-psabi-doc/) defines the public calling convention and ELF flags.
The [QEMU user-mode manual](https://www.qemu.org/docs/master/user/main.html) describes process-level emulation.
The ABI page identified version 2.0-rc0, dated 4 November 2026.
Both references were checked on 5 November 2026.
Tool and runtime versions belong to each measured result.
