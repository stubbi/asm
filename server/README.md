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
`hostaddr` optionally supplies the numeric IPv4 connection address.
This explicit address avoids a synchronous DNS lookup inside libpq's nonblocking connection API.
It is an operator-supplied address, not an embedded service address.
Do not hardcode a Kubernetes service IP in this source.

When `hostaddr` is absent, startup resolves the certificate hostname once through glibc.
It selects the first IPv4 stream/TCP result and appends its numeric address to the owned URL.
The hostname remains unchanged for TLS verification.
The selected address remains fixed until process restart; requests perform no further DNS lookup.
An explicit valid `hostaddr` bypasses resolution and its timer.

Resolution uses one absolute two-second monotonic budget.
One kernel-owned POSIX timer sends SIGKILL at that deadline, including when a library blocks ordinary signals.
This contract assumes a responsive Linux kernel and fair scheduling; it is not a hard real-time guarantee.
The process deletes its timer before database work and checks the deadline again.
DNS deadlines can terminate with status 78 or SIGKILL; other configuration refusals return 78.
The inherited SIGALRM action, interval timer, and signal mask remain unchanged on success.
Startup refuses any nonzero inherited interval-timer field or pending SIGALRM.

An early timer or signal refusal can exit without a diagnostic, before a bounded diagnostic path exists.
Check inherited timer state and permission for POSIX timer creation, arming, and deletion.
The private cluster's kernel and syscall policy remain separate qualification requirements.

### Prepare a projected key

`asm-hub prepare-config SOURCE_DIR DEST_DIR` makes a private snapshot without starting the service or reading serving environment variables.
The input key is always `SOURCE_DIR/database.url`; the output is always `DEST_DIR/private/database.url`.
Use absolute directory paths of at most 1024 bytes.
Except for `/`, omit trailing slashes and final `.` or `..` components.
Final directory components must not be symlinks; their ancestors remain trusted operator inputs.

Run this command with the server's nonzero real UID and GID, with matching effective identities.
Both roots require root/current ownership, the selected GID, and no other-write permission.
A group-writable input root must be on a read-only mount.
The output root may be group-writable because its child is private.

The source can use Kubernetes projection symlinks inside the pinned root and mount.
Linux `openat2` confines the fixed key; unsupported or blocked calls fail closed without a filesystem fallback.
The source must be a single-link regular file, owned by root/current UID and the selected GID.
Only owner read/write and group read permission bits are permitted; at least one read bit is required.
The file must contain 1–4096 bytes of printable ASCII, with one optional final LF.
Preparation preserves that LF and does not interpret the URL.
Serving still performs the URL and TLS checks above.

The private child must be owned by the current UID with exact mode `0700`.
The completed file has the current UID, selected GID, exact mode `0600`, and one link.
An identical valid destination is a quiet no-op; a different destination is refused without replacement.
Temporary-file writes handle short I/O and bounded interruptions, then sync before atomic no-replace publication.
An ordinary failure removes only the invocation's temporary file; an empty private child can remain.
This does not promise whole-path race freedom, isolation from same-UID writers, or power-loss directory durability.

After building, prepare the snapshot:

```sh
build/server/asm-hub prepare-config /projected /prepared
```

Success returns status 0 without output.
Use `/prepared/private/database.url` as `ASM_DATABASE_URL_FILE` in the serving process.
Mount that prepared volume read-only in the serving container.
URL changes require a new Pod; certificate and key projections remain separate for per-connection rotation.
No cluster configuration or rollout is activated by these source changes.

Certificate files are opened by libpq for each new connection.
No connection or certificate is cached by this process.
Projected-volume rotation must still pass against the actual private deployment.

## Build and test

Use a matching Linux x86-64, ARMv8-A AArch64, or RV64GC/LP64D host.
Install glibc 2.34 or later, GNU libmicrohttpd 1.0.3, and libpq/PostgreSQL 16.15 for that host.
The Makefile selects the assembly port from the host architecture.
If you set `TARGET`, use the matching `x86_64-linux`, `aarch64-linux`, or `riscv64-linux` value.
This build does not cross-compile.
Use Python 3.11 or later and an OpenSSL command for the integration fixture.
The build-time C program checks ABI constants only.
It is not linked into the application.
Application routing, configuration policy, connection lifecycle, and deadlines are assembly.

The [reference dependency recipe](../experiments/assembly-server/DEPENDENCIES.md) supplies reviewed source pins.
For this runtime, configure PostgreSQL with `--with-openssl`.
The reference recipe's TLS-free PostgreSQL build cannot pass these tests.
Keep HTTP transport behind the separately qualified ingress TLS boundary.

