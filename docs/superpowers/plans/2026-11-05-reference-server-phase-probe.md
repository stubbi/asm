# Reference Server Phase Probe Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans. Complete each test cycle before review.

**Goal:** Identify the database failure phase and inspect emulator task accounting without changing the selected application or acceptance limits.

**Architecture:** Reuse the retained image, server, MHD, and libpq bytes. Add a bounded diagnostic interposer and explicit fixture controls. Preserve the original suite before separate direct and proxy observations.

**Tech Stack:** Python test orchestration, a C diagnostic interposer, a recorded cross compiler, PostgreSQL 16.15, libmicrohttpd 1.0.3, and pinned QEMU 8.2.2.

**Spec:** The selected contract below, `docs/specs/security.md`, and the frozen `a40a3b81c67189829d27838d8763e6c843316565` observation harness.

## Selected contract

The user outcome is an inspectable failure before a package or target receives a release claim.
Evidence and resource use govern this change.
The interposer can affect timing, so each result remains diagnostic and UNQUALIFIED.
The original failed 19-test result remains failed.

- Keep server SHA-256 `3e0bce8b6d9be340be5dfabbdd39fda064d7c9dd46287432561d315603ba93c9` and size 33,584 bytes.
- Keep the retained image, MHD, and libpq pins from the frozen harness.
- Keep 2 CPUs, 2 GiB, 256 PIDs, UID 65532, no network, no capabilities, and no new privileges.
- Keep the checked 600-second host budget and its 90-second collection reserve.
- Keep the 180-second suite budget, original request timeouts, and startup, cap, and recovery windows.
- Keep all 14 original HTTP methods, 52 assertion expressions, and fault cases.
- Run separate direct-then-proxy arms after the original methods finish.
- Use 16 queries and eight workers in each comparison arm.
- Reuse the same owned cluster, catalog, reader credentials, binary, libraries, and plaintext database settings.
- Verify that the two private database URLs differ only by port. Do not publish either URL.
- Keep the other five original tests marked not-run.
- Preload only the exact server child. Never preload Python or PostgreSQL.
- Publish no database SQL, provider parameter strings, password, connection URL, or arbitrary error text.
- Retain the existing bounded synthetic HTTP fixture records with their response redaction.
- Use only integer fixture indices in provider traces and the stdout summary.
- Do not push, dispatch, deploy, or change the product before the source review.

## Review focus

- Preserve provider arguments, callback closure, return values, and errno, including nested public library calls.
- Reject incomplete host-task attribution. A thread name or numeric allowance is insufficient.
- Charge observations to existing absolute deadlines. Late successful observations must fail.
- Reject ambiguous trace associations, malformed records, missing records, and output overflows.
- Preserve original failures when comparison, collection, or cleanup also fails.

## Task 1: Trace producer and reader

**Files:** `tools/diagnostics/reference_libpq_trace.c`, `tools/riscv64_reference_trace.py`, `tests/riscv64/test_reference_trace.py`.

**Interfaces:** `read_records(path: Path) -> list[dict]`; prefix `ASM_REFERENCE_TRACE=`; fixed schema 1.
The reader defines the exact field names and bounds.
A record has at most 2,048 bytes, including its prefix and newline.
A log has at most 1 MiB, 4,096 bytes per line, and 256 unique records.

- [ ] Write failing forwarding, callback, ownership, nested-call, errno, and privacy cases.
- [ ] Record the failing checks.
- [ ] Implement one-query observations with typed libpq and MHD interfaces.
- [ ] Observe the query iterator before connection creation.
- [ ] Map only the exact synthetic `fixture NN` form to integer indices 1 through 16.
- [ ] Preserve all other query values without publishing their text.
- [ ] Preserve the first adverse application-facing return before connection cleanup.
- [ ] Reject invalid JSON, duplicate fields, unknown fields, invalid clocks, and producer error markers.
- [ ] Run native tests with their actual header and compiler versions recorded.
- [ ] Review the producer and reader before target execution.

## Task 2: Fixture attribution and comparisons

**File:** `experiments/assembly-server/test_server.py`, owned by the fixture owner on its separate successor branch.

**Interfaces:** `BinfmtFifoConfig(registration=dict, runner_deadline=float)`; `ServerTests.attribution_config` defaults to `None`.
`PhaseTraceConfig(library_path=Path, sha256=str, read_records=callable)` supplies the server-only trace settings.
`ServerTests.trace_config` defaults to `None`.
`ServerTests.run_controlled_search_comparison()` performs the explicit direct-then-proxy observations.

