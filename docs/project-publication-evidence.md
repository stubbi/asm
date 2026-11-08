# Native project publication and V2 observations

Date: 8 November 2026. Unreleased local source checks, not deployment or release qualification.

This extension follows the [prepared-input V2 checkpoint](registry-v2-evidence.md).
The [subsequent website extension](v2-website-evidence.md) connects these releases and observations to an explicit static build.
The worktree starts at `d958e0282b2b70639a2f490cd149a174907ef3fc` and includes uncommitted source changes.
The [V2 contract](specs/registry-v2.md#native-project-publication) and [hosting guide](hosting.md) define the new commands and their limits.
No production key, provider account, public endpoint, DNS record, cluster resource, or released package was changed.

The outcome is publication from committed projects and attributed observations without another service or duplicated artifact storage.
This follows dependable reuse, resource care, control, and evidence principles.
Assembly owns archive construction, canonical manifest generation, package checks, selection tags, and the native publication workflow.
Fixed Git reads object data; fixed gzip compresses native USTAR output.
Private log processing reuses the existing bounded SQLite ledger.

## Environment and artifact identities

The host was Apple Silicon macOS 15.6.1 with Python 3.14.6.
Intel macOS checks used Rosetta; they do not qualify Intel hardware or add an Intel macOS package tuple.
Linux ARM ran native instructions in Colima; Linux x86-64 ran through AMD64 emulation on that host.
Git was 2.39.5 in the qualified native environments.
The PostgreSQL authority fixture retained PostgreSQL/libpq 16.15, libmicrohttpd 1.0.3, and the reviewed OpenSSL 3.5.9 publisher.
No performance or capacity claim follows from test durations.

The native builds reused the exact previously qualified embedded TUF adapters.
`make -o build/asm-verify-TARGET registry-cli` rebuilt native code while retaining those unchanged adapter bytes.
This is a component qualification path, not a clean release build.
Go sources, trust profiles, signing helpers, SQL migrations, and checker policy were unchanged by this extension.
The earlier evidence record supplies their identities and qualification scope.

| Native artifact | SHA-256 |
| --- | --- |
| Linux x86-64 project client | `298d4e1e5f389aaacf8a7d79818df1de2e1e9d79f44f5bcef999161bc955b308` |
| macOS ARM project client | `d7eae3753f037785143b79c59cbf01816546fb7e0afa6ef88f474b24b6e1e41d` |
| Linux ARM project client | `72d4b39abb8955f7a3721ddbf7237cf578ed040a7bb0b071939faef616e3274c` |
| Intel macOS project client under Rosetta | `1251d2bb6006478a48d01cd890760e415784f6efa69d9ad23f7355714cfadc93` |

The original macOS nginx 1.30.6 executable remained `24e800750f32ed101f8af74fd08e55688777b8c232767aa6a4291d4db61089f5`.
The Linux fixture added official Debian package `nginx 1.22.1-9+deb12u10` for real static TLS and log checks.
Its executable SHA-256 was `62b20544dc6f509184ab550d15658bbc9fd18ca720235fda14eb8ef91e09d595`.
The Linux build used runtime OpenSSL 3.0.22; this fixture is not a production dependency selection.
Project publication requires Git; the prepared-manifest mode does not.
No additional service was added.

## Component checks

| Gate | Observed result | Scope |
| --- | --- | --- |
| Linux x86-64 project and existing V2 suite | 48 methods in 175.581s, one filesystem-specific skip | Exact native source/helper identities; case alias exercised on macOS |
| Actual authority, nginx TLS, and statistics flow | Two methods passed in 87.280s | Native committed-project preparation, actual assembly API/PostgreSQL, checking, signing, second mirror, installation, execution, counts, and failures |
| Intel macOS project and existing V2 suite | 48 methods passed in 62.457s, no skips | Native archive/manifest preparation, HTTPS task handling, TUF selection, and recovery; Rosetta execution |
| macOS ARM feature suite | 49 methods passed in 44.541s, no skips | Same contract plus deliberate ARM fixture execution after project publication and installation |
| Linux ARM feature suite | 49 methods in 56.603s; 48 passed, one filesystem-specific skip | Native ARM code; case-insensitive alias refusal was exercised on macOS |
| Default macOS CLI `make test` | 270 methods passed in 142.492s | Feature-off CLI; byte identity retained |
| Default Linux x86-64 CLI `make test` | 685 methods in 305.631s, 19 documented skips | Feature-off CLI; byte identity retained; optional environments qualified separately |
| Default Linux ARM CLI `make test` | 685 methods in 46.134s, 20 documented skips | Other-platform, root-only, and optional environments remain separate; feature suite qualified above |
| V2 log subset | 13 methods passed | Identity pins, immutable bindings, known/unknown counts, replay, privacy, and actual nginx requests |
| Combined origin-log suite | 38 methods, one Linux-only skip on macOS | V1 compatibility and V2 normalized observations |
| `make registry-infrastructure-test` | 95 methods with one platform skip; 98 registry methods and 26 publisher-tool methods passed | Locked SDK, actual nginx, storage, mirrors, counts, and existing publication operators |
| `make site-test` | 104 Node checks and 310 Python checks passed | Existing site and V1 observation behavior; no public site deployment |
| Workflow validation | `actionlint` passed | Updated CI prerequisites and gates; no remote CI run claimed |
| Independent privacy/recovery closure | Nine native HTTPS methods passed in 7.472s | Supplied-credential aliases, physical source boundary, 8190-byte limit, and post-POST recovery guidance |

The default x86-64 log includes expected failing qualification reports from negative tests; the complete suite passed.

The retained full-flow log is `/tmp/asm-project-full-flow-qualified.log`.
Its SHA-256 is `b723b89c03c3073a767fde66ff91c0e78c76ee19bd096d466c47170a800ad96e`.
The default x86-64 log is `/tmp/asm-project-publication-default-qualified.log`.
Its SHA-256 is `acec39a237d6621bb8ea01a0d2d3f1e0fe3f130f3fe91af0c25bb7fbf3f782bc`.

The final tested full-flow fixture SHA-256 is `11aa58d78cdc4b0574fe9e13afdf5e7e0de5bf9448b81f2d9c3b5f9c4c3954fb`.
The final artifact capture is `/tmp/asm-project-full-flow-final-artifacts.log`.
Its SHA-256 is `89dfba4a71fc6b855bd27214638dfab54bf420df689cfb963a00a6b5be87ab5a`.
It records the actual Linux client, verifier, signer, publisher, nginx, fixture, importer, and served configuration bytes.
The earlier preflight capture preceded the fixture timestamp correction and records that older fixture digest.

## Behaviors exercised

Project tests publish selected committed Git bytes and the committed manifest's version.
Dirty and untracked files do not enter the source archive.
SHA-1 and SHA-256 repositories, explicit subtrees, optional source locators, source targets, and prepared executables have distinct checks.
Repeated publication uses the same prepared bytes and skips received objects.
No build or package entry point runs during publication.

Bounds include complete TAR headers, payload padding, end markers, USTAR path splitting, member count, and object/task bytes.
Missing objects and hostile replacement, promisor, credential-helper, hook, or filter settings cannot start package-controlled commands.
Known sensitive filenames, links, submodules, dependencies, and source-path conflicts fail locally.
Physical file identities refuse the supplied credential as an executable or prepared object before candidate bytes are read.
This does not detect arbitrary secrets committed under ordinary filenames.

Real nginx tests cover root and prefixed mirror bases, exact selection tags, GET, HEAD, ranges, conditional replies, bot/internal classification, and interrupted transfers.
Malformed queries and encoded aliases do not enter the normalized logs.
Unknown or mismatched well-formed tags remain separate noncountable request diagnostics.
They cannot credit another package or block valid observations in the same batch.
Replay and conflicting source/request identities retain their existing transactional behavior.
Missing reporting stays null; observed zero requires a real imported batch.
Counts remain incomplete sender observations with gaps and stale-state metadata.

## Complete user flow

The first case creates a real owned Git project with a committed manifest, source, README, and AGPL license.
It replaces the working source and adds an untracked synthetic secret before native publication.
The actual canonical POST and retained archive match the committed source, not those working files.
The native command publishes through the assembly API and PostgreSQL authority, then private checking and signing complete distribution.
The task's in-flight `distributing` response is observed before signing and completed publication.

The client rejects the first unavailable mirror and installs through real nginx TLS on the second mirror.
It checks exact executable bytes and all seven inventory fields without executing the program.
An exact installation repeat preserves those files without another artifact transfer.
Only a deliberate invocation produces the expected stdout and absolute execution marker.

The importer reads the actual normalized nginx log as an immutable private batch.
The genuine selection contributes one package and release transfer.
A later forged tag receives the same immutable bytes but contributes only one unattributed request.
The second batch contains both log records; replay and request deduplication keep the genuine count at one.
Both imported-batch replays change no counts.
Counts were null before reporting, and the resulting coverage remains incomplete.
The native publish replay likewise reuses its task and sends no redundant object PUTs.

The second case retains prepared-manifest publication and omitted source locators.
Corruption, network failure, yanking, stale metadata, revocation after unyank, and credential revocation preserve existing bytes and inventory.
The API fixture terminates TLS for requests to the assembly service; the second mirror uses nginx TLS directly.
Python supplies test orchestration, not registry application logic.
The structural checker callback is trusted fixture code; the separate Docker isolation scope remains in the baseline evidence.
No external source host was contacted.

## Retained failures and corrections

- The initial native client lacked project mode and the exact V2 selection query; observable command tests first failed.
- The first Intel project candidate reached Git objects, then failed because its platform lacked mmap/munmap adapters.
  Narrow libSystem adapters replaced a proposed large static buffer; ARM uses matching feature-gated adapters.
- Two retained-object calls used the wrong argument cursor; corrected register contracts allowed canonical preparation.
- Project mode initially admitted a legacy manifest above the V2 checker's 8190-byte limit.
  The current preparer refuses that input before credential reads or HTTP.
- Independent review reproduced the supplied credential being uploaded as an executable in an owned synthetic fixture.
  Device/inode checks now refuse executable and prepared-object aliases before candidate reads.
  Physical parent-directory checks also protect source-subtree aliases, including `--project .` and actual APFS case aliases.
- A malformed response after POST incorrectly reported a local preparation problem.
  Actual POST-attempt state now preserves task inspection and same-key recovery guidance.
- An excluded build filename was checked for portability before exclusion and caused an ARM failure.
  The source exclusion check now precedes member validation.
- An APFS case-collision fixture overwrote its first filesystem name, so that failure did not demonstrate a product defect.
  Git index entries now construct the intended committed case collision.
- Syntactically valid forged selection tags initially rejected a complete reporting batch.
  Noncountable diagnostics now retain original fingerprints while valid package counts advance.
- A ledger could initially be placed inside publicly served mirror storage.
  Physical ancestry checks now refuse that configuration before creating ledger bytes.
- The original rootless Linux nginx check failed while creating `/var/lib/nginx/body`.
  Explicit private-prefix temporary paths corrected the selected build's defaults; the same non-root check then passed.

- The first new full-flow attempt selected a nonexistent PostgreSQL fixture prefix and failed during setup.
  No service assertion passed in that attempt; the verified 16.15 paths corrected the fixture selection.
- The next flow completed project publication and installation, then correctly refused its test batch's future end timestamp.
  The fixture now uses actual completed-event timestamps; the importer clock guard was unchanged and the full flow passed.

The earlier record retains the preceding disk, toolchain, source-copy, authority, and distribution failures.
Agent review is advisory; the deterministic checks above establish only their exercised contracts.

## Remaining boundaries

The public publication manifest, task API, TUF trust profile, and released V1 path remain unchanged.
Project publication requires a committed Asm project without dependencies and explicit prepared executable inputs when wanted.
It provides no implicit build, source-host authentication, independent build provenance, public enrollment, or ownership recovery.
Compression is repeatable for the same inputs and toolchain; cross-compressor byte identity is not claimed.
The new Git/compression runner configures 120-second alarms and file caps.
Inherited hash and archive-decompression helpers retain byte bounds and termination checks without a separate wall-clock alarm.
The hostile-input tests use explicit parent timeouts; no whole-command latency or capacity guarantee follows.

The V2 statistics snapshot uses immutable package/release IDs and supplies display names separately.
It does not silently merge with the existing website's V1 catalog or counters.
No cloud raw-log adapter or paid analytics service was activated.
Choose edge viewer observations or origin misses for one delivery path; summing both would double-count requests.
Qualify query handling, cache rules, privacy, permissions, and normalized provider logs in the chosen deployment.
Raw provider logs can contain personal data and are not accepted directly.

Production still needs protected trust provisioning, qualified images/providers/ingress/workers, current database compatibility, resource budgets, spending controls, and an isolated restore comparison.
The original ScienceHub rollout holds remain in place.

The owned ARM and x86-64 test containers and VM profiles were stopped after qualification.
Their saved pre-test CPU and memory settings were restored; retained fixture data and qualified artifacts were preserved.
The user's running default VM profile was unchanged.
