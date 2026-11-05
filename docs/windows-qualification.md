# Windows CLI qualification

Status: qualification tooling is implemented; native Windows results remain required.
This document does not declare either Windows port supported.

The user outcome is a working project and dependable package management on each Windows target.
The governing principles are independent target qualification, file preservation, and evidence bound to exact artifacts.

## Target boundaries

| Target | ISA | Operating system used by the workflow | External ABI | Native PE machine |
| --- | --- | --- | --- | --- |
| `x86_64-windows` | x86-64 | Windows Server 2025 | Microsoft x64 | `0x8664` |
| `aarch64-windows` | AArch64 | Windows 11 ARM64 | Microsoft ARM64 | `0xaa64` |

The runner records the actual operating-system build and CPU identifier.
It does not infer a minimum supported Windows version or additional CPU extensions from a passing run.
Those support declarations require source review and separate acceptance evidence.

Microsoft documents the [x64 ABI](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170) and [Windows ARM64 ABI](https://learn.microsoft.com/en-us/cpp/build/arm64-windows-abi-conventions?view=msvc-170).
These sources were checked on 5 November 2026.
Windows ARM64 reserves `x18` and has platform-specific calling requirements.
The C checker tests Windows LLP64: 64-bit pointers and 32-bit `long` values.

Cross-assembly establishes neither process behavior nor Windows filesystem behavior.
An x64 executable running through ARM64 emulation does not qualify the native x64 job.
The runner requires matching host and PE machine values through [IsWow64Process2](https://learn.microsoft.com/en-us/windows/win32/api/wow64apiset/nf-wow64apiset-iswow64process2).

## Native execution route

The [workflow](../.github/workflows/windows-ports.yml) uses `windows-2025` and `windows-11-arm` independently.
It runs separate CLI and package jobs on each ISA.
All four jobs must pass.
Package qualification proceeds independently when the CLI build or tests fail.
An independent Ubuntu job also runs the full reference-package suite.
It uses GNU cross tools, QEMU user mode, and QEMU system semihosting for the required Linux package cases.
Those results do not qualify native ARM64 or RISC-V hardware.
Other platforms' skipped runtime cases remain explicit and do not qualify those targets.
GitHub lists both labels in its [hosted-runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
These labels were checked on 5 November 2026.
The standard ARM64 label requires a public repository.

Runner images change.
The workflow records their actual versions instead of treating a label as a fixed image.
GitHub publishes the [Windows Server 2025 inventory](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md) and [Windows ARM64 inventories](https://github.com/actions/runner-images/tree/main/images/windows).
The obsolete `actions/partner-runner-images` repository is archived; it must not define current tool versions.

The build needs LLVM `clang.exe`, `lld-link.exe`, and the target Windows SDK import libraries.
Native C linking also needs the target MSVC runtime libraries and headers.
Microsoft describes [Clang acquisition and SDK integration](https://learn.microsoft.com/en-us/cpp/build/clang-support-msbuild?view=msvc-170).
That source was checked on 5 November 2026.

The CLI uses fixed executable paths for LLVM, Windows curl, and Git for Windows gzip.
The qualification fails when a required executable or import library is absent.
It does not silently install another toolchain or skip the affected target.
The workflow sets `LIB` and `INCLUDE` for the installed target toolchain.
Actual native compiler and linker success remains a required runtime result.

1. Commit the reviewed source.
2. Use a clean checkout at that exact commit.
3. Build the target PE executable through the workflow.
4. Run the target command below on its matching Windows host.

For x64:

```powershell
python tools/windows_test.py --asm build/asm-x86_64-windows.exe --target x86_64-windows --source-commit COMMIT --evidence build/windows-evidence/runtime.json --toolchain-bin 'C:\Program Files\LLVM\bin' --packages
```

For ARM64:

```powershell
python tools/windows_test.py --asm build/asm-aarch64-windows.exe --target aarch64-windows --source-commit COMMIT --evidence build/windows-evidence/runtime.json --toolchain-bin 'C:\Program Files\LLVM\bin' --packages
```

Replace `COMMIT` with the full checkout commit.
Success returns zero and records `outcome: pass` with `qualifies_native_runtime: true`.
A missing executable, wrong architecture, missing tool, or unavailable Windows runtime returns an error.
Failed checks return a nonzero status and retain their diagnostics.

`--allow-dirty` permits development checks only.
It records the input file digests and can produce `experimental-pass`.
It cannot produce native qualification evidence.

## Observable acceptance checks

The [runtime suite](../tests/windows/test_runtime.py) runs 45 test cases through native PE executables.
Each child has a timeout.
The tests use temporary directories and deterministic archive contents.
They check exit codes, standard output, standard error, and file effects.
An elevated runner can create directories owned by Administrators.
The fixture assigns the actual user as owner of intended private directories inside its temporary tree.
It preserves existing access entries before hostile-permission tests apply their deliberate changes.
This matches the private-directory ownership requirement enforced by the CLI.

| Boundary | Required observation |
| --- | --- |
| Command interface | Version, help, license, doctor, target, status, argument errors, and closed-output failures |
| First project | Create, initialize, build, run, test, and clean with visible output |
| Target selection | Named native source/test paths, no-run tests, inactive recipe rejection, and target-specific v2 locks |
| Process control | Literal arguments, spaces, Unicode, an empty `PATH`, and child failures |
| Preservation | Existing projects, partial initialization, failed assembly, failed checks, and failed links preserve files |
| Manifest and index | Duplicate fields, malformed records, unsupported targets, embedded NUL bytes, and input bounds fail |
| Downloads | Exact bytes succeed; corrupt bytes, wrong sizes, network failure, and existing destinations fail |
| Dependencies | Exact locks, actual assembly imports, update, remove, sync, and edited-cache rejection |
| Archives | Traversal, links, special members, duplicate paths, corrupt compression, and invalid headers fail |
| Windows paths | Junctions, alternate streams, reserved devices, trailing-dot aliases, and case aliases fail |
| Access controls | Everyone-writable state and destination directories fail without file mutation |
| Installed programs | Install, list, upgrade, deliberate execution, uninstall, hardlinks, and edited-file preservation |
| Publication preparation | Source and PE records contain exact digests; invalid source, ABI fields, and existing outputs fail |
| Native libraries | An assembly `main` calls Kernel32 and UCRT; a compile-only checker asserts LLP64 |
| Self-update | Exact replacement, three provenance bindings, substituted identity rejection, and finalization failure preservation |
| Capture deadline | The exact capture loop checks an advancing clock while one-byte reads remain continuously available |

Microsoft documents [Windows path aliases](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file) and [reparse-point operations](https://learn.microsoft.com/en-us/windows/win32/fileio/reparse-point-operations).
Both sources were checked on 5 November 2026.
The tests observe named hostile cases; they do not establish the absence of all filesystem races.

The self-update cases compile separate test-only assembly executables.
They replace two fixed tool paths with native PE fixtures.
They retain the parser, staging, identity checks, process control, and replacement mechanism under test.
The finalization variant injects an invalid directory handle only at the final replacement call.
The test requires all three successful verifier bindings before that failure.

The displaced-image case starts the CLI with its [primary thread suspended](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags).
It renames the mapped executable and creates a byte-identical file at the original path before resuming that thread.
An equal-version positive control must succeed before this case can assess image identity.
The fixture records native file IDs and separate kernel comparison results for both files.
The CLI must reject the displaced image before transport or staging and preserve both files.
The kernel comparison uses the [pinned class-44 research contract](https://github.com/m417z/ntdoc/blob/43061ffc1205edd6b49a146b03ebd243f36f3565/descriptions/processinfoclass.md#processimagefilemapping-44).
That internal API requires native qualification; unavailable calls and failed renames produce errors, never skipped successes.

The [tool fixture](../tests/windows/update_tool_fixture.c) enforces exact verifier arguments and rejects inherited test credentials.
It supplies deterministic release bytes and simulated verifier results.
It compares each subject and bundle against the exact expected fixture bytes.
The ordered transcript requires `manifest-identity`, `manifest-exact`, and `candidate-exact` separately.
Verifying the manifest twice cannot replace candidate verification.
It does not perform HTTPS or Sigstore cryptography.
These cases establish updater integration behavior, not a real release signature result.
The fixture is never linked into the CLI or a release artifact.
Its curl mode returns exact binary bytes on standard output, matching the bounded parent capture contract.

The capture-deadline test compiles a separate native PE harness with deterministic pipe and clock API shims.
It copies the capture loop or routine verbatim from the selected Windows adapter.
It requires a deadline result before 256 reads, with a 4096-byte capture limit.
This distinguishes the deadline from an eventual byte-limit failure without wall-clock delays or large buffers.
The result covers that routine with simulated APIs; it does not replace real process integration tests.

`--packages-only` runs `tests/packages/test_*windows.py` without requiring a CLI executable.
The workflow uses this option in both independent package jobs.
`--packages` adds these tests to a developer's combined CLI run.
The package gate requires seven matching native execution records bound to exact build-artifact digests.
Build-only results, skipped native cases, missing executions, and target mismatches fail this gate.
The report retains package input hashes, generated object/import-library/executable hashes, build records, and native execution records.
Package jobs use LLVM and the examples' declared import definitions independently of CLI SDK and MSVC prerequisites.
The package tests build the reference sources directly; they do not establish an `asm run` workflow for those packages.

The production executable remains unchanged throughout the suite.
Its digest is checked before and after testing.
Test-only executable digests and prepared-source digests are recorded separately.

## Evidence and limits

The workflow builds from its exact checked-out commit with read-only repository permissions.
It pins action commits and does not use `pull_request_target`.
It retains native bytes, generated assembly, build hashes, tool versions, and runtime reports for fourteen days.
The upload runs after failures when build evidence is available.
Failed runs remain part of the qualification history.

The JSON report identifies the source commit, target, ABI, host, tools, artifact digest, command results, and test outcomes.
Missing or skipped checks cannot become a passing native qualification.
Expected failures and unexpected successes also prevent qualification and have distinct recorded outcomes.
Native qualification is one input to release acceptance.
It does not replace verifier tests, complete history review, provenance publication, or testing published downloads.

Local checks on 5 November 2026 passed twenty-one evidence-driver and fixture tests.
The C tool fixture cross-compiled to x64 and ARM64 COFF with Apple Clang.
Neither result executes Windows code.
Both native Windows reference-package jobs passed in [run 41942208419](https://github.com/stubbi/asm/actions/runs/41942208419).
That run used source commit `0bf5b1d9c695fa520243757b991aa1e01f450eaa`.
The ARM64 CLI failed to link, and the x64 CLI failed runtime tests.
The aggregate qualification therefore failed.
Complete CLI behavior and native MSVC resolution remain unqualified.
The suite's unsupported-host refusal is an error result, never a skipped success.

Both cross-built PE executables also reached the native-host gate on the local macOS machine.
Each attempt returned status 2 and reported that no runtime test executed.
The local reports are `build/windows-evidence/local-x86_64-refusal.json` and `build/windows-evidence/local-aarch64-refusal.json`.
They retain the exact PE digests and dirty development-input hashes.
They are negative preflight evidence, not Windows qualification.

Review found an incorrect finalization fault anchor and insufficient verifier fixture bindings.
The pre-fix fixture accepted changed subjects, changed bundles, and duplicate manifest checks.
All four focused verifier regression tests failed against the retained pre-fix fixture executable.
The corrected helper and fixture tests pass.
`build/windows-evidence/review-before.json` and `review-before-fixture-regressions.log` retain those negative results.
The Unix fixture adapter tests decision logic only; it does not test Windows APIs.
Hostile absolute archive paths now target sentinel files inside a separately owned temporary directory.
The test retains that directory until all no-mutation assertions finish.

The current suite exercises generated projects, deterministic source packages, and the checked-in Windows hello and math reference packages.
The successful package jobs do not establish successful CLI integration or release qualification.
Windows server qualification is outside this workflow; the server deployment contract is Linux.

Run the evidence-driver checks on a development host:

```sh
python3 -m unittest discover -s tests/windows -p test_evidence_driver.py -v
```

These tests check the evidence gate.
They do not qualify a Windows port.
