# Project Publication and V2 Statistics Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Publish committed projects through the native CLI and observe attributed V2 transfers without another service.

**Architecture:** Assembly constructs bounded source archives and canonical V2 manifests, then reuses existing publication tasks. Static downloads carry public selection identifiers. Private asynchronous log imports reuse the bounded ledger and emit registry-scoped statistics.

**Tech Stack:** Assembly, fixed Git/gzip tools, existing TUF adapter, PostgreSQL authority, static nginx/S3 delivery, existing Python operator tools and SQLite.

**Spec:** [V2 project publication and observation contracts](../../specs/registry-v2.md#native-project-publication).

## Global constraints

- Preserve released V1 behavior and the prepared V2 publication mode.
- Keep package logic and archive construction in assembly.
- Keep credentials outside Git, builds, archives, arguments, URLs, and logs.
- Do not build or execute package code during publication.
- Retain explicit tuples, immutable bytes, all current limits, unknown counts, and reporting gaps.
- No production deployment, trust provisioning, new service, or provider credential changes.

## Review focus

- Missing promised Git objects cannot start a remote, hook, or credential helper.
- Dirty files and ignored caches cannot enter the committed snapshot; known sensitive filenames must be refused.
- Same-digest downloads cannot credit another release or registry.
- Malformed query strings cannot leak through logs or poison shared blob caching.
- Interrupted publication, replayed logs, and uncertain writes preserve prior files and counts.

### Task 1: Native project preparation and selection tags

**Files:** New `cli/registry_project.s`, hooks in `cli/registry_v2.s` and `cli/publish.s`, existing native tests.

**Interface:** Mutually exclusive `--project DIR` and prepared-manifest inputs; explicit metadata, commit/subtree, source tuples, and executable files.

- [x] Observe real-TLS failures for absent project mode and selection tags.
- [x] Add bounded committed-object reads, native USTAR writing, deterministic gzip and canonical manifest construction.
- [x] Finish all preparation before credential reads; retain common POST/receipt/upload/task handling.
- [x] Test dirty exclusion, SHA-1/SHA-256, subtree selection, hostile Git, path and byte bounds, dependencies, replay, and prepared mode.

### Task 2: ARM adaptation

**Files:** `cli/aarch64/registry_project.s`, ARM hooks, macOS transforms, shared native tests.

**Interface:** Same manifest, archive, subprocess, and URL contracts as Task 1.

- [x] Port the frozen routines with explicit register, descriptor, stack, and buffer contracts.
- [x] Test Linux ARM and macOS ARM, including deliberate execution only after installation.
- [x] Preserve feature-off behavior and run the required CLI gate.

### Task 3: Attributed private observations

**Files:** `tools/registry_log_import.py`, `tests/test_registry_v2_stats.py`, static nginx references and existing origin tests.

**Interface:** `LogStore.from_distribution(state, store, registry_id, sources=...)`; schema-2 identity-scoped snapshot; normalized eight-field log events.

- [x] Observe failures for absent V2 mapping, identity pins, and normalized nginx selection logs.
- [x] Reuse the ledger, deduplication, limits, counting rule, and private filesystem boundary.
- [x] Add exact metadata mapping and registry/release pins without fake V1 records or blob reads.
- [x] Test shared digests, unknown/zero, reporting gaps, replay conflicts, immutable bindings, and malformed queries.
- [x] Exercise real nginx GET/HEAD/range/interruption/privacy and import its actual logs.

### Task 4: Full user flow and evidence

**Files:** `tests/publisher/test_full_flow.py`, Makefile/CI if needed, hosting and status documents, dated evidence.

- [x] Publish from a real committed fixture project through the actual assembly API and PostgreSQL authority.
- [x] Check, sign, synchronize a second mirror, install, and deliberately execute the selected bytes.
- [x] Import normalized download logs and inspect package/release counts; replay without double counting.
- [x] Exercise corrupt bytes, network failure, existing destinations, revoked credentials, lifecycle changes, and task replay.
- [x] Run the affected CLI, verifier, registry, storage, nginx, and site gates.
- [x] Review the final diff, source boundaries, operator instructions, and exact tested artifact identities.

The user authorized implementation in this chat. Routine contract choices are the implementer's calls, not separate user approvals.

## Completion evidence

The [dated evidence record](../../project-publication-evidence.md) records exact artifacts, negative results, gate counts, and remaining limits.
Native tests cover Linux x86-64, Linux ARM, macOS ARM, and Intel macOS under Rosetta.
The full flow uses the assembly API, PostgreSQL, real nginx TLS, native installation, deliberate execution, and actual log import.
The unchanged verifier and signer bytes retain their earlier qualification; this extension adds no Go source or trust-profile change.
No release, production deployment, source-host integration, or complete website V2 catalog is claimed.
