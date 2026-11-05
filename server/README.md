# Assembly canonical registry runtime

Status: incomplete implementation, 5 November 2026.

This directory contains the assembly runtime path for hosted Asm work.
It is not a production registry or a deployable replacement for the static catalog.
It must not activate either private deployment stage.

The consumer outcome is exact compatibility feeds from the retained canonical catalog.
The governing principles are dependable reuse and evidence that states its limits.
Source implementation, target execution, deployment, and recovery remain separate acceptance results.

## Implemented scope

`asm-hub serve` reads `ASM_BIND` and `ASM_DATABASE_URL_FILE` before it starts HTTP threads.
Both variables are required.
The bind value must contain an IPv4 address and a decimal port from 1024 to 65535.
The process accepts no migration, grant, or import command.

| Route | Intended behavior |
| --- | --- |
| `GET /health/live` | Return process liveness without a database connection |
| `GET /health/ready` | Check the canonical migration, actual catalog reads, and reader privileges |
| `GET /api/v2/status` | Return the build's exact source revision and source URL |
| `GET /registry/v1/index.tsv` | Return the exact Linux compatibility feed, at most 1048576 bytes |
| `GET /registry/v1/index-macos.tsv` | Return the exact full compatibility feed, at most 1048576 bytes |
| `GET /registry/v1/index.json` | Return the exact schema 1 JSON export, at most 4194304 bytes |

TSV responses use `text/tab-separated-values; charset=utf-8`.
The canonical JSON response uses `application/json`.
The server preserves every response byte, including the final line feed.
An absent, null, empty, duplicate, oversized, or failed database result returns HTTP 503.
No static catalog replaces a failed database read.
Unimplemented routes return HTTP 404.

The HTTP routes reject request bodies, query fields, and methods other than GET.
The HTTP library admits at most 16 connections.
Each connection has a 32 KiB HTTP parsing allowance and a 256 KiB thread stack.
Response bodies use separate library allocations.
URLs have a 2048-byte limit.
Headers have a 64-field and 16 KiB limit.

Each readiness or export request owns one fresh PostgreSQL connection.
The connection runs `BEGIN READ ONLY`, the canonical reader guard, then the optional fixed export query.
Each command drains completely before the next command starts.
Connection, transaction setup, guard, export, and result handling share one two-second monotonic deadline.
The fixed connection options enforce read-only transactions, a one-second statement timeout, and a 200 ms lock timeout.
The guard checks the exact canonical migration digest and actual reader permissions.
No import means no ready catalog; the process refuses startup with exit 78.
Use the separate [operator procedure](catalog/README.md) to migrate, grant, bind namespaces, and import accepted records.

The export statement comes from `catalog/read-exports.sql`.
Only a router-selected literal enters its parameter array.
No request text becomes SQL or a database connection option.
The reader identity is exactly `asm_reader`.
The service receives no migration or operator credential.

The database result remains owned after its connection closes.
The HTTP library copies its exact byte length before the server releases that result.
The server uses no large stack response buffer.
JSON body storage can include the 4 MiB database result and its 4 MiB HTTP copy.
That is up to 8 MiB of body bytes per active JSON response, excluding library overhead and other allocations.
The limit of sixteen connections does not establish that the private 256 MiB memory proposal is sufficient.
Capacity and slow-reader behavior need separate measurements.
An HTTP allocation, header, or queue failure closes the connection after releasing response ownership.

SIGTERM and SIGINT stop admission and stop the HTTP daemon.
The integration suite checks a three-second idle shutdown bound.
Completion of every accepted response during shutdown remains unqualified.

## Private database configuration

The connection file must be regular, owned by the current UID or root, and inaccessible to other users and groups.
The final path component must not be a symbolic link.
The file has a 4096-byte limit.
One final LF is permitted.
The path and its parent directories are trusted operator inputs.
This final-component check does not establish a race-free directory traversal boundary.

The URL format is:

