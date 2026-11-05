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
- Publish no SQL, parameter strings, password, URL, or arbitrary error text.
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
