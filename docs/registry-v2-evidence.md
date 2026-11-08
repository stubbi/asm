# Signed V2 local evidence

Date: 8 November 2026. Unreleased source checks; no production deployment or release qualification.

The checkpoint starts at `d958e0282b2b70639a2f490cd149a174907ef3fc` and includes this branch's uncommitted changes.
The [V2 specification](specs/registry-v2.md) defines the contract; the [hosting guide](hosting.md) gives operating instructions.
The [7 November record](registry-infrastructure-evidence.md) retains the earlier infrastructure and publication results.
This record describes the prepared-input V2 checkpoint.
The [subsequent project and statistics record](project-publication-evidence.md) describes native archive preparation and attributed V2 observations.
No public endpoint, production key, provider account, DNS record, or Kubernetes resource was created.

The outcome is provider-independent publication and authenticated exact installation through separately selected mirrors.
This follows the foundation's dependable reuse, control, evidence, and resource principles.
Application and package logic remain assembly.
Maintained transport and TUF libraries provide cryptography; private tools orchestrate signing, storage, and database operations.

## Tested environment and identities

The host was Apple Silicon macOS 15.6.1 with Python 3.14.6.
Linux x86-64 ran under AMD64 emulation on that host; Linux ARM64 ran with native instruction execution in Colima.
PostgreSQL tools and libpq were 16.15, libmicrohttpd was 1.0.3, and publisher hashing used OpenSSL 3.5.9.
The Go adapter used Go 1.27.3 and go-tuf/v2 2.4.2 without new module dependencies.
Intel macOS client checks used Rosetta; they do not qualify Intel hardware or add an Intel macOS package target.
No performance or capacity claim follows from test duration.

| Artifact | SHA-256 |
| --- | --- |
| Linux x86-64 publisher | `78dc5d884e3045db4beea0fc54d2d9c7e7f621ca9afdc1202fe7b26a12d6c063` |
| Linux x86-64 TUF adapter | `e4b5ce10f0bf2497dc039c1a316416b5ba62d1a6beb267225653a89411aded4c` |
| Linux ARM64 TUF adapter | `c9f5da15f435c15b3bbd4fd8f16612e620befe777d243d89cda444c10244f9de` |
| macOS ARM64 TUF adapter | `c18ffeb2fd2b6881f427306c633f30ed03fdb968152bbe6531263aa7dacaab31` |
| macOS Intel TUF adapter | `f3e324bb758a0590fd367d364937dd6ac7aa63a138b4db5849b4f590e0bb4776` |
| Linux x86-64 private signer | `501787c8984a8ff58b8f8d27018b40100d603e13aeee36b0b062c19b1a5ae1a7` |
| Linux ARM64 private signer | `15bf16d31740faaad65748b21561928fbc227b715ddaae4ce1bb7ea467ec37c6` |
| macOS ARM64 private signer | `0a660a38973a35609d1d5da6bcaeeac782ce37dfa8d8184310ec5fdc49d1b9a8` |

| Native client | SHA-256 |
| --- | --- |
| macOS ARM64, final task-state gate | `88eb624701af59e6b5fd25acce5da05238cf1e8001500873a34068b78444f119` |
| Linux ARM64, final task-state gate | `fd952bcc9beaa33a6822814065db695290031657f557a314a0330caa663e552b` |
| Linux x86-64, final task-state gate | `f3371b65dd1a1ed8bf733a614173a0748536cdaf9babaeb15c3627616bd4ad79` |
| macOS Intel, final task-state gate under Rosetta | `66729e94110cedc4dbec4495af5292e78beda0e57325f990e6aaf0c28da212fe` |

The Linux x86-64 feature-off binary is `044189b2a05a96a69814387ac0a3919e01ec2d0b5d0540e15d2efed91a115799`.
V1 behavior is checked separately; no x86-64 byte-identity claim is made.
These are local executable identities, not published releases or reproducible-build claims.
The default feature-off binaries remain separate from the opt-in V2 build.

The publication migration remains byte-identical with SHA-384:

```text
142273d53453fa1396aa15e589b3a6137755dbafb220aac500bcdfc12170b033d1a8db64a1c7449d2c655a9387ea2611
```

The separate distribution migration and operator pin use SHA-384:

```text
45726d006a970ab5cbbea9521861e6c410fb6f139064e455a81ecb9d7f4aa7d4036d877b731ccac268b38c9ef8718422
```

The current checker policy SHA-256 is `a8f59d2380242dcd4932a10a3be2652f49ecd8245bdbb9df7b888e2ea34e3c24`.
The storage-key correction changes that source-bound policy; the earlier record's policy is historical.

## Checks and scope

