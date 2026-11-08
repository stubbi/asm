# Provider-independent publication

Status: unreleased source implementation, 8 November 2026. No public service is activated.

This contract develops the [architecture](../architecture.md) and its [acceptance gates](../architecture-gates.md).
The user outcome is submitting exact package bytes from Entire, a local machine, or any CI system.
GitHub accounts, Actions, and release assets are not prerequisites.
Direct Asm credentials are the first authentication mechanism.
OIDC is an optional later integration.

The first [publisher migration](../../server/publisher/README.md) implements authenticated tasks, private uploads, checks, and recoverable immutable publication intent.
The separate [signed V2 profile](registry-v2.md) extends that intent through distribution, lifecycle policy, and native selection.
The assembly publisher execution checkpoint is Linux x86-64; package uploads retain all six declared targets.
Native client qualification is separate from that server host and from public deployment.
Source tests do not qualify every server port, dependency build, container, or deployment.

## Keep ownership independent

An Asm owner has an immutable 128-bit identity, encoded as 32 lowercase hexadecimal characters.
The operator selects owner and credential identities with a cryptographic random generator.
A namespace is a separately recorded display binding to that owner.
A package has its own immutable identity and an owner-scoped name.
A source repository, account name, or CI job does not establish ownership.

The initial operator procedure deliberately enrolls an owner, records the approved namespace, and issues a scoped credential.
It records the approving operator, enrollment evidence, time, and recovery authority.
It does not require a GitHub identity or invent one for an Entire owner.
Namespace conflicts fail without replacing the existing binding.
Public account creation, ownership transfer, and browser login are outside this first increment.
Their absence must remain visible in its operating instructions.

### Direct credentials

The bearer token has this exact shape:

```text
asm_pub_v1_ followed by 64 lowercase hexadecimal characters
```

The suffix contains 32 random bytes from a mature cryptographic random generator.
It is an opaque secret, not a JWT or a signed statement.
The private issuance tool saves it in an owned `0600` file without printing it.
Creation refuses an existing destination.
After an uncertain result, replay the same credential identity with `--reuse-token-file`.
That replay retains the token and original expiry; it does not renew the credential.
No token enters a URL, source repository, command argument, task response, or log.
Clients send exactly one `Authorization: Bearer TOKEN` header over HTTPS.

The retained credential record contains:

| Field | Constraint |
| --- | --- |
| Credential identity | Operator-selected random 32-character lowercase hexadecimal identity |
| Token digest | SHA-256 of the complete ASCII token; no retained plaintext token |
| Owner identity | One enrolled immutable owner identity |
| Packages | One to 32 exact `namespace/package` names; no wildcard |
| Operations | Explicit subset of `publish` and `task-read` |
| Times | UTC issuance and expiry; maximum lifetime 24 hours; default requested lifetime one hour |
| Revocation | Nullable UTC revocation time; reference and operator retained in the audit record |

`publish` permits task creation and task-bound uploads for the listed packages.
`task-read` permits reading that owner's tasks for those packages.
Issuance normally grants both operations.
Credentials grant no namespace administration, arbitrary object access, signing, or lifecycle operation.
A replacement credential can inspect an existing task when its owner and package scope match.
It does not restore an expired upload reservation.

The server rejects malformed, unknown, expired, or revoked credentials with the same HTTP 401 response.
It rechecks the current credential and namespace binding at each mutation.
Final intent commit rechecks the credential recorded for that task, including revocation during worker delays.
Revocation blocks future authorization; it does not erase committed releases or completed audit records.
Existing tasks retain their result and a useful failure reason.

The database uses mature PostgreSQL SHA-256 and an indexed token-digest lookup.
The complete 256-bit random secret is hashed; plaintext tokens are not retained in database records.
Do not implement custom cryptography in assembly or SQL.
Disable token-bearing parameter logging before using the publisher route.

## Freeze the V2 manifest

V1 records and native clients require GitHub URLs.
Keep their published bytes and parser unchanged.
Never invent a GitHub locator for an Entire package.
The following JSON is the exact field shape of the source checkpoint's V2 publication manifest:

```json
{
  "artifacts": [
    {
      "abi": "sysv-amd64",
      "bytes": 512,
      "cpu_features": [],
      "format": "tar.gz",
      "isa": "x86_64",
      "kind": "source",
      "os": "linux",
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ],
  "license": "MIT",
  "name": "example/hello",
  "owner_id": "11111111111111111111111111111111",
  "schema": 2,
  "source": {
    "archive": {
      "bytes": 512,
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "commit": {
      "algorithm": "git-sha1",
      "digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "path": ".",
    "repository": "https://entire.com/et/example/hello"
  },
  "summary": "An assembly example.",
  "version": "1.0.0"
}
```

The identifiers, lengths, and digests above are synthetic examples, not package evidence.
All displayed fields are required except `source.repository`.
Every object rejects unknown and duplicate fields.
The server allocates the package identity on its first authorized reservation.
The existing owner binding must match both `owner_id` and the namespace in `name`.

Names, numeric versions, summaries, license identifiers, and portable source paths retain the current V1 bounds.
A commit uses `git-sha1` with 40 lowercase hexadecimal characters, or `git-sha256` with 64.
Reject the all-zero commit identity.
The commit remains a publisher assertion unless independent provenance establishes its connection to the uploaded archive.

The optional repository locator is printable ASCII, at most 1024 bytes, with HTTPS and no credentials, query, or fragment.
It is descriptive metadata, never a fetch instruction or ownership proof.
A local project can omit it.
The retained source archive is mandatory, including for executable-only releases.
It uses the existing bounded, link-free source archive format.
Its `asm.toml` has an 8190-byte limit before TOML parsing.
Source artifact selections reference that same archive digest and byte length.

Each artifact declares the ISA, operating system, ABI, and required CPU features separately.
The initial tuple vocabulary preserves all six current registry targets:

| Compatibility target | `isa` | `os` | `abi` | Executable `format` |
| --- | --- | --- | --- | --- |
| `x86_64-linux` | `x86_64` | `linux` | `sysv-amd64` | `elf` |
| `aarch64-linux` | `aarch64` | `linux` | `aapcs64` | `elf` |
| `riscv64-linux` | `riscv64` | `linux` | `lp64d` | `elf` |
| `aarch64-macos` | `aarch64` | `macos` | `apple-arm64` | `macho` |
| `x86_64-windows` | `x86_64` | `windows` | `windows-x64` | `pe` |
| `aarch64-windows` | `aarch64` | `windows` | `windows-arm64` | `pe` |

`kind` is `source` or `executable`; source selections use `format: "tar.gz"`.
The publisher supplies every target field; the service does not fill one from another.
The first profile accepts only an empty `cpu_features` array.
This declares no extension beyond the named ISA and ABI baseline; the RISC-V baseline is RV64GC/LP64D.
Additional features require a versioned allowlist and matching selection checks.
Container checks do not establish that instructions satisfy every declared CPU requirement.
Unsupported features or target tuples fail before reservation or file creation.
Publisher execution on Linux x86-64 does not limit uploaded package targets to that host.

