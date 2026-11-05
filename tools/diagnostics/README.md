# RISC-V concurrent export diagnostic

This is an unlaunched investigation candidate for PR #37.
It must not merge into main or replace a qualification result.
Use the existing registered `server-images.yml` workflow on this isolated branch only.
Its branch version accepts manual dispatch, runs RISC-V only, and has read-only permissions.
It contains no publication job.
Root review must authorize the one diagnostic run before dispatch.

The consumer outcome is understanding why six concurrent requests failed.
Trust earned through evidence and resource care govern the investigation.
No fix is selected by this candidate.

## Retained failure and causal limit

Run [42013635598](https://github.com/stubbi/asm/actions/runs/42013635598) tested application merge source `437fa424157d5e884a11bd2643b1eaca71674fc1`.
Its branch head was `61181be91d31cc671e3827a7aa17c9e2b37afe71`.
Both native image jobs passed all sixteen runtime methods without skips.
The emulated RISC-V image built successfully in 44 minutes 50 seconds.
Its sixteen methods ran in 63.995 seconds, with six failed concurrent-response subtests.
The first six submitted requests returned HTTP 503; the last two passed.
The other fifteen methods passed.
No successful RISC-V report or runtime image archive was retained.

Failed artifact `13410479344` contains the runtime log.
Its `runtime-tests.log` SHA-256 is `313e19a8a30a40467568ebee8784cfd9e20c14e05cca03c0e6314031f0f4fd22`.
Its environment log SHA-256 is `be72b3d944df72a51718a633b5ea35bcbc2a8b95c02ff6d1486960bdc014a520`.
The retained complete failed job log SHA-256 is `492b8d323263d64fb8bf3fc7f685696b9801ace3c47d141f21ee89cdaa8f97d4`.

The failures record status only; they do not identify the response body.
Asm's own export 503 path precedes response creation.
It follows a stop flag or a null database result.
Library allocation, header, or queue failures instead close the connection.
The retained status alone cannot establish which path produced the observed response.

Independent source review found no actionable register, stack, request-state, or response-ownership defect.
The stop flag never clears and stops the daemon, while subsequent methods passed.
Database refusal remains the first application path to investigate.
Possible causes include TLS/connect refusal, SQL error, result shape, guard refusal, or the absolute deadline.
The separate one-second statement timeout can also refuse a query before the two-second application deadline.
Shared emulation and CPU contention remain hypotheses.

## Exact observation path

1. Compare frozen application inputs with the tested merge source.
2. Run the five native Linux diagnostic checks before RISC-V compilation.
3. Rebuild the unchanged runtime and a derived diagnostic layer.
4. Compare executable and loaded library hashes across both images.
5. Run the original serial export and configuration methods with their assertions.
6. Run the original concurrent method twice, with six clients and eight requests in its original order.
7. Retain both observations, including every failed assertion.

Wave two is a reproducibility observation.
It cannot replace a failed first wave with a pass.
An assertion, error, skip, or cleanup failure keeps the diagnostic command nonzero.
The report scope is `riscv-concurrency-diagnostic`, which the publication gate rejects.

The request observer records a fixed route identifier, monotonic timestamps, status, byte count, and response digest.
It classifies content types and application error codes through fixed allowlists.
It also compares the body digest with Asm's exact fixed unavailable response.
It never prints arbitrary response text, header values, or exception messages.

The diagnostic library forwards libpq arguments and results unchanged.
It emits one bounded summary per connection, with thread-local state.
Records contain phase timings, polling outcomes, result shape, and a sanitized five-character SQLSTATE.
Phase 0 is `BEGIN READ ONLY`; phase 1 is the guard; phase 2 is the export.
No SQL, parameter text, connection URL, certificate path, key, or libpq error string is logged.
The library is included only in the derived diagnostic image.
`LD_PRELOAD` is set only for tested application processes, not the database or Python coordinator.

Fixed numeric CPU, throttling, memory, process, and pressure counters bracket each method.
The application, PostgreSQL, and Python still share the original two-CPU container.
Memory remains 512 MiB; process count remains 128; temporary storage remains 256 MiB.
The two-second database deadline, one-second statement timeout, and 180-second outer watchdog remain unchanged.

## Artifact and measurement limits

The diagnostic checkout and application source are separate report fields.
The runtime embeds the tested application merge revision.
The frozen branch and tested merge have the same server tree: `7b0392f814a5ccb746a98dc0c71a36b8c403d442`.
The report records rebuilt image IDs and actual executable, library, and observer hashes.
Rebuilt bytes are not claimed to match the failed run's unavailable executable bytes.
Debian repository inputs can change between builds.

The observer adds timing and metadata work under emulation.
The request observer also adds hashing and coordination work.
These costs can affect a result near its deadline.
A diagnostic result does not qualify the original binary or establish native RISC-V behavior.
CPU counter changes can support a hypothesis; they cannot establish causation alone.
Select a fix only after phase and refusal data identify the failing boundary.

## Local checks and retained preparation failures

Local macOS checks cover response classification, text suppression, and preservation of failed assertions.
Local Clang compiles the observer source, but supplies no Linux execution evidence.
The native Linux forwarding test exercises real `LD_PRELOAD` binding against a controlled libpq substitute.
It checks forwarded arguments/results, SQLSTATE handling, record bounds, and refusal of malformed producer records.
That test must pass before the workflow starts its long RISC-V build.

The initial macOS loader experiment emitted no observer record.
A follow-up fixture attempt had a macro-related compile error.
The final Mach-O attempt refused symbol resolution with exit 125.
Those attempts do not establish a Linux observer defect or a passing forwarding check.
The unsupported Mach-O detour was removed.
The complete five-check command intentionally refuses a non-Linux host instead of skipping its forwarding check.

No diagnostic job has been dispatched by this preparation.
No frozen PR #37 or PR #38 file, public image, registry, credential, DNS record, or cluster resource changed.
