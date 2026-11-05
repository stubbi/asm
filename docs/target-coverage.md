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
| Intel macOS CLI | Qualified source was integrated into `main` at `7efb4b7b543018d68e5c5801e5f4b7eef74772b5`. The combined PR 42 [native check](https://github.com/stubbi/asm/actions/runs/42042426309) also passed. | Admit a new release host only after its distribution gates pass. |
| Linux x86-64 and ARM64 servers | Qualified source was integrated into the same `main` revision. Both combined PR 42 [native package checks](https://github.com/stubbi/asm/actions/runs/42042426289) passed. | Deployment and recovery have separate gates. |
| RISC-V64 server | The PR 42 [emulated image check](https://github.com/stubbi/asm/actions/runs/42042426266) passed. The [extracted package](https://github.com/stubbi/asm/actions/runs/42042426725) built, then passed 17 of 19 tests. | Diagnose the connection-limit failure and simultaneous-search error. Pass all 19 extracted-package cases. |
| RISC-V64 CLI | The PR 42 [full-system Linux guest](https://github.com/stubbi/asm/actions/runs/42042426214) passed 356 CLI and 49 focused cases without skips. | Integrate qualified source after the separate server gate passes. Physical hardware and release admission remain unqualified. |
| Windows x86-64 CLI | The second managed run passed 106 of 118 methods; qualification remains incomplete. | Pass the current 118-case managed suite on native x86-64 Windows. |
| Windows ARM64 CLI | The second managed run passed 112 of 118 methods; qualification remains incomplete. | Pass the current 118-case managed suite on native ARM64 Windows. |
| Reference packages | Both Windows package jobs and the Linux GNU/QEMU package job passed. | Retain execution-mode labels and recheck changed package inputs. |
| Windows verifier | Both native Go suites passed all 19 mandatory Windows cases. [Run](https://github.com/stubbi/asm/actions/runs/42013532036). | Bind release checks to executed artifact bytes. Trust activation remains separate. |

The sixth Windows result used source `540620a9c8ed14fc5904d07c16dda0430cf9fcb1` in [run 42033134716](https://github.com/stubbi/asm/actions/runs/42033134716).
Subtests can produce multiple failure records for one method.
The [Windows record](windows-native-evidence.json) retains eight failed direct-layout runs and two managed runs.
The first managed run stopped in preflight.
The second executed all 118 methods on both targets, with no skips.
Successful package jobs do not establish successful CLI package workflows.
The expanded suite includes named target selection, nonexecuting test builds, inactive recipe failures, and target-specific dependency locks.

The seventh Windows [run 42038909292](https://github.com/stubbi/asm/actions/runs/42038909292) tested PR merge `93e6372555de392dc2ecc8c51d8fec92bb30383a`.
Its Git tree matches the tree of frozen PR head `502cbe525a4fef1fc4ffca861cdc7d37cd9feaf1`.
Both targets passed 44 of 45 methods.
The primary-image unmap fixture stopped at an unsupported raw-header equality precondition on both targets.
It made no unmap observation and retained no differing header bytes.
The separate x86-64 rename control succeeded for an ordinary file and denied replacement of a suspended image.

The eighth Windows [run 42042014143](https://github.com/stubbi/asm/actions/runs/42042014143) used development source `e147917ef5906ba92c8ab0715286bb7c25e0e409`.
This manual run was separate from PR 41's frozen head.
Both targets passed 45 of 46 methods; the positive updater case remained the sole failure.
The deliberate application case passed after 125.157 seconds on x86-64 and 125.188754 seconds on ARM64.
Both native Windows package scopes passed seven methods in each run.
Each Linux reference scope passed 24 methods; ARM64 and RISC-V execution used QEMU.

The corrected eighth-run kernel experiment completed all three controls on both recorded Windows hosts.
Replacement failed with `STATUS_ACCESS_DENIED` (`0xC0000022`) while each copied process remained alive.
Successful primary-image unmapping and a confirmed free memory region did not remove this denial.
Both denied cases preserved the original and candidate files.
Replacement succeeded after process exit and installed the candidate file identity at the original path.
All copied children were never resumed and were reaped.
The retained header snapshots differ only in the PE `ImageBase` field; the mutation cause remains unestablished.
These controls cover kernel operations and copied native images; they do not independently qualify the Python controller as unemulated.
They do not fix or qualify the production updater.
The user approved the versioned Windows layout on 5 November 2026.
Managed source is implemented; native qualification remains pending.

PR 42 head `66f432bb129c0c56922ec8edfa657e82b4fb9851` and tested merge `08baae84b06ddfac88406f43c5c8c44f6875a901` have the same Git tree.
That tree is `0cc9e50e333cadd85c7a6c7b30d8b136ed113716`.
The retained RISC-V CLI has 632,496 bytes and SHA-256 `42167bc9a21f3d215b6182ff7c3857df2469dc3c8151d5e9cf406edffc6f7d15`.
The full-system check uses an emulated RISC-V machine and its own Linux guest kernel.
It includes the three required kernel-denial branches; it does not qualify physical RISC-V hardware.
The extracted-server check uses user-mode emulation and shares the host kernel.
All 19 extracted-server cases ran, with one assertion failure and one error.
The retained error lacks the failed HTTP response status and body, so its cause remains unknown.
Successful image checks do not replace that failed package gate.
The merge queue keeps this source outside `main` until the required checks pass.

The sixth candidate passed 270 native Apple Silicon CLI tests, 97 registry tests, and 20 site tests.
The release suite ran 78 cases with 12 platform-specific skips.
Both local Go race-test packages passed through valid cached results.
Earlier local bootstrap timeouts remain recorded in the coordination ledger.
These local checks do not replace a clean release build or another target's runtime qualification.

The Intel run also built and tested the unified hello and math examples through the native CLI.
Separate injected-write package checks used Rosetta; they are not native Intel evidence.
Its source binding and two equal clean builds are recorded with the exact artifact digest.

The Windows verifier runs cover source-tested behavior, not an admitted release artifact.
Each target passed 39 top-level tests and 70 subtests; one Darwin-only test was inapplicable.
The executed test executables were not retained, so their exact digests cannot be recovered.
Production verifier source matches the frozen source; one fixture file changed.

General integration [run 42015109983](https://github.com/stubbi/asm/actions/runs/42015109983) passed Linux, macOS, and release-contract jobs at the fourth candidate.
The first integrated server run stopped because the shared harness rejected explicit matching Linux targets.
After that correction, both native server jobs passed at source `54625e990e81b603d8ea83c6f1554752c0052ed1`.
Each target passed ten native-link, 19 extracted-package, 11 hosted-runtime, and four failure-preservation cases.
The PostgreSQL TLS catalog checks also passed on both targets.
Retained CLI, server, archive, and log digests match the qualification receipts.
The earlier failed run remains recorded; these results apply only to their exact source and artifacts.

The merge queue owns integration into `main`.
The bounded 0.6.0 release retains only its independently qualified existing hosts.
Later host additions require a new version and their own release evidence.
