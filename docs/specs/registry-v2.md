# Signed V2 distribution and native use

Status: unreleased source implementation, 8 November 2026. No public deployment is activated.

This profile extends [publication](publication.md) from immutable intent through signed distribution and native use.
The outcome is publishing and installing exact package bytes without requiring a particular Git host or CI service.
It follows the foundation's resource, reuse, control, and evidence principles.
The [security specification](security.md) and [architecture gates](../architecture-gates.md) remain required.

## Preserve the implementation boundary

Assembly owns publication requests, package parsing, dependency resolution, graph locks, target selection, lifecycle checks, mirror retries, and installation.
The existing Go adapter handles maintained TUF verification and bounded HTTPS transport.
Private registry operations prepare signed metadata and reconcile storage with PostgreSQL.
They are not another public application backend.
No submitted package, source repository, hook, or build command runs during publication or installation.

The released V1 contract remains unchanged.
V2 verification failure never selects V1 metadata or another registry's authority.
An explicit source repository is descriptive metadata, not an authentication instruction.
GitHub, Entire, GitLab, Codeberg, other Git hosts, and local projects use the same publication manifest and credential contract.

## Fix registry identity and trust

A registry has one immutable random identity, encoded as 32 lowercase hexadecimal characters.
Its initial trusted root is selected independently of artifact mirrors.
Never trust a root merely because a mirror supplied it.
The production root still requires the offline ceremony and separate signing roles described in [trust provisioning](../trusted-distribution.md).
Fixture keys cannot activate production trust.

The initial native profile requires an explicit trusted root file, registry identity, and private persistent trust directory.
The verifier binds that directory to the registry identity and initial root's SHA-256 before reading cached metadata.
TUF root rotation retains that initial binding.
A changed initial pin or registry identity requires an explicit migration; it cannot silently reset rollback history.
Deleting trusted state discards previously observed versions and is not a recovery shortcut.
Root, state, and optional CA paths must be protected, clean absolute paths.

Mirrors change transport only.
Assembly tries at most three explicitly supplied mirror bases in order, using the same root, identity, and retained state.
Each base requires HTTPS without credentials, a query, or a fragment.
An optional explicit CA file supports private on-premises TLS.
Ambient tool settings cannot select roots, CAs, credentials, or weaker verification.

## Authenticate bounded release records

The first profile uses ordinary TUF root, targets, snapshot, and timestamp roles with consistent snapshots.
It has no custom signature protocol or delegated-role policy.
Role limits remain 1 MiB, with a 16 KiB timestamp and at most 32 root rotations per refresh.
The targets role permits at most 4,096 entries, including the lifecycle policy.
These are initial compatibility bounds, not global capacity evidence.
The signer must refuse a size overflow before exposing a new timestamp.

Registry timestamps sign `asm_registry_id` and `asm_issued_at` alongside the standard TUF fields.
The identity must match the explicitly selected registry.
The issue time uses UTC seconds, and the signed lifetime cannot exceed five minutes.
The client refuses expired checkpoints, issue times older than five minutes, and issue times over thirty seconds in the future.
These checks require a correct client clock.

A reject-only filter checks scope and time before a downloaded timestamp can enter durable rollback state.
The maintained TUF implementation still verifies signatures, versions, expiry, and metadata bindings.
The adapter checks the trusted checkpoint after refresh and again after target download, before creating its output.
Neither the filter nor a mirror can replace signature verification.

The exact release target is:

```text
registries/REGISTRY_ID/releases/OWNER/NAME/VERSION.json
```

It contains this closed JSON envelope:

```text
schema: 2
registry_id: immutable registry identity
package_id: immutable package identity
release_id: immutable publication task identity
manifest_sha256: digest of the original canonical publication request
publication: the complete V2 publication manifest object
```

