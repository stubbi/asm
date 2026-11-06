# Selected PostgreSQL 18 compatibility

Status: native AMD64 preflights passed at the recorded sources; documentation updated 6 November 2026.

This gate checks canonical catalog compatibility with the database image selected by the private deployment manifest.
The user outcome is inspectable SQL, TLS, role, operator, and HTTP evidence for that exact image.
The governing principles are dependable reuse, evidence tied to exact bytes, and bounded resource use.

Each measured result below covers its exact preflight source and image identities.
Local contract tests alone do not establish database or container behavior.
The current PostgreSQL 16.15 qualification remains separate.

| Binding | Required value |
| --- | --- |
| Image | `ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie` |
| Selected index | `sha256:39add80f5b1e573e2f6b641c66fd1a2f8dede67ca0330e870285bc1078551390` |
| Linux AMD64 child | `sha256:9d1808e9b9c82fb1175ecc7aba615e88b16013e8f118c536a8b5a9aca017ec03` |
| Image config | `sha256:e81943bf2a7f93b868b0ce332642e9005ab3bc02d23f7effb505e5a19b7daa42` |
| Actual server version | `180006` |
| Application client version | libpq `160015`, PostgreSQL 16.15 |

Public registry metadata supplied these bindings on 5 November 2026.
The gate checks the local image config, selected index, actual server version, and fresh database identity.
The [pinned upstream source](https://github.com/cloudnative-pg/postgres-containers/blob/4c2710a78328becdadf708ca6d9cb3fb61f3f5ee/Dockerfile) identifies the PostgreSQL operand image.

## Measured preflight

[Run 42073391909](https://github.com/stubbi/asm/actions/runs/42073391909) passed on 5 November 2026.
It tested [source `1d9d60eb33643640b5358ca04f3340b5264e4d65`](https://github.com/stubbi/asm/commit/1d9d60eb33643640b5358ca04f3340b5264e4d65) through one native Linux AMD64 job.
Its [retained reports and logs](https://github.com/stubbi/asm/actions/runs/42073391909/artifacts/13437068798) bind the source, selected database image, application image IDs, and runtime hashes.
The original [qualification receipt](postgres18-compatibility-evidence.json) is retained here without byte changes.
Its SHA-256 is `cf6929c22a755f995ea2011abd60eb3f2e681b2547ff091da7475b05bcc1da84`.

All 38 applicable cases passed: 22 operator and catalog cases, plus 16 canonical HTTP cases.
One declared macOS extended ACL case was inapplicable on Linux.
No applicable case was skipped.
Both fresh database fixtures reported server `180006`, client libpq `160015`, and TLS 1.3.
Their database system identifiers differed.
All 33 owned containers and the private preparation were removed.
No database log or cleanup failure was reported.

Applications used two CPUs and 512 MiB each.
The separate database fixture used two CPUs and 2 GiB.
These are fixture compatibility results, not private deployment capacity measurements.

Compared with permanent source base `6db61512563dd0de024abedcb4735f0e847bfe13`, the preflight changed only the registered `assembly-server.yml` workflow.
It used the permanent manual workflow's exact bytes.
The permanent branch excludes that temporary replacement and records this result through documentation and the retained receipt.
Source-bundle HEAD, `SOURCE.json`, image labels, compiled HTTP identity, fixtures, and reports use the tested preflight revision.
A different permanent revision changes revision metadata and source-bundle bytes.
This result covers the recorded preflight artifacts; it does not qualify future image builds.

## Combined source preflight

[Run 42118769226](https://github.com/stubbi/asm/actions/runs/42118769226) passed on 5 November 2026, attempt one.
It tested source `2d9e80ad1bec850eaa576dc3a4980f8783d0893f` through one native Linux AMD64 job.
Only the registered manual workflow differs from parent `9c53f28a08b2ce13bc5f3b67749577c7014c5b6b`.
Its workflow blob is `1cecf11010d4b2cd6e6803afb945bbbfd648a52c`.
The [manifest](deployment-envelope-evidence/42118769226/manifest.json) binds the original reports, image identities, fixtures, and artifact ZIP.

The [ordinary qualification](deployment-envelope-evidence/42118769226/ordinary-qualification.json) passed 44 applicable cases: 22 operator and catalog cases, plus 22 HTTP cases.
The existing macOS ACL case remained the only platform exclusion.
All nineteen named metrics unit checks passed separately from those case counts.
The HTTP cases include the exact startup-error assertion with hostile `HOME` and `PGPASSFILE` inputs.
Both fresh database fixtures reported PostgreSQL 18.6, libpq 16.15, and TLS 1.3, with different system identifiers.
The ordinary application limits remained two CPUs and 512 MiB.
All 41 owned containers and the private preparation were removed.
No database-log or cleanup failure was reported.

The [separate fixed profile](deployment-envelope.md#recorded-37-case-preflight) passed 37 cases and nineteen separate metrics unit checks.
Drivers, test tools, and runtime shared one CPU, 256 MiB, no swap, and a 64 MiB temporary filesystem.
Three fresh PostgreSQL fixtures remained outside that application cgroup.
All 80 cgroup samples closed their required boundaries without OOM events.
The record retains deliberate availability failures and the in-flight SIGTERM reset.
It does not establish graceful drain, private capacity, or deployment compatibility.

The [native runtime record](server-metrics-evidence/42118754579/manifest.json) separately covers AMD64 and ARM64 at parent source `9c53f28a08b2ce13bc5f3b67749577c7014c5b6b`.
It does not qualify another PostgreSQL 18 database architecture.
This documentation revision and future builds change source metadata and artifact bytes.
Neither record extends to those later artifacts.

## Isolation and scope

The database runs as UID/GID 26.
Applications run as UID/GID 65532.
Each container has a read-only root filesystem, no Linux capabilities, and bounded memory, CPU, processes, and temporary storage.
The database has no network interface beyond its isolated loopback interface.
Its application qualifier shares that owned network namespace.
No host port, persistent volume, Docker socket, production target, or production credential is accepted.

Host Docker commands require the root-owned `/usr/bin/docker` executable and `/var/run/docker.sock` Unix socket.
The gate rejects ambient Docker and builder selection variables before it creates Docker resources.
Each command uses a new private configuration directory and an explicit local endpoint.
Saved Docker contexts cannot select another daemon.
Workflow inspection, builds, pulls, and cleanup use this same boundary.

A fresh synthetic certificate authority binds each prepared run.
A fixed declaration binds its nonce, source commit, server version, and certificate digests.
The test provider checks the actual server identity before fixture SQL runs.
It reuses the existing certificate and database assertion helpers.
The PostgreSQL 16.15 fixture version checks remain unchanged.

Qualification images add only test files to existing images.
The database target compiles and installs nothing.
The gate compares base filesystem layers and hashes database executables, PL/pgSQL, and linked libraries.
It also checks application runtime layers and loaded file hashes against both qualification stages.
These checks bind the tested programs; they do not claim general reproducible builds.

| Suite | Required coverage |
| --- | --- |
| Catalog and operator | All 16 catalog cases, six offline operator cases, and the actual image command interface |
| Canonical assembly HTTP | All 22 runtime cases, including exact export bytes, failures, TLS, deadlines, shutdown, and six metrics cases |
| Metrics unit checks | All 19 named checks with exact qualification-tool hashes; these are separate from HTTP case counts |
| Platform exclusion | Only the existing macOS extended ACL case is inapplicable on Linux |

Each suite uses a new owned PostgreSQL cluster.
The combined candidate requires the metrics descriptor only from the HTTP baseline.
Capacity and envelope cases cannot substitute for its six HTTP metrics cases or 19 named unit checks.
Original and derived qualification images must have matching fixed test-tool inventories.
The earlier measured preflight remains 38 applicable cases at its recorded source.
The combined preflight records the expanded 44-case ordinary result separately.
The gate requires different database system identifiers.
The gate retains failed checks and cleanup errors.
It bounds standard output to 4 MiB and standard error to 1 MiB while reading each child process.
On overflow or timeout, it kills the child process group.
It then reaps the direct child.
It retains the bounded output buffers from a failed command.
SIGTERM follows the failure, cleanup, and evidence path.
A failed database log request makes the gate fail.
It removes only resources with the expected image, name, nonce, identity, and isolation settings.
Private preparation directories are trusted local parents; their identity checks do not establish a general filesystem isolation boundary.

## Run the gate

The manual workflow must be present on the default branch before GitHub can dispatch it.
Its job has repository read permission and no publication step.
It builds the fixed application tags and three compatibility targets.
It does not run on pull requests or pushes.

The recorded first diagnostic used a separately reviewed temporary replacement of the registered `assembly-server.yml` workflow.
That temporary workflow had no publication step.
It remains outside the permanent branch.
The diagnostic did not require a pull request solely to register a temporary workflow.

For local fixture contract checks, use Python 3 and OpenSSL.
OpenSSL creates temporary test certificates.

```sh
make postgres18-contract-test
```

Successful output reports all contract tests as passing.
This command does not use Docker or connect to a database.

The native gate requires Linux AMD64 and Docker.
The reviewed workflow prepares the required local tags.
Its final check uses a new evidence directory:

```sh
make hosted-postgres18-test SOURCE_REVISION=COMMIT_ID EVIDENCE_DIRECTORY=NEW_DIRECTORY
```

Replace both uppercase placeholders.
Successful evidence contains `"status": "pass"`, both suite results, exact image identities, versions, migration digest, and cleanup results.
Failure evidence retains the first reported failure and available logs.
An existing evidence directory is preserved.

## Retained development failures

The development record retains the initial certificate-path failure and its correction in `83a82f21`.
Review then exposed output, termination cleanup, database log, and ambient Docker selection failures.
Commit `d8155f3d` corrected those boundaries and added observable regression checks.

A later endpoint test reached its three-second deadline; its cause remains unknown.
Commit `94c2d779` changed only that test fixture's startup, while preserving the deadline and assertions.
An outdated mock also attempted two failing read-only Docker inspection commands during development.
Neither command created resources.
An earlier PostgreSQL 16.15 hosted test invocation lacked the reviewed fixture paths; no SQL case ran.
The later 28-contract checks and native preflight do not erase these earlier results.

## Remaining limits

This gate does not connect to the private cluster or qualify CloudNativePG reconciliation.
Forced process or host termination can prevent cleanup and evidence retention.
It does not test two-instance synchronous replication, failover, persistent volumes, backup, restore, capacity, or public deployment.
Fresh fixture startup does not establish production startup behavior or recovery.
Private deployment capacity remains unqualified by these owned fixture results.
The [fixed deployment envelope](deployment-envelope.md) records a separate AMD64 check for qualification drivers, test tools, and the runtime.
Its original parser failure remains retained beside the later complete 37-case result.
The ordinary PostgreSQL 16.15 admission image gate remains separate from that profile.
It does not qualify ARM64 or RISC-V database images.
The ordinary PostgreSQL 16.15 operator and server image gates remain required independently.
Older `psql` compatibility is limited to the command paths exercised here.
[PostgreSQL documents limits when an older client connects to a newer server](https://www.postgresql.org/docs/16/app-psql.html#APP-PSQL-NOTES).
