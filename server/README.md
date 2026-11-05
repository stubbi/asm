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
| `GET /metrics` | Return bounded internal request metrics; qualification remains pending |
| `GET /registry/v1/index.tsv` | Return the exact Linux compatibility feed, at most 1048576 bytes |
| `GET /registry/v1/index-macos.tsv` | Return the exact four-target macOS compatibility feed, at most 1048576 bytes |
| `GET /registry/v1/index-all.tsv` | Return the exact full six-target feed, at most 1048576 bytes |
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
The source now reserves one of eight process admission slots before connection creation.
It releases that slot after connection cleanup on success or failure, including a null connection result.
Recorded qualification covers only the sources and artifacts in the [image preflight](../docs/server-images.md#admission-image-preflight).
Later revisions require fresh checks.
The result and HTTP response do not retain a database admission slot.
Liveness and source identity do not request a slot.

When all eight slots are owned, the request returns the existing HTTP 503 response.
Admission uses at most sixteen atomic attempts and has no wait queue.
Contention can also cause temporary refusal before every slot is occupied.
This guard retains the canonical export error contract.
The [architecture proposal](../docs/architecture.md#default-public-interfaces) specifies HTTP 429 and bounded retry guidance for future public admission limits.
A versioned API change must introduce that response policy.
This source does not keep a persistent connection pool.
It does not read `ASM_DATABASE_POOL_SIZE`.

The connection runs `BEGIN READ ONLY`, the canonical reader guard, then the optional fixed export query.
Each command drains completely before the next command starts.
Connection, transaction setup, guard, export, and result handling share one two-second monotonic deadline.
The fixed connection options enforce read-only transactions, a one-second statement timeout, and a 200 ms lock timeout.
The guard checks the exact canonical migration digest and actual reader permissions.
The reviewed schema enforces non-null stored export bodies and canonical publication bytes.
Each export read separately rejects a null result before HTTP response creation.
Trusted administrator changes to database objects remain outside these guarantees.
No import means no ready catalog; the process refuses startup with exit 78.
Use the separate [operator procedure](catalog/README.md) to migrate, grant, bind namespaces, and import accepted records.

The export statement comes from `catalog/read-exports.sql`.
Only a router-selected literal enters its parameter array.
No request text becomes SQL or a database connection option.
The reader identity is exactly `asm_reader`.
The service receives no migration or operator credential.

The database result remains owned after its connection closes.
The HTTP library copies its exact byte length before the server releases that result.
Catalog responses use no large stack response buffer.
Each active metrics response uses a separate 16 KiB stack buffer.
JSON body storage can include the 4 MiB database result and its 4 MiB HTTP copy.
That is up to 8 MiB of body bytes per active JSON response, excluding library overhead and other allocations.
The limit of sixteen connections does not establish that the private 256 MiB memory proposal is sufficient.
Capacity and slow-reader behavior need separate measurements.
An HTTP allocation, header, or queue failure closes the connection after releasing response ownership.

SIGTERM and SIGINT stop admission and stop the HTTP daemon.
The integration suite checks a three-second idle shutdown bound.
Completion of every accepted response during shutdown remains unqualified.

## Candidate internal request metrics

`GET /metrics` uses the existing listener and HTTP request policy.
Keep this route behind the reviewed internal network and ingress policy.
The path itself supplies no authentication.
Application logic remains assembly on all three Linux ports.
Native qualification of this implementation remains pending.

The response uses Prometheus text format 0.0.4 with a final LF.
Its content type is `text/plain; version=0.0.4; charset=utf-8`.
It retains the existing cache and security headers.
The body has a 16384-byte limit and exactly 79 samples, including zero-valued series.
This fits the existing 200-sample and 64-KiB monitoring limits.

| Route label | Requests |
| --- | --- |
| `live` | `/health/live` |
| `ready` | `/health/ready` |
| `about` | `/api/v2/status` |
| `index` | All four compatibility export routes |
| `metrics` | `/metrics` |
| `other` | Other paths and application-handled overlong URIs |

Labels never contain request paths, package names, accounts, or credentials.
Unimplemented search and package routes receive no invented metric series.
Counters reset when the process restarts.

`asm_http_requests_total` has fixed `route` and `status_class` labels.
The status classes are `2xx`, `4xx`, and `5xx`.
Only responses accepted for queueing enter this counter.
A service-capacity `503` belongs to `5xx`, with its original route label.

`asm_http_request_duration_seconds` is a cumulative histogram with one fixed `route` label.
Its buckets are 0.005, 0.01, 0.05, 0.1, 0.5, 1, 2, and positive infinity seconds.
The response includes its bucket, sum, and count series.
For each route, the infinite bucket and count equal the sum of its request counters.

Timing starts at the first access-handler invocation, after MHD has received the request headers.
It ends when the response queue helper returns, before database-result release and metrics aggregation.
This includes application validation, SQL work, response copying, and queue preparation.
It excludes prior header receipt and subsequent client transfer.
A queued `2xx` does not establish delivery to the client.
The current scrape takes its snapshot before counting its own accepted response.

`asm_http_connection_failures_total` counts handled requests whose response could not be queued.
It has no labels.
Allocation, header-addition, and queue failures increment this counter without inventing an HTTP status or duration observation.
It does not count every transport failure or a client abort after queue acceptance.
MHD refusals and aborted requests before access-handler entry remain outside these application metrics.

One mutex protects the fixed aggregate table and its snapshot copy.
Rendering, allocation, SQL, network work, and clock calls occur outside that mutex.
Concurrent responses own separate output buffers.
These bounds do not establish deployed memory capacity or a hard scheduling deadline.

Clock failure, invalid elapsed time, and counter overflow make metrics unavailable until restart.
The server retains the last valid table and publishes no fabricated observations.
`GET /metrics` then returns `503` with code `metrics_unavailable`.
Its message is `Request metrics are unavailable. Restart the server.`
Ordinary routes retain their existing behavior.
An earlier valid snapshot can remain in flight when a later failure occurs.
Unexpected mutex failure terminates the process with a fixed diagnostic and exit `71`.

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
Install GNU libmicrohttpd 1.0.3 and libpq/PostgreSQL 16.15 for that host.
The Makefile selects the assembly port from the host architecture.
If you set `TARGET`, use the matching `x86_64-linux`, `aarch64-linux`, or `riscv64-linux` value.
This build does not cross-compile.
Use Python 3.11 or later and an OpenSSL command for the integration fixture.
Use a matching C compiler to build the test-only connection-failure interposer in the owned build directory.
The build-time C program checks ABI constants only.
It is not linked into the application.
Application routing, configuration policy, connection lifecycle, and deadlines are assembly.
Metrics aggregation and rendering also remain assembly.
The native C unit driver and fault interposer are qualification tools only.

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
Synthetic six-target source metadata distinguishes the Linux, macOS, and full feed vocabularies in the owned fixture.
It does not download or execute package artifacts.
Python supplies test orchestration only.
The capacity suite can inject a null connection result in a separate owned process through a prebuilt read-only library.
That library is a test fixture and is not part of the served application.
Set `ASM_SERVER_CONNECT_NULL_FIXTURE` to its fixed absolute path when a qualification image runs the suite directly.
The test never compiles or loads executable code from its temporary data directory.
The Makefile precompiles the metrics driver and fault interposer before the HTTP tests start.
Derived image qualifiers contain these read-only test tools; final runtime images exclude them.
The tests contain no compiler invocation or temporary executable fallback.

Tests cover private-file rejection, malformed configuration, duplicate fields, TLS identity failures, privileged-role rejection, and changed read permissions.
They also cover certificate replacement, a stalled handshake, encrypted-key prompt refusal, health, source identity, and idle SIGTERM.
Feed tests compare all four current exports byte for byte and check their content types.
They check fixed three-target, four-target, and six-target TSV vocabularies and refuse near-prefix request paths.
Database-result probes cover missing, null, duplicate, unavailable, oversized, and stalled results.
Trusted fixture administration temporarily changes a view for these probes, then restores it.
The maximum-size body probes test transport bounds; their repeated bytes are not canonical package records.
Rejection tests require the documented status, so a process crash cannot satisfy them.
Usage failures return 64; configuration and database refusal return 78.
Metrics initialization or synchronization failure returns 71.

The metrics driver checks fixed series, arithmetic, clock failures, overflow, mutex failures, and simultaneous updates and snapshots.
Six HTTP methods check exposition, rejected requests, SQL delay, concurrent scrapes, queue-failure ownership, and client abort semantics.
Queue-failure tests use the actual assembly executable with a derived-test-only library interposer.
They retain response-reference and database-result cleanup observations.

The server test gate also runs `test_capacity.py`.
Its saturation check holds eight database handshakes and requires the ninth request to return HTTP 503 without another connection.
It checks liveness, source identity, and complete same-process recovery through two independent waves.
Additional cases check admission cleanup after repeated database failures and client disconnects.
A disconnected HTTP client can retain database work until the existing deadline.
These tests do not establish immediate disconnect cancellation or shutdown draining.

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
The runtime and reference guards compare temporary-schema prefixes literally.
The retained migration bytes and checksum remain unchanged.
The runtime includes `catalog/reader-guard.sql` and reads the complete canonical ledger.
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
This run covers the original three-export contract, before the fourth-feed contract in PR #29.
Canonical image qualification and target runtime evidence remain separate requirements.
The four-export [test-first run 42012402145](https://github.com/stubbi/asm/actions/runs/42012402145) tested source `9ebcb125cf301b6dce481a3836ea482b1b53915f`.
Its sixteen runtime methods produced fifteen failures because the fourth route still returned HTTP 404.
Four errors came from a new, overbroad test expectation after trusted fixture administration made one view result null.
The corrected test requests the affected route and preserves its null-result refusal.
It does not require unrelated valid routes to fail after that trusted administrator change.
The reviewed SQL, reader guard, and enforced non-null storage constraints remain unchanged.
Local cross-assembly passed for x86-64 and AArch64 after the routing change.
Apple's clang rejected the RISC-V assembly attempt; that earlier check supplied no RISC-V result.
A later local check used Homebrew Clang 23.1.4 on 5 November 2026.
It assembled the runtime and configuration sources for x86-64, AArch64, and RV64GC/LP64D.
These six source checks did not link or execute an application.
The current `make -C server test` attempt refused the macOS host before compilation.
The current `make hosted-registry-test` attempt failed because reviewed PostgreSQL 16.15 fixture paths were unavailable.
Its six operator-plan tests passed, but no database test ran.
The port-evidence regression first failed because a fifteen-test log qualified; the corrected sixteen-test minimum then passed all nine checks.

The [prior foundation image run 41947880132](https://github.com/stubbi/asm/actions/runs/41947880132) passed eleven runtime tests per architecture without skips.
Those earlier tests did not cover canonical exports.
The [image guide](../docs/server-images.md#completed-prior-image-checks) retains their source revisions, executable digests, and execution limits.

The four-export [image run 42013635598](https://github.com/stubbi/asm/actions/runs/42013635598) tested merge revision `437fa424157d5e884a11bd2643b1eaca71674fc1`, containing source head `61181be91d31cc671e3827a7aa17c9e2b37afe71`.
Native AMD64 and ARM64 each passed all sixteen runtime methods without skips.
RISC-V user emulation ran sixteen methods in 63.995 seconds.
Six concurrent-response assertions received HTTP 503 instead of HTTP 200; the other fifteen methods passed.
The image workflow failed and did not publish images.
No causal fix has been established.
The [isolated diagnostic run 42035969713](https://github.com/stubbi/asm/actions/runs/42035969713) rebuilt that application source with a derived diagnostic layer.
Both observed eight-response waves passed the unchanged assertions, including their exact response bytes.
Instrumentation, a rebuild, and selected method execution make this diagnostic evidence; it does not qualify the original or current image.
CPU throttling occurred in the successful diagnostic waves and does not establish the cause of the original failures.
Fresh complete runtime and image checks remain required for the integrated source.

The metrics [test-first run 42079228127](https://github.com/stubbi/asm/actions/runs/42079228127) tested source `51b74f880703dff8bacc9cd9a329974c40ac920a`.
Native AMD64 and ARM64 each ran 17 HTTP tests.
All sixteen baseline tests passed; only the new metrics assertion failed with HTTP `404` instead of `200`.
The complete qualification records remain failed.
The downstream catalog-publication and build-failure-preservation steps skipped after that intentional failure.
Those skipped steps are not passes.
The result establishes the missing route before implementation, not successful metrics behavior in the later candidate.

[Run 42111761655](https://github.com/stubbi/asm/actions/runs/42111761655) tested metrics source `dc37fb2292614f07c81580b7723cac3fd3b4497b` on native AMD64 and ARM64.
Both jobs failed the first unit check, `zero_exposition`, before hosted HTTP execution.
Each job passed ten native-link and nineteen reference cases; neither completed the nineteen metrics unit checks or any hosted HTTP case.
Catalog publication and build-failure-preservation checks did not run.
The [original reports and shared failure log](../docs/server-metrics-evidence/42111761655/manifest.json) retain that result and its missing tool-hash evidence.
A local helper fixture reproduced the lookup's collision with a `# HELP` line.
Test-driver correction `240c371342c7e06a9a561dded7381d734802fb0a` changes no assembly or runtime behavior.
It has no complete native qualification result.

The isolated metrics source `dc37fb2292614f07c81580b7723cac3fd3b4497b` retains the earlier inline child-publication check.
Its result cannot establish the integrated publication gate.
The combined source must retain admission's shared child validator and the metrics descriptor checks.
That descriptor belongs to the baseline report; capacity cases cannot substitute for its six HTTP cases or 19 unit checks.
Combined runtime, image, and PostgreSQL 18 qualification remain pending.
Earlier receipts retain their original source and image bindings.

These requirements remain open:

- RISC-V64 image qualification of the combined source, with the earlier concurrent-response failures retained.
- Runtime and image qualification of the combined export, admission, and metrics contracts.
- Deployment qualification of the separate migration, grant, namespace assertion, and import procedures.
- Bounded hostname resolution compatible with private service discovery.
- Qualification of eight-slot admission and complete capacity recovery with the combined source.
- Persistent database connection reuse, if measurements justify it.
- Absolute HTTP header deadlines and qualified shutdown draining.
- Qualification of the combined fixed-label metrics and observed alert delivery.
- Public TLS, projected certificate rotation, network-denial tests, capacity, backups, WAL delivery, and isolated restore.
- Exact immutable images, artifact digests, provenance, and external HTTPS client checks.

No cluster resource, credential, DNS record, public route, or release artifact was changed by this checkpoint.

The admission test-first [native AMD64 run 42050169482](https://github.com/stubbi/asm/actions/runs/42050169482) tested source `f7987a5f3571f4c7a58f7e731b0127a0e263d3ab`.
All sixteen existing runtime methods passed in 8.319 seconds.
The capacity candidate then failed with `9 != 8`: the ninth request opened another database connection.
Its executable SHA-256 was `716eab55d79b1ef475300c3d22e70d41c5cd64e8a263c06f0fbf9218e2bce4ec`.
This retained failure establishes the missing admission behavior, not a passing implementation or recovery result.
The job had no two-CPU or 512 MiB runtime cap.
`make -j2` limited build parallelism only.
It was a behavioral diagnostic, not resource-capacity qualification.

Before publishing an admission-bearing image, run both runtime modules against that actual derived image.
The earlier sixteen-test image receipt cannot establish that the new admission code passed.
Its qualification stage must supply the new capacity suite and fixed read-only interposer.
Build that library before qualification starts; the qualifier needs no compiler or writable executable directory.
That image-gate integration remains required outside this source checkpoint.
Both image publication jobs have an explicit temporary hold until that gate is complete.

## Sources

- PostgreSQL 16 [connection control](https://www.postgresql.org/docs/16/libpq-connect.html): nonblocking restrictions, `PQconninfoParse`, and the encrypted-key callback.
- PostgreSQL 16 [command execution](https://www.postgresql.org/docs/16/libpq-exec.html) and [asynchronous processing](https://www.postgresql.org/docs/16/libpq-async.html): result ownership, parameters, and command draining.
- GNU [libmicrohttpd manual](https://www.gnu.org/software/libmicrohttpd/manual/libmicrohttpd.html): daemon lifecycle and response ownership.
- Pinned [libmicrohttpd 1.0.3 source](https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz): queue and completion boundaries.
- Prometheus [text exposition](https://prometheus.io/docs/instrumenting/exposition_formats/): metric families and cumulative histogram representation.
- [Hosted registry acceptance](../docs/hosted-registry.md).

The external API documentation was checked on 5 November 2026.
New source and tests use AGPL-3.0-or-later under the repository's [license scope](../LICENSING.md).
