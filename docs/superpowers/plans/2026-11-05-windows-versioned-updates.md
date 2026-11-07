# Windows Versioned Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make native Windows installation, launch, and manual CLI updates work on x64 and ARM64 with atomic selection and failure preservation.

**Architecture:** Install a stable assembly launcher and separate digest-addressed CLI payloads. Keep shared native release verification, then activate a verified payload through one selection-record rename. Generate the PowerShell bootstrap with Python build tools; installation and update never execute a candidate.

**Tech Stack:** x64 and ARM64 assembly, Windows NTFS and native process APIs, BCrypt SHA-256, fixed GitHub verifier, Python build/test tools, PowerShell bootstrap.

**Spec:** [Approved design](../specs/2026-11-05-windows-versioned-updates-design.md). The human approved implementation on 5 November 2026.

## Global constraints

- Native installed package logic, launcher, and updater remain assembly.
- Keep `HOME/.local/bin/asm.exe`, `.asm-cli/current.tsv`, and `.asm-cli/versions/<sha256>/asm.exe`.
- Use launcher protocol version 1. Keep old payloads; do not add automatic cleanup.
- Installation and updating must never execute the candidate, including after verification.
- Keep all three native provenance bindings and current fixed-tool/private-environment/deadline policies.
- Preserve existing invocations, unrelated files, exact precommit selection bytes, and the prior usable command after a failed activation.
- Read actual held launcher metadata after repair; historical bootstrap version fields grant no compatibility authority.
- Linux/macOS replacement, published 0.6.0 bytes, release host admission, trust roots, and deployment remain unchanged.
- Pass existing 46 Windows behaviors plus managed-layout gates on both native ISAs before a support claim.
- Read `docs/brand/foundation.md`, `docs/brand/messaging.md`, `docs/specs/security.md`, and `LICENSING.md` before implementation.
- Outcome: a person can install, create, run, test, update, and recover. Principles: dependable reuse, inspectable evidence, and file preservation.

## Review focus

- Changed HOME or missing state must not run the launcher's old embedded CLI; Task 2 tests actual executing-path roles.
- A precommit record reader can start the old payload after activation; Task 4 tests held-old versus newly opened records.
- High exit statuses and Ctrl+C/Break must survive the extra process; Task 4 tests real child status and owned consoles.
- Existing digest paths, links, unsafe access rules, and package aliases must not overwrite managed state; Tasks 2–4 preserve bytes on refusal.
- Interrupted installation and launcher repair must preserve the active payload selection; Task 3 tests failures at each publication boundary.

## Shared wire and lifecycle contract

These are implementation decisions within the approved design.

`layout` is a regular single-link private file with exact ASCII bytes `# asm-cli-layout-v1\n`.
`current.tsv` is at most 256 bytes, has no BOM, NUL, CR, or extra bytes, and has exactly:

```text
# asm-cli-current-v1\n
VERSION\tTARGET\tSIZE\tSHA256\t1\tMIN_LAUNCHER_VERSION\n
```

The displayed escapes denote actual bytes, not literal backslashes.
There is one header line and one six-field data line.
Versions use existing canonical three-component validation, at most 32 bytes and each component at most 2147483647.
TARGET equals this PE's exact Windows host target. SIZE is canonical decimal 1..67108864. SHA256 is 64 lowercase hexadecimal bytes.
The fifth field is exactly `1`. The sixth field equals the candidate metadata's canonical minimum launcher version.
Reject extra/missing fields, lines, duplicate records, truncation, and noncanonical numbers.
The only executable path is the fixed digest-derived path; records cannot supply paths or arguments.

A unique PE section named `.asmmeta` contains exactly 64 meaningful bytes, little endian:

| Offset | Meaning |
| --- | --- |
| 0 | Eight bytes `ASMCLI1\0` |
| 8 | uint32 metadata schema = 1 |
| 12 | uint32 required launcher protocol = 1 |
| 16 | uint32 minimum supported launcher protocol = 1 |
| 20 | uint32 maximum supported launcher protocol = 1 |
| 24, 28, 32 | uint32 artifact version components, matching the built CLI version |
| 36, 40, 44 | uint32 required minimum launcher version = 0, 6, 0 initially |
| 48..63 | Sixteen zero bytes |

