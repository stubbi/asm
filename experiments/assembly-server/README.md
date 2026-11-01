# Assembly application server experiment

This checkpoint demonstrates an assembly application calling established HTTP and PostgreSQL libraries through the C ABI.
It runs locally on Linux x86-64.
It has no public deployment or performance comparison.
See [the reproducibility results](RESULTS.md) for the current checks.
The [initial checkpoint](INITIAL_RESULTS.md) retains the earlier results and failures.

The experiment has four read routes:

| Route | Result |
| --- | --- |
| `/` | The implementation boundary and experiment status |
| `/health/live` | Process liveness without a database request |
| `/health/ready` | Required catalog reads, database role restrictions, and the exact migration checksum |
| `/prototype/packages?q=&after=` | Parameterized search with 20 records per page and an explicit next name |

The search response uses experimental schema 0.
Its cursor is not the stable v2 API cursor.
The next page follows ASCII package order.
A look-ahead row determines whether another page exists.
The endpoint never presents a truncated first page as a complete catalog.

## Implementation boundary

| Component | Implementation |
| --- | --- |
| Request routing, input bounds, connection lifecycle, deadlines, response handling, and shutdown | `server.s`, GNU Intel-syntax assembly |
| HTTP framing, parsing, connection admission, and thread management | GNU libmicrohttpd 1.0.3, a C library |
| PostgreSQL wire protocol, authentication, and available database TLS support | libpq 16.15, a C library |
| Query semantics and retained registry constraints | Fixed parameterized SQL and PostgreSQL |
| Process startup, allocation used by libraries, and standard runtime functions | The system C runtime |
| Build-time ABI assertions | `abi-check.c`, a separate executable that is not linked into the server |
| Fixture creation and tests | Python orchestration, an included SQL migration, and a fresh local PostgreSQL cluster |

There is no C, Rust, Python, or shell application backend behind the assembly routes.
The server is a dynamically linked executable.
Its runtime dependencies are part of its footprint and trust boundary.
Its executable size does not represent the size of the complete service.

GNU libmicrohttpd was built without its HTTPS feature for this experiment.
Both the HTTP listener and database host are fixed to loopback.
The tests use a local PostgreSQL connection.
They do not qualify public TLS, remote certificate validation, or certificate rotation.

The database schema originated in an unpublished behavioral reference at commit `286a75c9d806aaed3e91bd54785db2ac60f5310a`.
The [included migration](fixtures/0001_registry.sql) preserves that exact schema.
The copied role and readiness checks retain that checkpoint's restrictions.
The included fixture applies the exact migration before the assembly server starts.
It seeds fixed test records through parameterized SQL.
No external reference checkout or executable is required.
This fixture does not implement or qualify a live publishing service.

## Bounds and ownership

The HTTP library admits at most 16 connections.
Each connection has a 32 KiB HTTP memory allowance and a 256 KiB thread stack.
The inter-thread wake channel lets the listener release slots after connections close.
Responses close the connection after completion.
The library's two-second connection timeout measures inactivity.
It does not impose an absolute header-read deadline.

Each database request owns a separate connection and result.
No thread shares a PostgreSQL connection with another thread.
The connection, flush, read, and result-drain stages share a two-second monotonic deadline.
All socket waits use the remaining time.
Queries also have a one-second PostgreSQL statement timeout and a 200 ms lock timeout.
The connection fixes read-only transactions and its schema search path.

The implementation rejects:

- Request URLs longer than 2048 bytes.
- More than 64 headers or 16 KiB of header names and values.
- Methods other than `GET` and read requests with bodies.
- Unknown or repeated query fields.
- Query text longer than 160 bytes and page names longer than 104 bytes.
- Decoded NUL bytes, controls, and non-ASCII query bytes.
- Database results larger than 16 KiB or with an unexpected shape.
- Configuration files that are symlinks, nonregular, public, empty, or larger than 4096 bytes.
- Database roles with missing read grants or privileged memberships.
- A missing, changed, or failed migration.

Search strings enter `PQsendQueryParams` as text parameters.
Quotes and percent signs do not become SQL syntax or wildcard expressions.
PostgreSQL generates JSON with its standard JSON functions.
The application copies the response through the HTTP library before releasing the database result.

The server logs fixed messages only.
It does not log query strings, database errors, or credentials.
The configuration file contains a trusted operator-supplied connection URL.
The program reads that file once before starting threads.

