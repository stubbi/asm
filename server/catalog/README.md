# Canonical hosted catalog

This component stores accepted registry v1 records and publishes three exact exports in PostgreSQL.
It does not start an HTTP service or replace the static registry by itself.
The native CLI and authoritative HTTP application remain assembly.
`tools/registry_admin.py` is an explicit Python registry operator tool.
Registry operations can use other languages under [AGENTS.md](../../AGENTS.md).

The user outcome is a durable catalog with immutable release metadata and consistent consumer exports.
Dependable reuse requires exact identities and complete historical records.
Evidence remains limited to the checks performed here.

## Data and authority

The `asm_catalog` schema is separate from the legacy `asm` experiment.
No prototype table supplies missing fields or inferred targets.
Imports retain complete schema 1 records, including macOS artifacts, per-version licenses, source commits, paths, and artifact digests.
The existing [validator and serializers](../../tools/registry.py) prepare the import.
SQL independently checks record bounds, canonical bytes, and export equality before publication.

The accepted source repository is `https://github.com/stubbi/asm`.
Each import records an exact, nonzero, lowercase 40-character Git commit.
The operator reads committed blobs without replacement objects, hooks, network fetches, or ambient Git configuration.
It disables Git transport protocols and lazy fetching.
Bounded `git fsck --strict` verifies local commit, tree, and blob integrity before planning.
The check also scans repository objects, alternate object stores, and ancestor history.
It refuses repositories that exceed its 20-second deadline or output bound.
This refusal is not a measurement of catalog capacity.
Working-tree changes cannot alter an import plan.
Keep the local object store unchanged during planning; this tool does not lock every Git object against concurrent writers.
An acceptance commit identifies the imported source; it does not prove that review occurred.

Namespace bindings contain a numeric GitHub identity and their acceptance commit.
These bindings are operator assertions, not authenticated publisher identities.
Import does not authenticate GitHub users or transfer ownership.
It does not download, execute, or verify artifact bytes.

Website evidence reports metadata validation.
Artifact, provenance, formal proof, and agent review results remain `not-run`.
The component supplies no download counts.
An unknown count remains unknown.
It preserves v1 target strings without inferring an ABI, ISA, or CPU feature declaration.

| Role | Authority |
| --- | --- |
| `asm_migrator` | Own the schema; apply the pinned migration; restore precise object grants |
| `asm_operator` | Read operator metadata; call namespace binding and catalog import functions |
| `asm_reader` | Read the migration marker and current exports |

All three roles must be separate, nonprivileged login identities without cross-role membership.
Provision certificate authentication outside this component.
The database must belong to `asm_migrator`.
Neither the reader nor operator receives table mutation rights or schema creation rights.
The two mutation functions use `SECURITY DEFINER` with a fixed `pg_catalog,pg_temp` search path.
Stored functions pin standard string parsing; regular expressions do not depend on caller backslash settings.
The `C` collation fixes ASCII format checks; the native fixture does not test other database locales.
Both functions require the `asm_operator` session identity.
The migration revokes default `PUBLIC`, reader, and operator object grants before applying the listed permissions.
The `grant` command restores these object permissions; it does not alter role membership or administrator rights.
PostgreSQL administrators and the migration identity remain trusted.

## Migration identity

`schema.sql` is migration version `1`.
Its SHA-384 is:

```text
259a54d22fcd1e53addf4f5f197d7ca0f7c5040e2492776fc60a30f59cd1428a6618f4ec39fa1f3df867d4b05ee2d9ae
```

The tool verifies the exact file bytes against `MIGRATION_SHA384` before applying them.
The schema and its one-row marker are committed in the same transaction.
The marker stores version `1` and this digest.
Migration replay requires that exact marker and the expected schema owner.
It refuses an unknown schema state.
The marker records which migration was applied; it cannot constrain a trusted administrator who later changes database objects.

`reader-guard.sql` pins the same version and digest.
Tests compare its literal digest, the tool constant, and the migration file hash.
An installed migration must not be edited in place.
A future schema change requires a new migration and an explicit reader contract update.
The legacy `server/guard.sql` is unchanged.

## Private operator connection

The tested database and client version is PostgreSQL `16.15`.
Use Python 3, Git, and an explicitly selected `psql` executable.
The operator accepts Linux and macOS hosts.
Native macOS qualification does not establish Linux assembly ABI behavior.

The connection file must contain one ASCII PostgreSQL URL, with at most one final LF.
Its limit is 8192 bytes.
The following form shows required fields:

```text
postgresql://asm_operator@db.example.invalid:5432/asm?hostaddr=192.0.2.1&sslmode=verify-full&sslrootcert=/absolute/ca.crt&sslcert=/absolute/operator.crt&sslkey=/absolute/operator.key
```