The envelope uses the existing canonical JSON encoding.
The private exporter checks the original manifest bytes and digest against committed PostgreSQL intent.
The client authenticates the complete envelope through TUF before parsing its package policy.
Its receipt binds the envelope's digest separately from the retained original-manifest digest.
It does not reconstruct the original request from nested JSON indentation.
All fields, identities, target tuples, lengths, and digests remain explicit and bounded.
Duplicate fields, unknown fields, unsupported targets, and required CPU extensions fail before installation.

Artifact URLs are derived from the selected mirror and authenticated SHA-256:

```text
MIRROR_BASE/blobs/sha256/DIGEST
```

Length and SHA-256 must match before the client exposes the artifact.
An ETag remains a concurrency token, not an artifact digest.

## Keep lifecycle policy current

The signed policy target is `registries/REGISTRY_ID/policy.tsv`.
Its first line contains four tab-separated fields:

```text
# asm-registry-policy-v2    REGISTRY_ID    PUBLICATION_REVISION    POLICY_REVISION
```

Every later line contains six tab-separated fields:

```text
OWNER/NAME    VERSION    PACKAGE_ID    RELEASE_ID    YANKED    REVOKED
```

The examples above show field order; actual separators are single tabs.
Revisions are nonnegative decimal integers.
Flags are exactly `0` or `1`.
Lines use ASCII and one terminating LF, without blank lines or duplicate selections.
Rows are sorted by exact package name and version bytes.
The policy has a 1 MiB limit; the distributor admits at most 4,095 releases plus the policy target.
The selected row must agree with the envelope's name, version, package identity, and release identity.

The client checks current policy before each selection or repeated installation.
It refreshes policy again after artifact validation, immediately before exposing a new artifact or installation.
This final check uses the same registry-bound state and mirror order, without downloading the artifact again.
The first profile refuses yanked selections and always refuses revoked selections.
An operator can unyank a release; emergency revocation cannot be undone in this profile.
Each operation has its own idempotency identity, expected policy revision, reason reference, and audit event.
Neither operation changes published release bytes or frees the version for different bytes.
Revocation cannot remove existing copies or stop an installed program.
An offline mirror cannot learn later revocations; this profile does not ignore expired metadata for offline use.

## Complete distribution recoverably

PostgreSQL remains authoritative for committed intent and lifecycle revisions.
A separate distributor identity receives only fixed, fenced distribution functions.
Each batch freezes its release set, policy revision, and reserved monotonic TUF version.
Abandoned attempts do not permit another batch to reuse a metadata version for different bytes.
Distributor readiness checks the pinned migration and narrow database identity before claiming work.

The public store receives only eligible committed intent and its referenced bytes.
It remains separate from private upload staging and the checker's retained store.
The operator refuses equal or nested local stores and overlapping prefixes within the same S3 endpoint and bucket.
This separation check does not establish bucket, CDN, or directory-listing privacy.
The operator must qualify those deployment controls separately.

The distributor places committed artifact blobs and digest-addressed target payloads before signing the short-lived timestamp.
Those payloads alone do not authorize installation.
It then retains the exact signed bundle and seals its descriptor in PostgreSQL.
Public TUF roles and distribution heads change only after that seal.
Immutable roles arrive before conditional head advancement; the standard mutable TUF timestamp advances last.
An older worker cannot replace a newer observed timestamp or policy head.
The operator verifies retained public bytes before completing the authoritative `published` transition.
That transition emits its own event through the existing transactional outbox.

Unchanged publication and policy revisions reuse one immutable inventory instead of duplicating every release on each refresh.
Small per-batch plans bind that inventory and the new timestamp.
Routine renewal signs only the timestamp and retains the exact snapshot, targets, and root bytes.
It reads no artifact or target payload and needs only the timestamp signing key.
A changed root requires a full metadata refresh.
Snapshot or targets expiry within twenty-four hours also requires a full refresh.
The private scheduler must renew before the five-minute checkpoint expires; no deployed scheduler is implied.

