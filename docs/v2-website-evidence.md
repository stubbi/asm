# V2 website qualification

Date: 8 November 2026. Unreleased local source evidence, not deployment or release qualification.

This extension follows [project publication and observations](project-publication-evidence.md).
The worktree starts at `d958e0282b2b70639a2f490cd149a174907ef3fc` and retains uncommitted source changes.
The [website contract](specs/registry-v2.md#static-website-projection) and [hosting procedure](hosting.md#build-the-v2-website) define its scope.
No production key, account, cluster resource, DNS record, public endpoint, or released binary changed.

## Outcome and implementation boundary

Consumers can find V2 packages, inspect an exact release, copy a native fetch command, and inspect package or release observations.
The static build reads selected public distribution metadata and an optional private ledger.
It preserves immutable identities, exact target dimensions, lifecycle states, unknown counts, gaps, and observation cutoffs.
It adds no public application process, database connection, tracker, or per-download database write.
Assembly retains publication, package selection, current lifecycle checks, mirror retries, and native use.
Existing Python registry operations generate static files; existing browser scripts enhance presentation.

This follows resource care, dependable reuse, control, and evidence principles.
The trade-off is bounded local search and rebuild delay instead of another running service.
Metadata-only refresh avoids artifact reads; explicit artifact validation enables direct download links.
The native command independently authenticates current metadata and checks downloaded bytes in either case.

## Component checks

| Gate | Observed result | Scope |
| --- | --- | --- |
| Private projection | 12 methods passed in 1.310s | Canonical envelopes, manifest/object bindings, identities, lifecycle table, mirrors, concurrent head changes, and observation consistency |
| V2 page rendering | 11 methods passed in 1.679s | Exact pages, history, target dimensions, commands, raw-link gating, escaped text, lifecycle actions, unknown/zero counts, and shared-byte attribution |
| Final `make site-test` | 109 Node checks and 340 Python methods passed; Python 74.884s | V1 regression gates, V2 projection/pages/build, documentation, articles, bootstrap, and trust-publication checks |
| `make registry-infrastructure-test` | 95 methods with one platform skip, 24.304s; 98 registry methods passed, 14.409s; 26 publisher-tool methods passed, 0.742s | Locked storage SDK, actual nginx, retained stores, log import, registry validation, and publication operators |
| Browser | Completed at 1280-pixel and 320-pixel widths | Local synthetic fixtures; search, exact-version navigation, return state, filtering, copying, keyboard focus, script-free content, empty catalog, and unavailable V2 data |
| Complete authority flow | Two methods passed in 53.970s, no skips | Actual assembly API, PostgreSQL, signing, nginx TLS, website-command fetch, native installation, explicit execution, log import, rebuild, and lifecycle failures |

The final site log is `/tmp/asm-v2-website-site-qualified.log`.
The infrastructure log is `/tmp/asm-v2-website-infrastructure-qualified.log`.
The final page subset is `/tmp/asm-v2-website-pages-qualified.log`.
The coverage-claim regression is `/tmp/asm-v2-coverage-review-green.log`.
Agent reviews were advisory and did not replace these deterministic gates.

The final authority log is `/tmp/asm-v2-website-full-flow-qualified.log`.
Its SHA-256 is `6f8bdc20851a35a4df50969a67db9224d516f29327c5a12ae5c1fd991d076a44`.
The site log SHA-256 is `67043c80272dfde3099a7649fc0aff139e59d58296f687996abe6ae55ebd5b4e`.
The infrastructure log SHA-256 is `f662093d9d0f91e73beb46c9d302925fef6e8d23732e6d675fc16fd289ef8edc`.

## Complete user flow

The first method publishes a committed Git project through the actual assembly API and PostgreSQL authority.
Its structural-checker callback is trusted fixture code; the preceding evidence records separate container-isolation checks.
Private signing completes distribution and synchronization to a second mirror.
Actual nginx TLS serves the resulting homepage, exact release page, catalog, and observation snapshot.
Before reporting, package and release counters are null.

The fixture parses the displayed fetch command from that served page and checks its copy attribute.
Only documented root, state, and destination placeholders are replaced; the private fixture CA is added explicitly.
The real native client fetches exact executable bytes without creating an installation receipt or executing the program.
Native installation also tries an unavailable first mirror, succeeds through the second, and retains the complete bound receipt.
An exact installation repeat preserves files without another artifact request.

Actual normalized nginx logs establish two genuine completed transfers and one separate forged-tag diagnostic.
Private import and website rebuild expose package and exact-release counts of two through served HTML and JSON.
Overlapping batches and exact replays leave that count unchanged.
Only a subsequent deliberate program invocation creates the execution marker and expected output.
The second method retains prepared publication, corrupt/network refusals, credential revocation, lifecycle changes, and existing-file preservation.
Yanked and revoked website pages retain inspection metadata while exposing no new selection commands or raw artifact links.

The synthetic executable SHA-256 was `ec36bc7003723dceca0a19d71b90a1919c7bed51212c980a91acb2d941e01687`.
Its exact release envelope SHA-256 was `8a9add5bfa4774ceffa045462cb733c0f404c3b4aa9b785796ff0d3d539ee9df`.
The observed exact-release HTML SHA-256 was `6dec109059ebffe8e4a416ee9535da4f132be312511c03a9247a63bf0324d716`.
The final log retains all eighteen website file digests across unknown, observed, and replayed states.
These are synthetic fixture identities, not a public package release or adoption record.

## Exact fixture identities

Final Linux full-flow preflight matched the exact 92-file source and static-asset inventory against the host worktree.
The retained capture is `/tmp/asm-v2-website-full-flow-preflight.log`.
It records exact source hashes.
The final `/tmp/asm-v2-website-rosetta-preflight.log` checks the complete inventory, Python 3.11.2, libpq 16.15, and these unchanged executable identities:

| Executable | SHA-256 |
| --- | --- |
| Native Linux x86-64 V2 client | `298d4e1e5f389aaacf8a7d79818df1de2e1e9d79f44f5bcef999161bc955b308` |
| Maintained embedded verifier | `e4b5ce10f0bf2497dc039c1a316416b5ba62d1a6beb267225653a89411aded4c` |
| Private signing helper | `501787c8984a8ff58b8f8d27018b40100d603e13aeee36b0b062c19b1a5ae1a7` |
| Assembly publisher | `78dc5d884e3045db4beea0fc54d2d9c7e7f621ca9afdc1202fe7b26a12d6c063` |
| Linux fixture nginx | `62b20544dc6f509184ab550d15658bbc9fd18ca720235fda14eb8ef91e09d595` |

The host was Apple Silicon macOS 15.6.1 with Python 3.14.6.
Initial Linux x86-64 attempts used QEMU full-machine emulation.
The alternate fixture uses the existing VZ ARM profile and registered Rosetta interpreter.
Neither environment qualifies physical x86 hardware or performance.
The publisher retains libmicrohttpd 1.0.3 and OpenSSL 3.5.9 from the preceding qualification.
The Linux nginx fixture retains Debian package `1.22.1-9+deb12u10`; this is not a production dependency selection.
No CLI assembly, SQL migration, checker policy, Go adapter, or signing profile changed in this extension.
Full-flow qualification reuses the exact previously qualified binaries instead of rebuilding them.
It is not a clean release build or a new release-artifact qualification.
The component command was `make -o registry-cli -o build/asm-trust registry-v2-full-flow-test`.
The final container used one CPU, 1 GiB RAM, and a 256-process limit.
It had no external network, host ports, capabilities, or new privileges.
The Rosetta preflight SHA-256 is `628e2dbaff8bab4a8c723d92ccd5f6c88d2fb2eb8c9a9e586403baa94f2d952a`.

## Browser observations and resource scope

The browser fixtures contain two explicitly synthetic packages with one declared source selection each.
They establish presentation behavior, not real packages, adoption, artifact validity, or signing authority.
The reported fixture credits one imported transfer to one identity and leaves the shared-byte package at observed zero.
The page displays incomplete coverage and stale observations.
Copying returned exactly the displayed command, without a prompt, hidden execution, or changed arguments.
Keyboard copying retained a visible two-pixel focus outline and announced its result.
At 320 pixels, the page width remained 320 pixels; code and daily tables scroll inside their containers.
Script-free pages retained commands, exact records, and metadata while hiding nonfunctional copy/filter controls.
Unavailable V2 JSON left native browse and raw-index recovery links; it did not select the V1 catalog.

For this fixture, `app.js` was 61,028 bytes, or 15,047 bytes under deterministic gzip compression.
`package-page.js` was 4,718 bytes, or 1,534 bytes compressed.
The catalog was 6,297 bytes, or 1,010 bytes compressed; observations were 1,646 bytes, or 431 bytes compressed.
These are fixture file sizes, not latency, capacity, maintenance-cost, or hosting-bill measurements.
No new runtime dependency or paid service was added.

## Retained failures and review corrections

- Initial tests failed because the V2 builder and projection did not exist.
- The first metadata fixture omitted the mutable timestamp; the completed-distribution fixture now includes its exact bound bytes.
- Static Popular rows and exact-version links initially lacked the required script-free behavior.
- Browser refresh discarded immutable package IDs; a regression now preserves them during discovery rejoin.
- An inherited `__proto__` tuple lookup was admitted; an own-property check now refuses it.
- Browser mirror validation initially rejected supported IPv6 and explicit default-port bases; matching canonical checks corrected that mismatch.
- Independent review admitted complete/exact V2 counter claims in browser input.
  V2 validation now refuses those claims; actual counts retain their observed-minimum label.
- An observed-zero activity page initially lacked its collecting state; it now preserves the zero without implying complete history.
- Generated AI instructions and the Docs hub initially retained V1-only workflows.
  V2 output now describes native preview commands, independent trust, and the current registry contract.
- One integration assertion expected the earlier coverage wording; it now checks the rendered incomplete-coverage warning.
- Three full-flow attempts failed in database initialization before reaching application assertions.
  Both cases exceeded the unchanged 20-second `initdb` limit in each attempt.
  A separate diagnostic completed in 25.788 seconds; this was not counted as a gate pass.
  Pinning the diagnostic to one guest CPU still exceeded 20 seconds.
  Restoring the original one-CPU VM configuration did not resolve initialization.
  Qualification moved to the existing owned ARM test profile with Rosetta; the default user VM remained untouched.

The failed logs remain under `/tmp/asm-v2-website-*-red.log` and `/tmp/asm-v2-website-full-flow-{first,second}.log`.
The original-profile failure remains at `/tmp/asm-v2-website-full-flow-qemu-one-cpu-red.log`.
The transfer-source failure remains at `/tmp/asm-v2-website-full-flow-rosetta-sourcecopy-red.log`.
Database diagnostic logs remain separate from the full-flow gate.
- The first Rosetta flow passed database setup, publication, and distribution, then rejected transfer-generated AppleDouble blog filenames.
  Removing 155 verified AppleDouble sidecars from the owned fixture restored the exact host source inventory.
  The builder's filename check remained unchanged.

No deadline, assertion, persistence setting, or security check was weakened.

## Remaining boundaries

The website is a cached operator projection, not TUF signature or rollback authority.
Native commands require independently provisioned roots and retained private trust state.
Yanked and revoked pages retain inspection records while omitting new selection actions.
The current V2 envelope supplies no publication dates, source-host authentication, or README rendering guarantee.
New and Recently updated therefore remain explicitly unavailable, and documentation has a source-archive fallback.
No public enrollment, dependency integration, ownership recovery, hosted build, or proof service follows from this work.

Use the optional output on an isolated preview or on-premises origin.
The default official Pages build, released V1 clients, checked installer, self-update trust, and V1 feeds remain unchanged.
An apex migration must compose and qualify those compatibility routes before activation.
Cloud query/cache behavior, normalized provider-log adapters, ingress, capacity, spending, and recovery retain their deployment gates.
The existing ScienceHub rollout holds remain in place.

The new ARM test container, anonymous volume, imported image, host transfer archive, and preview listener were removed after qualification.
Both owned VM profiles returned to their original stopped configurations; the running default profile was unchanged.
The original x86 fixture and its private snapshot remain retained in that stopped profile.
Qualified binaries, failed logs, and source evidence were preserved.