Require a bounded unique initialized-data section with read access, no write or execute access, virtual size 64, and bounded raw size at least 64.
Do not alter release JSON schemas. Exact artifact provenance covers metadata bytes.
A candidate version must match its selected release version. Actual launcher version must meet its minimum.
The actual launcher must support its required protocol. Repair must preserve compatibility with the active payload.

Use the existing bin-directory `.asm.lock` byte-range lock for all installers and updates.
Open its single-link private file without reparse traversal; lock byte 0, length 1, nonblocking and exclusive.
Keep the native lock HANDLE until the owning operation finishes. Bootstrap uses the same kernel lock.
Use descriptor-relative publication and retained ancestor/file identities; repeat path checks before activation.
Record readers permit read/delete sharing so held old snapshots do not prevent atomic activation; deny write sharing.
Hold payload read/execute descriptors without write sharing through digest/metadata checks and suspended-child binding.
Accept only exact class44 success against that same held file; terminate and reap rejected children before reporting failure.

Roles derive from actual executing image and normalized checked paths, using Windows ordinal case-insensitive comparison.
A root `.local/bin/asm.exe` requires valid managed state even if HOME disagrees.
A versioned payload validates its digest-derived location and managed state; ordinary commands can continue after selection changes.
A payload can update only while its held identity equals the active selection.
Each launcher binds its own held root file to its executing image before dispatch.
Each payload binds its own held payload file to its executing image before update.
Update compatibility reads the held current root file: that file determines what the next invocation will run.
It does not trust a parent PID, inherited environment claim, or an old parent's version.
No launcher-parent handoff protocol is required or claimed.
A standalone build outside those fixed roles runs its checkout bytes and cannot update an installed managed command.
Reject path aliases and writes anywhere below the reserved `.local/bin/.asm-cli` store through package management and inventory.

Bootstrap stages the complete store privately, publishes it without replacement, then publishes the root launcher last.
A failure before root publication preserves all previous files; an interrupted new store is retained for explicit repair.
`-RepairLauncher` accepts only a fully validated known layout, preserves `current.tsv`, and checks actual PE compatibility.
An unfamiliar existing store fails. A different existing root command requires explicit `-ReplaceExisting`.
Launcher repair can fail while any launcher process remains open; instruct the person to close Asm processes and retry.
Do not claim transactional directory durability. Retained payload cleanup remains manual and excludes active payloads and running processes.

## File structure and ownership

| Owner | Files | Responsibility |
| --- | --- | --- |
| Coordinator | `tools/windows_layout.py`, `tests/release/test_windows_layout.py` | Build/test encoding oracle and PE metadata emission; no installed backend |
| x64 worker | `cli/windows/x86_64/managed.s`, `launcher.s`, `versioned_update.s`, existing `platform.s`, `pe.s`, `Makefile`, `test_host_shims.py`, `README.md`; `tools/windows_x64.py` | Native layout, held validation, launch, activation, and source adaptation |
| ARM64 worker | `cli/windows/aarch64/managed.s`, `launcher.s`, `versioned_update.s`, existing `hash.s`, `process.s`, `update.s`, `pe.s`, `Makefile`, focused shim/tests, `README.md`; `tools/windows_arm64.py` | Equivalent ARM native behavior and source adaptation |
| Bootstrap owner | `tools/windows_bootstrap.py`, `tools/windows-install.ps1.in`, `tests/release/test_windows_bootstrap.py` | Generated published/source bootstrap, kernel locking, provenance and repair |
| Coordinator | `tests/windows/test_runtime.py`, `runtime_helpers.py`, new `managed_helpers.py`, `tools/windows_test.py`, `.github/workflows/windows-ports.yml` | Actual managed-path acceptance and retained source/artifact evidence |
| Coordinator | `docs/self-update.md`, `docs/specs/security.md`, approved design, target/evidence docs | Windows contract, limits, recovery and qualification status |

