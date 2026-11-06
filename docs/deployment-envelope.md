# Fixed deployment envelope

Status: fixed native AMD64 profile passed at the recorded source; documentation updated 6 November 2026.

This profile tests the selected PostgreSQL 18 database with one fixed application resource envelope.
It serves operators who need inspectable resource and failure evidence before deployment.
The [implementation plan](deployment-envelope-plan.md) records its scope and governing principles.

| Component | CPU quota | Memory | Swap | Private temporary filesystem |
| --- | --- | --- | --- | --- |
| Application qualifier | 1 CPU | 256 MiB | None | 64 MiB |
| PostgreSQL fixture | 2 CPU | 2 GiB | Existing fixture policy | 512 MiB |

Qualification drivers and test tools share the application cgroup with the assembly runtime.
Unit tools run before the first suite snapshot; the memory peak retains their usage.
A cgroup is the Linux mechanism that applies these resource limits to related processes.
This conservative fixture scope is not an application-only capacity measurement.
The temporary filesystem budget does not emulate Kubernetes ephemeral-storage accounting.
The ordinary PostgreSQL 18 gate remains at 2 CPU and 512 MiB for applications.

## Fixed checks

The profile selects three modules in separate application containers with fresh owned PostgreSQL clusters:

1. Run all 22 canonical HTTP baseline cases, including the six metrics cases and 19 named metrics unit checks.
2. Run all twelve admission cases with the explicitly selected PostgreSQL 18 provider and fixed NULL-connection fixture.
3. Run three envelope cases for eight maximum-size slow readers, eight incomplete headers, and in-flight SIGTERM.

The ordinary admission module remains twelve cases.
Its 180-second image watchdog and other architectures remain separate from this native AMD64 profile.
The three modules total 37 cases; the unit checks remain separate from that count.
Metrics evidence belongs to the baseline report and cannot come from the other two modules.
All fixed qualification tools must match the original and derived image inventories.
The profile preserves the existing request, TLS, role, byte, and recovery assertions.
It does not extend their deadlines.
Neither PostgreSQL 18 profile accepts expected failures or unexpected successes as qualification evidence.

The producer records cgroup limits, current and peak memory, events, swap, and CPU counters.
It captures each test boundary and the final suite closure before exit.
Missing evidence, a different limit, an OOM event, or failed cleanup makes the gate fail.
CPU throttling remains visible and does not excuse a missed deadline.
Bounded raw request records retain completion, refusal, truncation, reset, and timeout outcomes, including failed cases.
Valid-request refusals and transport failures count as unavailable service even when an admission assertion passes.
Incomplete headers remain separate malformed traffic.
The test does not assume an additional health request can enter sixteen occupied HTTP connections.

The cancellation case reads the exact owned database log through a bounded provider interface.
The PostgreSQL 18 provider verifies the nonce, database system identifier, version, data directory, administrator, and TLS before every read.
Only `/run/asm-postgres18/postgres.log` is accepted.
The read accepts at most one MiB and rejects missing, malformed, oversized, or non-UTF-8 data.
The existing nine cancellation-message assertion and 0.7–1.8 second request assertions remain unchanged.
The test sidecar enables a fixed logging collector only for this profile.
The harness retains bounded console logs and the owned file separately.

## Run after review

The profile requires native Linux AMD64, cgroup v2, Python 3, OpenSSL, and the fixed local Docker endpoint.
Use the existing [PostgreSQL 18 preparation and image procedure](postgres18-qualification.md).
Bind every image and fixture to the exact candidate commit.
Run the ordinary gate first with its own new evidence directory.
That gate removes its private preparation.
Prepare a fresh fixture before building the compatibility images for this profile.

```sh
make postgres18-contract-test
make hosted-deployment-envelope-test SOURCE_REVISION=COMMIT_ID EVIDENCE_DIRECTORY=NEW_DIRECTORY
```

Replace both uppercase placeholders.
An existing evidence directory is preserved.
Successful evidence requires all three part reports, exact image bindings, resource closure, and successful owned cleanup.
Retain the complete evidence directory after failure.
The result below covers the recorded 37-case source and image bytes.
Future source revisions and image builds require their own qualification.

## First native preflight

