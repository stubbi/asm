# Hosted startup discovery

Status: approved implementation scope; qualification pending.

## Outcome and boundary

A private operator can start the assembly runtime with a DNS-only TLS URL and a Kubernetes projected configuration key.
The server resolves once before database work or HTTP admission.
A separate non-serving command prepares a private snapshot.
This serves dependable reuse and explicit evidence without changing catalog routes, SQL, TLS identity, or release policy.

The implementation targets Linux x86-64, AArch64, and RV64GC/LP64D with glibc 2.34 or later.
Existing HTTP, libpq, and system C libraries remain dependencies.
No application backend, shell command, deployment activation, or operator credential change is included.

## Startup resolver contract

`hostaddr` becomes optional; all other URL requirements, bounds, duplicate checks, and allowlists remain.
An explicit valid IPv4 address bypasses DNS completely.
For a DNS-only URL, copy the validated hostname before releasing parsed libpq options.
Keep the certificate `host` unchanged.

Submit one `getaddrinfo_a(GAI_NOWAIT)` request with `SIGEV_NONE`, `AF_INET`, `SOCK_STREAM`, and `IPPROTO_TCP`.
Keep request, hints, hostname, and notification storage valid until process termination.
Select the first result only; require its family, socket type, protocol, address length, and address pointer to match the profile.
Copy its numeric IPv4 address into owned storage.
Append one `hostaddr` field without exceeding the existing 4096-byte URL bound.
Free only a completed result.
The address remains fixed until process restart; readiness performs no DNS lookup.

Use one absolute monotonic 2000 ms budget.
Recompute the remaining wait after interruptions; never restart the budget.
Reserve SIGALRM during this phase and arm a separate two-second ITIMER_REAL watchdog before submission.
The handler terminates the whole process with exit status 78 through `exit_group`.
It performs no logging, cancellation, allocation, or cleanup.
glibc masks SIGALRM during helper-thread creation, including internal lock waits.
The target contract additionally requires a kernel-owned CLOCK_MONOTONIC timer with SIGEV_SIGNAL and SIGKILL.
Arm that timer at the same absolute 2000 ms deadline before submission.
It must terminate a fully masked stalled submission under a responsive kernel and fair scheduling.
A DNS deadline can exit with status 78 or termination by SIGKILL; malformed configuration still returns 78.
No listener opens on either deadline outcome.
Timer creation, arming, or deletion failure refuses startup with status 78.
This backstop remains unimplemented until native probe and masked-submission failure evidence are retained.
Require all inherited interval-timer value and interval fields to be zero.
Refuse any nonzero inherited timer state rather than silently replacing it.
Unblock SIGALRM while resolving.

After success, block SIGALRM, disarm the watchdog, and reject an expired or pending deadline signal.
Delete the owned hard timer and recheck the deadline before success.
Restore the original empty interval timer, then restore the original handler and signal mask.
No watchdog remains during requests.
Failure never opens a listener.
The ordinary database connection/query/result deadline remains 2000 ms.
These are configured deadlines, not hard real-time scheduler or kernel-I/O guarantees.

Export `resolve_database_address` using each target's C ABI.
Its input is a persistent, validated hostname pointer; it appends to the owned `db_config` buffer.
Success returns 1; an unresolved or invalid result terminates the whole process with status 78.
Only deadline termination can instead use SIGKILL, as specified above.
All callee-saved registers and 16-byte stack alignment are preserved.

## Fixed-key preparer contract

The direct command is `asm-hub prepare-config SOURCE_DIR DEST_DIR`.
It does not read serving environment variables, resolve DNS, connect to a database, or start HTTP.
The input key is always `SOURCE_DIR/database.url`.
The output is always `DEST_DIR/private/database.url`.
Both directory arguments must be absolute, bounded to 1024 bytes, and have non-symlink final components.
Except for `/`, reject a trailing slash or a final `.` or `..` component.
Their ancestors remain trusted operator inputs; no whole-path race-free claim is made.

Use the server's nonzero real UID/GID; refuse effective-ID mismatches.
Pin directory descriptors before file operations.
Require root/current ownership, the selected GID, and no other-write bit on input/output roots.
A group-writable input root additionally requires a read-only mount, checked through `fstatfs`.
The output root can be writable by the selected GID because it contains a private child.

