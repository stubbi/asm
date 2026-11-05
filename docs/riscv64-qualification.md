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
A missing tool, failed command, timeout, changed artifact, or skipped CLI check produces a failure.
The command retains the failed check and leaves later checks marked `not-run`.

The runner executes unchanged `make test ARCH=riscv64` and the focused RISC-V tests.
Schema 2 scopes the result to `native-cli-behavior`.
The current Makefile automatically loads every root `tests/test_*.py` module.
The runner records their names and digests without a second execution mechanism.
Both suites require nonempty tests, exit zero, and no skips or expected failures.
`make package-test` remains a separate reference-target gate.
Earlier attempts included foreign reference suites inside `make test`.
Those raw skipped outcomes remain retained and do not become passing CLI checks.
The complete suite covers project creation, builds, execution, archives, registry inputs, dependencies, publication requests, installed programs, and update recovery.
These tests include unsupported targets, corrupt artifacts, network failures, and existing destinations.
Tests create private transport and verification fixtures.
Those fixtures do not establish real release-signature verification.

Some cross-user checks require a root test process.
Run those checks in an isolated machine or the disposable CI job.
A skipped Make or focused check prevents CLI qualification.
Foreign reference packages retain their separate native-target qualification requirements.

## Emulated Linux qualification

The workflow uses QEMU user-mode emulation on an isolated Ubuntu runner.
A registered binary-format handler allows Python and the CLI to execute RISC-V ELF files directly.
The workflow selects GNU cross-tools at the CLI's fixed paths.
It installs RISC-V libc headers and startup objects for the linked-project tests.
The runner exposes the target loader and multiarch libraries at their standard paths.
It sets `QEMU_LD_PREFIX=/` so descriptor walks use the actual filesystem root.
A cross-sysroot prefix redirects guest `open("/")` and invalidates these checks.
A real RV64GC/LP64D libc probe must run before the complete suite.
These path changes apply only to that disposable runner.
They must not be applied to a person's workstation.

`ASM_TEST_TARGET=riscv64-linux` selects equivalent assembly fixtures for the guest target.
The override is accepted only on Linux.
It does not implement CLI commands or change production executable bytes.
Fault-injection filters still use actual host-kernel syscall numbers.
The three kernel-denial assertions remain unchanged and mandatory in the strict CLI suite.
An emulation difference that prevents a required assertion remains a failed check.
QEMU can combine distinct guest resource-limit operations into the host `prlimit64` call.
Complete syscall-failure qualification can therefore require a full-system guest or a native host.

The separate full-system workflow defines a hash-pinned Ubuntu RISC-V guest.
Its guest uses native Python and tools against the emulated Linux kernel.
This preserves the original syscall-denial assertions without host syscall translation.
The first complete system attempt passed all three guest-kernel denial cases.
Its complete qualification gate still failed on two fixture startup waits.
The [CI attempts](#ci-attempts) identify the exact source, executable, checks, and remaining failures.
The guest qualifier uses the following interface:

```sh
python3 tools/riscv64_test.py --asm build/asm-riscv64-linux --execution-mode emulated --emulation-kind system --emulator-provenance build/riscv64-system-provenance.json --evidence build/riscv64-qualification.json
```

System mode requires root Linux RISC-V guest Python and bounded host-provided provenance.
The provenance binds the emulator, pinned images, and exact guest source commit.
The outer runner must bind the copied guest report and executable digest.
A provenance file alone does not establish that a virtual machine executed.
This mode always reports `native_qualified: false` and `release_qualified: false`.
Full-system CLI qualification remains pending until its complete retained gate passes.

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

## CI attempts

The first [CI run](https://github.com/stubbi/asm/actions/runs/41939533640) stopped during setup because `rg` was absent.
It did not build or execute the RISC-V CLI.
The [CI attempt record](riscv64-ci-attempts.json) retains the source commits, failure, and raw-log digest.
The corrected workflow initializes failed/unrun evidence before setup commands.
The second run reached runtime and exposed branch-register and starter-template defects.
The third [CI run](https://github.com/stubbi/asm/actions/runs/41941931995) passed all 12 focused checks.
Its complete CLI suite ran 293 tests with 68 failures and two errors.
Most failures stopped at absolute path checks before transport or update operations.
The global cross-sysroot prefix redirected the guest root during those checks.
The sixth [CI run](https://github.com/stubbi/asm/actions/runs/41943502913) passed the corrected root and library setup.
Its real C-library probe and all 12 focused checks passed.
The complete CLI suite ran 295 tests with six failures and no errors.
Three failure entries came from one ELF fixture assumption and its inventory cascade.
The fixture now selects the actual load segment before mutating its permissions.
Three entries concern guest syscall-denial checks that user-mode emulation cannot reproduce.
The unchanged checks require the full-system gate.
These failed outcomes remain in the attempt record.

The later [user-mode run](https://github.com/stubbi/asm/actions/runs/42009507416) retained 358 tests, three denial failures, and 28 foreign-reference skips.
All 21 focused tests passed.
Those skips remain failed evidence from the earlier recursive test discovery.

After the Makefile split, [user-mode run 42013564914](https://github.com/stubbi/asm/actions/runs/42013564914) ran 341 root tests with three kernel-denial failures.
All 35 focused tests passed.
Neither suite skipped tests or reported expected failures.
The host syscall filters still could not reproduce the required guest-kernel denials.

[Full-system run 42013564640](https://github.com/stubbi/asm/actions/runs/42013564640) ran the same executable against the emulated RISC-V Linux kernel.
It used native RISC-V Python, assembler, linker, compiler, and GNU foreign-target tools.
All three denial cases passed: `getrlimit` syscall 163, `setrlimit` syscall 164, and `rt_sigprocmask` syscall 135.
The root suite ran 341 tests with one failure.
The focused suite ran 35 tests with one failure.
Neither suite skipped tests or reported expected failures.

The root failure stopped at the five-second held-verifier startup wait.
The focused failure stopped before the Python descendant marker at its 200 ms deadline.
The HOME displacement assertions did not run.
The descendant-survival assertion did not run.
The guest artifact and source bindings passed.
The outer runner correctly rejected the failed suites.
A complete corrected full-system rerun remains pending.
Fixture corrections do not convert this failed run into a pass.

These two runs checked source `c6c1c3de927198668bced04276d30532817711da` for branch head `290d7226bf6889b7c876d25fe7a1d35013140c8f`.
Both used the same 632,496-byte CLI executable:

```text
SHA-256: 83801012af27603203a954877009b5c84472aec0a0e965f7fea258ba271d0cb0
```

The attempt record retains each report and log digest.
Native RISC-V hardware and release qualification remain unrun.

## Primary references

The [RISC-V ABI specification](https://riscv-non-isa.github.io/riscv-elf-psabi-doc/) defines the public calling convention and ELF flags.
The [QEMU user-mode manual](https://www.qemu.org/docs/master/user/main.html) describes process-level emulation.
The ABI page identified version 2.0-rc0, dated 4 November 2026.
Both references were checked on 5 November 2026.
Tool and runtime versions belong to each measured result.