```text
postgresql://READER@CERTIFICATE_HOST:PORT/DATABASE?sslmode=verify-full&sslrootcert=/absolute/ca.crt&sslcert=/absolute/client.crt&sslkey=/absolute/client.key&hostaddr=IPV4
```

Use URL encoding for reserved characters in paths.
Supply each query field exactly once.
No other connection option is accepted.
The user and database identifiers permit lowercase ASCII letters, digits, and underscores.
Their first character must be a letter or underscore.
Each identifier has a 63-byte limit.
Certificate paths must be absolute and have a 1024-byte limit.

The process removes all `PG*` environment variables before connections start.
It fixes `passfile` to `/dev/null` and disables GSS encryption negotiation.
Password fields, service files, custom connection options, and host lists are rejected.
An encrypted client key is refused without an interactive password prompt.
libpq performs TLS negotiation, CA validation, hostname validation, and client authentication.
The runtime also requires an active TLS connection.

`host` identifies the certificate hostname.
`hostaddr` supplies the numeric IPv4 connection address.
This explicit address avoids a synchronous DNS lookup inside libpq's nonblocking connection API.
It is an operator-supplied address, not an embedded service address.
Do not hardcode a Kubernetes service IP in this source.

**The existing private DNS-only ConfigMap is incompatible with this checkpoint.**
A bounded resolver and its configuration contract remain required before that deployment can use this process.
The private ConfigMap's projected file permissions also need qualification against this file policy.

Certificate files are opened by libpq for each new connection.
No connection or certificate is cached by this process.
Projected-volume rotation must still pass against the actual private deployment.

## Build and test

Use a matching Linux x86-64, ARMv8-A AArch64, or RV64GC/LP64D host.
Use GNU libmicrohttpd 1.0.3 and libpq/PostgreSQL 16.15.
Use Python 3.10 or later and an OpenSSL command for the integration fixture.
The build-time C program checks ABI constants only.
It is not linked into the application.
Application routing, configuration policy, connection lifecycle, and deadlines are assembly.

The [reference dependency recipe](../experiments/assembly-server/DEPENDENCIES.md) supplies reviewed source pins.
For this runtime, configure PostgreSQL with `--with-openssl`.
The reference recipe's TLS-free PostgreSQL build cannot pass these tests.
Keep HTTP transport behind the separately qualified ingress TLS boundary.

Build and test from the repository root:

```sh
make -C server test MHD_PREFIX=/path/to/mhd PG_PREFIX=/path/to/postgres SOURCE_REVISION=FULL_COMMIT_ID
```

Replace `FULL_COMMIT_ID` with the exact 40-character source commit.
The status source offer points to that commit.
The reviewed build process must connect that commit to the resulting artifact digest.
Embedding a value alone does not establish provenance.

The test suite creates an owned temporary PostgreSQL cluster and test CA.
It verifies ownership before database changes.
It accepts no existing database target or production credentials.
It applies the pinned canonical migration with the explicit operator helper.
It seeds all current accepted manifest records through the catalog operator functions.
It does not download or execute package artifacts.
Python supplies test orchestration only.

Tests cover private-file rejection, malformed configuration, duplicate fields, TLS identity failures, privileged-role rejection, and changed read permissions.
They also cover certificate replacement, a stalled handshake, encrypted-key prompt refusal, health, source identity, and idle SIGTERM.
Feed tests compare all three current exports byte for byte and check their content types.
Database-result probes cover missing, null, duplicate, unavailable, oversized, and stalled results.
Trusted fixture administration temporarily changes a view for these probes, then restores it.
The maximum-size body probes test transport bounds; their repeated bytes are not canonical package records.
Rejection tests require the documented status, so a process crash cannot satisfy them.
Usage failures return 64; configuration and database refusal return 78.

## Evidence and remaining work

Local checks on 5 November 2026 assembled both source files with Apple's clang for `x86_64-linux-gnu`.
Python syntax validation passed.
These checks did not link or execute the application.

