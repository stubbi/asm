# Database admission implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Limit each server process to eight simultaneous reader connections and preserve recovery, exact responses, and database deadlines.

**Architecture:** Reserve one admission slot before creating each fresh PostgreSQL connection. Release that slot after connection cleanup, before returning a result. Refuse excess work through the existing HTTP 503 response.

**Tech stack:** Native Linux x86-64 System V, ARMv8-A AArch64, and RV64GC/LP64D assembly; libmicrohttpd 1.0.3; libpq/PostgreSQL 16.15; Python integration fixtures.

**Spec:** [Hosted registry acceptance](../../hosted-registry.md), [architecture gates](../../architecture-gates.md), and the bounded specification below.

## Checkpoint and bounded specification

This is an admission implementation candidate, dated 5 November 2026.
The reviewed diagnostic ran once at the source recorded below.
Its expected native RED was accepted before implementation started.
The registered workflow was then restored from the retained original blob.
The owner later reviewed the implementation and authorized one native source gate at commit `2881779f1927f660b367d48af08a28a3c09292be`.
Both native targets passed all twenty-eight cases in that uncapped gate.
The owner then authorized the local actual-image integration described below.
The image preflight later passed all three targets at the source recorded below.
The owner authorized a local evidence and publication-condition candidate after that result.
No push, publication, or deployment follows from preparing this final candidate.

The source inspected is canonical HTTP commit `61181be91d31cc671e3827a7aa17c9e2b37afe71`.
The public main inspected is `7efb4b7b543018d68e5c5801e5f4b7eef74772b5`.
The checkpoint branch is `codex/db-admission`.
The coordinator's coherent reconciliation is `7e67d7131377590b924d07191ccb174b51bf22c2`.
The checkpoint adopted it through normal merge `5992c3016f6a0ba972665054b5b4856659336d31`.
The operator and canonical HTTP base `1fcc70452ff9fba7008a495b406ce61c43aaf364` was later merged without conflicts into `2881779f1927f660b367d48af08a28a3c09292be`.

The operator audit reports an ignored `ASM_DATABASE_POOL_SIZE=8` variable.
That variable does not establish a runtime limit.
Sixteen HTTP connections permit sixteen fresh database connections per process.
Two replicas and one surge process can therefore attempt forty-eight reader connections against the reported role limit of thirty-two.

An eight-slot process limit permits at most twenty-four reader connections across those three processes.
This arithmetic is a resource bound, not measured service capacity.
It does not establish capacity for another replica count, direct database clients, or a changed rollout policy.

The consumer outcome is responsive liveness and understandable temporary refusal during database saturation.
The relevant foundation principles are resource care, dependable reuse, human control, and claims supported by exact evidence.
The trade-off is temporary refusal instead of waiting for an admission slot.

This work adds admission to fresh connections.
It does not retain connections or implement a persistent pool.
It does not raise the reader role limit.
It does not claim that an ignored environment variable is supported.

## Global constraints

- Preserve the HTTP limit of sixteen connections.
- Preserve the actual two-second monotonic database deadline and one-second SQL statement timeout.
- Preserve the 200 ms lock timeout, read-only transaction, exact canonical guard, and fixed export query.
- Preserve TLS hostname verification, certificate checks, fixed connection options, and ambient-configuration refusal.
- Preserve exact routes, methods, byte limits, response bytes, and media types.
- Preserve ownership of each accepted `PGresult` until the HTTP library copies its body.
- Preserve response cleanup after allocation, header, or queue failure.
- Keep the unrelated six-client RISC-V/QEMU failure visible.
- Do not claim that eight-slot admission fixes that failure.
- Leave DNS configuration preparation, timer changes, and metrics to their current owners.
- Read `docs/brand/foundation.md` and `docs/brand/messaging.md` before execution or a handoff.

The architecture proposal recommends HTTP 429 for caller admission quotas.
This bounded change retains HTTP 503 for process database capacity, as explicitly requested.
Its capacity rejection must remain an availability failure in later operational reporting.

## Ownership and source integration

