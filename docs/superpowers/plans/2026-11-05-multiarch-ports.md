# Multi-architecture ports implementation plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` for independent tasks and reviews.

**Goal:** Build and runtime-test the missing CLI and Linux server ports, with distribution support tied to qualified artifacts.

**Architecture:** Retain native assembly command and server logic.
Use explicit operating-system adapters and existing mature protocol and cryptography implementations.
Keep each port isolated until its behavioral and security gates pass.

**Tech stack:** Native assembly, GNU Binutils, LLVM, Windows APIs, existing HTTP/PostgreSQL libraries, Python test tooling, and GitHub Actions.

**Spec:** [Coverage and acceptance conditions](../../target-coverage.md), plus the user's implementation request on 5 November 2026.

## Global constraints

- Read `docs/brand/foundation.md` and `docs/brand/messaging.md` in full before work or handoff.
- Keep CLI package logic in assembly.
- Preserve published versions, retained evidence, license notices, and existing security gates.
- Declare ISA, OS, ABI, minimum runtime, and CPU features independently.
- Treat cross-assembly, emulation, native execution, release qualification, and deployment as separate results.
- Bind each runtime result to exact source and artifact digests.
- Run `make test` for CLI changes and the relevant documented registry, verifier, site, and release checks.
- Preserve existing destinations on failure; never execute a package during search or download.
- Require native qualification before native support claims.

## Target contracts

| Component | Implementation targets |
| --- | --- |
| CLI, existing host parity | `x86_64-linux`, `aarch64-linux`, `aarch64-macos` |
| CLI, missing ports | `riscv64-linux`, `x86_64-macos`, `x86_64-windows`, `aarch64-windows` |
| Server | Linux x86-64, ARM64, and RISC-V64 with independently checked library ABIs |
| Reference packages | Compatible hello output and callable math implementations for the selected targets |

Server deployment remains Linux-specific.
RISC-V server libraries can require a different ABI from the freestanding RV64I/LP64 hello example.
The Windows installation contract must name supported filesystems and enforce Windows access and reparse-point checks.

## Review focus

- Failed builds, downloads, inventory commits, or updates must preserve existing bytes and metadata.
- Paths with spaces, Unicode, case aliases, links, or reparse points must not redirect a protected write.
- Child creation, interrupted I/O, short transfers, and dependency failures must return useful failures.
- Target metadata, parser bounds, ABI preservation, executable headers, and runtime tool selection must agree.
- A missing runtime, missing tool, skipped suite, or failed gate must never become a successful qualification record.

## Task 1: Linux server ports

**Owner:** `Verify CLI and server implementation`; hosted image work belongs to `Clarify task request`.

**Files:** Target-specific assembly and ABI checks under `experiments/assembly-server/`; server-local build and test rules.

**Interface:** The extracted source package builds through the native Asm CLI and passes the existing HTTP/PostgreSQL behavior suite.

- [ ] Add failing build and runtime checks for ARM64 and RISC-V64.
- [ ] Implement ABI-specific server assembly and dependency assertions.
- [ ] Build and execute all three Linux targets with the same behavior and failure assertions.
- [ ] Run pinned dependency/image tests and record constituent image digests.
- [ ] Review exact source and evidence before distribution integration.

## Task 2: RISC-V64 Linux CLI

**Owner:** `Assess asm.build completeness`.

**Files:** `cli/riscv64/`, target-specific harnesses, and focused CLI tests.

**Interface:** Native assembly command behavior matches the current CLI contract, including resolver and installed-program commands.

- [ ] Add failing observable command, parser, archive, and package lifecycle tests.
- [ ] Implement native RISC-V assembly and explicit syscall/register contracts.
- [ ] Run new/build/run/test, package use, update recovery, and hostile-input checks.
- [ ] Record execution mode and artifact digests.
- [ ] Deliver a coherent port change for shared integration.

## Task 3: Intel macOS CLI

**Owner:** `Add native macOS ASM support`.

**Files:** Target-specific Darwin x86-64 adapters, source preparation, templates, and tests.

**Interface:** `x86_64-macos`, initially macOS 15+, produces and validates native Mach-O executables.