[Run 42111348191](https://github.com/stubbi/asm/actions/runs/42111348191) tested source `7b0e18b2aedf5054b9a0b1cc49d847cdd6a1681e` once.
That earlier 31-case source excludes metrics.
It cannot qualify the combined 37-case profile.
That source differs from frozen candidate `95d4cf94455c10917922a0d94a180bc0a54f983f` only in the registered preflight workflow.
The ordinary compatibility gate passed 38 applicable cases with the existing macOS exclusion.
Its source-scoped receipt is [retained separately](deployment-envelope-evidence/42111348191/ordinary-qualification.json).

The constrained baseline completed all sixteen assertions before its evidence parser rejected `core_sched.force_idle_usec` in `cpu.stat`.
The [failed qualification receipt](deployment-envelope-evidence/42111348191/qualification.json) keeps the original failure.
All [34 raw cgroup samples](deployment-envelope-evidence/42111348191/baseline.stdout.log) and the [baseline test log](deployment-envelope-evidence/42111348191/baseline.stderr.log) are retained.
The [local failing regression](deployment-envelope-evidence/42111348191/parser-red.txt) reproduces the parser defect from those samples.
The correction accepts bounded canonical dotted counter keys.
Required counters, duplicates, numeric bounds, monotonicity, limits, and OOM checks remain unchanged.

The twelve admission and three envelope cases did not run.
The nine-cancellation admission assertion did not run.
The partial baseline does not qualify the resource envelope, capacity, draining, or deployment.
Both gates reported successful owned cleanup.
That first run supplied no native result for the parser correction.

The original artifact ZIP is retained privately outside this repository.
It contains 183132 bytes.
Its SHA-256 is `d89f3b633f6a2fbf2673bf25d216dcda05832d12b41de2faacea6c5d6ee83311`.
This digest matches the [GitHub artifact metadata](deployment-envelope-evidence/42111348191/artifacts.json).
The [independent inspection](deployment-envelope-evidence/42111348191/independent-review.json) records the exact image identities and observed coverage.

## Combined preflight failure

[Run 42116208295](https://github.com/stubbi/asm/actions/runs/42116208295) tested source `c7dbecc236dcf71b0c24e3416be8b7506ad8d28c` once.
Its ordinary gate passed 43 applicable cases and failed the exact metrics startup-error assertion.
The actual error representation included an abbreviated password-file warning.
The existing macOS exclusion remained explicit; all nineteen metrics unit checks passed separately.
The planned 37-case profile did not run.
Its [original failure and raw HTTP logs](deployment-envelope-evidence/42116208295/independent-review.json) remain unchanged.
That result supplies no resource-envelope qualification.

## Recorded 37-case preflight

[Run 42118769226](https://github.com/stubbi/asm/actions/runs/42118769226) passed on 5 November 2026, attempt one.
It tested source `2d9e80ad1bec850eaa576dc3a4980f8783d0893f` on native Linux AMD64.
Only the reviewed manual workflow differs from parent `9c53f28a08b2ce13bc5f3b67749577c7014c5b6b`.
Its workflow blob is `1cecf11010d4b2cd6e6803afb945bbbfd648a52c`.
The [manifest](deployment-envelope-evidence/42118769226/manifest.json) binds the exact [profile report](deployment-envelope-evidence/42118769226/profile-qualification.json) and [ordinary report](deployment-envelope-evidence/42118769226/ordinary-qualification.json).

The ordinary gate retained its two-CPU, 512 MiB application limits.
It passed 44 applicable cases plus the existing macOS ACL exclusion.
The profile passed 37 cases without skips; its nineteen named metrics unit checks remain separate.
The hostile `HOME` and `PGPASSFILE` exact-error assertion passed in both HTTP baselines.
Metrics-tool and NULL-connection-fixture hashes matched the original and derived qualification images.

| Profile module | Cases | Boundary samples | Peak memory, bytes | Final current memory, bytes |
| --- | --- | --- | --- | --- |
| Baseline | 22 | 46 | 47058944 | 29175808 |
| Admission | 12 | 26 | 58105856 | 30171136 |
| Envelope | 3 | 8 | 136638464 | 58494976 |

All 80 samples reported the fixed CPU quota, 268435456-byte memory limit, and zero swap.
OOM counters remained zero, and all three application containers exited with code zero.
The envelope module recorded one CPU throttle event and 95476 microseconds of throttling.
The baseline and admission modules recorded no throttle increase during their sampled intervals.
Raw CPU counters and memory events remain in the profile report.
These measurements include qualification drivers and test tools with the runtime; they do not isolate application cost.

Eight 4 MiB JSON and eight 1 MiB TSV slow responses completed with exact bytes.
All eight incomplete-header connections closed after inactivity.
The owned admission log contained exactly nine SQL cancellation messages.
Their HTTP refusals took 1.0495–1.0503 seconds, within the unchanged 0.7–1.8 second assertions.
The observed in-flight SIGTERM request ended with `RemoteDisconnected`.
The process met the three-second exit assertion, but this does not establish graceful drain.

Raw valid-request availability failures remain 104 of 261 baseline requests, 248 of 566 admission requests, and nine of 39 envelope requests.
They include deliberate fault responses, startup refusals, and the in-flight reset.
The report also retains eight malformed incomplete-header closures separately.
These fixed fault workloads do not estimate production availability.
They do not require health to remain available when all sixteen HTTP connections are occupied.

The profile used three fresh PostgreSQL system identifiers and a fresh preparation nonce.
All 71 profile containers and its private preparation were removed.
The ordinary gate separately removed 41 containers and its preparation.
No state, database-log, or cleanup failure was reported.

The original ZIP remains private; duplicate ZIP and build logs are omitted here.
Artifact `13458375291` contains 238463 bytes.
Its SHA-256 is `c4777772d0d3464504bde6268c0d3b49709b248ba1efbb49c15035dae7794229`.
The manifest retains the collection-query failure and correction; the native result and original bytes were unchanged.
This documentation revision and future builds differ from the tested source and recorded images.

## Limits and sources

This profile does not qualify Kubernetes scheduling, ephemeral-storage accounting, multiple replicas, failover, backup, restore, or public traffic.
The recorded baseline includes the six metrics cases and nineteen separate unit checks.
Observed alert delivery remains a separate gate.
Startup integration retains its separate gate.
Bounded SIGTERM exit does not establish graceful response draining.
Resource observations apply only to the recorded images, host, and fixed workloads.

The interface references were checked on 5 November 2026:

- [Linux cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html) defines the recorded counters.
- [Docker resource limits](https://docs.docker.com/engine/containers/resource_constraints/) defines CPU quotas and equal memory/swap limits.
- [PostgreSQL 18 logging](https://www.postgresql.org/docs/18/runtime-config-logging.html) defines the test-only logging collector.
