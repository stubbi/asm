# Assembly registry runtime foundation

Status: incomplete implementation, 5 November 2026.

This directory contains the assembly runtime path for hosted Asm work.
It is not a production registry or a deployable replacement for the static catalog.
It must not activate either private deployment stage.

The operator outcome is a bounded process with explicit connection authority, health checks, and an exact source identity.
The governing principles are dependable reuse and evidence that states its limits.
Catalog serving and recovery remain separate acceptance requirements.

## Implemented scope

`asm-hub serve` reads `ASM_BIND` and `ASM_DATABASE_URL_FILE` before it starts HTTP threads.
Both variables are required.
The bind value must contain an IPv4 address and a decimal port from 1024 to 65535.
The process accepts no migration, grant, or import command.

| Route | Intended behavior |
| --- | --- |
| `GET /health/live` | Return process liveness without a database connection |
| `GET /health/ready` | Check the reference schema, actual catalog reads, and reader privileges |
| `GET /api/v2/status` | Return the build's exact source revision and source URL |
| Any catalog route | Return 404; no export exists in this checkpoint |

The HTTP routes reject request bodies, query fields, and methods other than GET.
The HTTP library admits at most 16 connections.
Each connection has a 32 KiB memory allowance and a 256 KiB thread stack.
URLs have a 2048-byte limit.
Headers have a 64-field and 16 KiB limit.

Each readiness request owns a fresh PostgreSQL connection.
Connection, query, and result handling share a two-second monotonic deadline.
The fixed connection options enforce read-only transactions, a one-second statement timeout, and a 200 ms lock timeout.
The readiness query checks the exact retained reference migration checksum.
It does not prove recovery or catalog export correctness.

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

Use Linux x86-64 with GNU libmicrohttpd 1.0.3 and libpq/PostgreSQL 16.15.
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
It seeds the retained reference schema and records through the reference test fixture.
Python supplies test orchestration only.

Tests cover private-file rejection, malformed configuration, duplicate fields, TLS identity failures, privileged-role rejection, and changed read permissions.
They also cover certificate replacement, a stalled handshake, encrypted-key prompt refusal, health, source identity, and idle SIGTERM.
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
Linux CI must run the integration suite before this checkpoint earns a runtime claim.

The schema and guard originated in the reviewed assembly reference.
`guard.sql` retains its provenance notice and checksum.
The runtime reuses that guard without changing the experiment or its evidence.
The reference schema excludes macOS artifacts and lacks fields required for complete current schema-1 exports.
No export has been guessed from incomplete records.

These requirements remain open:

- Exact Linux TSV, macOS TSV, and schema-1 JSON exports from retained canonical records.
- Reviewed schema migration, grants, namespace ownership, and idempotent import commands.
- Bounded hostname resolution compatible with private service discovery.
- Database connection reuse and measured admission behavior under saturation.
- Absolute HTTP header deadlines and qualified shutdown draining.
- Required fixed-label metrics and observed alert delivery.
- Public TLS, projected certificate rotation, network-denial tests, capacity, backups, WAL delivery, and isolated restore.
- Exact immutable images, artifact digests, provenance, and external HTTPS client checks.

No cluster resource, credential, DNS record, public route, or release artifact was changed by this checkpoint.

## Sources

- PostgreSQL 16 [connection control](https://www.postgresql.org/docs/16/libpq-connect.html): nonblocking restrictions, `PQconninfoParse`, and the encrypted-key callback.
- GNU [libmicrohttpd manual](https://www.gnu.org/software/libmicrohttpd/manual/libmicrohttpd.html): daemon lifecycle and response ownership.
- [Hosted registry acceptance](../docs/hosted-registry.md).

The external API documentation was checked on 5 November 2026.
New source and tests use AGPL-3.0-or-later under the repository's [license scope](../LICENSING.md).