Build the service from the repository root:

```sh
make -C server all MHD_PREFIX=/path/to/mhd PG_PREFIX=/path/to/postgres SOURCE_REVISION=FULL_COMMIT_ID
```

The startup tests need fixed test files with different owners.
Use a disposable Linux test host with `sudo` for that fixture setup.
The server and PostgreSQL tests run as the current non-root user.
Run these commands from the repository root:

```sh
ownership_parent=$(mktemp -d /tmp/asm-startup-owned.XXXXXXXX)
sudo python3 server/test_startup.py --prepare-ownership-fixtures "$ownership_parent/ownership" "$(id -u)" "$(id -g)"
ASM_SERVER_STARTUP_OWNERSHIP="$ownership_parent/ownership" make -C server test MHD_PREFIX=/path/to/mhd PG_PREFIX=/path/to/postgres SOURCE_REVISION=FULL_COMMIT_ID
sudo python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$ownership_parent"
```

The startup suite runs 38 hosted runtime methods through the real executable.
It covers projected snapshots, file preservation, timer denial, masked resolver stalls, and post-deadline survival after successful timer deletion.
The separate `make -C server test-kernel-timer` target probes five kernel/API cases without application linkage.
Native application qualification remains pending until its recorded run succeeds.

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

Tests cover private-file rejection, malformed configuration, duplicate fields, TLS identity failures, privileged-role rejection, and changed read permissions.
They also cover certificate replacement, a stalled handshake, encrypted-key prompt refusal, health, source identity, and idle SIGTERM.
Feed tests compare all four current exports byte for byte and check their content types.
They check fixed three-target, four-target, and six-target TSV vocabularies and refuse near-prefix request paths.
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

[Image run 41947880132](https://github.com/stubbi/asm/actions/runs/41947880132) later passed all 11 runtime cases per architecture, without skips.
AMD64 and ARM64 used native instruction execution; RISC-V64 used QEMU user emulation.
The tested PR merge revision was `09a5a2fb63185fedb9dd9b58d26199a0ea1f884f`, containing source head `4fe2c25277ed40a163b48b727ab814225d227cf8`.
These results do not qualify head `7d684055fc972fd511e450b77f6f0dda331cd06c` or later changes.
The [image guide](../docs/server-images.md#completed-prior-image-checks) records executable digests and the remaining gates.

These earlier foundation image results do not qualify canonical HTTP or startup additions.

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
This run covers the original three-export contract, before the fourth-feed contract in PR #29.
Canonical image qualification and target runtime evidence remain separate requirements.
The four-export [test-first run 42012402145](https://github.com/stubbi/asm/actions/runs/42012402145) tested source `9ebcb125cf301b6dce481a3836ea482b1b53915f`.
Its sixteen runtime methods produced fifteen failures because the fourth route still returned HTTP 404.
Four errors came from a new, overbroad test expectation after trusted fixture administration made one view result null.
The corrected test requests the affected route and preserves its null-result refusal.
It does not require unrelated valid routes to fail after that trusted administrator change.
The reviewed SQL, reader guard, and enforced non-null storage constraints remain unchanged.
Local cross-assembly passed for x86-64 and AArch64 after the routing change.
Apple's installed clang cannot assemble the RISC-V target; no local RISC-V assembly or execution result is claimed.

These requirements remain open:

- Runtime qualification of canonical HTTP serving on ARM64 and RISC-V64.
- Runtime and image qualification of the integrated four-export catalog contract.
- Deployment qualification of the separate migration, grant, namespace assertion, and import procedures.
- Integrated native and full-guest qualification of the startup resolver and projected-key preparer.
- Private-cluster ownership, `openat2`, timer/seccomp policy, and configuration-rollout qualification.
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
- Linux man-pages 6.19 [POSIX timer creation](https://man7.org/linux/man-pages/man2/timer_create.2.html) and [absolute timer arming](https://man7.org/linux/man-pages/man2/timer_settime.2.html).
- glibc 2.41 [SIGEV_SIGNAL timer implementation](https://github.com/bminor/glibc/blob/glibc-2.41/sysdeps/unix/sysv/linux/timer_create.c).
- [Hosted registry acceptance](../docs/hosted-registry.md).

The external API documentation was checked on 5 November 2026.
New source and tests use AGPL-3.0-or-later under the repository's [license scope](../LICENSING.md).