The frozen canonical HTTP source remains owned by its runtime coordinator.
The separate `codex/server-startup` branch owns native DNS and configuration preparation.
This task must not copy or modify that startup implementation.

A normal merge of public main was attempted in the isolated checkpoint.
Ten files conflicted, including both non-x86 ports, runtime tests, image sources, and workflows.
The merge was aborted without resolving or committing product files.
That initial test-only checkpoint retained the exact canonical base.

The runtime owner subsequently supplied the coherent reconciliation recorded above.
Its normal merge into this checkpoint completed without conflicts.
Both plan and capacity test were retained.
No product assembly changed during that merge.
The new RISC-V PIC fixes in public PR #42 remain outside this reconciliation.
Do not rebase the shared canonical source.
Keep both literal-prefix guards in `server/guard.sql` and `experiments/assembly-server/guard.sql`.
Keep the deceptive-schema regressions for `pgxtemp_`, `pgxtempx`, `pgxtoast_temp_`, and `pgxtoastxtempx`.
Preserve canonical export regressions when reconciling `server/test_runtime.py`.
Review main's RISC-V ABI and position-independent-code changes individually.
Do not resolve the port conflicts by choosing an entire older source file.

## Shared invariant and routine contracts

Use one naturally aligned 32-bit admission counter per process, initially zero.
The counter equals admitted `database_query` calls that have not completed connection cleanup.
Its permitted range is zero through eight.
This stronger lifetime includes connection creation and cleanup, so live reader connections cannot exceed eight.

Each call has a separate local `admitted` flag, initially zero.
Set it only after successful atomic acquisition.
Release exactly once on the common return path when this flag is one.
Do not infer admission from a non-null `PGconn`.
`PQconnectStartParams` can return null after admission succeeds.

Compute the existing absolute deadline before acquisition.
Use a bounded atomic compare-and-swap acquisition, with at most sixteen attempts.
Refuse immediately when the observed count is eight.
After sixteen unsuccessful contention attempts, return the existing temporary failure.
This explicit bound avoids an unbounded admission spin or a new wait queue.
It can refuse under contention even when a later slot becomes free; fairness is not promised.

`database_try_admit` takes no arguments and returns one after incrementing the counter, or zero without owning a slot.
It performs no allocation, library call, system call, wait, SQL, logging, or configuration access.
It uses no stack space and preserves every callee-saved register.

`database_release_admission` takes no arguments and returns no value.
Its precondition is ownership of exactly one unreleased slot.
It atomically decrements the counter and preserves the query result register.
It uses no stack space and performs no library call or system call.
It has no caller-visible failure path because it must not abandon an owned slot.

| Port | Acquisition output and changed registers | Release changed registers | Native atomic mechanism |
| --- | --- | --- | --- |
| x86-64 System V | EAX=0/1; RAX, RCX, RDX and flags change | Flags change; RAX remains unchanged | Locked 32-bit `CMPXCHG`; locked decrement |
| AArch64 AAPCS64 | W0=0/1; X0 and X9-X12 change | X9-X12 change; X0 remains unchanged | 32-bit acquire-exclusive load and release-exclusive store; clear an abandoned reservation |
| RV64GC/LP64D | A0=0/1; A0 and T0-T3 change | T0-T3 change; A0 remains unchanged | Aligned 32-bit `lr.w.aq` / `sc.w.rl`; release uses atomic add of minus one |

No optional AArch64 LSE instruction is required.
The RISC-V A extension is already part of the declared RV64GC target.
Keep each RISC-V load-reserved/store-conditional loop within the ISA's constrained-loop rules.
The release routine must retain the input result register even on a contention retry.

The proposed local flag fits existing unused frame storage:

| Source | Current frame and ownership | Proposed flag |
| --- | --- | --- |
| `server/runtime.s` | 56 local/outgoing bytes; RBX/R12/R13 hold borrowed SQL arguments, R14 the deadline, R15 the connection; `[RBP-48]` owns the result | 32 bits at `[RBP-68]`; do not overlap outgoing arguments at RBP-96/RBP-88 |
| `server/aarch64/runtime.s` | 80-byte frame; X19-X21 hold arguments, X22 the deadline, X23 the connection, X24 the result; bound/phase at SP+64/SP+72 | 32 bits at SP+68 |
| `server/riscv64/runtime.s` | 80-byte frame; S1-S3 hold arguments, S4 the deadline, S5 the connection, S6 the result, S7 the bound, S8 the phase; RA at SP+64 | 32 bits at SP+72 |

These offsets remained unchanged in the coherent source merge.
Recheck them after any later port change.
The existing argument and return contracts of `database_query` remain unchanged.
Its routine comment must identify the new shared counter and local ownership flag.

Before admission, validation failures return without releasing anything.
After admission, every failure clears any result, closes any connection, then releases the slot.
On success, `PQfinish` runs before release; the accepted result remains owned by the caller.
Do not hold admission while copying or transmitting an HTTP body.

The inspected callbacks have no independent HTTP cancellation handler for an executing database query.
A disconnected client can leave work running until its existing database deadline.
Test eventual cleanup within that unchanged deadline; do not claim immediate cancellation.
If immediate disconnect cancellation becomes required, specify that separately with the HTTP lifecycle owner.

## Review focus

- Connection creation fails after admission: release the slot despite a null `PGconn`.
- TLS, guard, malformed result, and SQL deadline failures: retain the exact 503 and restore capacity.
- An HTTP client disconnects during database work: release by the existing deadline without a process restart.
- An HTTP copy, header, or queue operation fails after database success: retain response and result cleanup without retaining admission.
- Simultaneous acquisitions and releases: never exceed eight live connections or decrement a slot twice.

## Task 1: Establish a native red result

**Files:** Create `server/test_capacity.py`; retain `server/test_runtime.py` unchanged.

**Interfaces:** Reuse the existing owned TLS/canonical database fixture and its public test helpers. Forward opaque TCP bytes without changing TLS policy.

- [x] Add a gate that forwards startup traffic and observes stalled handshakes.
- [x] Add `test_eight_handshakes_refuse_ninth_and_recover_in_the_same_process`.
- [x] Verify Python syntax and discovery of exactly one candidate test.
- [x] Smoke-test fixture forwarding and observation on local loopback sockets.
- [x] Build the unchanged canonical runtime on an approved Linux target.
- [x] Run the candidate with the same environment as `make -C server test`.

```sh
ASM_SERVER_BINARY=/absolute/build/asm-hub \
ASM_SERVER_SOURCE_REVISION=FULL_COMMIT_ID \
ASM_PROTO_LIBPQ=/absolute/postgres/lib/libpq.so.5 \
ASM_PROTO_PG_BINDIR=/absolute/postgres/bin \
python3 server/test_capacity.py
```

The intended red assertion is: `The ninth request opened another database connection.`
The expected native RED was observed in run `42050169482`.
A fixture, executable, crash, or eight-holder setup failure is a different result and must remain visible.

The candidate requires eight observed stalled handshakes within 0.8 seconds.
The ninth request must return the exact existing 503 without a ninth database connection, within 0.5 seconds.
Liveness and source identity must return 200 within 0.5 seconds while those holders remain active.
Each holder must return 503 within the existing integration tolerance of 2.8 seconds.
That tolerance does not change the implementation's two-second deadline.
Nine subsequent successful requests verify same-process recovery and catch success-path slot leaks.
A second fresh eight-holder wave detects even a partial timeout-path slot leak.
The gate tracks each wave separately because old fixture sockets can outlive the native deadline.

### Temporary manual native gate

The retained diagnostic commit `f7987a5f3571f4c7a58f7e731b0127a0e263d3ab` used the registered `.github/workflows/assembly-server.yml` path on `codex/db-admission` only.
It accepts `workflow_dispatch` only and selects one native AMD64 `ubuntu-24.04` job.
It requests `contents: read` and does not retain checkout credentials.
It contains no publishing, signing, deployment, or private infrastructure operation.