## Reproduce the local checks

Use Linux x86-64, GNU libmicrohttpd 1.0.3, PostgreSQL 16.15, and Python 3.10 or later.
Run tests as an ordinary user, without `sudo`.
The [dependency recipe](DEPENDENCIES.md) supplies pinned sources and exact local build commands.
The ABI check rejects different library headers or linked runtime versions.
It also checks the operating-system structures, system calls, flags, and libpq enums used by the assembly.
Review the boundary before changing those pins.

Run this command from the repository root to build the server:

```sh
make -C experiments/assembly-server \
  MHD_PREFIX=/path/to/libmicrohttpd-prefix \
  PG_PREFIX=/path/to/postgresql-prefix
```

Run the tests from the repository root:

```sh
make -C experiments/assembly-server test \
  MHD_PREFIX=/path/to/libmicrohttpd-prefix \
  PG_PREFIX=/path/to/postgresql-prefix
```

The fixture accepts no existing database URL, service name, or data directory.
It creates a private cluster, binds PostgreSQL to loopback, and uses random credentials.
It checks the connected server's data directory before issuing database changes.
Each catalog has separate migrator, operator, and reader roles.
Cleanup stops only the owned processes and removes their temporary files, including after a failed setup.
The tests do not download artifacts or contact public endpoints.

To inspect the application manually, prepare a local reader account that meets the included schema and role checks.
Run the following command from the repository root:

```sh
build/assembly-server/asm-hub-prototype 8081 /path/to/reader.url
```

The connection URL file must have mode `0600`.
The server accepts an HTTP port from 1024 to 65535.
The tests use the real network stack, HTTP library, PostgreSQL library, database, and assembly executable.

## Production work that remains

The implementation proves that the application can use assembly at the HTTP and database boundary.
It does not determine the production search or distribution architecture.

The current query scans bounded results from the authoritative catalog.
It is unsuitable as the design for global search.
A replaceable indexed search projection, ranking policy, synchronization contract, and measured query plans need their own implementation.
Artifact delivery and cached metadata delivery also need independent contracts.

The current thread model makes blocking request work explicit and bounded.
A production service needs measured scheduling, connection reuse, backpressure, and absolute request deadlines.
That work must preserve prompt liveness under saturation.
The local experiment's connection cap does not establish a global denial-of-service control.

The stable v2 API, deterministic v1 export, version detail, download observations, and fixed-label metrics remain unimplemented here.
The [architecture proposal](../../docs/architecture.md) and [acceptance gates](../../docs/architecture-gates.md) define the remaining work.
The included [HTTP tests](test_server.py) and [fixture tests](test_fixture.py) cover this checkpoint's implemented behavior.
Authenticated public publication and untrusted build execution remain separate services.

The frontend direction is semantic HTML with selective HTMX enhancement.
This checkpoint does not include frontend code.
Full documents, fragment responses, cache variation, accessible errors, and ordinary form fallbacks need explicit tests.

Compare implementations only after they serve the same workload and response contract.
Keep data, database connections, query plans, caching, TLS, concurrency, and connection reuse equal.
Measure tail latency, throughput at saturation, CPU, memory, errors, and recovery.
Assembly source alone does not establish a better result.

## Sources

- [GNU libmicrohttpd 1.0.3 release announcement](https://lists.gnu.org/archive/html/info-gnu/2026-04/msg00000.html)
- [GNU libmicrohttpd source archive](https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz)
- [GNU libmicrohttpd thread and event-loop model](https://www.gnu.org/software/libmicrohttpd/manual/html_node/microhttpd_002dintro.html)
- [PostgreSQL asynchronous command processing](https://www.postgresql.org/docs/16/libpq-async.html)
- [PostgreSQL connection control](https://www.postgresql.org/docs/16/libpq-connect.html)
- [HTMX documentation](https://htmx.org/docs/)

The GNU source archive used here has SHA-256 `7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a`.
The tested libpq package has SHA-256 `3f96dd36bcd7841172c1ead4965da20a193bb9ccf9a93a3f5a3ac7f56369dbb1`.
That package was `libpq5_16.15-0ubuntu0.24.04.1_amd64.deb` in the initial checkpoint.
The current [source-build recipe](DEPENDENCIES.md) pins PostgreSQL separately.
These hashes identify their recorded inputs.