| Check | Observed result | Scope |
| --- | --- | --- |
| `make verifier-test` | Both Go packages passed with the race detector; 12.969s and 3.261s | Registry/root binding, expiry, rollback, rotation, mixed roles, maintained verification, signing, and existing self-update regressions |
| Private distribution operations | 19 methods passed in 1.747s | Real fixture signing, compact inventories, preplacement, timestamp-only renewal, exact retry, stale workers, expiry replacement, readiness, and overlapping-store refusal |
| Storage boundary | 26 methods passed | Descriptor boundaries, immutable/CAS operations, valid long metadata keys, S3 prefix bounds, and unchanged archive restrictions |
| Distribution authority | Twelve-method suite passed in 96.508s; three final focused methods passed in 34.572s | Actual PostgreSQL roles, compact inventories, lifecycle fencing, retained seals, abandoned version replacement, and pinned migration; not one combined thirteen-method result |
| `make registry-infrastructure-test` | 82 infrastructure cases, one Linux-only skip; 98 registry cases and 26 publisher-tool cases passed | Locked SDK, storage/mirrors, private observations, and real nginx V1/V2 serving |
| Operator source, entrypoint, and publication checks | 19 methods passed in 22.110s | Existing source bundles, image policy, and private operator interface; not image qualification |
| `make site-test` | 104 Node checks and 310 Python checks passed | Existing site behavior, generated observation metadata, and documentation routes; no site publication |
| CI source validation | `actionlint` passed for all three affected workflows | Configuration check; CI execution remains separate |
| Final macOS ARM64 native V2 gate | 25 methods passed in 28.101s, no skips | Publication, exact signed fetch/install, mirror selection, task-state bounds, and deliberate native execution |
| Final Linux ARM64 native V2 gate | 25 methods passed in 31.439s, no skips | Same contract with native ARM instructions in the Linux guest |
| Final Linux x86-64 full user flow | Two methods passed in 84.895s | Actual in-flight task observation, assembly API, PostgreSQL, current checker source, real signing, second mirror, exact installation, deliberate execution, and failure preservation |
| Linux x86-64 and Intel macOS task-state regression | Two methods passed on each final artifact, 4.935s and 3.610s | Valid `distributing` and refusal of pre-publication release links; earlier full 23-method gates apply to their earlier artifacts |
| Default Linux x86-64 CLI `make test` | 672 run in 333.809s, 19 expected skips | Current-source fixture with genuine Git metadata and Node; optional and other-platform environments remain separately qualified |
| Default macOS CLI `make test` | 270 passed | Released feature-off path |
| Default Linux ARM64 CLI `make test` | 671 run, 18 expected skips | Released feature-off path; skips identify other hosts or optional feature gates |

The full-flow checkpoint before the final in-flight task observation passed two methods in 87.541 seconds.
It used Linux client `f3edb581f73356b32f030895cd6390eece013a6c55e1fd89d71a9b9838da46bb`.
It covered native publication, the assembly API, actual PostgreSQL authority, retained checking, real signing, and second-mirror installation.
Entire and omitted source locators both passed; other named hosts use the same manifest field and native request path.
The source locator and commit were synthetic publisher assertions; no external source host was contacted.
The fixture terminated TLS and forwarded HTTP requests to the loopback assembly API.
It also served static files and supplied no registry application policy.
The fixture checker callback was trusted test code; Docker isolation has separate evidence in the 7 November record.

Installation left the absolute execution marker absent and recorded all seven inventory fields exactly.
Only a deliberate later invocation produced the expected program output and marker.
Published task replay sent no duplicate PUT requests and retained one task.
Corruption, network failure, yank, stale rollback, revocation after unyank, and credential revocation preserved existing files and inventory.
The final rerun passed both methods in 84.895 seconds using Linux client `f3371b65dd1a1ed8bf733a614173a0748536cdaf9babaeb15c3627616bd4ad79`.
After the actual certificate-authenticated distribution claim, native HTTP task reads reported `distributing` with `release: null` before signing.
Both source-locator cases checked that observation; all earlier happy-path and refusal checks reran successfully.
The final fixture SHA-256 was `e9105d8ad2a469ecfddf8b58901e64512f6f4cf32d83e95f8de588900601dba2`.
Its preflight retained publisher, client, embedded helper, signer, and checker-policy digests.
The raw final logs are `/tmp/asm-native-full-flow-distributing.log` and `/tmp/asm-native-full-flow-distributing-preflight.log` on the authoring host.
The final raw log SHA-256 is `648baf5c7bc47e34d4c82409c894fc5e5d789467997bf88fecbd59e1503db990`.
The preflight log SHA-256 is `a1d0550e9306f44498a077aa04a256e5ca645b14760dcbdef2966f4f2c87921b`.
These temporary log paths are local evidence references, not published download URLs.

## Retained failures and corrections

- The native client retried artifact PUT requests after published-task replay; the API correctly refused them with HTTP 409.
  Both native ports now skip exact object receipts already confirmed by the server.
- Documentation review found that the native task enum omitted the valid `distributing` state.
  The native regression and full-flow observation cover that intermediate state and its absent release link.
- An ARM pipe-descriptor store used the wrong width and overwrote an adjacent descriptor.
  The fixed-width store corrected timeouts without increasing their deadline.
- A slow policy response could cross timestamp expiry after initial verification.
  The adapter now checks the signed five-minute checkpoint again after target download, before exposing output.
- A signed wrong-registry timestamp could poison cached version state before the scope check.
  A reject-only prefilter now refuses its scope before maintained TUF caching; signatures still require the maintained verifier.
