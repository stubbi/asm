# Registry infrastructure evidence

Date: 7 November 2026. These are historical local source checks, not release or deployment qualification.

The [8 November V2 record](registry-v2-evidence.md) describes subsequent signed distribution and native-client checks.
Counts and source digests below remain specific to the 7 November checkpoint.

The source checkpoint starts at `d958e0282b2b70639a2f490cd149a174907ef3fc` and includes this branch's unpublished changes.
No runtime image, public endpoint, storage account, DNS record, or cluster resource was published.
The [hosting guide](hosting.md) states current behavior and operating requirements.
The [research record](registry-infrastructure-research.md) records external sources and prices separately.

## Storage, mirrors, and observations

The host was Apple Silicon macOS 15.6.1 with Python 3.14.6.
S3 adapter checks used the hash-pinned dependencies in `requirements-storage.txt`.
The static origin used nginx 1.30.6.

| Check | Result | Scope and limit |
| --- | --- | --- |
| `make registry-infrastructure-test` with the pinned SDK and real nginx | 79 tests with one Linux-only skip; 98 registry tests and 24 publisher-tool tests passed | Storage, snapshots, mirrors, real origin transfers, delayed observations, site integration, and private operator tools |
| `make site-test` | 104 Node checks and 310 Python checks passed | Existing site behavior and generated observation metadata; no published-site change |
| `make verifier-test` | Both Go packages passed with the race detector | Existing transport and cryptography adapter regressions |
| Hosted registry suite in owned PostgreSQL 16.15 | 33 tests, one platform-specific skip | The macOS ACL check does not apply on Linux; all applicable database, operator, and distribution checks passed |
| Operator source, entrypoint, preparation, and publication checks | Initial 37-case suite and later 34-case selected suite passed, each with one fixture skip | Projected root-owned group-readable credentials need the container fixture; this was not image qualification |
| Mirror suite on Linux Python 3.11 | 29 passed | Includes controlled rejection of deeply nested JSON and forced missing-object repair |
| Local RustFS 1.0.4 compatibility suite | Seven passed | Five live provider checks and two configuration checks; not production storage qualification |

The owned Linux fixture ran through AMD64 emulation on the same Apple Silicon host.
Its PostgreSQL tools and libpq were both 16.15.
The PostgreSQL suite created disposable databases and accepted no production connection target.

Mirror checks cover immutable retries, concurrent head changes, rollback, unrelated history, corrupt bytes, and interrupted transfers.
Unchanged synchronization performs no artifact reads or writes.
An explicit audit reads retained objects; missing-object repair does not replace corruption.
These observations establish the tested transfer behavior, not a throughput or total-cost benchmark.

The database integration checks a storage snapshot before opening operator credentials.
It preserves that snapshot after a stale-revision refusal, then checks import and idempotent replay.
Its four canonical exports retain `not-run` evidence for checks without retained catalog evidence.

