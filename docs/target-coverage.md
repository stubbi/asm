# Target coverage coordination

**Audit date: 5 November 2026. Status: coordination record, with open implementation and qualification gaps.**

The user requested coordination across the active Asm sessions for all major architectures.
This record connects that request to component coverage, work ownership, and acceptance evidence.
The [README](../README.md#status) remains the source for current release support.

## Outcome and scope

People must be able to select compatible software and complete the same supported tasks on each declared target.
The governing principles are dependable reuse and trust earned through evidence.
Read the [foundation](brand/foundation.md) and [messaging guide](brand/messaging.md) before continuing this work.

The initial architecture coverage set is x86-64, ARM64, and RISC-V64 on Linux.
Desktop host gaps include Intel macOS and Windows on x86-64 and ARM64.
This scope is a coordination assumption, not a market ranking or a support declaration.
Other architectures remain outside this initial set.

A target includes its instruction set, operating system, ABI, minimum runtime, and required CPU features.
An ABI defines binary interfaces, calls, and data layout.
An architecture port does not qualify another operating system.
Server deployment targets and desktop CLI hosts need separate acceptance evidence.
Each independent package retains its own target and license scope.

## Observed repository coverage

This audit inspected source, configuration, and retained evidence.
It did not run builds or qualify new targets.
The main checkout was `452a798e0a62c2a7c0c6c436e15db316fda76959`, with substantial uncommitted changes from active sessions.
Results from another worktree or earlier artifact require a source and digest match before reuse.

| Component | Observed coverage | Open gap |
| --- | --- | --- |
| Native CLI | Linux x86-64, Linux ARM64, and Apple Silicon macOS 15+ have implementations and declared release support. | RISC-V64 Linux, Intel macOS, and Windows lack native CLI ports and qualification. |
| New native-library build path | Source exists for the three current CLI hosts. | Recorded macOS runtime checks passed; Linux changes were cross-assembled only. |
| Assembly server | Source, manifest, ABI checks, and workflow target Linux x86-64. | Current extracted-package runtime checks remain unrun; ARM64 and RISC-V64 server ports are absent. |
| Transport and cryptography verifier | Build integration covers Linux x86-64, Linux ARM64, and macOS ARM64. | RISC-V64 mapping is absent; trusted-distribution activation has separate provisioning gates. |
| Reference hello packages | Linux x86-64, ARM64, and RV64I/LP64 have release records. | RISC-V evidence uses emulation; no published macOS reference package was found in this audit. |
| Reference math package | Callable Linux x86-64 implementation. | ARM64, macOS, and RISC-V implementations and callable ABI tests are absent. |
| Static registry and website | Repository configuration uses GitHub Pages and generated registry indexes. | Static artifact delivery does not qualify an assembly server deployment. |
| Hosted registry and MCP | The hosted session reports active deployment work; MCP tools exist for source-checkout use. | No multi-architecture server image or deployment qualification follows from MCP runtime portability. |
| Installer and release pipeline | Three current CLI hosts have selection and qualification paths. | Each new host needs installer, verifier, metadata, provenance, and runtime integration together. |

Sources: [build rules](../Makefile), [command metadata](../cli/commands.json), [CI](../.github/workflows/ci.yml),
[release builder](../tools/release.py), [installer](../tools/bootstrap.py), [macOS contract](macos.md),
[server package](../experiments/assembly-server/README.md), [server results](../experiments/assembly-server/RESULTS.md),
[native-library evidence](native-linking-evidence.json), [math manifest](../examples/math/asm.toml),
[agent target profiles](../skills/asm-build/references/targets.json), and [trust activation](trusted-distribution.md).

## Coordination ownership

The following requests were delivered to the existing sessions.
Delivery records the requested scope; ownership remains pending acknowledgment.
The server session acknowledged the audit; release progress reflects the separate target requirements.
Neither acknowledgment nor a request establishes implementation completion.

| Existing session | Requested responsibility |
| --- | --- |
| Verify CLI and server implementation | Native-library parity, current Linux runtime evidence, and explicit ARM64/RISC-V64 server port requirements. |
| Add installed-package management | Command parity, installer selection, verifier integration, release metadata, and independent host qualification. |
| Assess asm.build completeness | Resolver and lock behavior across hosts, target-specific dependency metadata, and target assumptions. |
| Clarify task request | Hosted image architecture, MCP runtime qualification, agent target selection, and deployment evidence. |

This coordination session owns the coverage audit and overlap checks.
The requests preserve each session's existing work and security requirements.
New native CLI and package ports still need dedicated implementation ownership.
The shared release files require one integration owner; parallel ports must avoid conflicting edits there.

## Acceptance conditions

For each component and target:

1. Declare the ISA, operating system, ABI, minimum runtime, and required CPU features separately.
2. Keep CLI package logic in native assembly.
3. Build an exact source revision in a clean environment.
4. Record the artifact digest, toolchain, host, commands, and observed results.
5. Check the interface that the user will use.
6. Test unsupported targets, corrupt artifacts, network failures, and existing destinations where relevant.
7. Keep native and emulated execution results separate.
8. Run the documented CLI, registry, verifier, site, and release gates for the changed boundaries.
9. Preserve failed checks and unrun gates in the evidence record.
10. Publish support only after the corresponding qualification gates pass.

For a new CLI host, acceptance includes installation, project creation, visible output, package use, and update recovery.
For a server target, acceptance includes the extracted package, ABI checks, HTTP, database behavior, and dependency failures.
An image manifest or successful assembly command does not establish those runtime results.

## Material trade-offs and remaining work

Current host parity takes priority over adding target labels.
This preserves working commands while new ports receive separate implementation and qualification.
Mature transport, database, and cryptography dependencies remain subject to the existing security boundaries.

The next gaps are current Linux native-library execution, ARM64 server support, and dedicated RISC-V64 CLI/server ownership.
Reference package ports and desktop operating-system ports remain separate work.
The request for complete architecture coverage remains open until the selected component and target gates pass.

## Implementation assignments

The user subsequently requested implementation and runtime tests for all missing ports.
The [implementation plan](superpowers/plans/2026-11-05-multiarch-ports.md) records concrete work and acceptance checks.

| Work | Implementation owner |
| --- | --- |
| ARM64 and RISC-V64 Linux server | Verify CLI and server implementation |
| RISC-V64 Linux CLI | Assess asm.build completeness |
| Intel macOS CLI | Add native macOS ASM support |
| Windows x86-64 and ARM64 CLI | Coordination session, with separate implementation and runtime-test workers |
| Native hello and callable math packages | Review repo consistency and cleanup |
| Multi-architecture server images and runtime checks | Clarify task request |
| Shared installer, verifier, registry, CI, and release integration | Add installed-package management |

These are implementation assignments, not completed ports.
The server, Intel macOS, hosted-image, reference-package, and release sessions have acknowledged work in progress.
The RISC-V CLI assignment preserves the dependency session's existing work.
The coordination workspace passed its imported native macOS baseline: 215 tests.
This result does not qualify either Windows port.

## Implementation checkpoints

The initial audit above remains historical.
These later checks retain their own source and artifact boundaries.
They do not change published host support.

| Component | Observed result | Remaining gate |
| --- | --- | --- |
| Intel macOS CLI | Native Intel qualification passed 175 cases at `cea61bdfc8f87555f93d2e00bde15063f3df680b`. [Run](https://github.com/stubbi/asm/actions/runs/41940484143). | Requalify the unified target contracts, then complete distribution integration. |
| Linux x86-64 and ARM64 servers | Both native targets passed the corrected schema-privilege suites. [Run](https://github.com/stubbi/asm/actions/runs/41944988752). | Preserve the [exact package evidence](server-package-evidence.json) during integration. Deployment has separate gates. |
| RISC-V64 server | The hosted foundation passed an explicitly emulated image suite. [Run](https://github.com/stubbi/asm/actions/runs/41941462037). | Run the extracted package through the RISC-V CLI and target-native build tools. |
| RISC-V64 CLI | A complete source port and guest qualification work are in progress. | Finish the unified parser integration and complete CLI tests under a RISC-V guest kernel. |
| Windows x86-64 CLI | Native SDK linkage and execution succeeded; the 40-case runtime suite failed. | Fix access checks and process execution. Pass the expanded 44-case suite and updater identity checks. |
| Windows ARM64 CLI | Native SDK linkage and execution succeeded; the 40-case runtime suite failed. | Fix the observed runtime failures. Pass the expanded 44-case suite and updater identity checks. |
| Reference packages | Both Windows package jobs and the Linux GNU/QEMU package job passed. | Retain execution-mode labels and recheck changed package inputs. |
| Windows verifier | The frozen helper source builds for both Windows targets. | Run independent native Go suites with protected NTFS fixtures. Trust activation remains separate. |

The second Windows result used source `74221fc69af0b19444dede9eb71c400effdd1855` in [run 41947783095](https://github.com/stubbi/asm/actions/runs/41947783095).
The first [failed run](https://github.com/stubbi/asm/actions/runs/41942208419) remains part of the evidence.
Successful package jobs do not establish successful CLI package workflows.
The expanded suite includes named target selection, nonexecuting test builds, inactive recipe failures, and target-specific dependency locks.

The combined worktree passed 263 native Apple Silicon CLI tests, 73 registry tests, and seven server-evidence parser tests.
Earlier local bootstrap timeouts remain recorded in the coordination ledger.
These local checks do not replace a clean release build or another target's runtime qualification.

The merge queue owns integration into `main`.
The bounded 0.6.0 release retains only its independently qualified existing hosts.
Later host additions require a new version and their own release evidence.