- Actual PostgreSQL text output added one transport line ending after the canonical envelope's own LF.
  The distributor removes precisely that record separator and still checks exact length and digest.
- Unchanged renewals initially duplicated catalog membership and inventory data.
  Immutable snapshots and inventories now remain shared; only small attempt, plan, seal, and audit records grow per renewal.
- Large committed payload placement initially followed short-lived timestamp signing.
  Payload transfer now completes before signing; sealed metadata retains its exact version and bytes across retry.
- Expired sealed attempts lacked a safe replacement route.
  The operator now reconciles observed public versions, records abandonment, and retries once with a higher reserved version.
- Overlapping local roots or S3 prefixes could expose private retained objects through a public destination.
  Configuration checks now refuse recognized overlap before claiming a job; provider permissions remain an independent deployment check.
- Reusing archive-path validation rejected valid `con` and `aux` namespace components and long metadata paths.
  Storage keys now have their own explicit bounds; archive extraction retains its original portable-path restrictions.
- The first complete x86-64 default CLI run had two fixture errors among 657 methods, with eleven expected skips.
  Its source copy lacked genuine Git metadata and its runtime lacked Node for browser metadata parity.
  Genuine HEAD history and a test-only official Node 26.13.0 runtime corrected those prerequisites without changing application code or assertions.
  A comparison confirmed all 210 CLI, tool, and test source files matched the worktree before the final run.
  Both failed methods then passed; the complete rerun passed 672 methods with nineteen expected skips.
  The earlier failed run remains retained; its lower count also reflected stale fixture files.
  The final raw log is `/tmp/asm-default-cli-linux-x86-qualified.log`, SHA-256 `36235b1fe298f8a8b6ca09b2a35f310f03553b399683e6bc8fe11ef93cc7ceba`.
  Skips cover other platforms, cross-user/tool fixtures, and optional SDK, S3, nginx, or V2 environments qualified separately above.
- A full-flow fixture exceeded its fixed twenty-second database initialization limit during competing VM work.
  Serial execution passed with that limit unchanged; cleanup registration was corrected.
- A shared Go SDK was incomplete; compilation failed before a verifier result existed.
  A task-owned official Go 1.27.3 SDK restored the exact toolchain without changing module or security checks.
- The updated Linux ARM Makefile tried to rebuild the unchanged Go adapter, but that fixture had no Go executable.
  A following test command exercised the old client and failed the new task-state assertions.
  The exact native recipe was then built with the SHA-verified frozen adapter; all twenty-five feature methods passed.
- One infrastructure attempt selected an absent nginx path and failed its prerequisite check; zero tests ran.
  The complete gate later passed with the retained nginx 1.30.6 executable, SHA-256 `24e800750f32ed101f8af74fd08e55688777b8c232767aa6a4291d4db61089f5`.

The earlier disk, ACL, SQL, archive, worker-isolation, and provider failures remain in the 7 November record.
No retry changes an earlier failed result into a pass.

## Resource choices and remaining gates

Mirrors use static files or S3, synchronization, and HTTPS, without a database or signing authority.
Unchanged mirror synchronization performs no artifact transfer; explicit retention audits read current retained bytes.
Unchanged checkpoint renewal retains one release inventory and requires only the timestamp signing key.
Five-minute expiry requires regular renewal and mirror synchronization; it bounds accepted metadata age, not instantaneous revocation delivery.
These are tested operation shapes, not measured total cost, throughput, or global scale.
The flat profile permits at most 4,095 releases and can hit the role byte limit earlier.

At this checkpoint, native publication required prepared canonical manifests and digest-named objects.
Native archive generation and V2 observations were then separate extension work.
Dependency integration, public self-service enrollment, ownership recovery, and source-host OIDC adapters remain separate work.
Source locators are publisher assertions; neither scoped tokens nor checksums verify a source-host identity or provenance.
At this checkpoint, V2 per-package download observations remained unknown; the importer attributed only V1 selection routes.

Production activation still needs protected trust provisioning, selected-provider access and conditional-write checks, ingress, isolated workers, and current-source image qualification.
It also needs resource budgets, fault headroom, spending alerts, backup/WAL verification, and an Asm-specific isolated restore comparison.
ScienceHub's inspected PostgreSQL version differs from the 16.15 local fixture and needs deployment qualification.
No cluster rollout hold was changed.
The systemd references remain unverified on a deployment host.
Updated CI steps are configured source; no claim is made that they ran remotely.
The macOS fixture selects modern OpenSSL explicitly because the system LibreSSL lacks Ed25519 key generation.
The `macos-15` runner label selects ARM64 in the [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), inspected 8 November 2026.
Test fixtures require OpenSSL with Ed25519 support; set `ASM_REGISTRY_OPENSSL` to its absolute executable when necessary.

## Authoring-host cleanup

Both task containers and their previously stopped Colima profiles returned to stopped state after verification.
The saved x86 profile configuration returned to one CPU and 1.5 GiB; the ARM profile retained two CPUs and 3 GiB.
VM data, source, qualified executables, license notices, and evidence were preserved.
The approved Colima download cache and task-owned compilation caches were removed.
Other host profiles and their workloads were left unchanged.