A sealed attempt resumes its exact bytes and reserved version while its checkpoint permits further writes.
An expired checkpoint, or one with insufficient write time, first requires public-head reconciliation.
Audited abandonment requires the current lease and source binding, and retains the old seal and version.
The operator retries once with a newly reserved version; another expiry stops with both attempts retained.
It never signs replacement bytes at the abandoned version.

Storage and PostgreSQL do not share a transaction.
An uncertain write or final acknowledgment retains its batch, exact bytes, and last completed state for reconciliation.
A lost lease refuses database finalization.
Public signed metadata remains a publication fact even when a later acknowledgment fails.
No automatic garbage collector deletes uncertain or historical objects.

Mirrors need only scoped storage access, scheduled synchronization, and HTTPS serving.
They receive no database credential, publisher token, or signing key.
Their synchronization inventory controls byte copying; native TUF verification still establishes metadata authority and freshness.
Keep synchronization, explicit retention audits, delivery, and optional statistics separate.

## Native command surface

The new command family is `asm registry`.
Publication accepts a committed project or an explicit canonical manifest with digest-named files.
The project preparer writes the archive in assembly; neither mode executes or fetches source code.
The client snapshots and checks every declared object before creating a task.
It reads the bearer token from a protected file and never places it in arguments or a URL.
Authenticated requests permit no redirects.
The same manifest and idempotency key resume the same durable task after an uncertain result.
The client binds task identity, manifest digest, and each object's digest and length before trusting its receipt.
It skips objects marked `received: true`, uploads only missing objects, and finishes with a task read.
Committed or published task replay therefore needs no redundant upload.

| Native command | Result |
| --- | --- |
| `asm registry publish` | Submit a prepared manifest and digest-named files with a protected credential file |
| `asm registry task` | Read the exact task with a current scoped credential |
| `asm registry fetch` | Authenticate an exact release and expose checked artifact bytes |
| `asm registry install` | Install a compatible host executable and retain its bound receipt |
| `asm registry resolve` | Resolve source dependencies for one target and write the complete graph lock |
| `asm registry sync` | Authenticate the exact locked graph and restore its source cache |

`make registry-cli` builds this optional source checkpoint on the supported native CLI hosts.
The default released command path remains unchanged.
Native project preparation is described below.
Self-service owner enrollment remains outside this profile.

Fetch and install require an exact package version.
Fetch exposes checked bytes without execution.
Install accepts only a compatible host executable and refuses an unrelated existing destination.
Installed receipts bind registry, initial root, package, release, envelope, selected target, artifact digest, length, and destination.
V1 upgrade cannot reinterpret a V2 receipt as an ordinary index URL.
An exact repeated V2 installation checks current policy before accepting unchanged bytes.
Changing installed versions remains a separate explicit operation.

## Resolve a bounded dependency graph

This unreleased extension adds mandatory source dependencies from one explicitly selected registry.
The [implementation plan](../superpowers/plans/2026-11-08-v2-dependencies.md) records its scope and qualification work.
The [dependency evidence record](../v2-dependency-evidence.md) identifies completed checks and remaining limits.
The released V1 dependency commands and target-aware `asm-lock-v2` format retain their existing behavior.

The optional publication `dependencies` array contains at most 64 closed objects with `name` and `requirement` strings.
Names use the existing `owner/name` grammar.
The array uses name byte order, without duplicates.
An absent array means no declared dependencies.
Dependencies use the selected registry identity; they cannot select another registry, repository, or mirror authority.
The private checker compares every declaration with the archived root `asm.toml` before accepting the source.
Native fetch and sync also compare the source declarations with the authenticated release metadata.

The source manifest declares dependencies with this bounded syntax:

```toml
[dependencies]
"example/math" = "^1.2.0"
"example/vector" = ">=2.0.0,<3.0.0"
```

The dependency table requires quoted package names and quoted string requirements.
The source manifest retains its 8190-byte ASCII limit and existing package and build fields.
No `[resolution]` table is required.
Duplicate names or tables, inline dependency objects, optional dependencies, feature declarations, and escapes are unsupported.
Unknown or unsupported declarations fail; publication never removes them silently.
Published source must not contain a consumer `asm.lock`.