Use the command's required role in the URL.
Use a lowercase DNS certificate host and an explicit port.
Supply a canonical IPv4 `hostaddr` to avoid an unbounded DNS lookup.
Use URL encoding for reserved path characters.
Do not place a password in the URL.
Do not share credential contents in issue reports.

The tool requires `verify-full` TLS and TLS 1.2 or later.
It fixes a two-second connection timeout, a 15-second statement timeout, and a two-second lock timeout.
The whole child process has a 30-second deadline.
It disables ambient PostgreSQL passwords, services, options, and `psql` startup files.
The live connection must use TLS and the exact requested session role.

The connection file and private key require owner-only permissions.
Certificates and CA files must not permit group or other writes.
All credential files must be owned by the current user and have one hard link.
Each certificate or key has a 65536-byte limit.
The tool rejects encrypted private keys and all extended access-control lists.
It checks macOS ACLs through the opened descriptor.
It checks Linux POSIX access ACLs through the opened descriptor.
An unsupported ACL inspection fails closed.

Files remain open while `psql` reads their `/dev/fd` paths.
The final file component cannot be a symbolic link.
Parent directories are trusted operator inputs.
A same-user process can still modify an opened file; this is not a worker isolation boundary.
The tool uses argument arrays and hex-encoded SQL values, without shell interpretation of package data.
Standard error contains bounded diagnostic messages, without provider responses or credential values.

## Operator procedure

Uppercase tokens below are placeholders.
Replace each token before running its command.
`COMMIT_ID` is an accepted source commit in the local public repository.
`GITHUB_ID` is the deliberately approved numeric namespace identity.
`PLAN_DIGEST` comes from the reviewed plan output.
`REVISION` is the current revision; use `0` before the first import.

1. Apply the pinned migration with the migration identity.

   ```sh
   python3 tools/registry_admin.py --connection-file MIGRATOR_FILE --psql PSQL_PATH migrate
   ```

   Successful output contains `"status": "migrated"`, schema `1`, and the exact migration digest.

2. Restore the precise object permissions when required.

   ```sh
   python3 tools/registry_admin.py --connection-file MIGRATOR_FILE --psql PSQL_PATH grant
   ```

   Successful output contains `"status": "granted"` and the fixed reader and operator roles.

3. Record the approved namespace assertion with the operator identity.

   ```sh
   python3 tools/registry_admin.py --connection-file OPERATOR_FILE --psql PSQL_PATH bind-namespace --namespace NAMESPACE --github-id GITHUB_ID --acceptance-commit COMMIT_ID
   ```

   Successful output explicitly reports `"ownership_evidence": "operator-assertion"`.
   Repeating the same namespace and numeric identity is idempotent.
   A conflicting identity is refused without changing the binding.

4. Inspect the current revision.

   ```sh
   python3 tools/registry_admin.py --connection-file OPERATOR_FILE --psql PSQL_PATH status
   ```

   Before the first import, output reports revision `0` and a null acceptance commit.

5. Prepare the exact import without database credentials.

   ```sh
   python3 tools/registry_admin.py plan --repository REPOSITORY_PATH --commit COMMIT_ID --expected-revision REVISION
   ```

   Output includes each export's byte count and SHA-256, the validator digest, and `plan_sha256`.
   It also reports `"artifact_bytes_checked": false`.

6. Review the source identity, records, export sizes, and plan digest.

7. Import that exact plan with the operator identity.

   ```sh
   python3 tools/registry_admin.py --connection-file OPERATOR_FILE --psql PSQL_PATH import --repository REPOSITORY_PATH --commit COMMIT_ID --expected-revision REVISION --plan-sha256 PLAN_DIGEST
   ```

   Successful output reports the accepted commit, plan digest, and assigned revision.
   A mismatch fails before database mutation.

The ledger is append-only for namespaces, releases, artifact URLs, snapshots, exports, and audit events.
Published canonical manifest bytes cannot change.
Imports cannot omit retained releases or reuse an artifact URL for another release.
An advisory transaction lock and expected revision serialize publication.
Exactly one concurrent import with the same expected head can advance that head.
All three exports and the new head commit atomically.

Replaying identical bytes for an accepted commit returns its original revision.
Replaying an older commit does not move the current head backward.
Different bytes for an accepted commit are refused.
After a connection failure, inspect status before replaying the same commit.
The remote outcome can be unknown even when the command fails.
No failed command prints partial machine output.

Initial imports may retain records that were already yanked.
Changing a retained yank flag requires a separate lifecycle operation, which this component does not implement.
Ownership transfer and emergency revocation also require separate operations.
There is no public write endpoint, arbitrary build execution, or proof worker in this component.

## Fixed assembly read interface

Run `reader-guard.sql` in the actual reader transaction before accepting database readiness.
The transaction must be read-only.
The query returns exactly one non-null text field: `1` for acceptance or `0` for refusal.
A SQL error, missing result, or any other result is a refusal.
No import means no ready catalog: the guard returns `0` until all three exports exist.