- [ ] Test missing registration, wrong bytes, changed identity, invalid FIFO state, and late startup or recovery.
- [ ] Capture exactly one non-main pre-target host task through the owned, unopened FIFO invariant.
- [ ] Keep the same TID and start time through the accepted observations.
- [ ] Exclude that task only after complete attribution. Keep raw counts separately.
- [ ] Keep native counts and the 2/18/2 assertions unchanged.
- [ ] Verify 16 workers and matching owned connections before acceptance.
- [ ] Exercise the existing extra-client refusal and recovery checks within their original windows.
- [ ] Stop the original server before the additional comparison arms.
- [ ] Parse each stopped server's bounded trace log through the injected reader.
- [ ] Retain each cohort separately in the existing 1 MiB diagnostic record.
- [ ] Preserve cleanup and original failures if a comparison fails.

## Task 3: Header extraction and helper build

**Files:** `tools/riscv64_reference_build.py`, `tests/riscv64/test_reference_build.py`.

**Interfaces:** Extract PostgreSQL public headers from the exact retained image archive.
Extract the MHD public header from the same pinned 1.0.3 source archive used by the historical image build.
Compile the trace library and its forwarding check from recorded source files.
Record header, compiler, subordinate tool, source, output, and target identities.

- [ ] Test archive traversal, links, duplicates, whiteouts, missing headers, and size bounds before implementation.
- [ ] Bind the PostgreSQL headers to the retained image archive.
- [ ] Bind the MHD header to source archive SHA-256 `7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a`.
- [ ] Keep the runtime image and its libraries unchanged.
- [ ] Build only diagnostic artifacts with a fixed cross-compiler command and a private environment.
- [ ] Verify RISC-V ELF64, RV64GC/LP64D flags, a non-executable stack, and no writable executable segment.
- [ ] Run the forwarding check inside the retained image before the application suite.
- [ ] Preserve a compiler or forwarding failure without starting the application.

## Task 4: Runner and manual workflow

**Files:** `tools/riscv64_server_observations.py`, `tests/riscv64/test_server_observations.py`, `.github/workflows/server-images.yml`.

**Interfaces:** Supply `/inputs/binfmt-registration.json` through the readonly context.
The capture uses the exact version-1 schema agreed with the fixture owner.
Wrap `tearDownClass` to invoke the comparison helper, with the original teardown in `finally`.
Pass the existing absolute suite deadline into the fixture.

- [ ] Test the fixed registration schema and fail before launch on missing or changed inputs.
- [ ] Bind registration text, emulator bytes, server bytes, fixture source, source revision, and run identity.
- [ ] Record the trusted capture-to-launch stability assumption. Do not claim a race-free check.
- [ ] Add the trace source, reader, tests, and build receipts to exact Git materialization.
- [ ] Keep token scope limited to artifact retrieval.
- [ ] Reserve evidence collection and removal within the existing checked host budget.
- [ ] Run the trace forwarding check before the 14-method suite.
- [ ] Retain small bounded evidence on success or failure.
- [ ] Run focused tests, shared harness tests, actionlint, and diff checks.
- [ ] Review the exact source, compiler plan, fixture pin, and generated receipts before any push or dispatch.

## Interpretation limits

A direct/proxy difference is one diagnostic observation, not proof of relay causation or general performance.
The canonical TLS server test is not a timing control for this plaintext fixture.
An unobserved assembly deadline branch must remain unknown.
The new task attribution does not retrospectively identify task 139 from the earlier run.
The original 19-test gate cannot be cleared by this diagnostic.

## Local verification record

The workflow selects fixture commit `8fad44da00fa79001a42593810de2e0aa65597aa`.
Its test file has SHA-256 `580d5661bae102736aeaf3efd3c6889691cfe244485c6fe26c93ef5f53d9cd30`.
The fixture retains the original 14 methods and 52 assertion expressions.

Local checks on 2026-11-05 passed: 53 reference checks, 23 observation checks, and 20 shared harness checks.
Actionlint and the Git whitespace check also passed.
These checks include synthetic archive inspection, native forwarding, failure preservation, and bounded cleanup.
They do not establish target execution.

The real source archive, retained image headers, cross compiler, generated helper, and forwarding check require CI verification.
The actual server observations also require CI execution.
The runtime image, server, MHD library, libpq library, resource limits, and existing deadlines retain their recorded pins.
Only the server child receives the diagnostic preload.
The collector selects three exact files and excludes legacy server, database, and raw trace logs.

The phase fixture is diagnostic evidence and cannot replace the failed 19-test acceptance gate.
Remote execution requires the integration queue's source review and run selection.

