# V2 dependency graphs

Status: implemented and locally qualified, 8 November 2026.

## Required result

A consumer can resolve mandatory source dependencies from authenticated V2 metadata, retain the complete graph, and restore exact source packages.
Application and package logic remain in assembly on Linux x86-64, Linux ARM64, and Apple Silicon macOS.
Static mirrors need no resolver process or additional database.
This serves repeatable reuse and understandable failures while respecting hosting and maintenance resources.

The user authorized implementation after reviewing the resolver audit and uv lessons.
This plan uses that authorization and the existing isolated worktree.
Existing unpublished changes remain in place.

## Contract

- Reuse the signed policy inventory and immutable release envelopes.
- Add optional sorted `dependencies: [{name, requirement}]` to publication metadata. Absent means empty.
- Accept a bounded `[dependencies]` table with quoted package names and requirements in `asm.toml`.
- Support mandatory dependencies from one registry, numeric versions, exact requirements, `*`, caret, tilde, and comparator intersections.
- Use a canonical V2 requirement syntax without whitespace. Limit requirements to 128 bytes and eight comparators.
- Select one version per package for one explicit target. Record consistent cycles without executing imports.
- Retain the released V1 multi-target behavior. Refuse automatic conversion or replacement of a legacy lock.
- Give the optional V2 graph lock one explicit target. Refuse replacement under another target or authority.
- Keep optional dependencies, features, parallel versions, universal target solving, and build hooks unsupported.
- Resolve explicitly. Sync and build must never select newer versions.
- Enumerate at most 256 reached candidate versions and 64 direct requirements per release.
- Use deterministic bounded backtracking, with a 100,000-step search limit. This is not a PubGrub implementation.
- Distinguish unsatisfiable constraints, malformed or unavailable metadata, and exhausted resource limits.

`asm registry resolve --project DIR --target TARGET` takes the existing explicit registry ID, root, state, mirrors, and optional CA options.
It authenticates metadata and atomically writes `asm.lock`, without artifact downloads.
`asm registry sync` takes the same inputs and restores only the complete locked graph.
Build checks validate the local graph and cached source bytes. They do not refresh remote lifecycle policy.
Sync authenticates exact envelopes and refreshes policy for every selected node before and after materialization.

## Lock format

All rows use ASCII, single tabs, and one final LF. Names and edges use byte order.

```text
# asm-lock-v3
registry ID INITIAL_ROOT_SHA256 TARGET ROOT_ASM_TOML_SHA256
root NAME REQUIREMENT
node NAME VERSION PACKAGE_ID RELEASE_ID ENVELOPE_SHA256 MANIFEST_SHA256 SOURCE_COMMIT_DIGEST SOURCE_BYTES SOURCE_SHA256
edge PARENT_NAME CHILD_NAME REQUIREMENT
```

The examples show field order; actual separators are tabs.
Roots precede nodes. Nodes precede edges.
Mirrors are invocation inputs, not package authorities.
Sync reconstructs this canonical graph from authenticated exact metadata and compares every byte before cache changes.
Build checks root freshness, graph closure, ranges, reachability, and source declarations against the retained graph.
The local lock remains a project-controlled input; a local build alone does not establish current registry authentication.

## Tasks and interfaces

1. Extend publication validation and preparation in both assembly architectures, SQL, and private checking tools.
   Expose `g3_project_dependencies`, `g3_project_deps` (64 records of 240 bytes), and `g3_project_dep_count`.
   Each record contains name[105] at offset 0 and requirement[129] at offset 105.
   Extend V2 manifest parsing with the same `r2_dependencies` and `r2_dependency_count` layout.
   Test valid publication, source/metadata mismatch, malformed ranges, and unsupported declarations before credentials.
2. Implement the native solver and range evaluator in `cli/registry_solver.s` and its ARM equivalent.
   `g3_requirement(requirement, version)` returns match 1, mismatch 0, or malformed -1.
   `g3_solve` consumes candidate records (name pointer, version pointer, dependency pointer/count, usable flag) and root pairs.
   It returns solution 0, unsatisfiable 1, exhausted 2, or malformed 3, and writes selected candidate flags.
   Test an independent exhaustive oracle, diamonds, cycles, numeric ordering, invalid syntax, and budget exhaustion.
3. Implement native metadata loading, command dispatch, canonical graph locks, exact sync, and local build checking.
   Reuse existing transport, TUF verification, archive validation, checked cache paths, and project operation locks.
   Authenticate every envelope against the inventory identities. Retain existing files on failure.
4. Test the real native workflow through HTTPS, then the assembly publisher and PostgreSQL authority.
   Test no artifact transfer during resolve, exact restoration, actual source use, stale locks, corruption, unavailable metadata, lifecycle changes, and mirrors.
5. Review contracts, source changes, security effects, and evidence. Update source-profile documentation without changing published release claims.

## Verification

Run focused tests first and retain their initial missing-feature failures.
Then run `make test`, `make verifier-test`, `make registry-v2-test`, registry and publisher-tool tests, and the authority/full-flow gates.
Run site checks because publication metadata enters website projections.
Build both native assembly implementations and record qualified executable digests.
No public deployment or release is part of this task.

## Review focus

- Incomplete graph locks, orphan nodes, omitted edges, and source/metadata disagreement.
- Incorrect caret bounds at major zero, numeric version order, and false unsatisfiability from greedy choices.
- Trust-state resets, authority changes across mirrors, and lifecycle refresh covering only the last dependency.
- Partial filesystem effects, changed existing destinations, stale root manifests, and resource exhaustion.
- Default V1 behavior and architecture parity.

## Execution record

- Reconnaissance confirmed no existing transitive resolver and no dependency-bearing V2 publication support.
- Ruling: a single-target V2 graph lock keeps the initial graph contract bounded; released V1 multi-target locks remain unchanged.
- Ruling: eager bounded metadata discovery favors simpler native state over optimized lazy fetching. It can fetch unused candidate metadata.
- Ruling: chronological backtracking preserves completeness within the declared budget without adding a conflict-learning subsystem initially.
- Review found that explicit resolve could replace a locked release after a validly signed metadata change.
  Native checks now retain package identities across versions and every node binding for an unchanged version.
  Inconsistent package identities in one signed inventory also fail, including inactive releases.
  Four regressions cover those refusals and a valid same-identity upgrade.
  Retained project locks supply these pins; discarding a lock discards that history.

Further checks and deviations are recorded in the dependency evidence document.
