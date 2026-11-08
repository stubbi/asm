# V2 optional dependency and feature evidence

Status: local source qualification completed, 8 November 2026.
Public release and deployment results require separate recorded evidence.

## Outcome and contract

Consumers can select optional dependency groups and retain their exact enabled graph.
This follows dependable reuse, user control, and resource care in the brand foundation.
Application logic remains native assembly on both implemented architectures.
The maintained adapter supplies transport and cryptography; it does not interpret feature declarations or select packages.
Mirrors need no resolver process, database, or signing key.

The [contract](specs/registry-v2.md#feature-activation) defines the syntax and limits.
The [plan](superpowers/plans/2026-11-08-v2-features.md) records acceptance conditions and trade-offs.
The [earlier dependency record](v2-dependency-evidence.md) retains the mandatory-only checkpoint and its negative results.

Features affect graph selection. Assembly symbols and source imports remain explicit.
Requests unite across active paths; dormant edges contribute nothing.
Version-four locks retain selection, enabled features, active roots and edges, and the existing nine immutable node bindings.
Sync caches exact envelopes for local full-declaration checks without network access during build.
Version-three mandatory locks remain readable. Feature semantics require explicit resolution into version four.
No prereleases, parallel versions, universal target solving, or build hooks were added.

## Local checks retained

| Check | Result |
| --- | --- |
| Pure native model, Apple Silicon and x86-64 through Rosetta | 28 tests passed on each architecture |
| Early Apple Silicon model and signed graph checkpoint | 68 tests passed, 73.799 seconds |
| Linux ARM64 full `make test` | 817 tests passed, zero skips, 334.899 seconds |
| Complete release tests, Apple Silicon | 117 methods completed, with 12 unchanged Linux-only skips; 560.267 seconds |
| Real clean macOS release producer within that suite | Two identical full builds; exact-byte native suite passed the unchanged zero-skip gate |
| Full native publication, features, sync, build, execution, website and statistics | Three methods passed, zero skips, 101.063 seconds |
| PostgreSQL 16.15 authority | 23 tests passed, zero skips, 53.792 seconds |
| Exact 8192/8193 profile boundary and distribution authority | 14 tests passed, zero skips, 55.556 seconds |
| Assembly HTTP publisher | 16 tests passed, zero skips, 86.501 seconds |
| Operator infrastructure and real nginx | 95 methods; 91 passed and four macOS ACL cases skipped |
| Registry contracts | 98 tests passed, zero skips, 34.931 seconds |
| Publisher tools on Linux | 35 methods; 33 passed and two macOS ACL cases skipped |
| Six macOS ACL counterparts | Six tests passed, zero skips |
| Complete V1 and V2 publication compatibility | 58 tests passed, zero skips, 24.857 seconds |
| Explicit minimal V1 publication | 28 tests passed, zero skips, 1.136 seconds |
| Full site gate | 136 Node tests and 443 Python tests passed; Python suite 87.843 seconds |
| Go adapter race tests and distribution tools | Race-test packages passed; 19 distribution tests passed |
| Direct cleanup and x86-64 update regression | Five tests passed through Rosetta, 4.707 seconds |
| Native ARM cleanup and update suites | 36 tests passed, zero skips, 11.839 seconds |
| Direct macOS cleanup regressions | Three tests passed, zero skips |

These results identify development source snapshots over base commit `4709591eacedbca8a103d22914f26cf19c5b426f`.
They do not replace final exact-commit CI or the release workflow.
The Linux ARM client SHA-256 was `980bc50c1f987ed09c84ad0846a1be508d0f7bdd93f7bf859246c9560b4fd73c`.
Its source snapshot fingerprint was `18339adbfc363744a5e55021ab0cbd717bddb315d3da0f0d27e4232d9fb1f453`.

The full-flow Linux x86-64 client SHA-256 was `879a588febff7a64a0c041ad249ea55072ac9944293de2ca2311a344e6629498`.
Its publisher SHA-256 was `ade416ae6f381341774487ba5b1ee7388cc1b74311dd316241b635d92aae17c1`.
That fixture used PostgreSQL 16.15, libmicrohttpd 1.0.3, and the explicitly labeled OpenSSL 3.0.22 fixture profile.
The final CI publisher also requires its reviewed OpenSSL 3.5.9 profile.
No native x86-64 hardware result is inferred from Rosetta execution.

Linux ARM64 syscall 37 uses the Linux v6.18 [primary UAPI header](https://raw.githubusercontent.com/torvalds/linux/v6.18/include/uapi/asm-generic/unistd.h).
The mapping was checked on 8 November 2026.

The model corpus contains 96 generated feature graphs, with 57 satisfiable and 39 unsatisfiable cases.
An independent exhaustive assignment and feature-propagation oracle checks both native implementations.
The existing 96 generated mandatory graphs remain covered.
These finite cases are evidence of their exercised behavior, not a general correctness proof.

## Failures retained

- The new featureful native publication first failed because the private checker rejected its new fields.
- SQL acceptance first returned 400 instead of 202 on the required PostgreSQL 16.15 fixture.
- The dormant optional integration case first reported an unsatisfiable graph before native graph integration.
- The actual macOS build exposed a noncontiguous BSS assumption hidden by the earlier model harness.
  The solver now owns one explicit facts block, and model tests use the shipping macOS adapter.
- Two integration assertions initially used invalid fixture assumptions.
  A root default change can be semantically valid; restoring private metadata requires its original protected mode.
  The corrected cases retain invalid selections, omitted features, missing metadata, content corruption, and output preservation.
- A Linux fixture used non-executable temporary mounts, then an incorrectly owned temporary directory and missing cross tools.
  The installer refused the unsafe ancestor as designed. The corrected native fixture uses root-owned sticky temporary storage.
- Review found that an existing metadata cache entry could be hashed without a prior length check.
  The regression first observed the generic lock error. Sync now refuses a wrong length before hashing that entry.
- The exact Go SDK requirement refused the older ambient launcher after automatic SDK switching was disabled.
  Qualification uses the installed SDK declared by the source and the pinned CI setup.

- The first expanded native producer reached its old 300-second deadline.
  The completed macOS workload took 363.528 seconds. Full V2 now has a fixed 600-second budget; minimal V1 retains 300 seconds.
  No assertion or zero-skip requirement changed.
- Clean release tests exposed stale suite-selection fixtures and reliance on the obsolete generated-source cache path.
  Fixtures now model explicit gates, and the self-build test generates fresh assembly through the existing preparer.
- The legacy archive path first rejected its retained 16384-byte limit and later rejected UTF-8 comments and consumer locks.
  Explicit V1 and V2 validator entries preserve V1 behavior and keep V2's strict 8190-byte contract.
  V1 publication also refuses dependency and feature tables instead of silently dropping their meaning.
- Linux cleanup initially retained private update directories.
  Independent descriptor tests reproduced stale enumeration after files were created through another descriptor.
  Each walker now owns a fresh no-follow directory descriptor and preserves the caller's descriptor and cursor.
  Native regressions cover repeated walks, outside symlinks, failed inputs, descriptor counts, and update failure cleanup.
- The first Linux x86-64 full run reported 809 methods with 42 failures and four pre-execution errors.
  Cleanup and legacy-bound failures were corrected. The syscall-filter errors remain outside Rosetta's native qualification scope.
  Final x86-64 CI must run these unchanged cases on native hardware.
- Full-flow fixture setup first lacked actual Git history and then contained generated macOS AppleDouble files.
  Actual Git objects and source-only transport corrected those fixture inputs. No validator was weakened.
- Hostile CPU-feature and Go experiment settings first failed the new environment checks.
  Build, notice, and test environments now pin the baseline architectures, disable experiments, and retain the SDK's default FIPS source profile.

## Protected CI follow-up

The first [PR 69](https://github.com/stubbi/asm/pull/69) head was `96bd79441bb19dea1f637ab343b971ee28a7bc9f`.
Its test merge input was `2151d15b0a9a2b6819e13d61c8163e80f6637667`.
Its native server, infrastructure, images, CodeQL, Intel, ARM64, and macOS checks passed.
The [distribution trust run](https://github.com/stubbi/asm/actions/runs/42494377613) retained six registry-fixture failures on each Windows architecture.
Five failed current-user ownership checks; the expiry case stopped before reaching its delayed response.
The ordinary temporary parent could belong to Administrators rather than the current user.
The registry fixture now creates its protected child through `openState` and writes inputs through `writeExclusive`.
Production ownership, ACL, timing, required-case, and skip checks remain unchanged.
Local race tests pass, and both Windows test executables compile. Native Windows CI must qualify the correction.

Final audit also reproduced a retained-lock error-classification defect.
Duplicate, empty, or malformed feature names in the lock first returned command usage status 2.
The shared parser now returns its failure to the caller.
CLI syntax errors retain status 2; retained lock errors use status 1 with the existing resolve instruction.
Six sync/build failure cases preserve the lock, cache, output, and execution marker without a registry request.
Seven invalid CLI cases retain their usage behavior.
The two new macOS methods passed in 3.046 seconds; 44 Linux ARM dependency methods passed in 81.846 seconds.
Three x86-64 methods passed through Rosetta in 19.323 seconds, including successful default and explicit selection flows.
The recorded native macOS failure remains at `/tmp/asm-v4-malformed-selection-macos-red.log`.

## Release and deployment boundary

The release profile includes V2 by default, with an explicit V1-only source build still available.
Self-update trust provisioning remains independent.
Protected exact-commit CI, release provenance, published bytes, and deployed-site checks remain required before completion.
The release workflow retains proposed compatibility records separately from the flat signing handoff.
Agent review cannot replace those deterministic gates.

The correct ScienceHub cluster has both Asm Flux deployments suspended and no Asm namespaces.
No production V2 root, signing custody record, storage profile, or initial owner record was found.
The maintainer reported no known location for those records.
Treat official V2 activation as unprovisioned.
Do not resume Flux or promote fixture identities as production authority.
The CLI and hostable service source can be released independently of that activation.

## Published 0.7.0 acceptance

[Asm 0.7.0](https://github.com/stubbi/asm/releases/tag/v0.7.0) was published on 8 November 2026 as an immutable prerelease.
[Release run 42499673815](https://github.com/stubbi/asm/actions/runs/42499673815) used source `11f526c2f4264b8c33c4865ff03862857424c184`.
The default client profile includes V2; the separate self-update trust profile remains disabled.
All source gates passed on that exact main commit before the single release dispatch.

All 17 assets were downloaded from public release URLs without account credentials.
Their sizes and public API digests matched.
Every declared asset also matched `release.json` and `SHA256SUMS`.
All 16 signed subjects passed bundle verification without account credentials.
Verification fixed repository ID `1441332955`, the main release workflow, OIDC issuer, source digest, and signer digest.
Self-hosted runners were refused.

The [release manifest](https://github.com/stubbi/asm/releases/download/v0.7.0/release.json) has SHA-256 `fd54400d743042f3430b8364da4da23eb6816b70307649ef678dd9c7a515ec76`.
Its native receipts bind these exact tested executables, with zero skipped CLI tests:

| Native host | CLI tests | Executable SHA-256 |
| --- | ---: | --- |
| Linux x86-64 | 818 | `4eaa03e83b0462bb217dc10b60919c99cfbabacb6c83e7c698dd0ebc0a1cbf07` |
| Linux ARM64 | 819 | `4d6a6f6b966811b54b00f693cf8340b4c6cc0f4da5c1ce968a292dc3108bccc5` |
| Apple Silicon macOS | 411 | `5e134bdd48dedaa156f95674014ecb2ed8d91de8461580899aa784b5959656ab` |

Downloaded macOS and native Linux ARM64 clients each passed `version`, `new`, `run`, and `test` in a fresh directory.
Both printed `Hello from asm!` and passed the starter test.
A second `new` refused the existing destination and preserved every generated file's bytes and mode.
The executable digests remained unchanged after these checks.

The proposed compatibility records came from the same release run's artifact ID `13625192454`.
Its archive digest was `sha256:1339d2d633a77ff1e7aaeb57cd9c4d61b400520656a8141060bc753e6d22593e`.
All three records matched the public bytes, source commit, licenses, and targets.
Each published source archive reproduced exactly from the recorded Git objects.
The admitted files retain those original record bytes; earlier records remain unchanged.

Catalog admission uses a separate protected pull request.
That pull request records public website and installer results after deployment.
Official hosted V2 activation remains unprovisioned.
These results do not qualify production key custody, provider storage, public ingress, recovery, capacity, or comparative cost savings.

All three unchanged full-flow methods also passed with the downloaded Linux x86-64 client, without skips, in 155.280 seconds.
They covered native project publication, feature selections, complete locks, sync, build, deliberate execution, mirrors, website observations, and failure preservation.
The client digest above stayed unchanged before and after the run.
This local run used Rosetta on an ARM virtual machine and the retained OpenSSL 3.0.22 development fixture over `4709591`.
It does not establish native x86 hardware or deployed-service qualification.
The fixture publisher digest was `ade416ae6f381341774487ba5b1ee7388cc1b74311dd316241b635d92aae17c1`.
The fixture signing-helper digest was `501787c8984a8ff58b8f8d27018b40100d603e13aeee36b0b062c19b1a5ae1a7`.

The initial container-copy setup failed before tests because capability restrictions prevented root from traversing a private directory.
The existing directory owner created an exclusive file through standard input instead.
No capability, permission boundary, test assertion, or CLI bytes changed.
The failed setup record remains separate from the passing test record.

The catalog follow-up passed 98 registry tests, 136 JavaScript tests, and 443 Python website tests, without skips.
Metadata immutability validation accepted 21 releases against the prior main commit.
These checks do not substitute for the deployed website's public installer checks.