Final review found a late-write failure that could retain a passing host receipt after the deadline.
Two regressions reproduced this defect against the earlier source.
The correction removes the stale receipt before the failure rewrite.
If removal or rewriting fails, the runner attempts a bounded failure marker and propagates the original error.
Total filesystem failure can prevent both removal and marker publication. The CI result remains authoritative.
The corrected local checks passed: 25 observation checks, 53 reference checks, and 20 shared harness checks.
Actionlint and the Git whitespace check passed. The time limits and qualification flags retain their earlier values.

## Controlled query-cost follow-up

Run 42118833683 retained complete associations for all three request groups.
Six requests returned HTTP 503, including one direct request.
Those results do not establish a relay-only cause or a database bottleneck.

The integration coordinator authorized one bounded follow-up measurement.
This serves maintainers who need a specific cause before changing the application.
The evidence and resource principles require unchanged acceptance limits and visible failures.

Run the original methods and direct/proxy groups before additional measurements.
Keep their outcomes, assertions, source bytes, authentication, and resource limits.
Use the same owned 23-package catalog after all three application processes stop.
Measure the fixed search query before a separate instrumented query group.
Use `EXPLAIN ANALYZE BUFFERS TIMING OFF` for the instrumented group.
Use 16 queries and eight workers in each additional group.
Share one two-second connection-and-query deadline for each measurement.
Keep the application's one-second statement limit and 200-millisecond lock limit.
Charge the additional work to the original suite deadline, with a 30-second local cap.

Retain connection setup intervals separately from query intervals.
Label Python library setup as part of its measured connection interval.
Keep authentication and scheduling costs unseparated unless the evidence distinguishes them.
Reduce the database plan to bounded numeric fields and fixed plan names.
Keep full plan trees for at most two successful queries in each instrumented group.
Retain summary timings and explicit tree-retention status for every instrumented query.
Exclude SQL, parameters, raw plans, connection URLs, credentials, and provider messages.
Record database build settings, catalog estimates, hardware, and CPU accounting where available.
Keep instrumented planning and execution measurements distinct from uninstrumented query timings.

A complete diagnostic is not an application pass or a target qualification.
Preserve failed requests and missing measurements in its record.
Keep the initial catalog statistics unchanged for both initial groups.
The coordinator also authorized a separate statistics control in the same diagnostic.
Analyze only the six seeded lookup tables after those initial groups.
Repeat the same query and instrumented groups after that control.
Keep the fixed run order and cache limitations visible.
Keep SQL, authentication, requests, resources, and deadlines unchanged.
The temporary statistics control does not change the selected fixture or application source.

