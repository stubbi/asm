# Fixed deployment envelope

Status: failed native preflight; the parser correction awaits qualification, 5 November 2026.

This profile tests the selected PostgreSQL 18 database with one fixed application resource envelope.
It serves operators who need inspectable resource and failure evidence before deployment.
The [implementation plan](deployment-envelope-plan.md) records its scope and governing principles.

| Component | CPU quota | Memory | Swap | Private temporary filesystem |
| --- | --- | --- | --- | --- |
| Application qualifier | 1 CPU | 256 MiB | None | 64 MiB |
| PostgreSQL fixture | 2 CPU | 2 GiB | Existing fixture policy | 512 MiB |

The Python driver and assembly runtime share the application cgroup.
A cgroup is the Linux mechanism that applies these resource limits to related processes.
This conservative fixture scope is not an application-only capacity measurement.
The temporary filesystem budget does not emulate Kubernetes ephemeral-storage accounting.
The ordinary PostgreSQL 18 gate remains at 2 CPU and 512 MiB for applications.

## Fixed checks

The profile selects three modules in separate application containers with fresh owned PostgreSQL clusters:

1. Run all sixteen canonical HTTP baseline cases.
2. Run all twelve admission cases with the explicitly selected PostgreSQL 18 provider and fixed NULL-connection fixture.
3. Run three envelope cases for eight maximum-size slow readers, eight incomplete headers, and in-flight SIGTERM.

The ordinary admission module remains twelve cases.
Its 180-second image watchdog and other architectures remain separate from this native AMD64 profile.
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
No successful 31-case profile result exists yet.

## First native preflight

[Run 42111348191](https://github.com/stubbi/asm/actions/runs/42111348191) tested source `7b0e18b2aedf5054b9a0b1cc49d847cdd6a1681e` once.
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
The parser correction has no native result.

The original artifact ZIP is retained privately outside this repository.
It contains 183132 bytes.
Its SHA-256 is `d89f3b633f6a2fbf2673bf25d216dcda05832d12b41de2faacea6c5d6ee83311`.
This digest matches the [GitHub artifact metadata](deployment-envelope-evidence/42111348191/artifacts.json).
The [independent inspection](deployment-envelope-evidence/42111348191/independent-review.json) records the exact image identities and observed coverage.

## Limits and sources

This profile does not qualify Kubernetes scheduling, ephemeral-storage accounting, multiple replicas, failover, backup, restore, or public traffic.
Metrics and startup integration retain their separate gates.
Bounded SIGTERM exit does not establish graceful response draining.
Resource observations apply only to the recorded images, host, and fixed workloads.

The interface references were checked on 5 November 2026:

- [Linux cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html) defines the recorded counters.
- [Docker resource limits](https://docs.docker.com/engine/containers/resource_constraints/) defines CPU quotas and equal memory/swap limits.
- [PostgreSQL 18 logging](https://www.postgresql.org/docs/18/runtime-config-logging.html) defines the test-only logging collector.
