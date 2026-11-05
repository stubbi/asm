# Fixed deployment envelope

Status: unexecuted native qualification candidate, 5 November 2026.

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
No native profile result exists yet.

## Limits and sources

This profile does not qualify Kubernetes scheduling, ephemeral-storage accounting, multiple replicas, failover, backup, restore, or public traffic.
Metrics and startup integration retain their separate gates.
Bounded SIGTERM exit does not establish graceful response draining.
Resource observations apply only to the recorded images, host, and fixed workloads.

The interface references were checked on 5 November 2026:

- [Linux cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html) defines the recorded counters.
- [Docker resource limits](https://docs.docker.com/engine/containers/resource_constraints/) defines CPU quotas and equal memory/swap limits.
- [PostgreSQL 18 logging](https://www.postgresql.org/docs/18/runtime-config-logging.html) defines the test-only logging collector.
