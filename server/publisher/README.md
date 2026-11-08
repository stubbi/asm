# Direct publication source checkpoint

Status: unreleased source implementation, 8 November 2026. No public service is activated.

The user outcome is submitting exact package bytes without depending on GitHub, GitHub Actions, or a particular source host.
Entire repositories and local projects use the same scoped Asm credential contract.
This follows the foundation's dependable reuse, resource care, control, and evidence principles.

The separate Linux x86-64 `asm-publisher` process uses assembly for HTTP application state and orchestration.
GNU libmicrohttpd 1.0.3 handles HTTP; libpq 16.15 handles PostgreSQL and TLS; OpenSSL handles upload hashing.
The default reviewed publisher profile is OpenSSL 3.5.9.
The explicit `3.0.22-fixture` profile retains earlier local evidence; it is not a production dependency selection.
OpenSSL's [release policy](https://openssl-library.org/policies/releasestrat/), checked on 7 November 2026, lists 3.0 as unsupported and 3.5 LTS through April 2030.
Before activation, qualify the deployed dependency build and its security maintenance policy.
PostgreSQL enforces the bounded manifest, current authorization, transactional state, and immutable publication intent.
Python supplies private operator commands, credential-free checks, and test orchestration.
The existing [assembly reader](../README.md) retains its read-only role and four V1 exports.

The first migration implements task creation, private uploads, scoped task reads, leased checks, immutable intent, and a transactional outbox.
It stops at `committed`; that state is not a published package.
The separate distribution migration adds fenced signed-distribution receipts, published state, and audited lifecycle operations.
The optional `asm registry` client publishes, reads tasks, fetches, and installs under the [signed V2 contract](../../docs/specs/registry-v2.md).
Public accounts and ownership transfer remain outside this checkpoint.
The existing `asm publish` command still prepares a local record; `asm registry publish` invokes this API with prepared files.

Publisher status reports `source-build-only`, `declared_source_revision`, and `declared_source_url`.
The source values are operator declarations; they do not establish a clean source commit, release, or provenance.
Use the executable SHA-256 and exact source-file SHA-256 records to identify this uncommitted checkpoint.
`/health/ready` checks the current request role, pinned schema, and database read boundary.
It does not establish published distribution, native V2 verification, worker isolation, deployment qualification, or recovery.

## Build the reviewed library profile

Use Linux x86-64, GNU libmicrohttpd 1.0.3, and PostgreSQL/libpq 16.15 for this publisher checkpoint.
The build-only ABI check requires the selected exact OpenSSL headers and matching runtime version.
It also checks the EVP function signatures and runs a SHA-256 smoke check.
Unknown profiles fail before output creation.
The reader target does not select a publisher crypto profile.

OpenSSL 3.5.9 was the current 3.5 LTS patch when inspected on 7 November 2026.
Its [official release](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9) is dated 29 September 2026.
The [official archive checksum](https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz.sha256) is:

```text
603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
```