The first runtime test attempt failed because no runtime executable existed.
It ran zero runtime tests.
`make -C server test` also refused the unsupported macOS host before compilation.
The existing Linux guest returned an input/output error.
Earlier dependency preparation also recorded storage and read-only-filesystem failures.
No dependency build or container recovery was retried here.
Native macOS has libmicrohttpd 1.0.1 and libpq 18.1, which do not satisfy the pinned Linux qualification.
The later [Linux CI run 41934599148](https://github.com/stubbi/asm/actions/runs/41934599148) built the pinned dependencies and passed all 11 runtime tests.
It tested PR merge revision `b06b5eb37e68a90381241a53c48a6b9cb6b84fde`, which contains source head `fd977e5`.
This result covers the stated TLS, configuration, readiness, identity, and idle-shutdown cases.
It does not qualify deployment compatibility, catalog behavior, saturation, or recovery.

The legacy `guard.sql` retains its provenance notice and checksum for the separate reference.
The runtime now includes `catalog/reader-guard.sql` and reads the complete canonical ledger.
It does not infer missing fields or targets from the prototype schema.
The canonical component's [qualification record](catalog/README.md#qualification) remains separate from HTTP evidence.

The test-only [native Linux run 41946260936](https://github.com/stubbi/asm/actions/runs/41946260936) demonstrated the missing HTTP feature.
At source `61cad046fc17794f2704638094720fe7effcfb80`, all three new exact-export subtests failed with HTTP 404 instead of HTTP 200.
Its twelve-test suite retained the three failures; the existing reference suite passed sixteen tests.
The [native Linux run 42006909140](https://github.com/stubbi/asm/actions/runs/42006909140) tested source `6d7bb947281e9d6565ff04a1292f193840d8035a`.
All sixteen AMD64 HTTP tests passed without skips in 5.866 seconds.
The separate canonical SQL suite passed nineteen applicable tests; its macOS-only ACL case skipped.
Ubuntu Clang 18.1.3 assembled the x86-64, AArch64, and RV64GC/LP64D source files.
The cross-assembly step did not link or execute AArch64 or RISC-V code.
This run covers the original three-export contract, before the pending fourth-feed integration in PR #29.
Canonical image qualification and target runtime evidence remain separate requirements.
Local cross-assembly passed for x86-64 and AArch64 after the routing change.
Apple's installed clang cannot assemble the RISC-V target; no local RISC-V assembly or execution result is claimed.

These requirements remain open:

- Runtime qualification of canonical HTTP serving on ARM64 and RISC-V64.
- Runtime and image qualification after the pending four-export catalog integration.
- Deployment qualification of the separate migration, grant, namespace assertion, and import procedures.
- Bounded hostname resolution compatible with private service discovery.
- Database connection reuse and measured admission behavior under saturation.
- Absolute HTTP header deadlines and qualified shutdown draining.
- Required fixed-label metrics and observed alert delivery.
- Public TLS, projected certificate rotation, network-denial tests, capacity, backups, WAL delivery, and isolated restore.
- Exact immutable images, artifact digests, provenance, and external HTTPS client checks.

No cluster resource, credential, DNS record, public route, or release artifact was changed by this checkpoint.

## Sources

- PostgreSQL 16 [connection control](https://www.postgresql.org/docs/16/libpq-connect.html): nonblocking restrictions, `PQconninfoParse`, and the encrypted-key callback.
- PostgreSQL 16 [command execution](https://www.postgresql.org/docs/16/libpq-exec.html) and [asynchronous processing](https://www.postgresql.org/docs/16/libpq-async.html): result ownership, parameters, and command draining.
- GNU [libmicrohttpd manual](https://www.gnu.org/software/libmicrohttpd/manual/libmicrohttpd.html): daemon lifecycle and response ownership.
- [Hosted registry acceptance](../docs/hosted-registry.md).

The external API documentation was checked on 5 November 2026.
New source and tests use AGPL-3.0-or-later under the repository's [license scope](../LICENSING.md).