The measurement follows the PostgreSQL 16 [EXPLAIN](https://www.postgresql.org/docs/16/sql-explain.html) and [ANALYZE](https://www.postgresql.org/docs/16/sql-analyze.html) contracts.
Planning time excludes parsing and rewriting.
Execution time excludes parsing, rewriting, planning, and ordinary result transmission.
Instrumented measurements do not isolate authentication, scheduling, or emulation costs.

The follow-up passed 72 reference checks, 25 observation checks, and 20 shared harness checks locally.
Actionlint and the Git whitespace check passed.
Two independent source reviews found no remaining blocker after the deadline and evidence-bound corrections.
These checks use synthetic database boundaries and do not establish a target runtime result.

## One SQL candidate and paired comparison

The coordinator accepted the investigation and authorized one SQL candidate.
The user outcome is completed searches within the existing limits.
The candidate remains separate from the application until measured results and review support adoption.

Preserve the original query and its digest.
Keep the existing latest-release lookup for unfiltered listings.
For a nonempty search, select latest eligible releases once with `DISTINCT ON`.
Apply the package cursor before release selection.
Apply the summary filter after latest eligible release selection.
Compute owner and target presentation after the 20-row page.
Materialize only the bounded matching and page results.

The extra SQL branch protects unfiltered pagination from an unconditional release-history sort.
The search branch can still inspect more release history in catalogs with many versions.
Extra query text can increase planning cost.
The comparison must expose these trade-offs without assuming an improvement.

### Task: Prove query behavior

Files: `tools/diagnostics/reference_search_candidate.sql`, `tools/diagnostics/reference_search_cases.py`, and `tests/riscv64/test_reference_search_cases.py`.
Interface: `verify(case, baseline, candidate, deadline) -> dict` returns bounded case outcomes and digest bindings.

- [ ] Test independent expected results and exact baseline/candidate bytes.
- [ ] Cover older matching summaries, yanked fallback, unpublished releases, numeric versions, target ordering, cursors, pages, and empty results.
- [ ] Roll back temporary semantic records before measurement.
- [ ] Preserve the original 23-package query hashes.
- [ ] Use native PostgreSQL 18 only for a separately labeled semantic smoke check.
- [ ] Require real PostgreSQL 16.15 equivalence before measurement.

### Task: Reuse the bounded measurement

Files: `tools/riscv64_reference_performance.py`, `tools/riscv64_reference_suite.py`, `tools/riscv64_server_observations.py`, and their current tests.
Interface: run the concrete candidate check through the existing connector and collector.

- [ ] Use four ordinary-query waves in baseline, candidate, candidate, baseline order.
- [ ] Retain all 64 attempts, failures, result hashes, connection intervals, and CPU counters.
- [ ] Keep 16 requests, eight workers, SCRAM, resources, and all existing time limits.
- [ ] Keep the original catalog statistics unchanged.
- [ ] Run no statistics refresh during this comparison.
- [ ] Keep original acceptance results and qualification flags separate.
- [ ] Run relevant local checks and independent review before the single remote comparison.

The native semantic smoke used PostgreSQL 18.6 and libpq/psql 18.1.
All 47 query pairs passed in 16 case groups.
All 23 original package result hashes matched.
Rollback, case-database removal, and the unchanged benchmark catalog checks passed.
The report binds the exact helper, queries, migration, and local tool bytes.
This smoke does not replace the PostgreSQL 16.15 gate.

Local checks passed: 94 reference checks, 28 observation checks, and 20 shared harness checks.
Actionlint and the Git whitespace check passed.
Review corrections reject unsupported summary schemas and preserve SQL-only scope before guest collection.
The original HTTP and 19-method acceptance results remain separate from this comparison.

### Measured candidate result

[Run 42204735599](https://github.com/stubbi/asm/actions/runs/42204735599) tested source `e7e1ad42dfd599b9cbab5fb5fb9a79f0e8b54fe3`.
Baseline SQL SHA-256 was `5cd15a09fa823567a83b4042b799a33e9bd379ec3cd346b96371c02ebd234b0d`.
Candidate SQL SHA-256 was `556594715aac9fbb0ba7f3689b2c48ea7733be8152c4167460f9db7ce41df4b4`.
The retained PostgreSQL 16.15 image ran under pinned RISC-V emulation and the unchanged resource and authentication limits.
The workload used the original 23-package catalog, 16 queries, and eight workers in each fixed ABBA wave.
No statistics refresh ran during this comparison.

Real PostgreSQL 16.15 equivalence passed all 47 pairs, 16 groups, and 23 original package checks.
Cleanup and the unchanged benchmark catalog checks passed.
The 64 timed attempts produced these completion counts:

| Wave | Completed | Failed |
| --- | ---: | ---: |
| A1 baseline | 16 | 0 |
| B1 candidate | 14 | 2 |
| B2 candidate | 14 | 2 |
| A2 baseline | 15 | 1 |

All 59 successful result digests matched the checked original package digests.
Four failures returned result status 7 and SQLSTATE `57014`, which identifies query cancellation.
One candidate attempt reached its shared client deadline.
The provider error text was excluded; the cancellation origin is not independently established.

Eleven package indexes completed all four waves.
For those indexes, the median candidate-minus-baseline query interval was positive 59.870 milliseconds.
Each index compares the mean of its two candidate samples with its two baseline samples.
These complete cases exclude failed attempts and do not remove fixed-order or cache effects.
Candidate query and total-interval tails also increased in this run.

Structural samples showed single release/publication scans instead of 23 repeated lookups.
Root shared-buffer hits decreased from 103 to 11.
These sequential instrumented samples do not establish a latency benefit.
CPU quota throttling occurred in 134 of 135 measured periods across the four waves.
The counters cover the whole container and do not isolate authentication, database, client, or scheduling costs.

The measurement completed in 16.595091 seconds, including the semantic gate.
The workflow passed its evidence-collection contract; this result does not establish a candidate performance improvement.
The baseline remains the application query.
The original 19-method result remains failed; those methods were not run by this SQL-only comparison.
Application, native, and release qualification flags remain false.

Artifact `13496330930` contains 61,942 ZIP bytes with SHA-256 `1be4a50171d1de1105bbb9038e912e806daba28f007363d3e1b657979fdd4e3c`.
Its observation contains 78,256 bytes with SHA-256 `469f3615e3add43066f1b93f72411beeb9e3ca9699c915259e5ec5a611302c4f`.
All 21 expanded members were retained and independently checked against the ZIP.
The local `candidate-analysis.json` retains all wave distributions, failed attempts, and complete-case paired samples.
