# Hosted startup discovery implementation plan

> **For agentic workers:** Use subagent-driven development for independent architecture files; preserve the shared contracts and review the complete result.

**Goal:** Start the hosted assembly runtime from bounded DNS-only private configuration without relaxing its serving file policy.

**Architecture:** One startup asynchronous glibc resolver and a fixed-key non-serving preparation command. Each ISA has native assembly modules; mature library calls retain transport and TLS behavior.

**Tech stack:** Linux LP64 assembly, glibc, libpq 16.15, libmicrohttpd 1.0.3; Python/C test fixtures only.

**Spec:** [Startup contract](../specs/2026-11-05-server-startup-discovery-design.md).

## Global constraints

- Three Linux ISA profiles; native AMD64/ARM64 and explicitly emulated RISC-V evidence.
- Exactly 2000 ms configured startup DNS budget; whole-process timeout termination.
- Preserve certificate hostname, URL allowlist, 4096-byte limit, and existing database deadline.
- Fixed `database.url` key; private output; no overwrite of different destinations.
- Keep routing, SQL, existing fixture source, CLI/reference packages, and activation outside this change.

## Review focus

- Blocked resolver submission or stderr must not leave background threads or a listener.
- Deadline interruption cannot extend waiting; handler, mask, and timer state must recover after success.
- Projected symlinks cannot escape the pinned source or cross a mount boundary.
- Rotation must produce a complete snapshot or a bounded refusal.
- Retry and finalization failures must preserve unrelated destinations.

### Task 1: Observable test-only baseline

- [x] Add `server/test_startup.py` and a separate preload fixture; compose the existing TLS fixture without editing it.
- [x] Add `make test-fixtures` and expose `ASM_SERVER_STARTUP_FIXTURE`; keep test code out of application linkage.
- [x] Run native tests against current assembly and retain expected missing-feature failures.

### Task 2: x86-64 and shared integration

- [x] Add `resolver.s` and `prepare.s` with the specified C ABI and syscall contracts.
- [x] Modify main dispatch/usage and optional-hostaddr configuration only.
- [x] Extend target-header assertions and Makefile sources.
- [x] Run native AMD64 tests and fix observed defects.

### Task 3: AArch64 implementation

- [x] Add native AAPCS64 resolver/preparer modules and matching dispatch/config integration.
- [x] Crossassemble, then run the same suite on native ARM64.
- [x] Review register, stack, structure, and signal behavior independently.

### Task 4: RISC-V64 implementation

- [x] Add native RV64GC/LP64D resolver/preparer modules and matching dispatch/config integration.
- [x] Check real RV64GC/LP64D assembly output.
- [ ] Run the unchanged behavior suite through the image owner's full-system RISC-V guest kernel.
- [x] Preserve emulated versus physical evidence boundaries.

### Task 5: Reviewable handoff

- [x] Review all three implementations and complete native AMD64/ARM64 red/green failure gates.
- [x] Document command, prerequisites, rollout policy, errors, source/artifact binding, and remaining cluster gates.
- [x] Provide selected hosted-only commits and fixture integration contract to the image/routing owners.
- [x] Do not activate a deployment.
- [ ] Replace the image publication hold with same-source startup and full-system RISC-V qualification.