Requirements contain at most 128 bytes and no whitespace.
A requirement is `*`, or one through eight comma-separated terms whose constraints must all hold.
Each term contains a full numeric `X.Y.Z` version with an optional `=`, `<`, `<=`, `>`, `>=`, `^`, or `~` operator.
Bare versions are exact.
Version components range from zero through 2147483647, without leading zeros.
Partial versions, prereleases, build metadata, and OR expressions are unsupported.
Caret and tilde selections must be at least the stated version.
If the stated major is nonzero, caret keeps that major.
If major is zero and minor is nonzero, caret keeps major and minor.
If major and minor are zero, caret permits only the stated version.
Tilde keeps the major and minor components.
These version constraints express publisher compatibility declarations, not independently checked ABI compatibility.

The resolver authenticates the existing lifecycle inventory and immutable release envelopes through TUF.
It checks envelope package and release identities against the selected inventory row.
Every version of one name retains the same package identity, including yanked and revoked rows.
It considers active source releases for the explicit target tuple.
The initial discovery procedure eagerly reads candidate metadata for reached package names, including candidates that the solution might not select.
It does not download source archives, run builds, or execute packages during resolution.
Static mirrors require no resolver process or additional database.

The native solver uses deterministic bounded backtracking, rather than a new external runtime or a PubGrub implementation.
It selects one version per package for one target, with numeric version ordering.
Consistent dependency cycles remain explicit graph edges; dependency declarations do not execute assembly imports.
Parallel versions, feature selection, universal target solving, and build hooks remain unsupported.
The profile permits at most 256 reached candidate versions, 256 reached package names, 64 roots, and 64 dependencies per candidate.
Its search limit is 100,000 steps.
An exhausted bound fails instead of truncating the candidate set or reporting an unsatisfiable graph.
Malformed or unavailable metadata remains a separate failure from incompatible constraints.

### Complete graph locks

Use `asm registry resolve --project DIR --target TARGET` with the explicit registry, root, state, and mirror options.
Supply `--ca FILE` when private TLS requires an explicit CA file.
Resolve writes the complete `asm.lock` atomically after metadata and final lifecycle checks.
An explicit resolve can change selected versions within the declared constraints.
Sync and builds do not select newer versions.
Resolve refuses an existing legacy lock or a graph lock with a different target, registry identity, or initial root digest.
For retained names, resolve preserves the locked package identity across version changes.
For an unchanged name and version, resolve preserves every locked node binding, including signed metadata and source digests.
A changed binding fails without replacing the lock, even when the new metadata has valid registry signatures.
These checks use the retained project lock; removing it removes those package and release pins.

The canonical lock has this field order:

```text
# asm-lock-v3
registry REGISTRY_ID INITIAL_ROOT_SHA256 TARGET ROOT_ASM_TOML_SHA256
root NAME REQUIREMENT
node NAME VERSION PACKAGE_ID RELEASE_ID ENVELOPE_SHA256 MANIFEST_SHA256 SOURCE_COMMIT_DIGEST SOURCE_BYTES SOURCE_SHA256
edge PARENT_NAME CHILD_NAME REQUIREMENT
```

Actual field separators are single tabs.
Every row ends with one LF; blank rows, CR, control bytes, and ambiguous encodings are invalid.
Roots precede nodes; nodes precede edges.
Names and parent-child edges use byte order.
The lock has a 1 MiB limit.
Every selected node and every declared dependency edge is retained.
Mirrors do not enter the lock's authority binding.
The envelope digest binds the complete explicit source and artifact metadata, including the source commit algorithm and target dimensions.

Use `asm registry sync` with the same project, target, and explicit trust inputs.
Sync authenticates each locked exact envelope and reconstructs the canonical graph before cache changes.
Every reconstructed byte must match the retained lock, including root requirements, node bindings, and edges.
Sync checks current lifecycle policy for every selected identity before and after materialization.
An artifact transfer cannot extend policy freshness or permit a revoked dependency.
It restores only checked archive bytes and preserves existing source trees unless their bytes already match.
Failures retain the previous lock and existing source files.
Verified cache entries added before a later failure can remain for a subsequent retry.

