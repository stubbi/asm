# Explicit registry operator image

Status: source candidate, 5 November 2026. Native image qualification and publication remain pending.

This image packages deliberate registry operations for short AMD64 Linux Jobs.
The native CLI and HTTP application remain assembly.
Python supplies registry operations under the existing [language boundary](../AGENTS.md#protect-the-native-cli).
No public write endpoint, build worker, proof worker, or automatic import starts with this image.

The image connects reviewed source to an isolated catalog change.
The [catalog contract](../server/catalog/README.md) defines SQL authority, immutable records, and four canonical exports.
This recipe does not change its schema, guards, validator, or operator transport.

## Image and command contract

The image entrypoint is:

```text
/usr/bin/python3 -I /app/tools/operator_entrypoint.py
```

Python isolated mode excludes ambient Python configuration.
The dispatcher adds only its immutable application directory.
The default command is `--help`; starting the image does not change a database.

| Command arguments | Result |
| --- | --- |
| `prepare-operator --config-directory SOURCE --tls-directory TLS --destination-directory PRIVATE --role asm_migrator --resolve-dns` | Prepare one private migration snapshot; no database connection |
| `migrate --connection-file PRIVATE/database.url` | Apply or check the exact migration |
| `grant --connection-file PRIVATE/database.url` | Restore fixed reader/operator object grants |
| `bind-namespace --connection-file PRIVATE/database.url --namespace NAME --github-id ID` | Record a deliberate operator ownership assertion |
| `plan --expected-revision REVISION` | Prepare an offline plan from the image's exact source |
| `import --connection-file PRIVATE/database.url --expected-revision REVISION --plan-sha256 DIGEST` | Import that reviewed plan atomically |
| `status --connection-file PRIVATE/database.url` | Read the current revision and acceptance commit |

Uppercase tokens are placeholders.
Replace each token before execution.
Use `asm_operator` for namespace binding, import, and status.
Use `asm_migrator` for migration and grants.
The `grant` command has no configurable role flags.
The fixed roles remain `asm_reader`, `asm_migrator`, and `asm_operator`.

The image fixes these privileged paths:

| Item | Path |
| --- | --- |
| PostgreSQL client | `/opt/asm/postgres/bin/psql` |
| Migration | `/app/server/catalog/schema.sql` |
| Accepted Git objects | `/opt/asm/source.git` |
| Source identity | `/app/SOURCE.json` |

Repository, commit, client, and schema path overrides are not image arguments.
The accepted commit comes from the image marker.
Namespace assertions remain separate from authenticated publisher identity.
An acceptance commit does not prove that a review occurred.
Plan and import do not download or verify package artifacts.

## Projected credential trust boundary

`prepare-operator` is an explicit trust boundary for authorized Job projections.
It is not a general file-copy command or a serving credential manager.
Trust the controllers and Job configuration that supply both projected volumes.
File ownership alone does not authenticate their author.

The source configuration volume must contain `database.url`.
The TLS volume must contain `ca.crt`, `tls.crt`, and `tls.key`.
Each file must be a single-link regular file owned by root, with GID 65532 and mode 0440.
The source volumes must use one relative AtomicWriter `..data` generation pointer.
The preparer pins one generation directory descriptor per volume.
It refuses escaping pointers, unexpected symlinks, file changes, unsupported ACL inspection, and missing files during rotation.

Use physical absolute mount paths.
Symlink directory components are refused.
Directory ancestors must belong to root or the Job user and exclude untrusted writes.
A root-owned sticky temporary ancestor is permitted.
A shared writable final parent is refused.
The Job's own group is a trusted writer of its private output volume.
This boundary does not isolate a malicious root, same-UID process, or another trusted Job-group writer.

The source URL must select the requested role without a password.
Its CA, certificate, and key paths must exactly identify the fixed files in the supplied TLS mount.
Unknown or repeated options are refused before path rewriting or DNS.
The existing `verify-full`, minimum TLS, role, and private-file policy remains in force.
The preparer does not authenticate a certificate or connect to PostgreSQL.
The later operator command performs that authentication.

Without `hostaddr`, select `--resolve-dns` explicitly.
Resolution uses the system resolver in a separate five-second child without credentials.
It accepts at most eight IPv4 results and selects the first sorted result.
The DNS hostname remains the TLS identity; the selected address becomes `hostaddr`.
There is no automatic address fallback.
The existing PostgreSQL child deadline and public reader's two-second readiness deadline are unchanged.

Preparation reads all projected input before creating a private staging directory.
It creates owned mode-0600 files inside a mode-0700 directory.
It clears inherited setgid on that new directory.
It checks the existing private-file policy against the staged snapshot without a database connection.
Atomic no-replace publication exposes only the complete final directory.
An existing directory, file, or symlink is preserved.

An interruption after publication preserves the complete final snapshot.
If cleanup cannot establish staging inode ownership, it preserves those private files.
Inspect the result after an interrupted command.
Use a new destination for a deliberate retry.
Atomic publication does not establish directory durability after power loss.
Snapshots apply to short operator Jobs; they do not implement serving certificate rotation.

## Isolation and source

Run as UID/GID 65532 with fsGroup 65532.
Use a read-only root filesystem and a private writable output volume.
Drop Linux capabilities and prohibit privilege escalation.
Disable service-account token mounting.
Keep migration and operator certificates in separate Jobs and projections.
Never mount write credentials in the public reader.
Private manifests must adopt this exact interface through their own reviewed change.

The image uses the reviewed pinned Debian base index and signed Debian repositories.
The qualification report records resolved OpenSSL, Python, Git, libc, and other package versions.
It also records executable and loaded-library digests.
PostgreSQL psql/libpq use the pinned 16.15 source archive and SHA-256 in the Dockerfile.
The final filesystem contains no compiler or PostgreSQL server.

The build creates a complete bounded HEAD bundle from a clean checkout with full history.
It includes ancestors and excludes unrelated refs and local Git configuration.
Git consumes a private copy of the verified bundle bytes during restoration.
Bounded Git enumeration must equate all stored objects with the accepted commit's reachable graph.
Bundles have a 64 MiB limit and a 131072-object limit.
Each Git child has a 20-second deadline.
The final source store has one accepted ref and no remotes or alternate object stores.
Runtime Git transports and lazy fetching are disabled.
Copied application files must match their committed SHA-256 digests.
The source store belongs to UID 65532 for Git ownership checks; its files are read-only.
The required read-only root filesystem protects that store during operation.

Complete Asm source and its license history are available in `/opt/asm/source.git`.
`/app/SOURCE.json` identifies the exact commit and runtime source files.
The image retains Asm and PostgreSQL notices.
Debian package notices remain under `/usr/share/doc`.
Qualification records exact Debian source package versions and their source index links.
Independent package licenses are retained in the accepted source records.

Resolved Debian packages can change between repository updates.
Qualification binds the actual immutable image; it does not promise byte-for-byte reproducibility across those updates.

## Qualification and publication

The dedicated `operator-images.yml` workflow starts with read authority and no registry or database credential.
It builds native AMD64 and a derived isolated qualification image.
The test image adds PostgreSQL server tools and synthetic projected files.
Those additions do not enter the final image.
It retains the build's OpenSSL configuration at the compiled default path.
It generates synthetic projections at their final qualification path, so fixed TLS URL identities match that mount.

The harness checks exact final-image plan commands, missing-credential refusal, and absent compiler/server tools.
It compares application and loaded dependency bytes between final and derived images.
It runs the complete hosted SQL suite, preparation regressions, and actual entrypoint migration/import/status flow.
The Linux run must execute the root-owned projection case.
Preparation tests use the fixed image client; writable test storage remains non-executable.
Only the named macOS ACL test is inapplicable there.
No applicable test may be skipped.
The harness retains tests, source identity, package inventory, runtime digests, isolation settings, and failure evidence.

The PostgreSQL fixture is version 16.15.
These results do not qualify the private PostgreSQL 18.6 server.
That actual-image compatibility check remains a separate activation gate.
Other architectures, Kubernetes deployment, capacity, and recovery also remain unqualified here.

PR and manual runs do not publish.
Only a main push can load this run's exact qualified artifact and publish it.
One typed contract checks the report and inspected image before loading the artifact.
That contract comes from the trusted exact-main checkout.
It requires Linux AMD64, source and plan bindings, resolved dependencies, integer test counts, and exact isolation settings.
After loading, publication inspects the loaded image and applies that same contract before tagging or registry login.
The publisher does not execute image code.
Both inspections remain in the evidence, including failed publication checks.

The trusted release helper uses `registry.strict_json` before jq parses either input.
Each input must be one protected UTF-8 document within one MiB and 64 nesting levels.
It rejects duplicate decoded keys, nonfinite numbers, unpaired surrogates, and integers outside jq's exact range.
Only the report's `seconds` field permits a finite fractional value.
The helper supplies private canonical copies to the policy.
It preserves original evidence bytes; canonical copies do not replace raw-byte hashes.
Publication records the immutable registry digest and source provenance.
It does not rebuild the image with publication credentials.

Source review failures are retained as regressions: sticky ancestors, interrupted publication, cleanup faults, mutable bundle replacement, and hidden unrelated objects.
Packaging review failures also retain regressions for executable temporary fixtures and malformed publication evidence.
Candidate `751b3f2` failed packaging review for missing loaded-image validation and duplicate JSON fields.
Regressions retain those cases and number-representation failures.
Local source tests do not substitute for the pending native image gate.

The first native preflight used temporary source `3c4a328`, derived from candidate `c50a043`.
[Run 42042696593](https://github.com/stubbi/asm/actions/runs/42042696593) built both images but failed actual qualification.
It executed 39 tests with one projection failure and one SQL class setup error.
The 17 SQL and entrypoint class cases did not execute.

Diagnostic source `e13ba24` preserved those checks.
[Run 42048497201](https://github.com/stubbi/asm/actions/runs/42048497201) observed missing OpenSSL configuration and a TLS path identity refusal.
Fixture URLs named the build directory, while the test used the qualification mount.
The valid projection retained root ownership, GID 65532, and the required modes.
This result contradicted the ownership-loss hypothesis.
The qualifier now supplies the configuration and generates fixtures at their actual mount path.
This correction requires a new actual-image check; diagnostic images do not qualify the final candidate.

Git object-enumeration references checked on 5 November 2026:
[git cat-file](https://git-scm.com/docs/git-cat-file) and
[git rev-list](https://git-scm.com/docs/git-rev-list).