Open only `database.url` through `openat2` with `RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_XDEV`.
Normal Kubernetes projection symlinks can resolve within that pinned root.
Unsupported or blocked syscalls fail closed; there is no path-walking fallback.
Require a single-link regular source, root/current ownership, selected GID, and only owner read/write or group read permission bits.
Reject executable, special, group-write, and other permission bits.
Read at most 4097 bytes and reject content beyond 4096 bytes.
Accept the existing private reader's printable ASCII rule and one final LF.
Preserve the original accepted bytes, including that LF.
The serving command retains authority for URL and TLS validation.

Create or validate a current-UID `0700` child named `private`.
Its group does not confer access through this private mode.
Publish a completed `0600`, single-link file atomically with `RENAME_NOREPLACE`.
Use a private exclusive temporary file; handle short I/O and at most 16 interrupted-call retries per operation.
Bound random temporary-name collisions to 16 attempts.
Sync its bytes before publication.
An existing destination is a successful no-op only when its current UID, selected GID, exact mode, type, link count, length, and bytes match.
Refuse a different or symlink destination without changing it.
Normal failures remove only the owned temporary file; an empty private directory can remain.
Same-UID actors are outside this advisory coordination boundary.
No power-loss directory-durability claim is made.

Export `prepare_config` using each target's C ABI: source root and destination root pointers in the first two argument registers.
Return 0 or configuration-refusal status 78.
The main dispatcher emits a fixed useful diagnostic on refusal and remains quiet on success.
Incorrect command syntax returns 64.

## Integration and evidence

New modules are `server/{resolver,prepare}.s` and corresponding AArch64/RISC-V files.
Runtime edits are limited to command dispatch and usage.
Configuration edits cover optional hostaddr, persistent hostname storage, and one resolver call.
ABI assertions pin every accessed layout, flag, and syscall number.
No routing or SQL helper is changed.

Tests belong in `server/test_startup.py`, with a separate test-only preload fixture.
They reuse the maintained TLS fixture through composition.
The source owner approved removal of only the existing missing-hostaddr rejection subcase during implementation.
All other `server/test_runtime.py` cases remain unchanged; new tests require DNS-only success.
The fixture is built by `make test-fixtures` and supplied through `ASM_SERVER_STARTUP_FIXTURE`.
It is absent from the final runtime image.
Native AMD64/ARM64 jobs must run the actual executable; RISC-V qualification remains explicitly emulated.
The pinned QEMU user emulator lacks `openat2`; successful preparer qualification needs a compatible emulator or full guest kernel.
Unsupported execution must refuse configuration; no filesystem fallback is permitted.

Required cases cover DNS-only TLS success, unchanged TLS refusals, explicit-address bypass, pinned lookup count, malformed resolver results, failed submission, stalled submission/waits, full stderr, fully masked stalls, repeated interruption, inherited signal masks, and restored handler/timer state.
Successful resolution must delete its owned hard timer and remain alive beyond the original deadline.
Preparer cases cover AtomicWriter-shaped snapshots, retries, generation replacement, all file/permission/type bounds, escapes, syscall denial, and unrelated-destination preservation.
Tests use owned temporary files and databases, fixed resource/time bounds, and no production credentials.
Keep actual red runs, corrected runs, source commits, exact artifacts, and remaining deployment gates.

Deployment must project only the required key as `database.url` and mount it read-only.
The serving container consumes the prepared volume read-only.
URL changes require new Pods; certificate/key projections stay separate for per-connection rotation.
Actual private-cluster ownership, kernel/seccomp, rollout, and certificate-rotation qualification remain separate activation gates.

## Primary references

Inspected on 5 November 2026: glibc 2.41 `resolv/netdb.h` and `gai_misc.c`; Linux v6.12 UAPI `openat2.h` and interval-timer implementation; Linux man-pages 6.19 asynchronous resolver and exit semantics; Kubernetes v1.34.0 AtomicWriter, projected-volume, and Linux ownership implementations.
These versions identify reviewed sources; they do not establish the private cluster's version or qualification.
