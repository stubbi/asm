# RISC-V CLI and extracted server qualification

This plan extends the scoped evidence in [RISC-V qualification](../../riscv64-qualification.md).
It does not establish native hardware, release, deployment, or complete CLI qualification.
The full-system CLI gate owns kernel fault-injection tests.

The user outcome is a real RISC-V CLI build of the distributable server package.
Dependable reuse and explicit evidence govern the change.

1. Reuse the hosted Dockerfile `build` stage at `4fe2c25277ed40a163b48b727ab814225d227cf8`.
2. Prepare the reference package from `04c93b3f0200173298d24f22a06393bc359a1af0`.
3. Bind the candidate source to the exact workflow checkout commit and archive digest.
4. Use the full guest userland and fixed native guest `/usr/bin/cc`, `/usr/bin/as`, and `/usr/bin/ld`.
5. Retain the existing libmicrohttpd 1.0.3 and PostgreSQL 16.15 source pins.
6. Build the candidate CLI and exercise `new`, `build`, `run`, `test`, and native library linking.
7. Prepare, pack, and extract the target-specific server source package.
8. Run its unchanged `make test` with the candidate CLI and inherited libraries.
9. Require all 19 tests: fixture 2, server 14, runtime versions 1, package preparation 2.
10. Reject incomplete tests, skipped tests, wrong tool targets, and wrong ELF machines.
11. Retain logs, source identities, executable digests, and failed evidence.

The container uses UID 65532, loopback only, no capabilities, and bounded resources.
Its writable disposable build layer preserves outputs for collection after failure.
This scope differs from the separate read-only hosted runtime image qualification.
The gate publishes no image or release and changes no deployment.

Local validation uses deterministic rejection tests and workflow/source inspection.
Docker builds and runtime execution require a healthy Linux CI host.
No local Docker call or dependency download is authorized for this implementation task.

Host evidence collection uses an explicit eleven-file allowlist.
Each guest command log has a 4 MiB limit.
The outer runtime log has a 16 MiB limit.
A streamed overflow or deadline terminates the original process group.
The deadline includes descendants that retain the output pipe after their leader exits.
Collected evidence has a 128 MiB aggregate limit and separate file limits.
Each file travels through a bounded tar stream before host finalization.
The host rejects links, directories, extra members, and extended tar headers.
Short fixed evidence filenames require no extended headers.
Failed transport, truncated logs, and rejected evidence cannot produce a pass.

Only files collected successfully during the current run can reach report parsing or artifact hashing.
A failed collection preserves earlier files and records a failure.