Normal optional-V2 builds require a graph lock when the project declares dependencies.
Build checking validates the root manifest digest, selected target, graph closure, reachability, version requirements, source declarations, and complete cached source bytes.
This local check does not fetch metadata, refresh lifecycle policy, or authenticate a project-controlled lock by itself.
Use sync to authenticate the lock against current registry policy before building.
Assembly includes remain explicit; the build is not a hermetic sandbox.

## Static website projection

The optional V2 site build reads an operator-selected public mirror and private download ledger.
It adds no public application process, database query, source-host request, or measurement request.
Assembly retains publication, package selection, lifecycle checks, mirror retries, and native installation logic.
Python performs the existing private build and registry operations; browser scripts enhance presentation.
The default V1 build and its released CLI routes remain separate.

Select the distribution root, immutable registry identity, and one to three HTTPS mirror bases explicitly.
The builder checks the current inventory, mutable timestamp binding, canonical release envelopes, original manifests, and complete lifecycle table.
It refuses a changed distribution during projection.
These checks validate operator input; they do not authenticate TUF signatures or retain client rollback state.
The cached website exposes its distribution revisions and never claims current client authority.

`registry/v2/index.json` uses schema `2` and preserves registry, package, and release identities.
It retains exact source commit algorithms, optional repositories, targets, artifact lengths, and digests.
It preserves ISA, operating system, ABI, required CPU features, and format separately.
The latest selection uses the highest active version; yanked and revoked releases retain separate inspection states.
Absent publication times remain unavailable; signing and build times never supply New or Recently updated dates.
No V2 input becomes a counterfeit V1 record or a V1 fallback.

Package, namespace, exact-version, browse, and statistics pages retain ordinary links and useful content without scripts.
Search runs locally against the explicitly selected V2 projection.
Commands use `asm registry fetch` with an exact version, registry, independently provisioned root, persistent state, mirrors, target, kind, and destination.
They require the preview client and do not install or execute a package.
The native client independently authenticates current metadata and rechecks lifecycle policy.
Disabled releases receive no new selection commands or download links.
Raw artifact links require explicit builder validation of the exact retained artifact bytes and structure.
Metadata validation does not set artifact, provenance, proof, or review evidence to a pass.

`registry/v2/downloads.json` retains the validated identity-scoped sender snapshot and its incomplete coverage.
Package pages use package counts; exact pages use the selected release count.
Rolling and retained totals remain separate, with cutoff, gaps, stale state, unknown counts, and observed zeros.
Daily charts show unreported intervals as gaps rather than interpolated or invented zeros.
Projection reads no blob unless artifact validation was explicitly requested.
Rebuild after distribution or log import; a timestamp-only renewal does not require a website rebuild.

The bounded flat projection is not global discovery-capacity evidence.
The optional V2 output is separate from the official root's installer, self-update trust, and V1 compatibility feeds.
An apex migration must preserve and qualify those routes before activation.

## Acceptance

The [V2 evidence record](../registry-v2-evidence.md) identifies tested hosts, artifacts, failures, and remaining gates.
The [earlier infrastructure record](../registry-infrastructure-evidence.md) retains the first publishing and storage checkpoints.
Source checks and the owned full-flow fixture do not activate a public service or qualify an arbitrary provider.

