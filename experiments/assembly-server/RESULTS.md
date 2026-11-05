# Reproducibility checkpoint

Date: 1 November 2026.

The experiment builds and tests without the unpublished Rust reference executable or an existing database account.
The working checkout and an independent Git-object checkout each passed all 16 tests.
Both runs had no failures, errors, or skips.
Their elapsed suite times were 8.875 and 9.283 seconds, respectively.

The independent checkout came from tree `22b94bfab71da66e31fae719d80d31dcbcb5dda6`.
It compiled both executables again and started its own PostgreSQL clusters.
Legacy reference-tool and administrator-file variables pointed to unavailable paths during that run.
The build and tests did not use them.
At that checkpoint, all ten code and fixture inputs matched the recorded source manifest.

The native application, readiness query, and search query are byte-identical to the initial checkpoint.
The changes are build checks, a local PostgreSQL fixture, its regressions, and documentation.
The [initial results](INITIAL_RESULTS.md) preserve the earlier 13-test result and its failed checks.

## What changed

The build now checks the exact library headers and linked runtime versions on every invocation.
Its C ABI check includes the operating-system structures, system calls, constants, and libpq enums used by the assembly.
The checker is a separate executable; it is not linked into the application.

The fixture creates a fresh PostgreSQL cluster with private files and random credentials.
It accepts no existing database URL, service name, or data directory.
It verifies the owned process and connected data directory before creating catalog data.
Initialization, connection, query, startup, proxy cleanup, and process waits have explicit limits.
Startup connection and identity verification share one absolute deadline.

The included migration is byte-identical to the reviewed reference schema.
The fixture checks its digest before startup and applies its migration record in the same transaction.
It retains separate migrator, operator, and reader roles.
Parameterized fixture inserts create the same 23 package records without a production importer.

The original 13 HTTP tests remain.
Three additional tests cover this delivery change:

- Changed migration bytes and unsupported PostgreSQL versions fail before startup.
- A forced database-identity mismatch during startup removes the owned process, listener, and directory.
- Retained fixture digests, acceptance audit fields, and actual database timeout settings match their expected values.

## Inputs and scope

| Input | Recorded version or identity |
| --- | --- |
| Public source base | `063d3031bb5467d2cf574be6d7abd82c28d3c063` |
| HTTP library | GNU libmicrohttpd 1.0.3, built from its pinned official source |
| PostgreSQL server, headers, and libpq | 16.15, built independently from its pinned official source |
| PostgreSQL build parallelism | Two jobs |
| Python | 3.12.14 |
| Test identity | Unprivileged UID 65534 |
| Environment | Linux 6.18.57, x86-64, glibc 2.39 |

The dependency recipe contains source URLs, hashes, and build commands.
The tests need no Rust installation, container engine, shared PostgreSQL fixture, or public endpoint.
The PostgreSQL and HTTP builds used here do not enable TLS.
Both test listeners use loopback.

The working-checkout executable has 29,728 bytes, including debug information and excluding shared libraries.
Its SHA-256 is `58013036e02d73f6a00516fdeb3c4dd174c66d5a8173f51b9a7be64dd15edb0d`.
The independent executable's SHA-256 is `20e70adc518a222024e0e02e45354adcafb88205faa4f7c25aabecb7a67f3c58`.
Local debug and library paths can change executable bytes between checkouts.
This checkpoint does not claim a reproducible release binary.

The [machine-readable record](evidence/results.json) contains both executable identities and the exact source-input digests.
The [working-checkout output](evidence/working-test-output.txt) and [independent-checkout output](evidence/clean-test-output.txt) retain the test results.

## Failures and review corrections

The first PostgreSQL source configuration used an unsupported `--without-ssl` option.
The corrected recipe uses PostgreSQL's default configuration without TLS support.
The source configuration, two-job build, and local installation then completed successfully.

The first fixture run failed before the HTTP suite started.
Its URI encoder used form-style `+` characters for spaces in libpq connection options.
The pinned libpq URI decoder preserves those characters, so the server rejected the options.
The encoder now uses percent-encoded spaces.
The successful suite checks the database's effective statement and lock timeouts.

An independent source review also found two corrections before the successful run.
Fixture record digests now retain the reference's declared JSON field order, including artifact fields.
The startup connection and identity query now share the stated deadline.
The fixture retains all acceptance audit fields, and its failure test exercises cleanup inside startup.

These failures were corrected without weakening the HTTP assertions or increasing their time limits.
The [failure record](evidence/reproducibility-failures.json) identifies the retained logs by digest and states each correction.

## Administrator password correction

The first public CodeQL scan identified a password-file write in the local fixture.
The finding applies to commit `25793199b178c1a38e533304f2311f90af49811c`.
The fixture wrote its random administrator password to a temporary file before running `initdb`.

The fixture now sends that password through a private subprocess input pipe.
On Linux, `initdb` reads the pipe through `--pwfile=/dev/stdin`.
The password is absent from the process arguments and environment.
The 20-second initialization timeout and owned process-group cleanup remain unchanged.
The server's separate, owner-only connection URL files remain part of its tested configuration contract.

All 16 existing tests passed after this change as unprivileged UID 65534.
The run had no failures, errors, or skips and took 7.999 seconds.
The test cases, native application, SQL, and dependency pins did not change.
The [correction record](evidence/password-pipe-results.json) binds the result to the changed source and retained finding.
The [test output](evidence/password-pipe-test-output.txt) retains the complete unittest result.
This local result does not establish that the updated public CodeQL check passed.

## Remaining limits

This is an experimental source reference.
It has no public deployment, container image, release binary, or production promotion.
The tests ran on a shared host and establish functional outcomes only.
They do not establish throughput, tail latency, total memory use, or superiority over another implementation.

The [architecture gates](https://github.com/stubbi/asm/blob/main/docs/architecture-gates.md) still apply.
The experiment lacks full reference parity, indexed search, authenticated package metadata, artifact delivery, public publication, and an HTML interface.
Public TLS, production scheduling, absolute HTTP deadlines, independent assembly review, and failure qualification remain open.
