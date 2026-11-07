# Verified local checkpoint

Date: 1 November 2026.

The final build passed 13 integration tests against a separate PostgreSQL database.
The test run took 9.546 seconds.
It had no failures, errors, or skipped tests.
The fixture imported 23 packages before the native assembly server started.

These checks establish a working application boundary between assembly, an HTTP library, and PostgreSQL.
They do not establish production API parity or a performance advantage.

## Build identity

| Input or result | Recorded value |
| --- | --- |
| Public Asm base | `aa27c26abfb8e177531c14b3ed6d124e98339a66` |
| Unpublished schema and fixture tool | `286a75c9d806aaed3e91bd54785db2ac60f5310a` |
| Application source | GNU Intel-syntax x86-64 assembly |
| HTTP library | GNU libmicrohttpd 1.0.3 |
| PostgreSQL client and fixture | 16.15 |
| Compiler driver | GCC 13.3.0, Ubuntu package `13.3.0-6ubuntu2~24.04` |
| Assembler and linker | GNU Binutils 2.42 |
| Operating environment | Linux 6.18.57, x86-64, glibc 2.39 |
| Executable bytes | 29,712, including debug information and excluding shared libraries |
| Executable SHA-256 | `c0cc45dd930eff6c49c09bb9fe183a89f48c3f48aee74ca0ecfba528e2504b53` |

This historical run used an unpublished behavioral reference for its schema and administrative fixture commands.
The current [self-contained tests](RESULTS.md) use the included migration and require no external reference checkout.
The [initial record](evidence/initial-results.json) identifies these inputs and results.
The [initial test output](evidence/initial-test-output.txt) retains the complete 13-test result.

The ELF inspection found position-independent code, a non-executable stack, read-only relocations, and immediate symbol binding.
Its direct runtime dependencies are libmicrohttpd, libpq, and libc.
These libraries have their own dependencies.
The local executable contains workspace library paths and is not a distribution artifact.

The build-time C program checked the HTTP library's structure layout and numeric constants.
That program is not linked into the application.
The GNU archive and Ubuntu package hashes appear in the README.
The archive came from GNU over HTTPS.
A detached release signature was not checked.

## Observable checks

| Check | Verified behavior |
| --- | --- |
| Health | Liveness works independently of the database; readiness reads the required catalog and checks its role and schema. |
| Configuration | Empty, oversized, NUL-containing, public, symlink, and FIFO files fail before listening. |
| Admission | Sixteen incomplete requests use at most 18 process threads, including the main thread and listener. Excess admission fails. |
| Recovery | The first request after the closed connections are cleaned up succeeds. |
| Query input | Duplicate, unknown, control-containing, non-ASCII, and oversized query fields fail. |
| Privilege loss | Readiness fails when a required read grant is removed and recovers after restoration. |
| Pagination | Two pages return all 23 fixture packages without duplicates or missing records. |
| SQL parameters | Quotes, percent signs, and SQL-shaped input remain literal search values. |
| Concurrency | Sixteen searches across eight test workers return their own expected package records. |
| Database stall | A stalled database request fails within the tested deadline while a concurrent liveness request succeeds. |
| Shutdown | Process termination completes within the tested deadline during a stalled database request. |
| Startup role | A migrator role and a reader without a required grant fail before listening. |
| HTTP input | Unknown paths, unsupported methods, request bodies, oversized URLs, and excessive headers are rejected. |

The final run observed these times:

| Observation | Seconds |
| --- | ---: |
| Database stall until service failure | 2.003004 |
| Concurrent liveness request during that stall | 0.001788 |
| Connection cleanup and successful recovery request | 0.011733 |
| Shutdown during a database stall | 1.989432 |

Each value is one fixture observation.
There was no comparative benchmark, representative load study, tail-latency study, or total-memory measurement.
These values are not service-level objectives.

## Defects found and corrected

The initial HTTP configuration omitted `MHD_USE_ITC`, the library's inter-thread wake channel.
After saturation, worker threads exited while the listener's admission count still included their connections.
The first recovery request was reset.
Waiting for the worker threads alone did not fix the failure.

The pinned library source explains this behavior in `cleanup_connection` and `MHD_cleanup_connections`.
Connection cleanup uses the wake channel to resume admission.
The assembly configuration now enables that channel, and the ABI check verifies its flag value.
The strict recovery assertion passed in a focused test and the complete final suite.
The failed runs remain in the local evidence record.

The configuration reader now uses nonblocking open before checking the file type.
This makes the FIFO rejection terminate without waiting for a writer.

Two setup failures were also corrected.
The GNU build needed a writable temporary directory.
The first database fixture setup incorrectly omitted the supplied administrator password.
The harness now preserves that credential, generates private role credentials, and registers cleanup before each dependent operation.
A mistyped focused-test class name also failed before test execution; the corrected invocation passed.

## Production parity remains open

The minimum application surface is routing, bounded validation, lifecycle management, deadline handling, and response ownership.
Established libraries retain HTTP parsing, PostgreSQL protocol handling, transport security, and cryptography.
The local fixture does not test public TLS or remote database certificate validation.

The scan-based search and connection-per-request model are experiment choices.
They are not the design for global software distribution.
Production work needs an indexed search projection, independent artifact delivery, metadata caching, connection reuse, and measured backpressure.
It also needs absolute request deadlines and a defined liveness path under full admission saturation.

The experiment lacks the stable v2 API, deterministic v1 export, version detail, download observations, and fixed-label metrics.
It also lacks publication, an HTML interface, HTMX fragments, production authentication, and deployment qualification.
The HTTP and database memory settings do not establish a total process-memory ceiling.
The application still needs fuzzing, allocator-failure checks, architecture portability work, and an independent assembly review before promotion.

No public repository, service, DNS entry, or private deployment source changed for this checkpoint.
