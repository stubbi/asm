# Canonical RISC-V phase diagnostic plan

> **For agentic workers:** Implement the approved staged diagnostic. Freeze source and local checks before root authorizes one execution.

**Goal:** Locate the observed six export refusals within the actual canonical client pipeline.

**Architecture:** Add a qualification-only pass-through libpq observer and an owned HTTP driver. Keep all runtime assembly and SQL unchanged.

**Tech stack:** Pinned libpq 16.15, libmicrohttpd 1.0.3, RV64GC/LP64D, C diagnostics, and Python qualification orchestration.

**Spec:** The failed canonical run `42195670810`, exact source `cb0f3f7315fe2878660684a1fe6eea76ca65e5ae`, and this approved measurement contract.

## Global constraints

- The public head and tested merge `7f0ba4c2f0a0f2b463e16ff9742f3c42f44043ef` share tree `f0bd93473df4b69c16178b85629a71df6ec77177`.
- Run one untraced eight-request control, then one traced eight-request arm. Preserve six workers in each arm.
- Reuse the same owned TLS fixture and certificates. Start a fresh application process for each arm.
- Preserve the fixed order and record cache/order limits. This is not a randomized comparison.
- Preserve two CPUs, 512 MiB memory, mutual TLS, eight admission slots, and the existing two-second whole-database deadline.
- Preserve the one-second statement timeout, request limits, guard semantics, and all existing runtime policy.
- Keep held drain source `4b356d6` and hosted source `dc01408` in their existing worktrees.
- Emit no SQL, parameters, credentials, URLs, paths, pointers, provider messages, or arbitrary server text.
- Route association is unknown unless directly established. HTTP records use an independent fixed route enumeration.
- A source-rebuilt executable is UNQUALIFIED. The failed run retained no executable or image bytes to match.
- No cold PostgreSQL rebuild, large image pull, RISC execution, container execution, CI, or dispatch occurs before root review.
- Use one absolute 600-second host budget, including setup, collection, cleanup, and late output.
- Reserve 90 seconds for collection and cleanup. Cap preparation/build at 120 seconds within the shared remaining time.
- Keep one shared 180-second guest envelope for owned setup, both eight-request cohorts, and guest cleanup.
- Cap that complete guest envelope by the remaining host work budget. Do not allocate a new 180 seconds for either arm.
- Preserve the original HTTP wire behavior and three-second socket inactivity timeout. The shared guest deadline bounds the whole comparison.
- The temporary `server-images.yml` replacement is diagnostic-branch-only and permits manual dispatch with read-only contents/actions permissions.
- Do not merge or cherry-pick this workflow into main. Restore the original main workflow in a reviewed successor before retaining the tools.
- This diagnostic does not replace the original sixteen/twelve-case image or release gates. Public queue-head production assembly, SQL, and workflow remain unchanged.

The outcome is an inspectable failure phase before selecting an optimization.
Evidence-bound trust requires retaining failures and unknown associations.
Resource care requires reusing bounded, digest-bound assets and refusing an unapproved rebuild.
Observer overhead remains a measurement limitation.
The temporary workflow replacement is a material tradeoff: it isolates this diagnostic while preserving the original main gates as a separate requirement.

## Review focus

- libpq 16.15 calls public `PQconnectPoll` within its constructor; provider-internal calls must not corrupt application ownership.
- The observer must forward all arguments, callbacks, return values, and errno without changing policy.
- BEGIN returns command status; guard and export return tuple status. Each phase must drain before the next.
- A client deadline can expire before a failed provider call. Retain the last observed phase without inventing a reason.
- A completed diagnostic is not a successful registry qualification. Every HTTP refusal and transport failure remains visible.

## Stage 1: Local contracts and pass-through observer

Files:

- `tools/diagnostics/canonical_libpq_trace.c`: fixed, bounded connection and phase records.
- `tools/canonical_riscv_trace.py`: strict numeric record validation and original trace-line retention.
- `tests/riscv64/test_canonical_trace.py`: typed mock-provider forwarding and ownership checks.
- `tools/canonical_riscv_phases.py`: strict record validation, exact HTTP cohort, resource snapshots, and evidence binding.
- `tests/riscv64/test_canonical_phases.py`: controlled helper and driver failure tests.
- `tools/canonical_riscv_build.py` and `tests/riscv64/test_canonical_build.py`: independently owned bounded asset extraction and host cross-build.