The [versioning policy](https://openssl-library.org/policies/general/versioning-policy/) preserves public API and ABI compatibility within major version 3.
These policy statements do not replace the concrete header, loader, and application checks.
Archive checks established a digest match; no detached-signature verification is claimed.

Use a writable private installation prefix for this local recipe.
Protect deployed libraries from service-account writes before activation.
Run the source build outside the Asm checkout:

```sh
curl --fail --location --proto '=https' --proto-redir '=https' --max-time 120 \
  --output openssl-3.5.9.tar.gz \
  https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
printf '%s  %s\n' \
  603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a \
  openssl-3.5.9.tar.gz | sha256sum --check --strict
tar -xzf openssl-3.5.9.tar.gz
cd openssl-3.5.9
./Configure linux-x86_64 shared no-tests \
  --prefix=/opt/asm-openssl-3.5.9 \
  --openssldir=/opt/asm-openssl-3.5.9/ssl --libdir=lib
make -j2 build_libs
make install_dev
```

The checksum command must print `openssl-3.5.9.tar.gz: OK` before extraction.
This recipe builds the libraries and development files, without applications, documentation, or upstream OpenSSL tests.
Keep the OpenSSL license and source notices with retained library artifacts.

Run the publisher gate from the Asm repository root:

```sh
make -C server publisher-test \
  'CC=cc -I/opt/asm-openssl-3.5.9/include -L/opt/asm-openssl-3.5.9/lib -Wl,--disable-new-dtags,-rpath,/opt/asm-openssl-3.5.9/lib' \
  MHD_PREFIX=/opt/asm-mhd PG_PREFIX=/usr/lib/postgresql/16 \
  PG_LIB_DIR=/usr/lib/x86_64-linux-gnu PG_INCLUDE_DIR=/usr/include/postgresql \
  PUBLISHER_OPENSSL_PROFILE=3.5.9 SOURCE_REVISION=FULL_COMMIT_ID
```

Replace `FULL_COMMIT_ID` with the declared source revision.
The dependency paths above reproduce the owned Debian Bookworm fixture; other installations need their reviewed paths.
`CC` and its paths are trusted operator configuration, never package input.
`DT_RPATH` selects the same private prefix for libpq's indirect `libssl.so.3` dependency.
An executable-only `DT_RUNPATH` does not establish that indirect selection.
Use `PUBLISHER_OPENSSL_PROFILE=3.0.22-fixture` only to reproduce the earlier unsupported-library fixture.

On 7 November 2026, the supported-library gate passed all 16 HTTP methods in 101.810 seconds.
A later raw-log handoff build passed the same 16 methods in 97.058 seconds.
The methods included the actual 60-second upload deadline, interrupted transfers, immutable retries, authorization failures, and the real intent coordinator.
The separately retained ABI compile and runtime check exited with status zero.
The final process mappings contained both libraries under `/opt/asm-openssl-3.5.9/lib/`.
`ldd` and the ELF `DT_RPATH` record agreed with those live mappings.

| Retained handoff artifact | SHA-256 |
| --- | --- |
| `asm-publisher-openssl359` | `78dc5d884e3045db4beea0fc54d2d9c7e7f621ca9afdc1202fe7b26a12d6c063` |
| `libcrypto.so.3` | `7b0206e5342d03a686bc6d0c6cb0ce8b79ac43e36fde7b88747b47c264d48405` |
| `libssl.so.3` | `83a963dfc76672d91efad7ddbd151b8d9dfea69c1080b4980520d56566b35696` |

The earlier successful build had executable digest `15147bbe0123c59c133527c3e5ee9682626350ba7d5ac95a0fa16693a52a8773`.
These are distinct build artifacts; reproducible-build equality was not established.
The handoff executable is retained locally under `build/qualification/`; it is not a released download.

The first library build reached its configured 20-minute timeout and returned exit status 124.
Its failed log remains retained.
One unchanged incremental continuation, bounded to ten minutes, completed successfully with two build jobs.
The final build tree used 217 MiB; the installed prefix used 24 MiB; the guest archive used approximately 51 MiB.
The host archive copy used another approximately 51 MiB.
These local observations stayed below the 500 MiB incremental disk ceiling; they are not capacity or operating-cost measurements.

Library ABI and API checks do not qualify production deployment or upstream cryptographic conformance.
No FIPS validation, public ingress, deployment image, package release, signing authority, or recovery result follows from this checkpoint.

## Prepare private authority

Use Python 3.11 or later and the reviewed PostgreSQL 16.15 `psql` executable for operator commands.
Use separate certificate-only connection files for `asm_migrator`, `asm_operator`, and `asm_publication_worker`.
The [canonical operator procedure](../catalog/README.md#operator-procedure) defines their protected files and TLS prerequisites.
The publisher's connection file uses `asm_publisher` instead.
Keep all connection files, private keys, token files, and their parent directories outside public storage.

Apply the pinned canonical catalog migration before this migration.
Retain the existing canonical roles and their grants.
A trusted database administrator must create these additional roles:

```sql
CREATE ROLE asm_publisher LOGIN NOINHERIT NOSUPERUSER NOCREATEDB
  NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE asm_publication_worker LOGIN NOINHERIT NOSUPERUSER NOCREATEDB
  NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE asm_publisher SET log_parameter_max_length=0;
ALTER ROLE asm_publisher SET log_parameter_max_length_on_error=0;
ALTER ROLE asm_publication_worker SET log_parameter_max_length=0;
ALTER ROLE asm_publication_worker SET log_parameter_max_length_on_error=0;
```

Grant database connection access through the existing private database procedure.
Issue each role its own client certificate.
Do not grant role membership, direct table writes, schema creation, or migration authority to either process role.
The migration grants only its named functions.
Publisher readiness refuses extra write authority, unexpected role membership, and token-bearing parameter logging.
It requires a writable `READ COMMITTED` transaction and the exact publication migration digest.
Trusted administrators still control database logging and can change these boundaries.

Replace uppercase placeholders before each command.
Run commands from the repository root.

```sh
python3 tools/publisher_admin.py \
  --connection-file MIGRATOR_FILE --psql PSQL_PATH migrate
```

Expected output is one JSON object with `status: "migrated"`, schema `1`, and the migration SHA-384.
An exact migration replay preserves its installed state.
The reviewed migration SHA-384 is:

```text
e78431a236e7d51945ab767b4318d62f2f04f2cb0289988ed8df930d5fb4ba4604fd8ec0b35d5ef2ecffe7bb4b95ba44
```

These bytes replace the unpublished V2 fixture schema.
Rebuild an older fixture database before testing this schema.
For an installed database, prepare a reviewed upgrade migration.
Do not change its installed migration history.

The runtime embeds the digest of its selected migration file.
`asm_publication.publisher_ready(EXPECTED_SHA384)` returns exactly `1` only when the inspected request boundary passes.
That marker establishes neither deployment health nor storage recovery.
Do not edit an installed migration in place.
This unreleased source revision adds optional dependency declarations and changes the earlier fixture migration digest.
An older installed fixture does not pass the new pin.
Use a separate migration before adopting this revision in an existing installation.
The earlier evidence retains its measured migration digests.

## Enroll an owner and issue a credential

Generate separate owner and credential identities with a cryptographic random generator.
Each identity contains 16 random bytes encoded as 32 lowercase hexadecimal characters.
Record the enrollment evidence and accountable recovery authority before granting a namespace.
Use their retained reference in the operator audit record.

```sh
python3 tools/publisher_admin.py \
  --connection-file OPERATOR_FILE --psql PSQL_PATH enroll \
  --owner-id OWNER_ID --namespace NAMESPACE --reference ENROLLMENT_REFERENCE
```

Expected output has `status: "enroll-completed"`.
Enrollment is an operator assertion, not verified GitHub, Entire, or publisher provenance.
A conflicting namespace or owner binding fails without replacing the retained binding.

Create an owned private directory for the token file.
The following command grants one exact package and both publication operations:

```sh
python3 tools/publisher_admin.py \
  --connection-file OPERATOR_FILE --psql PSQL_PATH issue \
  --owner-id OWNER_ID --credential-id CREDENTIAL_ID \
  --package NAMESPACE/PACKAGE --operation publish --operation task-read \
  --ttl-seconds 3600 --token-file /private/asm/publisher.token \
  --reference ENROLLMENT_REFERENCE
```

Expected output identifies the credential, token file, and `requested_ttl_seconds`.
It never contains the token value.
The file uses mode `0600`; creation refuses an existing destination.
The database retains only the complete token's SHA-256, exact package and operation scopes, times, and revocation state.
A credential permits one to 32 exact packages and a lifetime no longer than 24 hours.
It grants no namespace administration, signing, or lifecycle authority.

After an uncertain result, preserve the token file and credential identity.
Replay the same issue command with `--reuse-token-file`.
That replay preserves the original expiry; `requested_ttl_seconds` is not remaining validity.
A changed lifetime, package set, operation set, or token under the same credential identity fails.
Issue a new identity and token for a replacement grant.
Reuse follows trusted operator-supplied parent paths and checks the final file; it is not a descriptor-anchored directory traversal.

```sh
python3 tools/publisher_admin.py \
  --connection-file OPERATOR_FILE --psql PSQL_PATH revoke \
  --credential-id CREDENTIAL_ID --reference REVOCATION_REFERENCE
```

Expected output has `status: "revoke-completed"`.
Revocation blocks subsequent authorization and final intent commit.
It retains committed intent, prior task results, and audit history.
Never put token values in command arguments, URLs, source files, or logs.
Use a client that reads protected credential files.

## Submit and check a task

The [publication contract](../../docs/specs/publication.md) defines the exact V2 manifest and request fields.
It requires canonical ASCII JSON, at most 64 KiB, without duplicate or unknown fields.
Source records use an algorithm-tagged Git commit and a mandatory retained source archive.
An optional HTTPS source locator is descriptive metadata; no worker fetches it.
The commit remains a publisher assertion unless independent provenance checks establish the source binding.

Artifacts declare ISA, operating system, ABI, CPU requirements, format, length, and digest separately.
All six existing compatibility targets are accepted: Linux x86-64, AArch64, and RISC-V; Apple Silicon macOS; Windows x86-64 and ARM64.
The initial CPU feature array must be empty.
Source and executable container checks do not prove instruction compatibility or general safety.
Each unique object permits 64 MiB; each task permits 128 MiB and fifteen unique objects.
The profile accepts bounded dependency and feature declarations.
It rejects publisher-supplied check results and artifact URLs.
Metadata validation does not resolve dependencies or run package code.

| Request | Successful result |
| --- | --- |
| `POST /api/v2/publications` | HTTP 202 and a durable task; exact authorized replay returns HTTP 200 |
| `GET /api/v2/publications/{id}` | HTTP 200 and the current owner's scoped task |
| `PUT /api/v2/publications/{id}/artifacts/{sha256}` | HTTP 201 after durable checked transfer; exact receipt replay while uploads remain authorized returns HTTP 204 |

Task responses use schema `2` and distinguish object receipts, failure, and immutable intent state.
They never expose a usable release while distribution remains incomplete.
`accepted` means a durable task exists; `uploading` means some object receipts exist.
`checking` means every declared transfer has a receipt, not that structural checks passed.
`committed` means the retained immutable intent exists and its outbox event was committed atomically.
With migration two, `distributing` identifies an intent in the active frozen batch.
`published` requires a completed distribution receipt and exposes its exact signed target and metadata URLs.
The internal task remains committed; expiry and quota rules do not reopen a published version.
The native client checks task identity, manifest digest, and each object's digest and length before using receipt flags.
It uploads only objects without a durable receipt and finishes with a task read.
Replay after commit or publication therefore sends no redundant PUT.

`make registry-cli` builds the optional native client on supported native CLI hosts.
Root, retained trust state, and optional CA paths for fetch or install must be protected, clean absolute paths.
The client selects an exact package version, explicit target, artifact kind, and at most three ordered HTTPS mirrors.
It never executes a downloaded package or falls back to V1 after V2 verification fails.
Native project mode prepares committed dependency-free source archives and a canonical manifest before using the same publication API.
It requires Git and accepts prepared executable files without building or executing package code.
The [hosting guide](../../docs/hosting.md#use-the-native-v2-preview) defines its inputs and recovery procedure.
Dependency support and self-service enrollment remain outside this profile.

The source publisher binds only to loopback and requires an owned `0700` upload directory.
Configure `ASM_BIND`, `ASM_DATABASE_URL_FILE`, and `ASM_UPLOAD_ROOT` before starting `asm-publisher serve`.
HTTP parsing, TLS configuration, private filesystem boundaries, length, digest, and time limits remain separate checks.
Public TLS, ingress restrictions, exact images, resource saturation, and deployed client flows still require qualification.

Select the trusted checker revision and exact policy digest before running checks:

```sh
python3 tools/publication_check.py policy

python3 tools/publisher_admin.py \
  --connection-file OPERATOR_FILE --psql PSQL_PATH check-policy \
  --checker-revision CHECKER_COMMIT --policy-sha256 POLICY_SHA256 \
  --reference POLICY_REVIEW_REFERENCE
```

The first command prints the policy SHA-256.
The second returns `status: "check-policy-completed"`.
The policy binds the exact checker, registry validator, and storage-boundary source bytes.
A worker cannot select another policy merely to obtain a pass.

The private [worker command](../../tools/publication_worker.py) claims a fenced lease through its separate database identity.
Its checker receives private copies of only the selected task manifest and declared objects.
The Docker executor selects a preloaded image by digest, disables networking and capabilities, and mounts task inputs read-only.
It rejects image-declared volumes, which could otherwise permit unbounded writes despite a read-only root.
It mounts no database file, object-store credentials, Docker socket, or signing key inside the checker.
The coordinator and Docker daemon must see source and work paths at the same absolute locations.
The [local evidence record](../../docs/registry-infrastructure-evidence.md) records the actual container checks and their limits.
The checker executes no package, build, test, proof, or source-host command.

Use a separate private retained store for this V2 checkpoint.
Do not select the public V1 mirror or expose pending V2 blobs through a bucket domain, CDN, or directory listing.
An authorization change can occur after object placement but before intent commit.
Storage hashes do not enforce bucket privacy.
The distribution operator exposes only eligible committed intent under its authenticated publication policy.

Run one check job with the selected private store and preloaded runtime:

```sh
python3 tools/publication_worker.py \
  --connection-file WORKER_FILE --psql PSQL_PATH \
  --staging /private/asm-uploads --work-root /private/asm-check-work \
  --worker-id WORKER_ID --docker /usr/bin/docker \
  --docker-socket /var/run/docker.sock \
  --checker-image RUNTIME_AT_SHA256 --checker-revision CHECKER_COMMIT \
  --store local --root /private/asm-v2-retained
```

Create the owned `0700` work directory before running the job.
Replace uppercase placeholders before use.
The runtime image must supply Python 3.11 or later at `/usr/bin/python3` and declare no volumes.
Select its exact `NAME@sha256:DIGEST` or locally loaded `sha256:IMAGE_ID`; mutable tags are refused.
The command never pulls an image.
An empty queue is quiet; a processed job returns bounded JSON describing its authoritative result.
Schedule repeated jobs and separate expiry reconciliation through the private operating system or cluster job mechanism.
Use the hosting guide's S3 options only with a separately reviewed private destination and scoped writer.

The coordinator retains verified objects and the exact V2 manifest before final intent commit.
SQL then rechecks the recorded credential, namespace binding, current checker policy, object bindings, and worker fence.
Missing staging input produces `error`; malformed package structure produces `fail`.
Check failures and transient retries retain their receipts.
An uncertain database result preserves staged and retained bytes for reconciliation.
The current 60-second lease does not renew during a slow check or storage transfer.
A lost lease refuses commit; repeated processing can reuse verified retained bytes.
An unavailable Docker daemon can leave job cleanup uncertain and requires operator reconciliation.
The outbox claims pending rows explicitly; it never skips events by using an allocated event ID as a commit watermark.

## Bound storage and recovery work

| Scope | Initial enforced limit |
| --- | --- |
| One owner | 64 accepted attempts in a rolling 24 hours; eight active tasks; 1 GiB cumulative declared object bytes |
| Whole registry | 4,096 retained attempts; 64 active tasks; 32 GiB cumulative declared object bytes |
| One check lease | At most 60 seconds; a later claim changes its fence |
| One expiry call | At most 128 tasks |

These are conservative source limits, not measured capacity, a provider bill, or production spending alerts.
Failed and expired attempts retain their storage charge because uncertain writes can leave unreferenced immutable objects.
Repeated artifact digests remain charged per accepted task; this favors a safe bound over estimated deduplication savings.
An exact task replay does not create another charge.
Do not raise a limit or grant another identity to bypass a full budget without reviewing retained storage and recovery.

The private `asm_publication.expire_tasks(LIMIT)` function fences expired or revoked uncommitted tasks.
It releases their version reservations and active-task slots.
It returns their task identities and declared objects for separate cleanup reconciliation.
It does not delete staged files, retained objects, tasks, receipts, audit records, or storage charges.
Allow up to 256 KiB for its largest response.
There is no automatic garbage collector or storage-quota credit mechanism.
Never free a committed version for different bytes.

## Add signed distribution authority

Apply distribution only after the publication migration above.
Create a separate private distributor role:

```sql
CREATE ROLE asm_distributor LOGIN NOINHERIT NOSUPERUSER NOCREATEDB
  NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE asm_distributor SET log_parameter_max_length=0;
ALTER ROLE asm_distributor SET log_parameter_max_length_on_error=0;
```

Issue its own certificate through the existing private database procedure.
Grant database connection access without role membership, table access, or schema creation.
Keep signing keys outside the publisher, checker, and mirror processes.
The distributor receives only fixed export, lease, seal, authorization, completion, and readiness functions.
SQL records the authority decision; private operations verify TUF signatures and public storage delivery.

```sh
python3 tools/publisher_admin.py \
  --connection-file MIGRATOR_FILE --psql PSQL_PATH migrate-distribution
```

Expected output is one JSON object with `status: "migrated"`, schema `2`, and the separate migration SHA-384.
This distribution source revision requires the dependency-aware publication migration digest shown above.
An exact replay preserves installed state; a changed installed pin refuses the operation.
The reviewed distribution migration SHA-384 is:

```text
647baa6b9167e978e16990f51c7e5a8396e710be170dc4c16045e49dfff806fb30e5579827a16b972efda25fbc0dc126
```

Bind one immutable registry identity and HTTPS origin:

```sh
python3 tools/publisher_admin.py \
  --connection-file OPERATOR_FILE --psql PSQL_PATH configure-distribution \
  --registry-id REGISTRY_ID_32_HEX --origin https://registry.example/asm \
  --reference PRIVATE_AUDIT_REFERENCE
```

An exact configuration replay succeeds; a changed identity or origin refuses the operation.
Origin configuration does not establish production signing-key custody or TLS deployment.
Each batch reserves a monotonically increasing metadata version and a renewable lease of at most 300 seconds.
Readiness checks the pinned migration and narrow distributor identity before work is claimed.
Equal or nested local stores and overlapping prefixes within one S3 endpoint and bucket are refused.
These checks do not establish external bucket or CDN privacy.

The operator places committed blobs and digest-addressed target payloads before signing a fresh five-minute timestamp.
It retains and seals the exact signed bundle before changing public TUF roles or distribution heads.
The standard mutable TUF timestamp advances last through a conditional write.
A recovered lease uses the same sealed bytes and version, with a new fence.
If a sealed checkpoint expires or has insufficient write time, the operator reconciles public heads before abandoning its batch.
`abandon_distribution` requires the current lease, source digest, and a private reconciliation reference.
It retains the old seal and version; the next claim reserves a higher version.
An exact abandonment replay succeeds without changing the newer batch.
The operator permits one fresh-version retry; another expiry stops with retained attempts for inspection.
Never change signed bytes at an already reserved version.
Ordinary new intents wait for the next batch without invalidating the frozen snapshot.
Lifecycle changes abandon the active batch immediately and require a new signed policy.

Unchanged refreshes reuse one immutable release inventory and its membership rows.
Small per-batch plans bind that inventory and the replacement timestamp.
Each unchanged refresh retains a new timestamp and small batch, plan, seal, audit, and completion records.
New publication or policy revisions retain a new immutable inventory.
The flat profile permits at most 4,095 releases plus one policy target.
Its policy permits 1 MiB; its complete frozen source permits 4 MiB.
The signer must also refuse actual TUF role overflow before exposing a new timestamp.
These are compatibility limits, not a global capacity claim.

The private distributor uses the existing storage adapters:
Create an owned `0700` work directory before running the job.
Select a reviewed absolute trust-tool executable.
Replace uppercase placeholders before use.

```sh
python3 tools/registry_distribution.py publish \
  --connection-file DISTRIBUTOR_FILE --psql PSQL_PATH --worker-id WORKER_ID \
  --trust-root ROOT_FILE --keys-dir SIGNING_KEY_DIRECTORY --trust-tool ABSOLUTE_ASM_TRUST \
  --work-root /private/asm-distribution-work \
  --source-store local --source-root /private/asm-v2-retained \
  --store local --root /private/asm-v2-public
```

An empty queue is quiet; a completed batch returns its bounded authoritative JSON result.
An uncertain result requires inspection and exact replay, without deleting its retained candidate or seal.
The [hosting guide](../../docs/hosting.md) supplies the storage deployment boundary and S3 prerequisites.

Add `--refresh` to reserve a checkpoint renewal when publication and policy revisions have not changed.
The trust helper's `refresh-registry` path signs only the timestamp with the timestamp key.
It preserves exact root, snapshot, and targets bytes without reading artifact or target payloads.
A root change selects a full metadata refresh instead.
Snapshot or targets expiry within twenty-four hours also requires a full refresh.
Schedule renewals before the five-minute checkpoint expires; no deployed scheduler is supplied by this source checkpoint.

Every signed registry timestamp binds `asm_registry_id` and a canonical UTC `asm_issued_at`.
Clients reject wrong scope, expired checkpoints, issue times older than five minutes, or over thirty seconds in the future.
A reject-only prefilter runs before timestamp caching; maintained TUF verification still authenticates the metadata.
The trusted checkpoint is checked again after target download.
Assembly refreshes lifecycle policy after artifact validation, immediately before exposing the artifact or installation.

`tools/registry_distribution.py sync` copies a selected public inventory to an independently served byte mirror.
It needs storage access and a private work directory, without database credentials or signing keys.
The separate `verify` command audits the selected inventory's files and blobs without changing them.
Synchronization does not authenticate a mirror to native clients; the maintained TUF checks establish that authority.

Use the observed policy revision for lifecycle changes:

```sh
python3 tools/publisher_admin.py \
  --connection-file OPERATOR_FILE --psql PSQL_PATH lifecycle \
  --release-id RELEASE_ID_32_HEX --action yank \
  --operation-id OPERATION_ID_32_HEX --expected-policy-revision OBSERVED_REVISION \
  --reference PRIVATE_AUDIT_REFERENCE
```

Actions are `yank`, `unyank`, and `revoke`.
Emergency revocation cannot be undone in this profile.
Reuse the exact operation identity after an uncertain outcome; changed parameters require review and a new identity.
Lifecycle operations preserve release bytes, ownership, committed version reservations, and audit history.
Neither database completion nor lifecycle operations delete historical storage.

## Evidence and remaining gates

The dated results below retain earlier checkpoints and their failures.
The [V2 evidence record](../../docs/registry-v2-evidence.md) binds later native, verifier, distributor, and full-flow checks to their exact artifacts.
The [project publication evidence](../../docs/project-publication-evidence.md) records committed-source publication, actual nginx TLS, and V2 count qualification.
These source results do not activate production trust, qualify an arbitrary storage provider, or establish deployed capacity and recovery.

On 7 November 2026, 17 authority methods passed against an owned PostgreSQL/libpq 16.15 fixture without skips.
Eight private-admin methods passed on Python 3.14.6 on Apple Silicon macOS.
The database suite exercised the actual private operator command, coordinator, checker receipt, retained store, and atomic intent transition.
It also checked revocation, expiry, scope, malformed manifests, target declarations, concurrency, policy substitution, worker fencing, and conservative quotas.
A delayed earlier event remained claimable after a newer event was committed and acknowledged.
Enabled prepared-statement logging retained no synthetic bearer value under the required parameter settings.

The first database attempt ran zero methods because its fixture lacked the new migration file.
A directory-copy mistake repeated that missing-file result; no SQL gate passed during either attempt.
Early checks failed during migration, reference validation, and upload authorization.
Corrections deferred readiness-function resolution, bounded the audit-reference pattern, and qualified the upload's column names.
A test also leaked a role grant between owned fixture cases; explicit cleanup corrected that isolation defect.
The retained final suite passed after these corrections.
Two later ACL regressions demonstrated inherited grants despite mode `0600`.
Parent and staged-file descriptor checks now refuse those grants before writing token bytes.
The existing files and ACLs remain unchanged after refusal.

On 8 November 2026, twelve distribution-authority methods passed against the owned PostgreSQL/libpq 16.15 fixture in 96.508 seconds.
They included real private certificate authentication, checker retention, signed TUF distribution, and synchronization to a second local mirror.
The fixture used a synthetic archive; it did not execute submitted package code.
Other cases checked stale leases, exact sealed replay, lifecycle fencing, ordinary publication arrivals, role isolation, and migration replay.
Three unchanged refreshes retained one inventory and one membership row, instead of duplicating them per attempt.
An overflow case preserved the last completed head at the flat profile limit.
Ten private-admin methods passed on the macOS host.
After adding explicit abandonment, three focused authority methods passed in 34.572 seconds against the final migration pin above.
They checked exact replay, stale fencing, retained seals, a higher replacement version, and the unchanged publisher readiness boundary.

Initial distribution tests failed because the migration did not exist.
The real operator integration then exposed an extra PostgreSQL text-output line ending; exact transport handling corrected that digest mismatch.
The refresh regression exposed duplicated membership rows; immutable inventories removed that repeated storage.
A synthetic 4,095-row fixture load exceeded the fixed five-second query limit.
Loading 256-row transactions retained the same triggers and deadline; the complete suite then passed.
The abandonment regression first failed because its required function was absent.

Run the authority checks with the reviewed owned-fixture paths:

```sh
ASM_PROTO_PG_BINDIR=PG_BIN_DIRECTORY ASM_PROTO_LIBPQ=LIBPQ_FILE \
  python3 -m unittest discover -s tests/publisher -p 'test_authority.py' -v

python3 -m unittest discover -s tests/publisher -p 'test_admin.py' -v
```

Build the trust helper for the test host before the signed authority gate:

```sh
make build/asm-trust
ASM_PROTO_PG_BINDIR=PG_BIN_DIRECTORY ASM_PROTO_LIBPQ=LIBPQ_FILE \
  ASM_REGISTRY_TRUST="$PWD/build/asm-trust" PYTHONPATH=tests/publisher \
  python3 -m unittest test_distribution_authority -v
```

The required helper and database fixtures fail closed when missing.

Use `make -C server publisher-test` with the reviewed dependency paths for the assembly HTTP checks.
Their runtime result, container isolation, published images, TLS, recovery, and external client evidence remain separate from the SQL result.
No production resource, credential, DNS record, package release, or public endpoint was created by these local checks.