The pinned dependency recipes remain unchanged.
The job runs the existing sixteen canonical runtime tests first.
It then runs the candidate capacity test without retries.
The candidate runs after either baseline success or failure, provided the baseline step actually ran.
Baseline failures remain failures of the job.
No failure is converted to success or automatically classified as the intended RED.

Each test step retains its raw output and exit status.
An always-run receipt records step outcomes, source identity, and the executable digest when the executable exists.
The artifact retains that receipt, logs, source-file digests, host/tool information, and the exact diagnostic executable.
Its retention period is seven days; collect the evidence before that period ends.

The intended RED requires sixteen baseline tests to pass and the candidate to fail at the ninth-connection assertion.
A setup, fixture, timeout, crash, or holder-precondition failure is a separate failed result.
The 0.8, 0.5, and 2.8 second assertions remain unchanged.
The unrelated RISC-V gates were excluded from this diagnostic, not treated as passing.

The original workflow is preserved by Git blob `3b209e45bae4b61032ba906005664173ebd19c3f`.
Its SHA-256 is `ecbcbb4e97b58d3993dfd66d53ff61941ad80977dfcbe6d3ac6562ab7c654a17`.
A local copy is `/private/tmp/asm-admission-original-3b209e45.yml`.
Restore the workflow before any implementation integration or public pull request:

```sh
git restore --source=5992c3016f6a0ba972665054b5b4856659336d31 -- .github/workflows/assembly-server.yml
```

`actionlint` passed on the temporary workflow locally.
That check does not establish successful dependency builds or native runtime execution.
The workflow uses GitHub's documented [status functions](https://docs.github.com/en/actions/reference/workflows-and-actions/expressions) and [read-only permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).
These references were checked on 5 November 2026.

## Task 2: Implement and check the three native ports

**Files:** Modify only `server/runtime.s`, `server/aarch64/runtime.s`, and `server/riscv64/runtime.s` for admission logic.

**Interfaces:** Implement the two routine contracts above. Keep `database_query` arguments, results, frame alignment, and library calls compatible.

- [x] Require Task 1's correct native failure before product code.
- [x] Add the named eight-slot limit and aligned counter to each port.
- [x] Add the local flag and bounded acquisition before connection creation.
- [x] Release from the common epilogue after `PQfinish`, including null-connection failures.
- [x] Run the candidate until its complete saturation and recovery assertion passes.
- [x] Run the existing native runtime suite without skips on every claimed native target: AMD64 and ARM64.
- [x] Keep the independent RISC-V six-client regression and its result unchanged in reporting.

Cross-assembly checks do not establish native saturation, cancellation, or recovery.
Do not weaken a timing assertion or query guard to obtain a pass.

## Task 3: Cover the remaining cleanup boundaries

**Files:** Extend `server/test_capacity.py`; add `server/test_connect_null.c`; update `server/Makefile` and `server/README.md`.

**Interfaces:** Use observable HTTP responses, accepted TCP connections, same-process identity, and the existing owned fixture administrator.

- [x] Add nine sequential healthy reads to catch success-path leaks independently of saturation.
- [x] Add handshake-abort recovery checks.
- [x] Add nine wrong-certificate failures followed by exact-export recovery.
- [x] Add nine reader-guard failures followed by readiness and export recovery.
- [x] Add nine null, duplicate, and oversized-result failures followed by full-eight recovery.
- [x] Add SQL deadline checks below 1.8 seconds with nine server-side statement-timeout messages.
- [x] Add eight-client disconnect cleanup checks within the original deadline.
- [x] Add an HTTP abort after a maximum-size response starts.
- [x] Add sixteen simultaneous contenders and a replacement case that overlaps acquisitions with individual releases.
- [x] Observe the TCP fixture's actual live handshake sockets during those cases; require a peak no greater than eight.
- [x] Add a dedicated null-connection fixture with a fixed precompiled read-only library input.
- [x] Add both modules to the documented native server test gate.
- [x] Document fixed admission separately from persistent connection reuse and unsupported environment settings.
- [x] Run `make -C server test` with the reviewed dependency prefixes and exact source revision at `2881779f1927f660b367d48af08a28a3c09292be`.
- [ ] Review the full diff, source integration, failure records, and security effects before any publication decision.

