# V2 dependency evidence

Status: local unreleased source qualification, 8 November 2026.
The affected native, publisher, database, infrastructure, verifier, and website gates passed locally.
No public deployment, production key, or release is activated.

## Outcome and boundary

The optional V2 client resolves mandatory source dependencies in assembly.
It records every root, selected node, dependency edge, immutable identity, and artifact binding in `asm.lock`.
Explicit sync authenticates exact selections and restores source packages without selecting newer versions.
Build checks use the local complete graph and checked source cache.
They do not refresh registry policy or establish current remote authentication.

This follows dependable reuse, user control, evidence, and resource care.
Static storage and HTTPS mirrors supply the existing signed metadata and artifacts.
No resolver service, new database, or source-host identity is required.
Private operations and test tooling use suitable other languages.
The native package and resolver logic does not delegate to them.

The [contract](specs/registry-v2.md) and [workflow](hosting.md#resolve-and-restore-v2-dependencies) describe supported inputs.
The [implementation plan](superpowers/plans/2026-11-08-v2-dependencies.md) records scope and material trade-offs.

## Deliberate limits

- One selected version per package, one registry, and one explicit target per V2 graph lock.
- Mandatory source dependencies only; no features, optional dependencies, hooks, prereleases, or parallel versions.
- Canonical full numeric versions, exact ranges, wildcard, caret, tilde, and at most eight comparator terms.
- At most 256 reached candidate versions and 64 root requirements or dependencies per release.
- Deterministic chronological backtracking, with a 100,000-operation search limit.
- Eager metadata discovery can read unused candidates and fail when their metadata is unavailable.
- Resolve can update permitted versions. Sync and build cannot update selections.
- Source imports remain explicit. A consistent graph cycle does not cause automatic source inclusion or execution.
- The released V1 direct-dependency and multi-target lock paths remain separate.

The solver is not PubGrub.
It enumerates the usable versions of each unresolved reachable package and rechecks active constraints after each assignment.
A visited queue terminates cycles within each branch.
Its finite search is complete only when the supplied supported graph fits the bounds and the search budget is not exhausted.
Tests do not prove general solver correctness or the truth of declared ABI compatibility.

The implementation learns from uv's separation of solving, locked synchronization, static metadata, and package-source identity.
The [uv resolver source](https://github.com/astral-sh/uv/blob/3e2f08f8e75624ec942f864cd56b816885b80b7c/docs/reference/internals/resolver.md) was reviewed on 8 November 2026.
Asm does not copy uv's universal Python environment model or claim its measured performance.

## Retained checks

| Gate | Observed result |
| --- | --- |
| `make test`, Apple Silicon macOS | 270 tests passed, 190.813 seconds |
| `make verifier-test` | Both Go packages passed with the race detector |
| Final `make registry-v2-test`, Apple Silicon macOS | 19 distribution-tool tests and 90 native tests passed; native suite 94.060 seconds |
| Native solver standalone | 11 methods passed on ARM64 and x86-64 through Rosetta |
| Final Linux ARM64 native V2 | 90 methods, 89 passed and one filesystem skip; 92.045 seconds |
| V1 dependency contract through the optional V2 binary | 20 unchanged tests passed on the final binary, 2.772 seconds |
| Independent oracle | 96 fixed-seed generated graphs, plus literal range, cycle, diamond, ordering, and limit cases |
| Signed graph integration | 26 HTTPS cases included in each native V2 gate |
| Final `make site-test` | 109 Node and 343 Python tests passed; Python suite 108.887 seconds |
| Publisher and distribution authority | 20 and 13 PostgreSQL tests passed; 74.546 and 62.269 seconds |
| Infrastructure gate, Linux x86-64 through Rosetta | 95 methods with four macOS skips, then 98 registry tests and 29 publisher-tool methods with two macOS skips |
| Skipped macOS checks on their native host | Four ACL tests and all 29 publisher-tool tests passed, with no skips |
| Final assembly publisher full flow | Three methods passed, 99.508 seconds |
| Final `make registry-v2-test`, Linux x86-64 through Rosetta | 19 distribution-tool tests; 89 native methods, 88 passed and one filesystem skip; native suite 197.893 seconds |
| Publisher HTTP runtime | 16 methods passed, 99.375 seconds |

The signed integration uses real TUF verification, explicit roots, persistent trust state, and HTTPS mirrors.
It checks complete canonical locks, exact restoration, cached restoration without artifact transfers, and actual transitive source use.
The installed consumer is executed deliberately after successful build.
Failures cover malformed ranges, missing or corrupt metadata, network loss, incompatible targets, inconsistent source declarations, stale roots, changed locks, corrupt artifacts, lifecycle changes, and existing-file preservation.
Four additional cases check altered signed releases, package identity rebinding, inconsistent inventory identities, and a valid same-identity upgrade.
Resolve is checked for no artifact transfer or package execution.

The new authority flow publishes leaf versions 1.0.0 and 2.0.0 and a middle package requiring `^1.0.0`.
Its consumer resolves two packages, synchronizes their exact sources, builds, and deliberately executes the consumer.
It refuses corrupt transitive bytes, incompatible root requirements, and a revoked leaf release.
It retains the prior lock and existing executable on failure.
The earlier signed installation, mirror, website, and download-observation methods also pass in the same gate.

The final synthetic dependency consumer SHA-256 was `e671dff7e3c722235d7efc7f6e643ec7a04d26797263ed4c72b126b5f7dfe48b`.
Its complete lock SHA-256 was `05e33ece62805ab30bd2e916f44c31197a4cbc2a9193f36c813c60ac63cc956f`.
These identify the local fixture, not a published package or user installation.

## Initial failures and corrections

The first diamond test failed because the native resolve command did not exist.
The initial graph suite retained that missing-feature failure.
A reversed maximum-length solver chain exceeded the budget because propagation repeatedly scanned unchanged selections.
A bounded visited queue corrected that work without changing the search limit.

The first complete graph run exposed a cached-sync failure.
The legacy payload verifier expected a temporary path already occupied by signed policy metadata.
The graph cache now hashes the copied private payload directly and retains exact digest checking.
Its warm-sync regression checks that no artifact GET occurs.
Network failures now use the graph metadata error instead of an unrelated exact-install policy message.

The new consumer-build test initially expected `build/consumer`.
The documented native output is `build/app`.
Correcting that fixture retained actual execution and file-preservation assertions.

Independent review found website source validation accepted a consumer lock refused by publication and native use.
A failing regression reproduced the mismatch.
The shared V2 source validator now rejects `asm.lock`; the checker no longer duplicates that guard.
Fifteen projection tests and eleven checker tests passed after the correction.

The final client review found explicit resolve could replace a locked version after a validly signed metadata change.
The service already prevents ordinary immutable-release replacement; the client needed its own retained-history check.
New failing regressions reproduced altered bytes, package identity rebinding, and inconsistent initial inventory identities.
Both assembly implementations now reject those changes and preserve the prior lock.
An unchanged package identity can still select a newly published compatible version.
These pins belong to the retained project lock; they do not survive its removal.

Two host infrastructure attempts stopped at the unchanged `boto3` prerequisite.
The normal host Python and an unrelated existing virtual environment lacked it.
Those attempts ran no infrastructure assertions and are not passing evidence.
The owned Linux fixture supplies the complete infrastructure prerequisites for the remaining gate.

The first Linux infrastructure run lacked Git metadata and failed one release-history assertion.
Importing a bundle of the repository's actual history corrected the fixture.
No synthetic source commit replaced that history.
The final complete infrastructure gate passed with its platform skips recorded above.

A slow image export from the older QEMU guest was cancelled.
That guest reported 479 MiB free; no existing images or files were deleted.
The replacement fixture used PostgreSQL 16.15 through Rosetta in the existing ARM VZ guest.
The first package-install attempt refused mismatched libpq header and runtime selections.
Pinning both packages to 16.15 satisfied the unchanged ABI gate.
The fixture used the explicit OpenSSL 3.0.22 fixture profile and GNU libmicrohttpd 1.0.3.
No ABI assertion or initialization deadline was weakened.

## Artifacts and remaining activation gates

| Qualified artifact | SHA-256 |
| --- | --- |
| Final Apple Silicon macOS V2 client | `63c5af2be1a6c3e2d2d9a2ffb327f08aff40e6892a3bcbec3a5699c6995cbb61` |
| Final Linux ARM64 V2 client | `f865367a78935826510dafb68bc4053b87c27598154305732e62af069ee1ee1e` |
| Final Linux x86-64 V2 client | `54a3ed9f6cdf33b5dbb006827045ee87f25b4577fbe0e9521c119aa0026fe4d9` |
| Linux x86-64 publisher, HTTP and final full-flow artifact | `afbdf4fd2e46c408118f1a38f4d7c5ca4c3b71e23a4b3ba8eed197fbc7f47059` |
| Linux x86-64 bundled verifier | `e4b5ce10f0bf2497dc039c1a316416b5ba62d1a6beb267225653a89411aded4c` |
| Linux x86-64 fixture signer | `501787c8984a8ff58b8f8d27018b40100d603e13aeee36b0b062c19b1a5ae1a7` |

The x86-64 fixture copied 544 source and helper files without host mounts or AppleDouble files.
Its inventory SHA-256 was `d9445a65022d29cf6216c9dc190aea10adaa1a5a758b3f2193ddb69d9b5a88ab`.
The actual history bundle SHA-256 was `8b81f631bbb9244e22fbe724443eeb31900dace7bdd803fff00d364708d3dddd`.
After the client immutability correction, 292 runtime and test inputs were checked against the final copied source with no mismatches.
That final inventory SHA-256 was `b8fdba37a562e0061ddabad185b052f4e56ac7b8254c06f39e9dc24b51293a4e`.
The working tree contained unpublished changes over base commit `d958e0282b2b70639a2f490cd149a174907ef3fc`.
That base alone does not identify the qualified source; the copied inventory binds the modified inputs.
The PostgreSQL image digest was `sha256:5264710be20f409750ac6dc4e5706dcef929c87e241605463f0f9aefa932a8d9`.
The GNU source archive SHA-256 was `7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a`.
Its built libmicrohttpd SHA-256 was `91bb2ba1808dc117b68a07a2369d5a8ad2759943519254f54d0c12f7632de475`.
The library used HTTP in the loopback fixture; nginx supplied actual TLS delivery.
This is the retained fixture profile, not a production OpenSSL recommendation.

The ARM64 gate used a private container with one CPU, 768 MiB, no network, and no host mounts.
Its final source inventory SHA-256 was `8e7968f64f4e3f0d1311031099e977a8ea3dfe46d4c9eb8bea75e26465e8249a`.
Its single skip requires a case-insensitive filesystem alias; the macOS gate exercises that test.
The ARM image and virtual-machine resource settings remained unchanged.

The default macOS CLI SHA-256 remained `bbb51a682e3cdd0d17317b28246a297f079450b05875c61288cc54cdb73fb3ea` after the last optional-V2 correction.
The 270-test default gate therefore covers the same executable bytes.
The earlier successful full flow used client `f8476bcc4da83be75e786f01a4adf52f869bf3ffc4f6dc13a329e188ecf91487` and publisher `0775df78cb8978dacd2526d55127c07a9978ad1df26b49aa654829541e4cb970`.
The publisher was rebuilt for its HTTP gate; final qualification uses the artifacts in the table above.
This local checkpoint does not establish reproducible publisher builds.

Raw gate logs, source inventories, and qualified Linux binaries remain under `/tmp/asm-v2-deps-*` and `/tmp/asm-v2-bindings-*`.
Task containers, copied archives, fixture-only dependencies, and newly pulled images are removed after qualification.
Owned virtual machines return to their original stopped state; the user's default virtual machine remains running.

No source changes are represented as published 0.6.0 behavior.
This work does not qualify global resolution workloads, production costs, deployed mirrors, key custody, recovery, or public ingress.
The flat signed inventory and existing role limits remain in force.