The guard requires the exact migration marker, required reads, trusted object owners, and a complete current export set.
It rejects database or schema creation, table and column writes, updatable view writes, and sequence mutation permissions.
It rejects privileged built-in roles and reachable privileged role memberships, including non-inherited memberships.
It rejects reader membership in either operator or migration authority.
It rejects executable user `SECURITY DEFINER` functions, including functions outside `asm_catalog`.
These checks include effective `PUBLIC` permissions.

Use the fixed statement in `read-exports.sql`:

```sql
SELECT body FROM asm_catalog.current_exports WHERE route = $1;
```

Bind `$1` to a router-selected literal from this table.
Never interpolate a request path into SQL.

| Literal route | Maximum body bytes | Content type |
| --- | ---: | --- |
| `/registry/v1/index.tsv` | 1048576 | `text/tab-separated-values; charset=utf-8` |
| `/registry/v1/index-macos.tsv` | 1048576 | `text/tab-separated-values; charset=utf-8` |
| `/registry/v1/index.json` | 4194304 | `application/json` |

Exactly one row contains the response bytes.
Zero rows means unavailable; it does not mean an empty successful response.
The caller must retain or copy the result before releasing the database result object.
The caller must enforce the route-specific byte bound and HTTP content type.
A single statement observes one committed head, including all related export metadata.
Independent requests can observe different revisions during publication.

The Linux TSV preserves `registry.legacy_tsv` behavior.
The full TSV preserves macOS rows from `registry.make_indexes`.
JSON bytes match `registry.json_bytes`, including sorted keys, two-space indentation, and one final LF.
Do not reconstruct these exports from the prototype schema or infer target compatibility.
Runtime response buffers must support these bounds before routes are enabled.
The legacy runtime's 16384-byte response limit cannot serve the current JSON export.

## Qualification

The retained suite starts an owned PostgreSQL cluster with private TLS certificates.
It refuses existing database targets and requires the reviewed PostgreSQL 16.15 fixture binaries.
Run the focused suite with the fixture paths:

```sh
ASM_PROTO_PG_BINDIR=PG16_BIN ASM_PROTO_LIBPQ=PG16_LIBPQ make hosted-registry-test
```

Run the existing registry gate:

```sh
python3 -m unittest discover -s tests/registry -p 'test_*.py' -v
```

Tests cover current-catalog parity, macOS preservation, immutable history, namespace conflicts, atomic failure, concurrent publication, replay, and source isolation.
They also cover duplicate or noncanonical JSON, role denial, dangerous default grants, credential file permissions, and TLS policy refusal.
Reader tests exercise function-only authority, indirect roles, column writes, views, sequences, missing reads, and exact migration binding.
The macOS extended ACL regression runs on macOS.
The assembly-server workflow runs this gate on Linux with the pinned PostgreSQL build and TLS enabled.
Native macOS database evidence does not qualify Linux server ABIs, HTTP response ownership, Kubernetes deployment, capacity, or backup restoration.

The PostgreSQL 16.15 source archive used for native qualification has SHA-256:

```text
c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed
```

Source: [PostgreSQL 16.15 archive](https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2).
Qualification uses macOS 15.6.1 on Apple Silicon, Python 3.14.6, OpenSSL 3, and the existing disposable fixture library.
The tested Git version is Apple Git 2.39.5, build 154.
Failed checks exposed canonical JSON acceptance, default grants, private-key ACLs, temporary-schema prefix handling, caller-controlled parsing, and local object corruption.
Temporary type shadowing also caused a valid import to fail before explicit trusted type resolution was added.
The retained regression tests exercise these failures after their corrections.
One later fixture run exceeded the unchanged 20-second `initdb` deadline before database tests began.
Its five offline tests passed; that run did not qualify database behavior.
Another combined run passed 14 of 20 tests.
The plan command exceeded its unchanged 15-second test deadline.
Database creation exceeded the fixture socket deadline.
Four later setup operations could not use that fixture connection.
Earlier independent final-schema and operator runs passed 18 and five tests, respectively.
A complete run of the final 20-test suite remains required.

Protocol references checked on 5 November 2026:
[PostgreSQL 16 privilege functions](https://www.postgresql.org/docs/16/functions-info.html),
[function security](https://www.postgresql.org/docs/16/perm-functions.html), and
[CREATE FUNCTION security guidance](https://www.postgresql.org/docs/16/sql-createfunction.html), and
[string compatibility settings](https://www.postgresql.org/docs/16/runtime-config-compatible.html).
These sources define effective privileges, role membership, fixed search paths, and default function execution grants.
The [Git fsck documentation](https://git-scm.com/docs/git-fsck) defines its object-integrity checks and diagnostic controls.
