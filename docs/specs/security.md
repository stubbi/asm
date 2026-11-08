# Security model

This document states the implemented checks and the controls required for later services. Implementation and release gates are tracked in the [roadmap](../roadmap.md).

Asm distributes executable code. A package can be correctly signed, build successfully, pass tests, and still be malicious. The interface must report what was checked, on which bytes, by which tool, and under which assumptions.

## Current implementation

The registry tools validate metadata, artifact size, and SHA-256. They compare immutable history when a baseline is supplied. They also check source archives and target-specific executable containers and segment bounds. Source packaging can read a pinned Git commit.

If a declared GitHub release URL returns HTTP 504, the site build can use GitHub's public release-asset API.
Release metadata must match the original repository, tag, filename, browser URL, and known byte size.
Only one uploaded asset can match, with a valid numeric identifier.
Requests use no credentials and retain bounded metadata, responses, timeouts, HTTPS origins, and redirects.
All existing byte, archive, and bootstrap bundle checks remain mandatory.
Permission errors, missing files, rejected metadata, and byte mismatches cannot use this fallback.
API delivery does not establish that the original browser-download route currently works.

The native CLI parses the bounded index and verifies fetched bytes. Fetch does not extract, execute, or overwrite a destination. The archive module validates all members before extraction. It also compares cached files with the original archive bytes.

The released V1 index relies on HTTPS and control of the registry origin.
It has no separate signature, expiry, rollback protection, or authenticated namespace service.
The released [signed V2 client](registry-v2.md) has separate trust, ownership, and freshness boundaries described below.
No public V2 service is activated.
Advisory scans, isolated third-party builds, Lean/Kraken proof checks, and agent review are not running registry services.
Their status must remain `not-run`.

Asm's own bootstrap installer and manual self-update command verify release provenance before installing a binary. This fixed release policy does not apply to general package downloads. A package must not inherit Asm's provenance result.

The following sections distinguish source controls from requirements for later activation.
Passing an artifact validator does not establish deployment, isolation, provenance, or proof results.

The website's optional GitHub star counter first reads a first-party public observation.
On static hosting, it can request the fixed public repository API when that observation is absent or expired.
This request omits credentials and referrers; GitHub receives the connection's network address.
GitHub also receives standard browser metadata, including the site origin.
No search terms, page paths, or application-added identifiers enter the request.
The response must identify `stubbi/asm` and supply a safe nonnegative integer.
Bound response size, request time, and refresh frequency.
The browser renders counts as text and hides expired observations when refresh fails.
Session storage contains public repository metadata and a bounded retry deadline, without visitor identifiers.
These counts do not establish package suitability or safety.