Test native publication through HTTPS with no source-host or CI credential.
Run the actual assembly API, PostgreSQL authority, checker, signed distributor, and native client.
Install through a second mirror, then deliberately run the installed fixture program.
Repeat the flow for source locators from the named Git hosts and an omitted locator.
Test task replay, revoked credentials, expired uploads, malformed manifests, immutable conflicts, and interrupted transfers.
Test wrong registry identity, changed root pins, expired metadata, rollback across restarts, rotation, mixed snapshots, and corrupt mirrors.
Test reversed distribution completion, stale leases, partial public writes, changed lifecycle policy, and uncertain final acknowledgment.
Test unsupported targets, corrupt executable containers, existing destinations, receipt collisions, and no implicit package execution.
Record each tested native host and exact executable digest.
Run the required CLI, verifier, registry, site, and existing server gates for their affected boundaries.
For graph qualification, compare bounded native solutions with an independent exhaustive oracle on small generated graphs.
Test shared dependencies, backtracking, consistent cycles, unsatisfiable constraints, numeric version order, and search exhaustion.
Test complete lock restoration, stale root manifests, omitted edges, orphan nodes, wrong authorities, unavailable metadata, and source declaration mismatches.
Confirm that resolve transfers no artifact blobs and that sync and builds retain exact versions.
Test lifecycle changes across all selected nodes, corrupt archives, existing edited sources, target mismatches, and mirror failures.
Record unresolved and failed graph checks in the dependency evidence record.
Production custody, deployed provider behavior, public ingress, capacity, spending, and isolated restoration remain separate activation evidence.

## Native project publication

This extension removes the need to prepare an archive or JSON manifest manually.
Assembly prepares the same canonical publication request and digest-named objects, then uses the existing upload workflow.
It does not add a public API route or change the publication schema.

Use `registry publish --project DIRECTORY` instead of `--manifest FILE --objects-dir DIRECTORY`.
The two input modes are mutually exclusive.
The project directory selects a local Git repository root.
`--source-path` selects a portable subtree, defaulting to `.`.
`--commit` accepts an exact nonzero SHA-1 or SHA-256 commit; otherwise resolve HEAD once.
Read files and the version from that committed subtree, independently of dirty and untracked working files.
Do not describe this as checking a clean working tree or verifying build provenance.
Keep the optional HTTPS source locator independent of the Git provider.

Require explicit `--name OWNER/NAME`, `--owner-id ID`, `--summary TEXT`, and `--license SPDX` values.
The unscoped committed project name must match the package suffix.
The committed manifest supplies the numeric version.
Select source tuples through repeated `--source-target TARGET` options, at most six.
Select prepared executables through repeated `--executable TARGET FILE` options, at most six.
Require at least one artifact selection; retain the mandatory archive even for executable-only publication.
Do not build, test, or execute project code during publication.

Assembly writes normalized USTAR headers and member data; fixed gzip supplies compression with its timestamp and filename disabled.
Use sorted portable ASCII paths, regular modes `0644` or `0755`, and zero ownership and timestamps.
Retain 4096 entries, 240-byte paths, 16 MiB files, and the complete 64 MiB expanded-stream limit.
Count headers, padding, and end markers inside that expanded limit.
Retain the publication's compressed-object, task-byte, and manifest bounds.
Reject case collisions, file/directory conflicts, links, submodules, and sensitive source filenames.
Apply the existing source exclusions for `.git`, `.asm`, `.venv`, `__pycache__`, `build`, and `dist` components.
Repeated Git blobs at different paths become separate regular members, never TAR hardlinks.
Validate every declared project target and inactive required input; registry selections still use only six supported tuples.
Read mandatory dependency declarations from the committed root manifest and retain them in the canonical publication request.
Reject unsupported feature or optional-dependency declarations and committed `asm.lock` before reading credentials.
Publication validates declarations without solving or downloading their dependency graph.

Use fixed Git plumbing and bounded output, with one unbuffered object-reader process.
Disable replacement objects, ambient global/system configuration, optional locks, external filters, lazy fetches, and network protocols.
Git can read the local repository metadata required to identify its object format and committed objects.
Finish Git reads, archive construction, executable snapshots, and validation before reading the publication credential.
Missing objects fail with no remote fetch, hook, or credential helper execution.
The new Git and compression runner sets a 120-second alarm and file caps, with direct arguments and checked termination.
Reused hashing and archive-decompression helpers retain byte bounds and status checks but have no separate wall-clock alarm.
The source archive binds the selected local commit's bytes; the executable's provenance remains a publisher assertion.