A manifest contains one to fourteen distinct target-and-kind selections.
One digest cannot declare different byte lengths.
Every object uses a lowercase SHA-256 and a length from one byte through 64 MiB.
Count the source archive and distinct artifact digests once toward the 128 MiB task limit.
There are at most fifteen distinct uploaded objects.
The optional `dependencies` array contains same-registry declarations, sorted by package name without duplicates.
Each object requires `name` and `requirement`.
It permits Boolean `optional` and `default_features`, plus a sorted requested `features` array.
Their defaults are false, true, and an empty array.
The optional top-level `features` array contains sorted closed objects with `name` and `members`.
All lists have at most 64 entries; native feature text has an 8192-byte limit.
The [V2 feature contract](registry-v2.md#feature-activation) defines activation and the source-manifest syntax.
The checker compares full declarations with the exact archived source manifest, including inactive declarations.
Missing child features are a resolver compatibility decision, not a publication identity check.
Unknown fields, duplicate names or members, invalid references, and local feature cycles fail validation.
Existing feature-free publication bytes remain unchanged.
Publisher-supplied check results, executable validation commands, and artifact URLs remain unsupported.
Unsupported fields are errors rather than ignored input.
Asm constructs retained object locations under its configured storage origin.

### Canonical JSON and errors

Control requests use `application/json`, printable ASCII field values, and integer numbers without exponent or fractional encodings.
Reject a byte-order mark, invalid UTF-8, control characters, duplicate fields, and nesting beyond sixteen levels.
The create body has a 65536-byte limit.
Its exact bytes must match the existing canonical JSON encoding: sorted object keys, two-space indentation, and one final LF.
Arrays keep their declared order.
SHA-256 of those complete bytes is `manifest_sha256`.
Canonicalization must not silently repair an ambiguous or invalid request.

A mature JSON library can validate the bounded body.
Alternatively, PostgreSQL can validate raw `json` before conversion to `jsonb` and compare its canonical encoding.
Assembly passes raw bytes through a fixed parameterized statement and handles the typed result.
It must not implement an unqualified JSON parser or interpolate request text into SQL.

Errors use `application/problem+json` with `type`, `title`, `status`, `detail`, `code`, and `retryable`.
`type` is `urn:asm:publication:error:CODE`; the HTTP status and `status` field agree.
`detail` gives a fixed problem statement and recovery action without input bytes or provider diagnostics.
The problem format follows [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html), checked 7 November 2026.

| HTTP status | Stable `code` | Recovery |
| --- | --- | --- |
| 400 | `invalid_request` | Correct the schema, canonical encoding, headers, or identifier |
| 401 | `invalid_credential` | Obtain a current direct credential; do not retry the same secret |
| 403 | `not_authorized` | Request the required owner, package, or operation scope |
| 404 | `task_not_found` | Check the task identity; another owner's task is also absent |
| 409 | `publication_conflict` | Inspect the existing task or version; do not replace its bytes |
| 410 | `upload_expired` | Create a new task with a fresh key and current credential |
| 413 | `limit_exceeded` | Reduce the declared request or object size |
| 415 | `unsupported_media_type` | Use the route's fixed content type |
| 422 | `artifact_invalid` | Resend the declared bytes; a changed manifest needs a new task |
| 429 | `admission_limited` | Wait for the bounded `Retry-After` interval |
| 503 | `temporarily_unavailable` | Inspect the task before replaying the same operation |

Only temporary admission or dependency failures set `retryable: true` in an HTTP error.
A task's retained failure separately identifies its safe recovery action.
HTTP 401 includes `WWW-Authenticate: Bearer realm="Asm publication"` for missing, malformed, unknown, expired, and revoked credentials.
Use a bounded `Retry-After` value from one through sixty seconds for HTTP 429 or 503.
Expired or revoked current credentials fail authorization.
A current credential cannot renew an expired upload reservation; the upload returns HTTP 410.
Cleanup and reservation release require expiry processing.

## Implement three task routes

Every route requires a current direct credential and returns `Cache-Control: no-store`.
Reject query fields and unsupported methods.
Control responses have a 65536-byte limit.
The first increment needs no token-exchange, commit, cancellation, account, or forge-specific HTTP route.

| Route | Request and result |
| --- | --- |
| `POST /api/v2/publications` | Canonical manifest body; authorize, reserve, and return HTTP 202 with a durable task and `Location` |
| `GET /api/v2/publications/{id}` | No body; require `task-read`; return HTTP 200 with that owner's task |
| `PUT /api/v2/publications/{id}/artifacts/{sha256}` | `application/octet-stream`; require `publish`; upload one declared object, including the source archive |

Task identities and `Idempotency-Key` values are 32 lowercase hexadecimal characters.
The POST requires exactly one `Idempotency-Key` header.
Its durable identity is the owner identity, create operation, and supplied key.
The database retains that identity with `manifest_sha256` in the task transaction.
An authorized retry with identical bytes returns HTTP 200 and the same task.
A different body under that key returns HTTP 409 without changing state.
A concurrent reservation cannot replace another task's active package-version reservation.
The native client can prepare committed projects or read explicit prepared manifests and objects.
Both modes use the same canonical request and durable task routes.
Project preparation performs no implicit build or source-host fetch.
The native client validates response bindings before using object receipts.
It skips received objects, uploads only missing declared bytes, and performs a final task read.

The task representation has exactly these fields:

| Field | Shape |
| --- | --- |
| `schema`, `id`, `package_id` | Integer `2`, task identity, immutable package identity |
| `manifest_sha256` | Digest of the accepted canonical manifest |
| `state` | `accepted`, `uploading`, `checking`, or `committed`; the distribution migration adds `distributing` and `published` |
| `upload_expires_at` | UTC `YYYY-MM-DDTHH:MM:SSZ`; creation plus at most 24 hours, capped by credential expiry |
| `objects` | Digest-sorted array of exact `{sha256, bytes, received}` objects; `received` is Boolean |
| `failure` | Null, or exact `{code, detail, retryable}` with a fixed code and recovery instruction |
| `release` | Null until completed distribution; exact `{manifest_url, metadata_url}` only after `published` |

`committed` establishes immutable intent, not completed delivery.
`distributing` identifies an intent in an active frozen distribution batch.
`published` requires the authoritative distribution receipt and exposes its exact signed target and metadata URLs.
These states do not change the underlying committed task or free its version reservation.

The server reports object receipt only after the full upload is durable.
A PUT requires an exact, single `Content-Length` matching the declared object.
Reject conflicting lengths, transfer encoding, undeclared digests, and expired reservations before accepting body bytes.
Stream into a private task stage with explicit byte, time, and concurrency bounds.
A failed or interrupted transfer preserves earlier complete uploads and exposes no partial object.
The same task route permits retrying the complete object; partial-range uploads are outside this increment.
A first complete receipt returns HTTP 201; an exact replay while uploads remain authorized returns HTTP 204.
A replay still checks the supplied bytes; it cannot overwrite a corrupt or different retained object.
Committed tasks no longer accept uploads; native replay uses their durable receipts instead.
Receipt establishes complete private transfer, not a successful archive or executable check.

The last required receipt durably queues checking in the same transaction as its receipt record.
It does not synchronously wait for validation or create another public endpoint.
The response and later GET show the resulting durable task state.
A process restart must preserve completed object receipts, task identity, and queued work.

The source uses conservative admission limits:

| Scope | Enforced limit |
| --- | --- |
| One owner | 64 accepted attempts per rolling 24 hours; eight active tasks; 1 GiB cumulative declared object bytes |
| Whole registry | 4096 retained attempts; 64 active tasks; 32 GiB cumulative declared object bytes |
| One task | 128 MiB of distinct declared object bytes; fifteen objects; 64 MiB per object |

Every accepted attempt retains its byte charge after failure or expiry.
Uncertain storage writes can leave unreferenced objects, so the ledger does not assume that failed bytes disappeared.
Repeated digests are charged per accepted task; exact task replay adds no charge.
These limits are source controls, not measured capacity, provider bills, or spending alerts.
Physical concurrent-upload storage, crash leftovers, and deployment spending ceilings need separate qualification.

The upload deadline bounds authorization to complete private staging.
An expiry operation fences old workers before releasing an uncommitted version reservation.
It releases active-task slots and returns object identities for separate cleanup reconciliation.
It retains tasks, receipts, idempotency records, audit history, and their cumulative storage charges.
No automatic staging cleanup, retained-object deletion, or quota credit is supplied.
A terminal check failure also fences its attempt before releasing the uncommitted reservation.
Revoked grants receive that reservation cleanup through expiry processing; final authorization refuses them immediately.
A corrected manifest needs a fresh idempotency key and an authorized new task.
The failed task remains inspectable and cannot later commit through an old worker.

## Preserve application and database boundaries

Keep the assembly reader and its database role read-only.
Use a separate assembly publisher process with narrowly scoped database functions.
Reuse the existing HTTP and PostgreSQL libraries and reviewed connection policy.
Assembly owns request routing, authorization invocation, bounds, streaming state, and task orchestration.
SQL enforces transactional authorization checks, canonical records, uniqueness, and immutable state transitions.
Fixed parameterized calls must replace whole-catalog import authority on this path.
No public request can call the existing `asm_catalog.publish` operator function.

The check coordinator is a private registry operator, not another HTTP application backend.
Its credential-free checker requires an independently qualified isolation boundary.
It accepts only fixed task-bound inputs and approved checker commands.
It receives private staging reads and narrow, fenced result-recording authority.
It receives no namespace administration, signing key, source-host credential, or general production credential.
It must not execute submitted packages, builds, tests, proofs, or hooks.
Its receipt binds the task, manifest digest, each object digest and length, checker revision, policy digest, and outcome.
The assembly workflow accepts only the current fenced attempt and matching receipt.
A checker result cannot authorize publication by itself.

Use PostgreSQL leases and an outbox initially.
An outbox is an event committed in the same transaction as its authoritative state change.
Keep transient worker retries within the active task and credential deadlines.
Final commit rechecks current namespace ownership, package scope, credential expiry, revocation, and the complete receipt.
It reserves the immutable version and event atomically.
After `committed`, different bytes cannot reuse that version.
Failures retain the last completed state, fixed failure code, and recovery guidance.
Do not skip late commits by consuming only increasing allocated event IDs.

### Migration and compatibility

The first publication migration adds owner identities, credential digests, tasks, object receipts, leases, reservations, and outbox records.
Never edit the installed V1 migration or reinterpret its GitHub bindings as authenticated Asm owners.
Keep all authoritative publication state in the canonical PostgreSQL authority.
Task tables are not a second public catalog.
Each migration has its own pinned marker and compatibility checks for the reader guard and existing operator procedure.
Retain V1 release records, licenses, audit history, exact four exports, and their current permissions.
Revoke public execution of new functions and deny their mutation grants to the reader.
Grant each publisher and checker role only its fixed task functions.

A checked V2 intent must not enter a V1 export through fabricated URLs or a relaxed validator.
The first migration retains checked immutable intent without making it installable.
The separate distribution migration and private operator bind authenticated V2 metadata to that exact intent.
Only complete distribution can transition it to `published` and expose final release links.
It must not fall back to V1 after failed V2 authentication.

## Keep later extensions separate

Private operator commands implement separately authorized and audited yank, unyank, and irreversible emergency revocation.
The [signed V2 profile](registry-v2.md) carries that policy to native clients.
Public lifecycle endpoints, ownership transfer, and self-service enrollment remain outside this task API.

OIDC means OpenID Connect, an identity protocol based on signed tokens.
An optional later exchange can grant the same owner, package, operation, and expiry scopes as a direct credential.
Its enrollment fixes the issuer, audience, stable principal claims, workflow, and release context.
It must not accept an arbitrary discovery URL from a request.
Each adopted issuer needs substitution, replay, expiry, rename, rotation, and ownership-change tests.
No CI issuer is required to implement or qualify the direct-credential workflow.

Entire supports native Git repositories and integrations with several CI providers.
Depot documents OIDC for Entire repositories under its `https://identity.depot.dev` issuer.
Its Entire subject includes `ci/entire` and the complete repository namespace.
Preserve the distinction between Entire-native `et/...` repositories and mirrored `gh/...` repositories.
Buildkite supplies its own OIDC issuer and job policies.
Its Entire integration is in preview.
GitHub Actions is another optional issuer.
These facts were checked on 7 November 2026:

- [Entire native hosting](https://entire.com/features/code-hosting).
- [Depot's Entire integration and OIDC](https://preview.depot.dev/docs/ci/integrations/entire).
- [Buildkite's Entire integration](https://buildkite.com/docs/pipelines/source-control/entire).

These sources do not establish that Asm supports those issuers today.
Do not assume that Entire itself issues a suitable publication token.

## Acceptance and activation

The direct increment needs real assembly API tests with synthetic credentials and an owned temporary database.
Test an Entire source locator, an omitted locator, and uploads without GitHub or CI credentials.
Compare exact accepted bytes after process restarts, retries, conflicts, and interrupted transfers.
Test unauthorized namespaces, concurrent versions, changed payload retries, revoked credentials, expired tasks, stale workers, and reordered completion.
Check all six artifact targets and hostile archives under fixed resource limits.
Retain a rejection result for unsupported targets and CPU features.
Test failed-transfer cleanup and preservation of retained bytes.
Expired-task staging reconciliation remains separate from automatic upload cleanup.
The existing read-only runtime and four export regressions must continue to pass.

Qualify HTTP parsing, mature-library ABI calls, isolation, upload deadlines, quotas, and the complete worker receipt boundary.
Do not claim an implemented publisher from SQL tests or a successful operator import alone.
The first publisher execution checkpoint may qualify Linux x86-64 separately from later server ports.
Its host scope does not change package target support.

The unreleased signed V2 source reuses the maintained TUF boundary in `asm-verify`.
Production signing custody, independent root delivery, critical-policy operation, and restoration still require activation evidence.
An air-gapped mirror cannot learn new revocations; it needs an explicit offline policy and visible last policy checkpoint.
A digest match cannot establish freshness or publisher identity.

Before activation, the operator must approve owner enrollment, recovery authority, storage semantics, quotas, spending limits, TLS, and backup identities.
Actual source implementation can use synthetic identities and private fixtures before those operating choices are made.
Code, tests, deployment, and external-client qualification remain distinct evidence.