The static site build embeds a Content Security Policy before resources in each published HTML page.
It restricts scripts and assets to the same origin, with the GitHub API permitted for the fixed repository observation.
Inline styles remain permitted for existing charts and interface styles; inline executable scripts and event handlers are rejected during the build.
This document policy does not provide HSTS or framing protection, which require response headers unavailable through the current GitHub Pages configuration.
Fresh discovery and statistics responses from the local preview server do not inherit this build-only document policy.
The [CSP specification](https://www.w3.org/TR/CSP3/#meta-element) defines delivery through HTML and its limits.
[Chrome's transition guidance](https://developer.chrome.com/docs/web-platform/view-transitions/cross-document) requires the retained early head script.
These primary references were reviewed on 8 November 2026.

Exact dependency locks bind archive digests and selected targets. Native cache checks compare expected source bytes and reject unexpected members. Advisory locks coordinate Asm processes; they do not constrain other processes running as the same user.

Asm 0.5.0 records installed executables in a bounded local inventory, including explicit output paths.
Upgrade and uninstall check the recorded destination, size, and digest before changing a file.
They also require a user-owned, single-link regular executable with protected permissions.
They retain the package origin and reject downgrades or changed bytes for an existing version.
Older installations remain unmanaged; updating Asm does not adopt them.
These package checks do not inherit Asm's own release-provenance policy.
The [installed-program contract](../installed-programs.md) states the staging, recovery, and interruption limits.
The executable and inventory are separate filesystem entries; interruption can require manual recovery.

Lock checks cover declared dependencies. GNU assembler includes and data directives can select other local files. The local build workflow is not a hermetic sandbox. Registry workers need separate isolation before they build untrusted submissions.

Asm 0.6.0 selected-target builds validate every declared recipe before creating a build stage.
The CLI invokes fixed GNU or LLVM tools with direct arguments.
Cross-target output is never executed implicitly.
V2 locks bind package and target pairs and validate inactive metadata before cache actions.
Only the selected target's cache is required for a build.
Existing staging and directory checks remain in use; they are not a general hermetic build sandbox.

## Trust boundaries

Treat package contents, manifests, documentation, proof projects, build output, and agent output as untrusted input. A maintainer account, CI job, registry host, mirror, or dependency can be compromised independently.

| Threat | Required control |
| --- | --- |
| A download differs from the selected release | Verify its size and SHA-256 before use; bind the digest into the lock file |
| A release is silently replaced | Immutable version records and artifacts; append a new version instead |
| A stale or compromised mirror changes the index | Authenticate registry metadata, check expiry and monotonic versions, and retain trusted client state |
| Someone publishes under another maintainer's name | Explicit namespace ownership and a narrowly authorized publisher identity |
| A package escapes its extraction directory | Validate archive members before extraction; reject links and special files |
| A build or proof runner steals credentials | Disposable isolated workers, no publisher secrets, restricted network, resource limits |
| A dependency targets the wrong machine or calling convention | Resolve architecture, ABI, object format, and required ISA features explicitly |
| An agent follows instructions in a package README | Treat repository text as data; give analysis workers no publishing authority |
| A proof establishes a weaker or unrelated statement | Compare against a separately trusted statement and bind the result to exact inputs |

## Publication and ownership

The initial alpha used reviewed pull requests for publication records.
That intake route is retired; `registry/` retains compatibility records and bootstrap input.
The [hosted publication boundary](../hosted-registry.md#publication-boundary) defines the intended replacement and remaining gates.
There is no deployed public publisher endpoint.
The [assembly publisher source](../../server/publisher/README.md) has a loopback-only task API with expiring, package-scoped credentials.
It rechecks authorization at upload receipt and immutable intent commit.
It does not expose the catalog operator's whole-catalog import authority.
Its first migration stops at immutable `committed` intent.
The separate distribution migration adds fenced `published` receipts and audited lifecycle operations.
The native `asm registry` commands authenticate that distribution through maintained TUF verification.
The released client and source checks do not qualify public ingress, deployed storage, signing custody, or recovery.

The check coordinator can place bytes before final intent authorization.
Its retained store must remain private and separate from public serving, CDN aliases, and bucket listings.
The distributor exposes only committed intent and refuses overlapping source and destination storage locations.
Path and prefix checks do not prove external bucket privacy; provider and deployment policy require separate qualification.
Private storage and credential writes check opened descriptors, including ACLs that can grant access beyond mode bits.

The existing [catalog operator](../../server/catalog/README.md) imports exact accepted Git snapshots through a separate PostgreSQL identity.
Database credentials authorize catalog operations; they do not authenticate the package publisher.
Numeric GitHub namespace bindings remain operator assertions.
Plain import does not verify artifact bytes.
Its optional `--distribution-root` gate validates a matching snapshot and every artifact before opening database credentials.
That receipt describes the operator invocation; it does not change stored evidence or authenticate the publisher.

A maintainer must verify namespace claims and changes against the recorded owners before accepting publication input.
A source URL, display name, or accepted commit alone is not identity verification.

Validation runs must have read-only repository permissions. They must not receive deployment credentials or use `pull_request_target` to execute contributor-controlled code. A trusted publication job must validate accepted inputs again with an approved validator revision. Contributor-supplied CI output is not registry evidence.

The [provider-independent publication contract](publication.md) starts with expiring Asm credentials scoped to an owner, exact packages, and permitted operations.
Source hosting does not establish package ownership.
Keep credentials outside source trees, task responses, URLs, logs, and package artifacts.
Recheck revocation, expiry, scope, and current ownership before committing a release.

An optional future OIDC exchange can issue the same scoped grant from a short-lived identity.
Verify issuer, audience, expiry, signature, stable principal, workflow, and permitted release context.
Changes to publisher identity require an auditable owner action.
No GitHub account or CI issuer is required for the direct-credential workflow.

[npm's trusted publishing](https://docs.npmjs.com/trusted-publishers/) and [PyPI's security model](https://docs.pypi.org/trusted-publishers/security-model/) provide useful precedents. Short-lived credentials reduce exposure. The workflow and people allowed to trigger it remain trusted.

## Integrity, provenance, and registry freshness

These are separate checks:

- **Integrity:** the downloaded bytes match a digest already trusted by the client.
- **Provenance:** an expected identity attested to those bytes and their build context.
- **Freshness:** the client has not been served expired or rolled-back registry state.

A checksum served beside an archive is useful against accidental corruption. It does not authenticate an index compromised along with the archive. HTTPS does not remove that distinction.

Use GitHub artifact attestations or a Sigstore bundle for release provenance. Verify the artifact digest, certificate identity, OIDC issuer, expected repository/workflow, and the relevant transparency evidence. Verification against any valid signer is insufficient. [GitHub documents artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations); [Sigstore documents identity-bound blob verification](https://docs.sigstore.dev/quickstart/quickstart-cosign/). A valid attestation establishes origin, not code safety, as [PyPI explicitly explains](https://docs.pypi.org/attestations/security-model/).

The bundled verifier reuses a maintained TUF client for separate registry and self-update profiles.
The self-update trust profile remains disabled; production trust is not provisioned.
Hosted activation still requires independent root delivery, offline root custody, separate signing roles, native qualification, and compromise-recovery tests.
Follow [TUF's specified client checks](https://theupdateframework.github.io/specification/) for metadata versions, expiry, hashes, signatures, and consistent snapshots.
A custom signature over one JSON file is not a substitute for that protocol.

Never silently downgrade verification after an unavailable service, expired metadata, or invalid signature. A future explicit offline mode may use already-verified, locked artifacts; it must show which freshness checks could not be performed.

### Signed registry V2

Assembly owns package parsing, dependency resolution, complete graph locks, target selection, lifecycle policy, mirror retries, and local installation.
The Go adapter returns only bounded, TUF-authenticated target bytes through a fixed command interface.
It does not select a package, interpret lifecycle rows, or choose another mirror.
Mirrors cannot supply the initial trusted root or reset durable version history.
The protected state binds the registry identity and initial root digest before cached metadata is read.
Assembly tries at most three explicit HTTPS mirror bases under that same binding.
An optional protected CA file supplies private TLS roots; ambient CA overrides are refused.

Signed registry timestamps contain the expected `asm_registry_id` and canonical UTC `asm_issued_at`.
The client enforces a five-minute maximum lifetime and age, current expiry, and at most thirty seconds of future clock skew.
A reject-only prefilter prevents wrong-scope or stale timestamps from poisoning the durable version cache.
Maintained TUF verification still establishes signatures and metadata bindings.
The verifier checks the trusted checkpoint after refresh and again after target download, before exposing target bytes.
This policy requires a correct client clock and an available current mirror.

Assembly validates the signed release envelope and complete lifecycle table before selecting an artifact.
It checks artifact length and digest before finalization.
Source fetch also validates archive structure; executable installation checks the host container format.
It refreshes lifecycle policy again after the artifact transfer, immediately before exposure or installation.
Yanked or revoked selections fail, including exact repeated installations.
Emergency revocation remains irreversible and audited; it cannot remove existing copies or stop an installed program.
An expired checkpoint, invalid signature, wrong registry, or stale mirror never selects a V1 fallback.

The distributor places committed opaque payloads before signing the five-minute checkpoint.
It seals exact signed bytes before changing public TUF roles or conditional heads.
Expired sealed checkpoints require reconciliation, audited abandonment, and a new reserved metadata version.
Database authorization and storage writes do not share a transaction; uncertain results retain their identities and bytes.
Mirrors need storage access and HTTPS serving, without database credentials, publisher tokens, or signing keys.
These mechanisms establish scoped metadata authority and integrity, not package safety or source provenance.

### V2 dependency graphs

Dependency declarations are authenticated release metadata bound to immutable package, release, source, and envelope identities.
Native validation and the private checker compare each declaration with the exact archived source manifest.
The graph profile permits mandatory and optional same-registry source dependencies for one explicit target.
Feature requests unite across active paths; dormant edges contribute no constraint or request.
All declarations remain validated, including inactive references and local feature cycles.
It selects one version per package; parallel versions and universal target solving are unsupported.
The source requirement grammar uses bounded full numeric versions without whitespace, prereleases, alternatives, or implicit registry fallback.
Version compatibility remains a publisher declaration; the solver does not establish ABI compatibility.

Resolve authenticates the signed lifecycle inventory and candidate envelopes before solving.
Every envelope must match the inventory's immutable package and release identities.
Versions of one name must retain one package identity, including inactive policy rows.
It reads at most 256 reached candidate versions when active solver branches require their names.
Dormant optional edges cause no metadata request.
Resolve downloads no archive and executes no package code.
The native backtracking solver also bounds roots and per-candidate dependencies to 64, with a 100,000-step search limit.
Exhaustion and unavailable or malformed metadata must not become false unsatisfiability reports.
Mirrors remain byte origins for the same explicit registry and initial root; they cannot replace package authority.
No new public resolver service or synchronous database query is required.

The canonical `asm-lock-v4` binds registry, initial root, target, root manifest, selection, enabled features, selected nodes, and active edges.
Exact envelope digests retain inactive declarations.
Version-three mandatory locks remain readable; customized feature declarations require explicit resolution into version four.
Resolve refuses automatic replacement of legacy locks or locks from another authority or target.
An explicit resolve can change selected versions within the declared constraints.
It preserves the package identity of retained names and every node binding for an unchanged version.
A newly signed view cannot silently replace a previously locked release.
These checks depend on the retained project lock; deleting it discards those package and release pins.
Sync authenticates only locked exact metadata and compares the entire reconstructed graph before cache changes.
It checks current lifecycle policy for every selected node before and after source materialization.
Source length, digest, archive structure, and dependency declarations must match before extraction.
Existing source files and the previous lock survive failure; verified cache additions can remain after a later graph operation fails.

Build checks validate local graph closure, feature propagation, reachability, requirements, root freshness, source declarations, and exact cache bytes.
Version-four builds also require the exact digest-addressed envelope bytes retained by sync.
A locally edited feature row cannot replace recomputation from those declarations.
They do not refresh signatures or lifecycle policy and do not independently authenticate a locally edited lock.
Use sync before building when current registry authentication is required.
A correct graph does not make assembler imports hermetic or establish that package code is safe.
The [V2 dependency contract](registry-v2.md#resolve-a-bounded-dependency-graph) records the format and qualification limits.

### Native committed-project preparation

The V2 CLI prepares source archives and canonical manifests in assembly.
It reads selected local commit objects through fixed, bounded Git plumbing and uses fixed gzip compression.
It disables ambient global/system Git configuration, replacement objects, lazy fetches, network protocols, hooks, and filters.
It does not build, test, or execute submitted package code.
Dirty and untracked working files do not enter that committed snapshot.

Source validation and preparation precede publication credential reads.
Physical directory checks refuse a supplied credential path inside the selected source subtree.
Opened executable and prepared-object identities are compared with metadata-only credential identity before candidate reads.
These checks protect the supplied credential file and its aliases; they do not detect arbitrary secrets committed under ordinary names.
Known sensitive filenames, links, unsupported dependency declarations, malformed paths, and bounds violations fail before HTTP publication.
Executable provenance remains a publisher assertion; the private checker supplies the existing structural checks.
A malformed reply after POST requires task inspection and the same request identity, because task creation can already be durable.

### V2 delivery observations

V2 GETs append public selection identifiers to the unchanged digest object path.
The normalized exporter accepts only the complete canonical path and query grammar.
It writes no raw query, IP address, visitor identity, cookie, user-agent string, or referrer.
Malformed or untagged requests remain outside its reporting scope.

Private observation mapping checks operator-selected immutable metadata descriptors; it does not perform TUF authentication or grant publisher authority.
The ledger pins registry and release bindings and refuses a location inside public storage.
Package counts require exact identity, target, kind, digest, declared size, and complete public HTTP 200 transfer.
Well-formed unknown selections are retained as noncountable diagnostics, so they cannot credit a package or poison an otherwise valid batch.
Original event fingerprints, batch digests, and source/request deduplication remain intact.
Other invalid fields and conflicting bindings fail before writes.

Unknown counts, reporting gaps, unreported mirrors and CDN hits, stale state, and source coverage remain explicit.
Counters describe sender observations, not verification, installation, unique people, or safety.
The [V2 specification](registry-v2.md#v2-delivery-observations) defines the initial JSON snapshot and deployment qualifications.

### V2 website projection

The explicit V2 static build reads only the selected public inventory and optional private statistics ledger.
It validates immutable envelope, manifest, lifecycle, and observation bindings without opening application credentials.
The inventory is operator input; these checks do not authenticate TUF signatures or retain rollback state.
Native fetch commands remain the authority for current signed metadata, lifecycle policy, and final artifact checks.
The website cannot provision a root from a selected mirror or reset retained client trust.

Generated pages escape package text, retain explicit target dimensions, and keep yanked and revoked actions disabled.
The builder reads artifact bytes only for explicit validation; metadata checks cannot supply successful artifact evidence.
Exact release counters bind the release identity rather than a shared blob or package-wide total.
Public snapshots contain aggregates and coverage, without raw events, request identities, credentials, or private ledger files.
V2 discovery failures never select the V1 catalog.

## Bootstrap and manual self-update

The [bundled-verifier implementation](../trusted-distribution.md) is gated on key provisioning and native qualification.
The following contract describes the published route until that migration is activated.

The bootstrap installer installs the CLI for Linux x86-64, Linux ARM64, or Apple Silicon macOS 15+ when the checked release supplies that executable. It detects the host locally with `uname`. Each target has a separate fixed URL, size, and digest. An unsupported host fails before downloads or file changes. The assembly command `asm self update` manages later manual updates. Both routes require a direct, user-owned `$HOME/.local/bin/asm` installation. They do not request administrator access or replace a command owned by another package manager.

The installer script is obtained from `https://asm.build/install.sh`. HTTPS and control of that origin are the initial script trust boundary. A signature check inside a modified installer cannot make that installer trustworthy.

The quick-start command streams the script to a POSIX shell. The shell must parse the complete function and final entry block before installation starts. An incomplete entry block does not download an artifact or change the installation. The installer never runs the downloaded `asm` command.

The quick-start pipeline is for interactive use. Its exit status can be zero if curl fails before it sends any script bytes. Curl still reports the download error. For scripts and CI, use the complete-download route in the installation instructions. That route requires a successful download before execution. The separate inspection route keeps the downloaded file for review before execution.

Both routes use GitHub CLI 2.93.0 or later for Sigstore verification. This minimum includes the upstream [TUF mirror authentication-header fix](https://github.com/cli/cli/security/advisories/GHSA-8xvp-7hj6-mcj9). The verifier receives no GitHub credentials or ambient trust-root configuration. It uses a fresh home, configuration directory, and cache. Bounded standard proxy variables can change routing; they cannot change the required identity or trusted roots.

The policy fixes the repository name and numeric identity. It also fixes the release workflow, main source ref, OIDC issuer, SLSA predicate, and hosted-runner requirement. The source and signer commits must match the selected release. A valid signature from another repository, workflow, or commit is insufficient. The verifier must return exactly one matching repository identity.

Each release contains the action-produced `release-attestation.sigstore.json` bundle. It is a single JSON object with a 1 MiB limit. The release job verifies every payload against this same published bundle without a GitHub account. The bundle supplies signature evidence, not replacement trust roots.

The site build copies the selected bootstrap executables and signed bundle to digest-qualified paths on `asm.build`.
It checks each executable's size, SHA-256, and container before publishing the complete site.
These copies retain the original release bytes, source identity, and license.
The generated bootstrap downloads these copies and can recover a transient failure through the exact public GitHub release-asset API.
The site build binds each recovery endpoint to the original repository, tag, filename, browser URL, uploaded state, and byte size.
The installer receives fixed numeric asset identifiers; it does not parse API metadata or accept a caller-selected endpoint.
Recovery uses no credentials and retains the HTTPS, redirect, byte, and file limits.
Each artifact has a total download budget of 120 seconds across its two transport attempts.
A missing first-party copy can use its pinned public API endpoint; the copy route has no package authority.
Missing official assets, permission errors, certificate failures, corrupt bytes, and failed attestations stop installation.
API rate limits or unavailable recovery endpoints also stop installation and preserve an existing command.
This recovery applies to the generated bootstrap. Published native clients retain their existing download behavior.
Only the current bootstrap release receives these first-party copies.
Saved older installers can lose their copy URLs after a later deployment and use their original API endpoint instead.
This controlled bootstrap route is not a general package mirror, retained artifact store, or new package authority.
Static hosting supplies no Asm-owned download observations. These copies do not establish a known download count.

The site offers the bootstrap only for checked CLI releases from 0.2.0 onward. It also downloads the required bundle before publication. A missing or malformed bundle stops the site build. These site checks establish availability and format; the installer performs signature verification. Earlier releases retain the source-build route.

The native updater also downloads and verifies `release.json`, with the same size limit. Its bounded assembly parser rejects malformed JSON and duplicate keys. The signed manifest must match the version, tag, repository, source commit, and selected executable's name, size, and digest. Both the manifest and executable must satisfy the same provenance policy.

Both installation routes check the byte size and SHA-256 digest before exposing the file. The site checks the executable format before it generates the bootstrap script. The native updater also checks the downloaded ELF or Mach-O format and segment bounds. macOS also verifies the code signature and rejects ACL allow entries or ownership-disabled APFS. Bootstrap finalization refuses an existing different destination. Self-update checks the running executable's device and inode before staging and again before replacement. It uses a private stage and an advisory directory lock. It syncs the candidate before the final atomic rename. The candidate is not executed during installation or updating.

The bootstrap accepts an existing file only if its ownership, link count, permissions, size, and digest match the installation contract.
This no-op creates no temporary files and does not download files or run the provenance verifier.
It can succeed when the existing installation directories permit no writes.

The manual command refuses a downgrade. An equal selected version is a no-op; it does not reverify the installed file or establish registry freshness. A stale index can hide a newer release. The protocol has no independently signed expiry, emergency revocation record, or durable metadata-version history. GitHub CLI's root refresh does not supply those missing Asm release guarantees.

This protocol is not an audited TUF client for Asm metadata. It does not enable unattended updates. The repository, release workflow, GitHub identity service, verifier, and trusted roots remain trusted. Same-account processes can ignore advisory locks. Atomic replacement does not promise directory durability after power loss.

Read [the self-update contract](../self-update.md) for exact identities, supported filesystems, permission requirements, and recovery instructions.

## Archive and execution policy

The source registry rejects absolute paths, `..` traversal, duplicate paths, ambiguous separators, and NUL bytes. It also rejects links, devices, FIFOs, and other special entries. Limit file count, path length, individual file size, total expanded size, and archive size. Extraction must remain inside a newly created staging directory and become visible atomically only after validation succeeds.

Installing or adding a dependency must not execute package code or install hooks. Build recipes must describe tools and arguments rather than interpolate package-controlled strings into a shell. Assembly includes and macros can still read files, and assemblers and linkers have their own attack surface. Registry builds therefore require isolation even when a package has no shell script.

Build workers must not share writable caches with unrelated jobs. Cache keys must include source, dependency digests, target, compiler/linker identity, and relevant options. Publishing credentials belong to a separate job that consumes validated results. These choices follow the separation of build workers and signing authority described in the [SLSA threat model](https://slsa.dev/spec/v1.2/threats).

## Findings and evidence

Each check result must identify:

- Package, version, artifact SHA-256, and target.
- Checker and policy versions, configuration digest, and run time.
- Outcome: `pass`, `fail`, `not-run`, `unsupported`, or `error`.
- Covered files or routines, findings, assumptions, and an inspectable report.
- The identity that produced the evidence and how that identity was verified.

`not-run`, `unsupported`, and `error` must never be rendered as passing. Counts of successful checks are not safety scores. A package page may say “archive validated” or “this routine's stated contract was proved”; it must not infer “safe package.”

Use OSV for known-advisory checks where a dependency has a supported ecosystem identity or a known upstream commit. [OSV supports version and commit queries](https://google.github.io/osv.dev/api/). Do not invent an `asm` ecosystem identifier and assume coverage. An empty response means no matching advisory was returned at that time. Native Asm advisories need their own maintained identifiers and version ranges until an upstream mapping exists.

Yanking removes a version from the released V1 native index without changing its recorded bytes.
V1 has no authenticated client revocation policy.
The V2 profile separately enforces signed yank and emergency-revocation records.
Any legal or secret-removal exception must retain a tombstone; an old version must never become assignable to different content.

## Lean and Kraken

The proposed Kraken integration is [AeneasVerif/kraken](https://github.com/AeneasVerif/kraken), the assembly-semantics project associated with Lean. This is the researched interpretation of the requested “Kraken,” not an installed dependency or completed integration.

Its README, checked on 2026-10-31, describes x64 and AArch64 support. RISC-V is planned. It reasons at an abstraction above assembly and linking. Its documented x64 scope covers sequential computation and excludes operating-system and concurrency features, among other limitations.

Asm must pin a reviewed commit and publish the exact supported subset. Coverage must identify the supported instructions and targets.

Start with small routines and explicit contracts: arithmetic results, bounds on memory access, preserved registers, and preconditions. A proof about a mathematical model has a defined scope. It does not automatically cover toolchains, loaders, operating systems, timing, or final executables. Reproducible builds and provenance help connect inputs and outputs; they do not prove that translation preserves semantics.

A proof record must identify the source digest, routine, target, ABI, theorem, and assumptions. It must also identify semantics, toolchain, and proof-dependency revisions. The trusted statement must be maintained separately from the submitted proof. Unsupported instructions or an unproved source-to-model correspondence must fail the requested proof claim, not be replaced with axioms.

For the default proof profile, reject `sorryAx`, custom axioms, and native-evaluation shortcuts that add unapproved trust. Audit transitive axioms against a documented allowlist. A successful `lake build` alone is insufficient for adversarial submissions. Follow Lean's [proof-validation guidance](https://lean-lang.org/doc/reference/latest/ValidatingProofs/). Isolate proof generation. Validate exported proof data. Compare the resulting theorem against the trusted statement with a separate checker. Where supported by the pinned toolchain, use `comparator` with an independent checker. Lean's [axiom reference](https://lean-lang.org/doc/reference/latest/Axioms/) explains why an accepted theorem is still conditional on its axioms.

## LLMs and agents

Agents may propose tests, inspect changes, identify suspicious routines, explain findings, and generate candidate proofs. Their output is advisory until reproduced by a deterministic check or accepted through an accountable review.

Give each analysis job a bounded input set and disposable workspace. Keep registry signing, credentials, releases, and owner changes outside its permissions. Record the model identifier, prompt/policy revision, input digests, tool calls, and report. Redact credentials and private data before any external model request. Repository comments and documentation must not be allowed to change the agent's tools or policy.

No model verdict may override a failed digest, unauthorized publisher, unsupported proof, or failed kernel check. There is no “LLM approved” safety badge. A proven finding may trigger a defined quarantine rule. Uncertain findings need review, supporting evidence, and an appeal route.

## Local artifact delivery and download observations

The local website tool serves exact artifact selections and records Asm-owned transfer events.
This is a loopback development adapter, not a deployed distribution or publishing service.
The [discovery contract](discovery.md) defines its counting and coverage policy.

A versioned route binds package, version, target, format, and digest before storage access.
The adapter rejects unknown selections and new yanked selections.
It checks byte length, SHA-256, and artifact structure before sending a retained object.
The private cache uses conditional digest-key creation, owned files, bounded storage, and explicit transfer limits.
An operator-selected storage reader is separate from the event source.
Requests cannot supply an upstream URL, traffic class, or counter increment.

A completed full response can create an event only after its body write and flush succeed.
This does not prove client receipt, verification, installation, publisher identity, or software safety.
Known bot and internal classifications are advisory exclusions, not authenticated identities.
Reporting errors interrupt coverage without turning a successful file response into a failure.
A reporting gap cannot silently establish zero activity.

The private ledger accepts selection-bound, idempotent events through local tooling.
It stores no visitor identifiers, IP addresses, cookies, fingerprints, user-agent strings, or search terms.
The service does not log request URLs.
Host, Origin, path, header, time, byte, concurrency, and filesystem checks bound the local route.
There is no public event-ingestion API or authenticated browser session on this adapter.

Production delivery requires the architecture's separate artifact origin, authenticated metadata, edge reporting, and recovery gates.
Published v1 records and native HTTPS rules remain unchanged.
Legacy direct-origin downloads are outside the local Asm event coverage.

## Release gates

Before public unattended installation, test rejection of tampered archives, malformed metadata, hostile paths, and target mismatches. Also test signature substitution, stale metadata, and compromised publisher identities. Before displaying formal-verification results, test incorrect theorems, changed instructions, hidden axioms, and mismatched artifact digests.

Before accepting untrusted build or proof jobs, test isolation independently of the package being evaluated. A static site, a policy document, and a green workflow run do not establish these guarantees by themselves.