## V2 delivery observations

Artifact GET requests retain their existing physical digest key and append one canonical query:

```text
/blobs/sha256/SHA256?x-asm=REGISTRY_ID.PACKAGE_ID.RELEASE_ID.TARGET.KIND
```

The identifiers come from the authenticated release envelope.
They identify public package selections, not consumers.
The tuple and kind come from the selected authenticated artifact.
The client retains its ordinary length, digest, policy, and installation checks.
There is no additional telemetry request, cookie, device identity, or synchronous database write.

The normalized nginx exporter matches the complete raw query against that one ASCII grammar.
It accepts no encoded aliases, duplicate parameters, unknown parameters, or trailing fields.
It writes the existing eight-field private log shape with this virtual selection URI:

```text
/downloads/v2/REGISTRY_ID/PACKAGE_ID/RELEASE_ID/TARGET/KIND/SHA256
```

Never log the raw query, IP address, cookie, user-agent string, or referrer.
Untagged or malformed selections remain unattributed; their artifact bytes can still be served.
A valid tag does not authenticate a consumer or prove installation.

The private importer reads exact retained release envelopes through checked distribution descriptors.
It reads no artifact blob, archive, signing key, or database credential.
Pin the registry identity and each immutable envelope binding in the existing ledger before accepting events.
Reserved identity and binding rows are internal pins, not countable artifacts or synthetic transfers.
Reject mixed registry histories, V1/V2 ledger confusion, and changed metadata bindings before writes.
Well-formed requests with unknown or mismatched selections remain unattributed instead of blocking valid observations.
Retain their original event fingerprint, source/request deduplication, and raw batch digest under a noncountable reserved route.
Its expected byte length is `-1`, which no accepted event can match.
Malformed event syntax and additional private fields still fail the batch before writes.
Do not fabricate V1 package records or source URLs for V2 releases.

Count complete public GET responses with HTTP 200 and the exact declared byte length.
Exclude HEAD, ranges, redirects, conditional responses, failures, interrupted transfers, classified bots, and internal checks.
Deduplicate repeated reports by configured source and request identity.
Keep distinct complete requests separate; they do not identify distinct people.

The schema-2 snapshot identifies its registry, immutable package and release identities, display names, and reporting sources.
Counts use package and release identities; names alone cannot merge authorities or recreated selections.
Separate rolling and retained unattributed-request counters identify valid tagged requests without an accepted selection binding.
They never credit a package and do not estimate untagged, malformed, or unreported traffic.
Before a real reporting cutoff, counts remain null.
An imported empty interval establishes an observed zero only for that reporting source.
Retain lower bounds, gaps, stale state, the rolling thirty-day window, and retained totals.
The current website's V1 catalog is not silently rewritten or combined with V2 observations.
The bounded JSON snapshot can be published through static storage.

Use one counting layer per delivery path: edge viewer logs or origin misses, never both for the same request.
Unreported CDN hits and mirrors remain unknown.
Cloud storage adapters must sanitize provider logs before Asm persistence and need their own qualification.
Configure query-independent caching only for immutable public blob paths, with safe handling of response override queries.
Qualify GET-with-query behavior on each selected object provider and CDN before deployment.

Primary references inspected 8 November 2026:

- [Git object-reader protocol](https://git-scm.com/docs/git-cat-file).
- [Git 2.39.5 lazy-fetch refusal](https://raw.githubusercontent.com/git/git/v2.39.5/promisor-remote.c).
- [S3 logging and ignored `x-` query parameters](https://docs.aws.amazon.com/AmazonS3/latest/userguide/LogFormat.html).
- [Cloudflare cache keys](https://developers.cloudflare.com/cache/how-to/cache-keys/).
- [CloudFront query forwarding and caching](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/QueryStringParameters.html).