Keep canonical POSIX assembly unchanged. Assert generator anchors before replacing Windows routine bodies.
Add borrowed-descriptor hash/container readers rather than reopen a checked pathname.
Each nontrivial native routine documents registers, failures, preserved registers, stack, bounds and descriptor ownership.

### Task 1: Freeze executable metadata and record encodings

**Files:** `tools/windows_layout.py`, `tests/release/test_windows_layout.py`.
**Interfaces:** Python `encode_record(version, target, size, sha256, minimum_launcher='0.6.0')->bytes`; `decode_record(data, target)->dict`; `metadata_bytes(version, minimum_launcher='0.6.0')->bytes`; `read_pe_metadata(data, target)->dict`; `metadata_assembly(version, syntax)->str`.

- [ ] Write failing observable format tests: canonical round trip; every truncation; CR/NUL/BOM/extra fields; noncanonical versions/sizes; target mismatch; duplicate/write/execute/overlapping or out-of-range metadata sections; metadata/release version mismatch.
- [ ] Run `python3 -m unittest discover -s tests/release -p test_windows_layout.py -v`; record the expected missing-implementation failure.
- [ ] Implement the bounded build/test codec and section emitter, using the exact values above.
- [ ] Run the focused tests and `git diff --check`; commit only this contract and approved status/plan.

### Task 2: Implement the native managed lifecycle on each ISA

**Files:** The per-ISA worker files above. Execute x64 and ARM64 in parallel after Task 1.
**Consumes:** Exact wire/metadata contract; existing shared updater verification; existing Windows native security and descriptor adapters.
**Produces:** `win_managed_startup()`, `win_managed_open_installation()`, `win_managed_check_absolute_installation()`, `win_managed_check_destination()`, `win_managed_commit_update()`, `win_managed_cleanup()`, `win_managed_reserved_path(path)`.
**Native interfaces:** x64 uses SysV-style adapter inputs RDI/RSI/RDX and result RAX; ARM uses x0/x1/x2 and result x9. Returning routines preserve each existing adapter's callee-saved registers. `win_managed_startup` returns 0 for standalone/payload; a launcher waits and exits directly with its child's DWORD. Errors terminate through existing CLI error routines.
**Held helpers:** x64 `win_hash_fd(fd, exact_size, hex65)->0/error`; ARM equivalent x0/x1/x2→x9. `win_managed_pe(fd,size,metadata64)->0/error` never owns/closes the input fd. `win_child_image_matches(processHANDLE,fileHANDLE)->0/-116/-95` never resumes or closes handles.
Generic package PE validation remains independent of CLI metadata; only managed CLI paths require `.asmmeta`.

- [ ] Add failing actual-native-routine shims for strict parser/metadata, record-length bounds, changed HOME/roles, held hashing, remote class44 exact status, and descriptor closure.
- [ ] Demonstrate old source failures for the new contracts and preserve those results.
- [ ] Emit metadata from the built CLI version; insert startup dispatch immediately after existing Windows argument/security initialization.
- [ ] Implement protected ancestor walking, held record snapshot, actual launcher metadata, payload digest/container/access checks, role selection, and reserved-store checks.
- [ ] Implement dedicated suspended launch with explicit inherited standard handles, original argv quoting, complete DWORD propagation, infinite deliberate wait and owned Ctrl+C/Break handler. Never set NULL/global-ignore handlers or a new kill-descendants policy.
- [ ] Replace only generated Windows updater open/recheck/destination/commit bodies. Preserve shared index/download/provenance code. Use private staging under the store, no-replace digest publication, flushed record staging, identity rechecks, and one final `current.tsv` rename.
- [ ] Close owned descriptors on every failure. Preserve old selection before commit; postcommit cleanup cannot report an update failure. Retain existing payloads.
- [ ] Run focused shims, the ISA cross-link, and required `make test`; freeze file hashes and source diff for independent review. Commit each coherent ISA lifecycle change through the coordinator.

### Task 3: Generate the Windows bootstrap

