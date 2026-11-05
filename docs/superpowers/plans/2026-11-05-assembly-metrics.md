# Bounded assembly metrics implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose bounded internal request metrics without changing catalog bytes, database permissions, or request admission.

**Architecture:** Keep routing, measurement, aggregation, and rendering in assembly on all three Linux ports.
Measure handler entry through response queueing, using stack-owned request state and one fixed aggregate table.
Copy a consistent snapshot under a short mutex, then render outside that mutex.

**Tech Stack:** GNU assembly; Linux LP64; libmicrohttpd 1.0.3; libpq 16.15; existing pthread/libc calls; Python and C tests only.

**Spec:** [Runtime contract](../../../server/README.md), [architecture operations gate](../../architecture-gates.md), and the acceptance contract below.
The existing monitoring contract requires bounded `asm_*` metrics without user-derived labels.
This plan specifies the missing assembly implementation; it does not establish deployed behavior.

## Global constraints

- Start from public main `4e1685d7a0c0deb3fd510d3b531cbc8409df30b2` in `codex/metrics`.
- Read [foundation](../../brand/foundation.md), [messaging](../../brand/messaging.md), purpose, security, licensing, and applicable `AGENTS.md` before implementation.
- Serve operators through understandable failure signals. Earn trust with scoped evidence and fixed resource bounds.
- Preserve assembly application logic on x86-64, AArch64, and RV64GC/LP64D Linux.
- Preserve configuration ownership, TLS policy, SQL guards, canonical responses, deadlines, admission, and shutdown behavior.
- Preserve libmicrohttpd 1.0.3 and libpq 16.15. Add no runtime dependency.
- Do not change the CLI, reference experiment, private manifests, alerts, startup preparation, capacity harness, or drain behavior.
- Add `GET /metrics` on the existing listener. Keep deployment exposure internal through existing network and ingress policy.
- The route adds no authentication boundary. Do not describe an HTTP path as intrinsically private.
- No local image layers, large builds, CI dispatch, publication, or production operations belong to this planning task.

## Acceptance contract and choices

### Timing and ownership

Start the monotonic timer at the first access-handler invocation, immediately after checking the handled sentinel.
Stop it immediately after the common queue helper returns, before `PQclear` and metrics aggregation.
Count only responses that `MHD_queue_response` accepted.
This includes parsing performed inside the application, routing, SQL work, response copying, and queue preparation.
It excludes prior header receipt, later client transfer, and metrics aggregation.
A queued `2xx` does not establish client delivery.

Preserve `req_cls` values `0`, `1`, and `2`, the URI callback, and existing URI/error responses.
Keep `{start_ns:u64, route:u32, clock_valid:u32}` in the handler's stack frame.
Never store request strings, package identifiers, account identifiers, sockets, or credentials in the aggregate table.
Repeated access callbacks with sentinel `2` neither measure nor count again.
Header parsing failures inside MHD, connection-limit refusal, and pre-handler aborts remain outside these request metrics.
Post-queue disconnects retain their queued status and one observation.

Pinned source was inspected on 2026-11-05: [GNU libmicrohttpd 1.0.3 archive](https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz).
Its SHA-256 is `7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a`.
`src/include/microhttpd.h:1707,2769,3807` defines separate completion notification and response queue APIs.
`MHD_REQUEST_TERMINATED_COMPLETED_OK` concerns finished sending, rather than queue acceptance.
The header excludes never-presented requests from completion notification.
However, `src/microhttpd/connection.c:5648–5655` sets `client_aware` before the URI callback.
The close path at `1305–1310` checks that flag before notification.
Thus URI-created state can receive completion before access-handler entry in this pinned implementation.

Reject transfer-completion timing for this increment.
It requires a new request-context lifecycle, termination classification, and sentinel ownership across timeout, abort, and stop paths.
Reject timestamps in the URI callback because they would change the measurement boundary and request ownership.
Reject heap allocation per measured request and independent atomic histogram fields.
The latter cannot provide the required coherent snapshot without another consistency mechanism.

### Fixed exposition

