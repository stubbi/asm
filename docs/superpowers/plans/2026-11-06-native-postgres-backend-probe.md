# Native PostgreSQL backend control

**Goal:** Inspect whether a native PostgreSQL package changes completed searches with the same RISC-V application and clients.

**Scope:** One isolated diagnostic. No product or permanent qualification-environment change is selected.
The original 19-test failure and the rejected SQL candidate remain independent evidence.
The rejected candidate and its result are retained on `codex/reference-query-candidate`, including documentation commit `8055e0e`.

This serves maintainers who need to distinguish an application failure from a constrained backend environment.
The foundation principles are evidence, dependable reuse, and resource care.
The accepted trade-off is a package comparison with build differences, rather than a pure emulation comparison.
Source bindings, unchanged controls, all response records, and cleanup evidence define the useful result.

## Selected inputs

- Keep server SHA-256 `3e0bce8b6d9be340be5dfabbdd39fda064d7c9dd46287432561d315603ba93c9` and size 33,584 bytes.
- Keep the original SQL, RISC-V libpq, MHD, Python, and psql bytes.
- Keep the retained image `sha256:ea55425e6daa994ad57c46862258368c192c6f1f44b146c8a7bf3d1758571ae1` as the base.
- Keep fixture commit `f0ca5991344848ead087cf60fc2040337cd81f7f` and its 33-file source contract.
- Keep SCRAM, the owned cluster factory, localhost transport, and the existing database and client settings.
- Keep 2 CPUs, 2 GiB, 256 PIDs, UID 65532, no external network, no capabilities, and no new privileges.
- Keep the shared 180-second runtime and 600-second host budget, including existing cleanup reserves.
- Keep startup, client, two-second database, and one-second statement limits.

Native input: Docker Official `postgres:16.15-alpine3.23`, Linux AMD64.
Its platform manifest is `sha256:751329300ebdcbde5461c14fac796c8840d13fc74cc49b9b94745b0285907961`.
Its config is `sha256:5bbe1b33f05489cf9ea1aa962ce6599cc238094344de42ce3f40e2478c9714bf`.
Eleven compressed layers contain 115,570,150 bytes.
The [official mapping](https://github.com/docker-library/official-images/blob/1b851c635e093e70beddd58d633ddaf5e307abfc/library/postgres) identifies the [pinned recipe](https://github.com/docker-library/postgres/blob/9d15534160ade17f2b6c455a39ee967c49b1937d/16/alpine3.23/Dockerfile).
The upstream PostgreSQL 16.15 source digest is `c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed`.
Only small metadata and source files have been retrieved locally.

## Qualification-only overlay

Place the native package under a separate prefix.
Preserve its executable, share, module, and dependency layout.
Add only the previously absent AMD64 musl interpreter and its architecture-specific search-path file outside that prefix.
Replace no existing RISC-V file.
Use no official image entrypoint or authentication defaults.

Native initdb and postgres wrappers clear child-only preload and library-path variables.
The musl search-path file selects only the separate native library directories.
Keep the parent environment unchanged.
Delegate any psql selection explicitly to the original RISC-V executable.
The reference fixture administers PostgreSQL through retained RISC-V libpq; it does not invoke psql.

Verify exact versions, executable machines, loader and dependency identities, module/data paths, and notices before requests run.
Verify the actual PostgreSQL process through its executable identity.
Record the existing base timezone data because the native build's system-timezone path does not relocate.
Keep ICU and native cryptographic providers within the native child dependency closure.
Hash the retained RISC-V components before and after the comparison.

## Measured work

Use fixed ABBA order if the original shared budget permits it.
Create a new owned cluster and server for each arm.
Replay the original simultaneous-search method with 16 requests and eight workers per arm.
Keep all 64 response records, body hashes, failures, timings, and whole-container CPU and memory counters.
Record all startup and cleanup failures.
Do not extend a deadline if setup or a measurement runs late.

The complete 19-test acceptance suite is not run by this diagnostic.
Label the single-method replays separately from acceptance results.
Keep historical failure records and all application, native, and release qualification flags false.

## Interpretation and review

This changes the PostgreSQL initialization/daemon package architecture and build.
The native package adds musl, LLVM, ICU, and other dependency/configuration differences.
The original PostgreSQL build already enables OpenSSL; MHD's separate HTTPS option does not describe PostgreSQL TLS support.
No result can isolate emulation alone.
No permanent environment change follows without result review and an explicit selection.

- [x] Review loader, path, notice, and dependency boundaries.
- [x] Test file collisions, malformed metadata, wrong executables, late work, and failed cleanup.
- [x] Verify fixture, request, resource, authentication, and component bindings in the harness.
- [x] Freeze the proposal and implementation before the one selected dispatch.
- [ ] Retain positive and negative results with exact artifact digests.

Local checks on 2026-11-06 passed: 114 reference tests, 32 observation tests, 20 shared harness tests, workflow lint, and diff checks.
Independent reviews found no remaining blocker for the single diagnostic.
These checks used synthetic fixtures. Actual image construction, required native loading, PostgreSQL setup, and HTTP behavior remain untested.
The preflight checks required core tools, PL/pgSQL, and bootstrap data. Unused modules remain untested.