**Files:** Bootstrap-owner files above.
**Consumes:** Task 1 codec/metadata, approved layout, fixed provenance policy and lock contract.
**Produces:** `render_source_installer(artifact: Path,target: str)->bytes` and `render_installer(release: dict)->bytes`; CLI build command `python3 tools/windows_bootstrap.py --source-artifact PATH --target TARGET --output FILE`.
**Runtime:** PowerShell 5.1 or later on native Windows. An explicitly source-generated installer binds its local artifact path/size/digest without claiming publisher authentication. Published generation requires complete Windows release metadata and fixed provenance inputs; it does not admit a released host.

- [ ] Add failing generator tests for exact target rejection, incomplete release metadata, changed source bytes, distinct existing command preservation, strict metadata, interrupted setup and repair incompatibility.
- [ ] Run `python3 -m unittest discover -s tests/release -p test_windows_bootstrap.py -v` and retain expected failures.
- [ ] Implement complete-download generation, fixed tool arguments, bounded size/digest/provenance checks, private native descriptor operations and exact lock sharing. Embedded PowerShell/C# API wrappers are installer infrastructure, never a CLI backend.
- [ ] Implement staged initial store publication, launcher-last commit, explicit replacement and validated repair preserving active selection. Never invoke a candidate, including for metadata/version/install inspection.
- [ ] Add native PowerShell acceptance cases to Task 4 through the coordinator; freeze generator/template hashes and submit a coherent commit without publishing installers or changing released-host selection.

### Task 4: Qualify actual managed commands and activation

**Files:** Coordinator-owned Windows tests, evidence driver and workflow.
**Consumes:** Both native lifecycle implementations and generated source bootstrap.
**Produces:** source/target/tool/host-bound native receipts with exact pre/post CLI digests and test outcomes.

- [ ] Add failed baseline managed tests before the new lifecycle runs: install via generated PowerShell, `doctor`, `new`, `run`, `test`, and package lifecycle from root `asm.exe`.
- [ ] Adapt positive self-update to managed activation while retaining all three provenance calls, original negative cases, exact candidate digest/size, next-command version/behavior, unchanged launcher bytes and retained old payload.
- [ ] Add corrupt/missing/duplicate record, metadata incompatibility, held-old/new-record ordering, download/verification/write/flush/activation failure, concurrent lock and path-displacement cases. Assert exact previous selection bytes and usable command before commit.
- [ ] Add full DWORD child statuses, Unicode/literal argument and stream propagation, actual 125-second application, owned-console Ctrl+C/Break, remote-image substitution rejection, inactive-payload update refusal, HOME disagreement, links/reparse/unsafe ACLs and reserved-store alias refusal.
- [ ] Test source bootstrap existing destinations, deliberate replacement, complete known-state repair and interrupted boundaries; assert candidate code never runs.
- [ ] Execute the full native Windows workflow once per frozen candidate on both ISAs. Retain every failure and exact run/source/artifact binding. Keep package/reference scopes and emulation labels separate.

### Task 5: Review, document and integrate the qualified change

**Files:** Coordinator documentation and evidence files above; PR 41 metadata.

- [ ] Update Windows installation/update/security/recovery instructions from observed behavior. Document extra process, retained disk use, snapshot semantics, manual launcher maintenance, current filesystem/OS scope and same-user/power-loss limits.
- [ ] Run `make test`, `make verifier-test`, registry tests, site checks, release tests, focused generator/native driver checks and workflow lint for the changed boundaries. Report platform-specific skips explicitly.
- [ ] Review the complete diff, native descriptor/security boundaries, both ISA equivalence and all required evidence with fresh reviewers. Fix exposed defects and rerun affected gates.
- [ ] Update draft PR 41 to the coherent frozen source after native qualification; run its complete required checks. Preserve all historical failed observations and recorded main/source decisions.
- [ ] Let the existing merge queue own complete-history review and admission. Do not merge a failed gate or activate a new release host, trust configuration or deployment.

## Self-review

The five review-focus classes are assigned to explicit native/installer acceptance steps.
The approved layout, snapshot semantics, no-execution rule, compatibility authority, cancellation, repair and cleanup limits each have an implementation owner.
Common Python interfaces are build/test only; native register interfaces are explicit and per-ISA files do not overlap.
The existing user instruction supplies execution through coordinated workers; implementation proceeds after this plan without another permission request.