- [ ] Reuse typed forwarding and `provider_depth` from `881208fcec32ec8fe4609747ca2c4d8b9065c49f:tools/diagnostics/reference_libpq_trace.c`.
- [ ] Remove reference query-parameter inspection and single-query assumptions.
- [ ] Observe connect, BEGIN, guard, export, result draining, and finish through fixed ordinal phases.
- [ ] Retain result status, bounded SQLSTATE, and only the guard scalar states unknown, zero, or one.
- [ ] Record monotonic wall times, callback-thread CPU times, poll returns, and the unfinished phase at finish.
- [ ] Emit at most 256 connection summaries, each at most 4096 bytes. Mark overflow or ownership violations inconclusive.
- [ ] Invoke the inherited original concurrent-export method through an observation-only subclass.
- [ ] Retain all eight HTTP outcomes when the original cohort completes, with route enumeration, status, body SHA-256, and byte count.
- [ ] Preserve expected-byte checks and executor cancellation. Retain actual partial outcomes after a transport error.
- [ ] Snapshot `cpu.stat`, `cpu.max`, `memory.events`, `memory.current`, `memory.peak`, and `memory.max` before and after the cohort.
- [ ] Label `memory.peak` as a container-lifetime cumulative value. Never call its arm difference a per-arm peak.
- [ ] Test malformed, duplicate, missing, oversized, and untrusted input with fixed bounds.
- [ ] Run local mock-only typed forwarding checks. They do not establish target ABI or RISC execution.

## Stage 2: Bounded asset reuse and execution preparation

- [ ] Reuse retained image `sha256:ea55425e6daa994ad57c46862258368c192c6f1f44b146c8a7bf3d1758571ae1` through its exact ZIP/TAR receipts.
- [ ] Materialize the exact reviewed `881208fcec32ec8fe4609747ca2c4d8b9065c49f` SDK separately from canonical source and diagnostic-head source.
- [ ] Bind each reused asset to an exact digest and size before extraction or use.
- [ ] Stop at the missing-asset limit. Report it before any cold dependency rebuild or large transfer.
- [ ] Preserve exact canonical source and dependency identities in the diagnostic record.
- [ ] Reuse the reviewed materializer where its contract fits. Keep producer images and deployed artifacts unchanged.
- [ ] Build a source-rebuilt candidate only through the approved bounded route. Label it UNQUALIFIED throughout.
- [ ] Host cross-assemble and link unchanged canonical runtime/config against exact retained libraries. Do not rebuild PostgreSQL.
- [ ] Compile the unchanged ABI/version probe and typed mock smoke. Execute them only later inside the reviewed image.
- [ ] Precompile the observer into a read-only qualification location. Preload only the application child.
- [ ] Preserve the existing owned TLS fixture and container restrictions.
- [ ] Freeze the complete source, local checks, raw negative evidence, and asset plan for root review.

## Stage 3: One authorized diagnostic

- [ ] Run exactly the approved control/traced pair with unchanged policy and resource budgets.
- [ ] Retain actual phase records, all eight HTTP outcomes, before/after resource values, source and artifact digests, and cleanup results.
- [ ] Emit one bounded closed-schema guest JSON record and only validated numeric trace lines before guest exit.
- [ ] Retain the bounded attached pipe privately. Publish only validated controlled records; do not copy evidence from stopped tmpfs.
- [ ] Retain typed Docker OOM/exit state if the guest cannot emit its after snapshot. Mark that missing snapshot explicitly.
- [ ] If the original map cancels queued requests after a transport error, retain actual partial observations and mark collection incomplete.
- [ ] Fail the diagnostic on missing observations, invalid output, timeout, lost evidence, or unowned cleanup.
- [ ] Distinguish a captured refusal from missing instrumentation. Do not convert refusals into a qualification pass.
- [ ] Report the observed phase and costs. Keep root cause and any proposed optimization conditional on that evidence.

## Current limits

The original failure proves six HTTP 503 responses in the concurrent-export method, not their cause.
The test submits eight requests through six workers; assertion order does not establish completion order.
The canonical fixture uses certificate authentication. Reference SCRAM and SQL findings do not transfer.
Root confirmed availability of retained artifact `13423240467` on 6 November 2026. Its exact ZIP/TAR pins remain mandatory.
The retained image has no guest compiler. A missing bounded host tool or payload is a limit, not permission for a cold rebuild.
Callback-thread CPU includes host emulation and observer work. It does not isolate cryptographic cost.
The original sixteen/twelve-case qualification remains outside this diagnostic's scope.

## Local preparation evidence

The focused local aggregate passed 75 checks: 20 builder, 18 guest, 18 observer/parser, and 19 host/core checks.
These checks use controlled fixtures and a typed mock provider. They do not qualify the target ABI or the application.
The host transport checks use the complete closed guest schema without replacing its validation function.
Retained local failures include the original map-cancellation assumption, ephemeral tmpfs collection, source-mode binding, and SDK ownership joins.
No RISC-V application, container, CI run, or private profile has executed for this candidate.