The [static origin record](../deploy/mirror/README.md#verification-and-limits) identifies the tested nginx source and executable digests.
It records GET, HEAD, range, conditional, refusal, interruption, privacy, and log-import checks.
The [local S3 record](../deploy/mirror/README.md#local-s3-compatibility-check) identifies the exact RustFS image and operation results.
Neither result qualifies ingress TLS, CDN behavior, production permissions, distributed durability, or restoration.
The systemd units are operational references; no systemd verifier was available on the tested hosts.

## Direct publication checkpoint

The new SQL authority initially passed 17 owned PostgreSQL 16.15 tests without skips.
The final upload-expiry correction then passed three focused SQL tests.
The final migration SHA-384 is `142273d53453fa1396aa15e589b3a6137755dbafb220aac500bcdfc12170b033d1a8db64a1c7449d2c655a9387ea2611`.
The migration, operator pin, and assembly build marker agree.
Eight private-admin cases pass on macOS, including actual inherited-ACL regressions.
Linux admin and real operator-CLI checks passed seven applicable cases, with two macOS-only skips.

The SQL suite exercises the actual coordinator, checker, private retained store, and atomic immutable intent commit.
It checks revocation, expiry, exact operation scopes, concurrent retries, checker-policy substitution, fences, quotas, and late outbox commits.
A current replacement credential cannot renew an expired reservation; that upload returns HTTP 410.
An expired current credential remains HTTP 401 before task lookup.
All credential refusals use the same public problem and Bearer challenge.
Private SQL error payloads do not enter HTTP responses.

The assembly publisher passed all 16 HTTP methods against source-built OpenSSL 3.5.9.
The final raw-log run took 97.058 seconds and included the actual 60-second post-header upload deadline.
Its executable SHA-256 is `78dc5d884e3045db4beea0fc54d2d9c7e7f621ca9afdc1202fe7b26a12d6c063`.
The earlier successful 16-method checkpoint took 101.810 seconds and produced a different executable digest.
No byte-reproducible build claim follows from those results.
The [publisher guide](../server/publisher/README.md) records source, library, loader, and artifact identities.
The default reader separately passed all 16 regressions; later publisher-only changes preserve its preprocessed instructions and data.

The checker ran in a disposable Debian Trixie runtime with Python 3.13.5 and OpenSSL 3.5.7.
Its local image identity was `sha256:57cf0fbad222c78321fe77fcb6f1f61dbe7d154bcccebf5a2ddfcad85e6cc323`.
Actual boundary probes confirmed a non-root UID, no capabilities, no new privileges, seccomp, and unavailable external networking.
They checked read-only task inputs, absent credential environment fields, 512 MiB memory, one CPU, and sixteen processes.
An image with declared writable volumes was refused before execution.
The 7 November checker policy digest is `58406bc316899173b2d827b2a35f6fe61c83b327d24adf309ad0d150e5e2e16c`.
The inputs were synthetic; no production credential or signer entered the checker.
These checks do not establish isolation against every kernel vulnerability or qualify Kubernetes worker deployment.

At this checkpoint, the API stopped at `committed`, with no usable release link.
V2 retained bytes remain private; conditional storage does not establish bucket access policy.
TUF distribution, native V2 installation, and lifecycle operations then required separate implementation.
Deployment and restoration still require qualification.

## Retained failures and corrections

- Host disk exhaustion paused the Linux guest on write errors.
  An initial server build exited 255; no runtime test or successful binary came from that attempt.
  A production-image build was interrupted with exit 130 and supplied no image qualification.
- An initial site run failed two writes and returned HTTP 503 from its free-space guard.
  The authorized dependency and Rust-output cleanup restored enough space for the later complete site checks.
  Source, branches, and Git history were preserved.
- The PostgreSQL container initially combined 16.15 tools with libpq 18.6.
  Matching 16.15 runtime and development packages resolved preparation; the version guard was retained.
- An initial database suite failed because Git was absent from the disposable fixture.
  Installing that required tool allowed the later complete suite; the failed attempt supplied no database qualification.
- A login-free shell selected unsupported Python 3.9 and failed to import `tomllib`.
  Later checks selected the documented Python version explicitly.
- Review reproduced repeated artifact reads during unchanged synchronization.
  The corrected path checks metadata only; separate audit and repair commands retain their explicit read cost.
- Linux Python 3.11 exposed an uncaught recursion failure for deeply nested JSON.
  The validator now returns a controlled format error; the retained Linux regression passes.
- Invalid DEFLATE data and deeply nested source TOML escaped their parser error boundaries.
  The shared validator now returns controlled errors; hostile source inputs produce bounded checker failure receipts.
- Inherited macOS ACL grants bypassed mode-only token and local-store privacy checks.
  Descriptor ACL checks now run before secret or stored-object bytes are written.
  Existing files and permissions remain unchanged after refusal.
- Stricter storage ACL checks initially rejected a supported deny-only ledger input directory.
  The full 79-case infrastructure run retained that failure.
  Ledger input now uses its own trusted traversal and deny-only ACL policy; the complete gate passed afterward.
- Public SQL refusals initially exposed private error shapes, and some credential refusals lacked an HTTP challenge.
  Fixed public problems now cover every supported status; unknown database statuses fail closed with HTTP 503.
- The first container probe failed because the local daemon could not see host checkout paths.
  A later probe refused a lone-file mount whose parent lacked private ownership.
  The runner now mounts a private task view and requires matching coordinator/daemon paths.
- The first disposable runtime declared a writable image volume despite its read-only root.
  The runner now refuses such images; the later clean runtime passed the stated boundary checks.
- The first OpenSSL 3.5.9 build reached its explicit 20-minute limit and exited 124.
  One bounded ten-minute continuation completed with unchanged source and two jobs.
  Source, objects, installed libraries, and both archive copies stayed below the stated 500 MiB incremental disk ceiling.

Additional nginx preparation and provider-inventory failures remain in their component records.
Later passing checks do not erase these earlier results.
Agent review informed corrections; it did not replace deterministic gates.

## Remaining acceptance work

Public publishing, native authenticated mirror selection, and complete V2 distribution have separate acceptance conditions.
See the [publication contract](specs/publication.md) and [architecture gates](architecture-gates.md).
Provider permissions, TLS, signing custody, capacity, spending limits, and complete isolated restore remain activation requirements.
Source tests do not establish a deployed service or a recovery result.
The new CI steps are source configuration; no CI execution result is claimed here.
The existing native server workflow reuses its PostgreSQL and HTTP libraries for the new publisher checks.
Its Linux x86-64 job builds the pinned OpenSSL release and runs authority, tool, and HTTP gates with read-only repository permissions.