Use Prometheus text format `0.0.4`, UTF-8, LF endings, and a final LF.
Return `Content-Type: text/plain; version=0.0.4; charset=utf-8`, `Cache-Control: no-store`, and existing security headers.
Use no compression, timestamps, exemplars, dynamic names, or negotiation-dependent formats.
Follow the [primary exposition specification](https://prometheus.io/docs/instrumenting/exposition_formats/) and [histogram guidance](https://prometheus.io/docs/practices/histograms/), reviewed 2026-11-05.

| Route label | Existing paths |
| --- | --- |
| `live` | `/health/live` |
| `ready` | `/health/ready` |
| `about` | `/api/v2/status` |
| `index` | All four existing `/registry/v1/index*` feed paths |
| `metrics` | `/metrics` |
| `other` | Every other path, including an overlong URI |

Classify bounded decoded paths through fixed comparisons before method/header/query rejection.
Use `other` directly for the URI-length marker; do not scan that rejected path again.
Known paths retain their route label for application-generated `4xx` responses.
Emit no `search`, package, version, or other unimplemented route series.

| Series | Labels and behavior | Fixed samples |
| --- | --- | ---: |
| `asm_http_requests_total` | `route`, `status_class` in `2xx`, `4xx`, `5xx`; accepted queues only | 18 |
| `asm_http_request_duration_seconds_bucket` | `route`, cumulative `le` in `0.005`, `0.01`, `0.05`, `0.1`, `0.5`, `1`, `2`, `+Inf` | 48 |
| `asm_http_request_duration_seconds_sum` | `route`; integer nanoseconds rendered as decimal seconds | 6 |
| `asm_http_request_duration_seconds_count` | `route`; equal to that route's accepted-queue count | 6 |
| `asm_http_connection_failures_total` | No labels; handled requests whose response could not be queued | 1 |

Emit all zero series at startup: exactly **79 samples**, including the failure counter.
Expose one `HELP` and `TYPE` declaration per metric family before its samples.
The request and histogram `HELP` text must say queue acceptance and exclude header receipt and client transfer.
The failure counter does not count all transport failures or post-queue client aborts.
Do not invent an HTTP status when queueing fails.
Capacity rejection remains HTTP `503`, with the original route and `status_class="5xx"`.

Use one 16,384-byte stack response buffer only while serving `/metrics`.
The snapshot uses at most 640 additional bytes.
Bound every append and prove the worst rendering fits, including maximum counters, HELP text, and all zero series.
An internal bound breach returns the fixed `503` response; never expose truncated text.
The result stays below the existing 200-sample and 64-KiB scrape limits.
Concurrent scrapes own separate buffers; MHD copies each response before its buffer goes out of scope.
A scrape contains the snapshot taken before that scrape's own queue acceptance.

### Concurrency and failures

Use one explicitly initialized pthread mutex around table updates and snapshot copies.
Allocate 64 bytes with 16-byte alignment for its opaque storage.
Require native `sizeof(pthread_mutex_t) <= 64` and alignment at most 16 before linking.
Do not encode `PTHREAD_MUTEX_INITIALIZER` bytes in assembly.
Perform no allocation, rendering, clock call, SQL, or network call while holding the mutex.
Destroy it only after MHD stops and joins its request threads.
Initialization failure prevents the listener from opening and returns a fixed redacted error with exit `71`.
Unexpected lock/unlock failure terminates the process with a fixed redacted error; do not continue with uncertain synchronization.
Use `asm-hub: request metrics could not start.` and `asm-hub: request metrics synchronization failed.` respectively, each with a final LF.
This is bounded storage and work per critical section, not a hard scheduling-latency guarantee.

Under the mutex, check all affected unsigned 64-bit increments and additions before changing any field.
On overflow, retain the last valid table and latch metrics unavailable until restart.
Never wrap, saturate individual histogram fields, reset counters silently, or expose partial updates.
The same snapshot must satisfy cumulative buckets, `+Inf == count`, and `count == sum(status-class counters)` for each route.

Validate `CLOCK_MONOTONIC` success, nonnegative seconds, nanoseconds below one billion, conversion arithmetic, and `end >= start`.
Clock failure or an invalid elapsed interval latches metrics unavailable; do not invent a zero-duration observation.
Subsequent `/metrics` requests receive the fixed `503` response while ordinary application routes retain their behavior.
Use code `metrics_unavailable` and message `Request metrics are unavailable. Try again shortly.` for that new route's error.
Do not reuse its database-error message or change existing route errors.
A valid snapshot already queued before a later clock failure can still complete.
An unqueued response increments only the failure counter; it creates no request or histogram observation.
Count MHD response allocation, header-addition, and queue failures through that same terminal path.
Retain existing response and `PGresult` release behavior on every path.

## Review focus

- Duplicate callbacks and overlong URIs preserve one observation and existing sentinel/error behavior. Test in Task 2.
- Concurrent readers never expose inconsistent buckets, count, sum, or shared response bytes. Test in Tasks 1 and 2.
- Clock faults and near-overflow values produce unavailable metrics without fabricated latency. Test in Task 1.
- Response allocation and queue failures preserve ownership and increment the diagnostic exactly once. Test in Task 2.
- Admission saturation retains its original route and records every accepted `503` as `5xx`. Test after admission integration in Task 3.

## Task 1: Implement the fixed aggregate and renderer on all ports

**Files:** Create `server/metrics.s`, `server/aarch64/metrics.s`, `server/riscv64/metrics.s`, and `server/test_metrics.c`.
Modify `server/Makefile` and `server/abi-check.c`.

**Interfaces:** All ports use their native C calling convention and preserve required registers and stack alignment.
Export `asm_metrics_init(void) -> int` (`1` success), `asm_metrics_destroy(void) -> void`, and `asm_metrics_route(const char *) -> uint32_t`.
Export `asm_metrics_begin(request *) -> void` and `asm_metrics_finish(request *, uint32_t status, int queued) -> int`.
The finish function returns the original MHD result; accepted status classes are `2xx`, `4xx`, and `5xx` only.
Export `asm_metrics_render(char *dst, size_t capacity) -> ssize_t`, returning a positive length or `-1`.
Document request layout, table layout, ownership, register effects, and maximum stack use beside each routine.

- [ ] Add native driver cases for zero series, route classification, exact bucket boundaries, sum decimal conversion, and output canaries.
- [ ] Add `parallel_snapshot`: 16 fixed workers produce known totals while another worker renders repeatedly.
- [ ] Assert exact totals, monotonic cumulative buckets, `+Inf == count`, valid output, and 79 unique samples.
- [ ] Add clock-fault cases using a test-only linker wrapper: failure, invalid timespec, arithmetic overflow, and backwards time.
- [ ] Add near-limit counter/sum cases using `ASM_METRICS_TEST`-only seeding; assert no partial update and sticky unavailability for exposition.
- [ ] Add mutex initialization failure and unexpected synchronization-failure child cases; assert fixed diagnostics and exit `71`.
- [ ] Run `make -C server metrics-test` on a supported native Linux host; require the new missing routines to fail first.
- [ ] Implement the interfaces and a `metrics-test` target with checked arithmetic, fixed formatting, and coherent snapshots.
- [ ] Check `pthread_mutex_t` size/alignment and callback types against installed headers in `abi-check.c`.
- [ ] Assert the exact eight-argument access-handler type and three-argument raw-URI callback type, including `void **req_cls`.
- [ ] Run `metrics-test` again; require all named cases to pass without skips.
- [ ] Ensure production assembly excludes test seeding symbols and the test clock wrapper.
- [ ] Commit this independently tested component with its tests.

## Task 2: Integrate the real HTTP boundary without changing existing responses

**Files:** Modify all three `server/*runtime.s` ports and `server/test_runtime.py`.
Create the small test-only `server/metrics_faults.c`; extend `server/Makefile` test artifacts.

**Interfaces:** Begin a stack request context once after the sentinel check.
Call finish immediately after each fixed or catalog queue attempt, before releasing any owned `PGresult`.
Add a metrics queue routine with its private bounded stack buffer.
Use Task 1's renderer and the existing response helper; preserve existing URI, method, header, query, body, and cache policy.

- [ ] Add six observable runtime tests: `test_metrics_fixed_exposition_and_route_labels`, `test_metrics_errors_and_exactly_once_queue_accounting`, `test_metrics_database_delay_and_failed_request_timing`, `test_metrics_concurrent_scrapes_preserve_snapshots`, `test_metrics_queue_failures_preserve_ownership`, and `test_metrics_aborts_preserve_queue_semantics`.
- [ ] Assert all feed paths map to `index`, status maps to `about`, unknown paths map to `other`, and no input becomes a label.
- [ ] Assert POST, query, body, overlong URI, and header failures retain existing codes and one accepted-queue observation.
- [ ] Assert delayed SQL crosses the intended finite buckets; retain the existing request-deadline assertion unchanged.
- [ ] Assert requests made without database work still expose metrics while database-backed requests return their existing errors.
- [ ] Use isolated server children and a derived-test-only interposer to fail MHD response creation, header addition, and queueing separately.
- [ ] Assert the next successful scrape observes exactly one failure increment, no fake HTTP class, no duration observation, and a working server.
- [ ] Bound fault tests by process/socket deadlines; retain their stderr and verify no credential appears.
- [ ] Assert partial headers followed by disconnect add no application observation; post-queue disconnect retains its queued class exactly once.
- [ ] Keep abort tests behavioral; do not claim complete-transfer latency or repair shutdown draining here.
- [ ] Run the new test selections against the unchanged runtime; require failure because `/metrics` is absent.
- [ ] Integrate the route, context, shared queue-finalization path, lifecycle, and fixed failures on all three ports.
- [ ] Run `make -C server test` with the documented pinned native dependencies; require all existing and six new tests without skips.
- [ ] Commit HTTP integration and the corresponding tests.

## Task 3: Bind the complete tests to existing image and compatibility evidence

**Files:** Modify `containers/server.Dockerfile`, `tools/test_server_image.py`, `tools/record_server_ports.py`, and `tests/test_server_qualification.py`.
Modify only the assembly-source validation loop in `.github/workflows/assembly-server.yml`.
Update `server/README.md` and the hosted-registry capability wording only for implemented behavior.
After PG18 integration, update its HTTP test-identity check in `tools/test_postgres18_image.py` and `tests/postgres18/test_harness.py`.
Use the existing workflows; add no new workflow or capacity framework.

**Interfaces:** Build the native driver and fault interposer in the build stage.
Copy them only to the derived qualification target; keep the final runtime free of test tools and fixtures.
The existing image gate still binds executable, libraries, RootFS prefix, source commit, UID, and security settings.

- [ ] Add rejection tests for a report or loaded suite missing any of Task 2's six exact test identities.
- [ ] Require all discovered applicable tests to run without skips; a numeric minimum alone cannot establish metrics coverage.
- [ ] Retain the existing minimum and raise it by six only after reconciling the merged suite; do not discard admission's additional tests.
- [ ] Record metrics contract version `1`, timing `handler-entry-to-accepted-queue`, sample count `79`, and response bound `16384` in qualified reports.
- [ ] Assert final images exclude test artifacts, test seed symbols, and injected fault configuration.
- [ ] Extend the existing assembly-only validation loop to include each new metrics source, including RISC-V.
- [ ] Run `python3 tools/test_server_image.py --self-test` and `PYTHONPATH=tests python3 -m unittest test_server_qualification -v`.
- [ ] Document metric meanings, labels, zero series, failure behavior, and queue/transfer limits in the existing runtime README.
- [ ] Review the complete diff, licensing notices, test identities, and source-bundle inclusion before committing the gate changes.

## Integration dependencies and evidence limits

The isolated branch contains the main baseline, not the active admission or startup work.
Integrate their reviewed sources before qualification; preserve their tests and avoid duplicate ownership.
After admission integration, extend its existing ninth-request and contention assertions with `index/5xx` metrics deltas.
Do not replace its bounds, introduce a pool, or count refusal as a client quota error.
Startup remains a separate prerequisite for deployment; metrics cannot fix credential projection or database-address preparation.

Run native AMD64 and ARM64 gates through the existing workflow after root authorizes implementation and hosted execution.
Retain RISC-V assembly validation and the existing image execution mode; label emulation explicitly.
A local driver, cross-assembly check, or emulated run does not establish native RISC-V behavior.
Re-run the selected PG18 HTTP compatibility gate only after source integration and explicit hosted-run authorization.
Its earlier receipt covers earlier bytes, not these metrics changes.
Preserve the PG18 server pin, client version, owned TLS fixture, app/DB resource separation, and all existing failures.

No result here establishes the smaller deployment memory envelope, slow-client capacity, in-flight draining, placement, disruption, or recovery.
Those retain separate implementation and deployment gates.
This document is an unexecuted plan; no product code or compatibility result accompanies it.
