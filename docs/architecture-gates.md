# Architecture gaps and acceptance gates

**Status: proposed gates with local source evidence, 8 November 2026.**

This table accompanies the [global distribution architecture](architecture.md).
It is not a claim that the proposed platform exists.
The deployed public alpha is the static Pages site and generated v1 registry.
Rows labeled "reference" describe a local, unpublished Rust server experiment.
Its PostgreSQL tests cover functional contracts, not public service availability or the proposed global workload.
The [published assembly source experiment](../experiments/assembly-server/README.md) has narrower local HTTP and database coverage.

| Boundary | Current evidence or gap | Required acceptance result |
| --- | --- | --- |
| Application language | Public CLI and published local source experiment use assembly; Rust reference remains unpublished | Assembly server passes reviewed domain, database, HTTP, deadline, and failure assertions |
| Discovery query | Public browser filters a JSON catalog; reference scans authoritative package data | Indexed projection meets relevance, query-plan, latency, and isolation targets under a declared workload |
| Search pagination | Reference keyset cursor does not freeze concurrent updates | Qualified snapshots have aggregate retention and creation limits; expiry and generation changes never silently mix views |
| Search eligibility | Reference supports a target filter and per-version licenses | Target, license, and evidence facets match the same release and applicable artifact |
| Replay and rebuild | Local publisher has a transactional outbox and fenced acknowledgments; no production projection lifecycle | Consistent source revisions, tombstones, and replay converge; conflicting equal revisions fail; rebuild preserves active queries |
| Event positions | Local SQL tests retain late allocated events after newer acknowledgments; no production consumer qualification | Early sequence allocation and late commit cannot skip an event; acknowledgments survive worker failure |
| Installation metadata | Released V1 uses a bounded whole catalog; opt-in V2 retrieves authenticated exact release and policy targets | Exact installs retrieve bounded authenticated package data without search or a full catalog |
| Metadata trust | Released alpha uses HTTPS; opt-in V2 has registry/root-bound TUF, rollback, expiry, rotation, and mixed-role regressions | Reviewed TUF profile rejects invalid signatures, rollback, expiry, cross-registry confusion, and mixed snapshots |
| Trust scaling | No measured delegation or snapshot profile | Cold and warm dependency tests establish bounded trust requests, bytes, validation time, and rotation behavior |
| Artifact storage | GitHub alpha assets plus conditional filesystem/S3 operator stores; 64 MiB object limit | Verified conditional creation, immutable digest keys, resumable transfers, retention, and recovery on the selected storage |
| Mirrors and CDN | Conditional byte-mirror tools and native V2 failover tests pass locally; public CDN and provider access rules remain unqualified | Corrupt and stale mirrors fail verification; healthy alternatives work without changing package authority |
| Publication | Unreleased assembly API, native publishing, fenced checks, and signed distribution pass local full-flow tests | Authenticated durable tasks, final authorization checks, fencing, idempotency, and recoverable distribution steps |
| Distribution heads | Local private distributor seals exact bundles, checks policy/leases, and conditionally advances public heads; cross-system writes are not atomic | Fenced conditional advancement preserves monotonic revisions and critical policy despite reversed worker completion |
| Discovery availability | Local task responses distinguish committed, distributing, and published; completion emits a revisioned event; discovery projection remains incomplete | Only distributed `published` releases appear as installable; that transition emits its own revisioned event |
| Publisher identity | Direct credentials use opaque owner identities; private enrollment remains an operator assertion | Verified enrollment and scoped publisher policies resist rename, transfer, expiry, and replay mistakes |
| Version immutability | Canonical V1 records and local V2 intents are immutable; local concurrency and retry checks pass | Preserve those invariants through upload retries, concurrent publication, failover, and administrative recovery |
| Lifecycle policy | Audited yank/unyank and irreversible revocation; five-minute signed policy, checked again after transfer; deployed delivery remains unqualified | Separate audited lifecycle operations; critical policy bypasses search lag and ordinary worker backlog |
| Evidence | Public registry marks unperformed checks as `not-run` | Every displayed result identifies check scope, artifact, target, policy, and checker; no aggregate LLM safety claim |
| Download observations | Local V2 ledger, asynchronous private origin-log import, and explicit static website projection; no qualified edge pipeline | Counters declare event type, coverage, deduplication, and delay; absent mirror reports do not imply zero downloads |
| Browser fallback | No qualified server-rendered search and publication flow | Search, pages, forms, and task recovery work with optional JavaScript disabled; HTMX preserves the same actions |
| Public API | Three assembly V2 routes and opt-in native client have local HTTPS full-flow evidence; no public deployment | Versioned machine-checked schemas, limits, error behavior, compatibility tests, and documented deprecation rules |
| Failure isolation | Reference has local HTTP and database bounds | Discovery saturation cannot consume publication reserves or block authenticated exact installs |
| Regions and recovery | No deployment capacity, cost, or regional recovery qualification | Named fault model, fencing, tested restore, trust-state recovery, and budgeted capacity before traffic expansion |
| Operations | Fixed metrics and redacted logs in the reference | Capacity rejection counts against availability; bounded metrics report lag, recovery, cache, and cost separately |

The [V2 evidence record](registry-v2-evidence.md) gives exact artifacts, checks, failures, and remaining gates.
The [project publication extension](project-publication-evidence.md) adds native archives and identity-scoped V2 origin observations.
The [website extension](v2-website-evidence.md) records the explicit V2 static build and its qualification limits.
The flat V2 profile has bounded roles and 4,095 releases; it does not meet the proposed global workload by assertion.
Production custody, provider semantics, ingress, spending, isolation, and restoration need deployment evidence.

## Evidence-based scale decisions

Catalog size is a test dimension, not an automatic architecture switch.
Apply these gates to the declared workload and operating budget.

| Decision | Evidence that requires action | Next bounded change |
| --- | --- | --- |
| Separate search capacity | Search violates latency or resource targets, or affects authoritative operations | Dedicated projection capacity and admission control |
| Change the search engine | The indexed baseline fails required relevance, snapshots, facets, or cost targets after measured tuning | Compare one mature alternative through the same backend contract and corpus |
| Add change-data capture | Polling cost or replay lag violates its budget under publication load | Qualify a documented snapshot and commit-position handoff |
| Partition trust metadata | Root, snapshot, delegation, or package-page work exceeds client budgets | Revise the authenticated partition profile and test rotation before rollout |
| Add regional search | Measured user latency or regional availability fails its objective | Another rebuildable regional projection with explicit freshness reporting |
| Add write partitions | A measured write or recovery constraint remains after simpler changes | Specify authority routing, fencing, transfer, and conflict rules before adding writers |
| Raise artifact limits | A real package class needs larger files | Streaming validation, storage, transfer, extraction, and quota tests for that class |

## First deliverables

The next complete change should include contracts, implementation, and their acceptance evidence.
Do not count a schema or benchmark harness as a passed gate.

1. Publish draft resource and manifest schemas with exact identity, target, and lifecycle semantics.
2. Preserve the reference's immutable-version and reader-permission regressions in the assembly server suite.
3. Implement transactional outbox delivery and its late-commit, duplicate, and crash tests.
4. Build a derived search document with correct per-version facets and a versioned relevance corpus.
5. Record query plans and load distributions before selecting the production search backend.
6. Qualify the signed-metadata and artifact path with the native client before replacing v1 installation.

Deployment remains separate from these code changes.
Traffic, spending, custody, and durability choices need verified operational inputs.
No capacity or performance result is implied by this proposal.