- [ ] Add failing command and failure-preservation tests.
- [ ] Implement Darwin ABI, filesystem, process, package, and update behavior.
- [ ] Exercise the first-project and package lifecycle interfaces.
- [ ] Establish native Intel CI qualification; label Rosetta runs separately.
- [ ] Deliver exact artifact evidence and port files for integration.

## Task 4: Windows x86-64 CLI

**Owner:** Coordination subagent `windows_x64`.

**Files:** `cli/windows/x86_64/`, `tools/windows_x64.py`.

**Interfaces:** `python tools/windows_x64.py --output build/windows/x86_64/asm.s` prepares assembly only.
The local build produces `build/asm-x86_64-windows.exe`.
The CLI creates `app.exe` and uses fixed compiler and linker arguments without a shell.

- [ ] Pin failing native version/help and first-project behavior in Task 6's runner.
- [ ] Implement startup, Windows API adapters, PE validation, and shared command source preparation.
- [ ] Implement package, inventory, dependency, publication, and update failure boundaries.
- [ ] Cross-assemble locally and execute on the Windows x86-64 runner.
- [ ] Fix runtime failures and record exact executable evidence.

## Task 5: Windows ARM64 CLI

**Owner:** Coordination subagent `windows_arm64`.

**Files:** `cli/windows/aarch64/`, `tools/windows_arm64.py`.

**Interfaces:** `python tools/windows_arm64.py --output build/windows/aarch64/asm.s` prepares assembly only.
The local build produces `build/asm-aarch64-windows.exe`.
The observable command and security contract matches Task 4 with Windows ARM64 calling conventions.

- [ ] Pin failing native behavior in Task 6's runner.
- [ ] Implement Windows ARM64 startup, process/file adapters, PE validation, and assembly preparation.
- [ ] Preserve package, inventory, dependency, publication, and update behavior.
- [ ] Cross-assemble locally and execute on the native Windows ARM64 runner.
- [ ] Fix runtime failures and record exact executable evidence.

## Task 6: Windows runtime qualification

**Owner:** Coordination subagent `windows_qualification`.

**Files:** `tests/windows/`, `tools/windows_test.py`, `.github/workflows/windows-ports.yml`, `docs/windows-qualification.md`.

**Interface:** `python tools/windows_test.py --asm PATH --target TARGET --evidence OUTPUT.json [--toolchain-bin DIR]`.
The runner fails when the required native runtime, toolchain, target match, or behavioral check is absent.

- [ ] Add meaningful command and failure tests before implementation passes.
- [ ] Include Unicode, aliases, existing destinations, corrupt bytes, network failures, and reparse-point checks.
- [ ] Prepare native Windows x86-64 and ARM64 CI with pinned actions and read-only permissions.
- [ ] Retain source/executable hashes, OS/tool versions, exit codes, and test results.
- [ ] Review the complete workflow and source before pushing an isolated test branch.

## Task 7: Reference package ports

**Owner:** `Review repo consistency and cleanup`.

**Files:** New target-specific example directories and package tests.

**Interface:** Existing unsigned-minimum behavior and visible hello output retain their explicit ABI and MIT license scope.

- [ ] Add failing callable/output checks for each new package target.
- [ ] Implement target-specific assembly and package manifests without changing published bytes.
- [ ] Test boundary values, equal values, output failures, and process exits.
- [ ] Deliver source/artifact digests and target-specific execution evidence.

## Task 8: Shared distribution integration

**Owner:** `Add installed-package management`.

**Files:** `Makefile`, CLI metadata, installer/update selection, verifier mappings, registry feeds, and CI/release tools.

**Interface:** Only a port with its own passed gates becomes a declared host or published artifact.

- [ ] Preserve the current release and finish its existing defect fix.
- [ ] Add failing target selection, format, feed compatibility, and provenance tests as port inputs arrive.
- [ ] Integrate target-specific build and test commands without weakening aggregate gates.
- [ ] Run the full release checks and a real first-project/package flow for every declared host.
- [ ] Review complete history and record material trade-offs before any merge or publication.

## Execution record

Assignments were delivered on 5 November 2026.
Implementation and qualification remain active; no new host is qualified by this plan.
The initial machine had about 225 MB free; cache cleanup restored about 2.8 GiB.
The Docker storage path still reports I/O errors, so Linux execution uses independently checked remote or emulated environments.
Existing imported baseline input hashes are retained in `/private/tmp/asm-windows-baseline-inputs.json`.