Do not add application metrics in this task.
Allocation-failure injection is not present in the existing HTTP fixture.
If a deterministic allocation/header failure gate is required, coordinate a separate bounded fixture rather than claiming socket abort covers it.
The cleanup assertions passed in the later accepted native source gate.
The later actual-image result is recorded below.
Discovery now finds sixteen unchanged baseline methods and twelve capacity methods, for twenty-eight total cases.
All new native cases were unrun at the initial implementation checkpoint `815eea50876b6a6bd495e5f088d735c094b7417d`.
The accepted native result at `2881779f1927f660b367d48af08a28a3c09292be` is recorded below.

## Evidence and limits

The local host is Darwin/arm64 and cannot execute these Linux runtime binaries.
No Docker build or large local dependency build was started.
Python syntax and complete twenty-eight-case discovery passed.
A local loopback smoke check passed for byte forwarding, ninth-connection observation, and independent wave tracking.
These are fixture checks only.
`make -C server test` refused this host before compilation with the documented native-Linux requirement.
It returned exit status two and ran zero runtime tests.
The accepted [native RED run](https://github.com/stubbi/asm/actions/runs/42050169482) tested source `f7987a5f3571f4c7a58f7e731b0127a0e263d3ab` before admission implementation.
All sixteen baseline methods passed in 8.319 seconds, with no skips.
The candidate failed with `9 != 8 : The ninth request opened another database connection.`
Its single test took 4.370 seconds and returned exit status one.
The baseline returned exit status zero.
The 40,408-byte executable had SHA-256 `716eab55d79b1ef475300c3d22e70d41c5cd64e8a263c06f0fbf9218e2bce4ec`.
Retained source and test digests matched the reviewed frozen source.
The local receipt is `/private/tmp/asm-admission-red-42050169482/observation.json`.
Complete raw run logs and both test exits are retained beside that receipt.

This job had no two-CPU or 512 MiB runtime cap.
`make -j2` bounded build parallelism only.
The result is a behavioral diagnostic, not resource-capacity qualification.
The candidate stopped at the first ninth-connection failure.
Its later saturated liveness and recovery assertions did not run.

Installed Homebrew clang 23.1.4 cross-assembled all three modified Linux runtime sources.
This did not link or execute those runtimes.
The AArch64 atomic helper instructions were also exercised on Darwin ARM64 with only address-relocation syntax adapted for Mach-O.
Checks covered eight admissions, ninth refusal, 64-bit X0 preservation, and sixteen threads making sixteen thousand attempts.
The observed active peak was eight, with no residual slots after the threads completed.
This helper check does not establish Linux HTTP, TLS, database cleanup, or another port's runtime behavior.
Its local record is `/private/tmp/asm-admission-arm64-helper/result.json`.

Six image-contract self-tests and nine source-qualification recorder tests passed locally.
Those tests use controlled metadata and do not execute the new runtime or a container.
Precompiled-fixture path and permission rejection checks, C syntax, actionlint, and Makefile shell syntax also passed.
The first cross-assembly command stopped before compilation because its source paths repeated the `server` directory.
The corrected command assembled all three runtime sources; no assembly failure is concealed by that correction.

The initial checkpoint lacked native GREEN, full failure cleanup, and disconnect recovery evidence.
The later accepted native gate exercised all twenty-eight cases on AMD64 and ARM64.
The later actual-image gate passed the recorded source and fixture; private resource-capacity qualification remains separate.
An independent agent review identified two candidate-test gaps, which were corrected and reviewed again.
That advice did not replace the executed native and image gates.

### Required actual-image integration

Before publication, the admission-bearing derived image must run both the existing runtime suite and the new capacity suite.
An earlier sixteen-test image receipt describes different bytes and cannot qualify this change.
Build the test-only interposer in the owned native build directory before qualification.
The qualifier receives a fixed precompiled read-only library through `ASM_SERVER_CONNECT_NULL_FIXTURE`.
It needs no compiler and loads no executable code from its temporary data directory.
Keep the failure interposer outside the served production image.
The source test gate alone does not establish that the final derived image contains or passes the capacity checks.
The image-gate integration remained a publication requirement until the complete three-target preflight passed.
Both publishers were explicitly held during that preflight, so it published nothing.
After the owner verified all three receipts, this final candidate removes only the temporary false conjuncts.
The trusted main-push rules, dependencies, permissions, and shared strict validator remain unchanged.
Every later main source must pass its own complete image gate before publication.

### Native receipt boundary

The reviewed admission checkpoint is `815eea50876b6a6bd495e5f088d735c094b7417d`.
The native port recorder now requires at least twenty-eight hosted tests in the combined unittest summary.
Its observable boundary test accepts twenty-eight and rejects twenty-seven.
Before the recorder changed, that test failed because twenty-seven received a successful receipt and exit status zero.
The retained failure is `/private/tmp/asm-admission-native-gate-20261105/boundary-red.log`.
After the recorder changed, all nine recorder checks passed.
Their controlled metadata does not establish native runtime behavior.
The existing native workflow and combined Make test command remain unchanged.

### Actual-image gate implementation

The owner accepted native run `42060225513` at source `2881779f1927f660b367d48af08a28a3c09292be`.
Both native targets passed all twenty-eight hosted cases, including the fixed read-only NULL fixture.
That uncapped source gate does not qualify the derived images.

The image gate runs two sequential containers: `baseline` with all sixteen cases and `capacity` with all twelve cases.
Each container retains the existing 180-second watchdog, two CPUs, 512 MiB memory, 128 processes, and 256 MiB noexec temporary filesystem.
The combined test watchdog budget therefore increases from 180 to 360 seconds.
The workflow orchestration step increases from five to ten minutes for preflight and cleanup around those parts.
This preserves each callback deadline and allows the expanded coverage to finish without weakening runtime assertions.
It adds a second owned PostgreSQL fixture and container startup to qualification cost.
Neither the source gate nor this image gate establishes private deployment capacity.

The build stage uses the existing `test-admission-fixture` target under `/build/server`.
Only the qualification stage receives `/qualification/fixtures/connect-null.so`, root-owned with mode `0444`.
The served runtime receives neither the fixture nor a compiler.

The aggregate scope is `assembly-canonical-exports-admission`.
Each part uses `assembly-image-runtime-part` and names its `suite`.
Both parts must identify the same architecture, execution mode, source commit, runtime image ID, qualification image ID, ELF artifact, library digests, fixture descriptor, and security settings.
The fixture descriptor records its fixed path, SHA-256, byte count, mode, UID, and GID.
Each part records all discovered tests, zero skips, elapsed time, and the unchanged container limits.
The aggregate requires exactly one part of each name, at least twenty-eight total tests, and the exact sum of both part counts.
Legacy sixteen-case scopes, missing or duplicate parts, mismatched identities, exclusions, and malformed count types fail closed.
The child publisher and combined-index publisher consume the same Python evidence contract.
Raw part output and bounded timeout or failure outcomes remain available when aggregation fails.

- [x] Add observable acceptance and rejection contracts before changing the harness.
- [x] Retain the initial failure, including rejection of a legacy sixteen-case receipt.
- [x] Add the qualification-only fixture and two-part harness without changing frozen product or test bytes.
- [x] Update both publisher consumers, self-tests, and image documentation; retain both explicit publication holds.
- [x] Run focused contract, parity, syntax, and workflow checks; freeze a clean local checkpoint for owner review.

Local checks passed thirteen admission-image contracts, six image self-tests, nine native recorder contracts, and four source-package contracts.
All three workflows passed actionlint.
An isolated import of the qualification COPY inputs discovered exactly sixteen baseline and twelve capacity methods.
Nineteen frozen source, query, fixture, native-gate, and input-allowlist files matched the accepted native source byte for byte.
The served runtime Docker stage also remained unchanged.
These are local metadata, orchestration, source, and syntax checks, not actual-image execution.
The retained first failures and local check logs are under `/private/tmp/asm-admission-image-gate`.

The initial image-gate candidate remains at `c070c20de162e704161542020870e5b640e03363`.
Fresh review found that its pathname metadata check preceded an unbounded read.
A retained regression supplied 2,102,535 valid JSON and whitespace bytes through a FIFO and received successful publication validation.
Other regressions observed an empty FIFO blocking, a symbolic link accepted, and a regular file growing after metadata accepted.
The reader now opens once with `O_NOFOLLOW` and `O_NONBLOCK`, checks regular-file status through that descriptor, and closes it on every exit.
Its total reads cannot exceed two MiB plus one byte; excess content is rejected before JSON parsing.
The existing credential reader was inspected but also imposes ownership, ACL, and single-link policies that do not apply to image evidence.
The fix uses the same mature descriptor operations without those additional credential restrictions.
All seventeen admission-image contracts pass, including the exact-size boundary and growth case.
The original failure log and bounded-reader evidence are under `/private/tmp/asm-admission-evidence-reader`.

Docker execution and CI dispatch were outside that local checkpoint; the owner subsequently authorized exactly one image preflight.
No CI retry occurred.
The prior six-client RISC-V failure remains visible, and its cause remains unresolved.

### Completed three-target image preflight

[Run `42073901743`](https://github.com/stubbi/asm/actions/runs/42073901743), attempt one, passed source `b1450bd54efb12c0fb047c01117869c63e82197b`.
AMD64 and ARM64 executed natively; RISC-V64 used the pinned user emulator.
Every target passed all sixteen baseline and twelve admission cases without skips.
RISC-V64 completed those parts in 40.468 and 161.065 seconds, within the unchanged separate 180-second watchdogs.
The two native admission parts took 73.164 seconds on AMD64 and 75.226 seconds on ARM64.
Each complete owned fixture used two CPUs, 512 MiB memory, 128 processes, and 256 MiB noexec temporary storage.
Both publishers were skipped under the temporary holds.

The [image result record](../../server-images.md#admission-image-preflight) links the exact source, run, jobs, and three original aggregate receipts.
The reports are retained byte for byte under `docs/server-admission-evidence/42073901743`.
They bind both parts to the same source, runtime and qualification images, executable, library inventory, read-only fixture digest, and isolation.
Raw checkout logs identify the same source; runtime-step logs record aggregate twenty-eight-case success.
Local collection used bounded report ranges and compressed job logs, without image payloads or layers.
A local watcher encountered `ENOSPC`; its collection failure was retained separately while the remote jobs continued and passed.
Storage recovery allowed collection to resume without a CI retry.

This pass does not establish the cause of the earlier RISC-V failure or prove an admission-related correction for it.
It does not qualify physical RISC-V hardware, private one-CPU/256 MiB capacity, PostgreSQL 18, startup integration, deployment, or service recovery.
The final evidence and hold-release revision has no new CI result; later revisions and artifacts require their own exact-source checks.
The current preparation does not authorize a push, PR, merge into main, or publication.

The complete available Git history has not been reviewed for a merge decision.
That review remains required before merging the eventual implementation.

Primary instruction references checked on 5 November 2026:

- Intel 64 and IA-32 instruction reference, Volume 2: [locked operations and `CMPXCHG`](https://cdrdv2-public.intel.com/782156/325383-sdm-vol-2abcd.pdf).
- Arm Compiler armasm Reference Guide 6.00: [load-acquire exclusive](https://support.arm.com/documentation/dui0802/a/A64-Data-Transfer-Instructions/LDAXR).
- RISC-V unprivileged ISA v20260120: [atomic operations](https://docs.riscv.org/reference/isa/unpriv/a-st-ext.html).
- PostgreSQL 16: [asynchronous processing and result draining](https://www.postgresql.org/docs/16/libpq-async.html).

The libmicrohttpd manual request timed out during this checkpoint.
No new daemon-cancellation behavior was inferred from that failed request.
