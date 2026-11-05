# Windows x86-64 CLI candidate

This directory contains an unqualified Windows x86-64 implementation candidate.
It does not establish released Windows support.
Two native Windows runs executed the CLI and retained failed runtime results.
The second run created a project, then exposed ownership and child-process failures.
Keep the failed and missing results in the qualification record.

The user outcome is the existing assembly project and package workflow on Windows.
The relevant brand principles are dependable reuse, explicit target qualification, preserved files, and evidence with stated limits.
Cross-assembly evidence does not establish Windows behavior.

## Implementation boundary

The CLI command, manifest, registry, archive, dependency, inventory, and publication logic remains assembly.
`tools/windows_x64.py` prepares assembly source at build time.
It does not provide a package backend or run during CLI use.
The generated starter text has the MIT grant retained from `cli/templates.s`.
Platform adapters and build tools use AGPL-3.0-or-later.

`platform.s` adapts the shared System V internal register contract to Windows APIs.
Each API frame aligns the stack and reserves the required shadow space.
The adapter calls exported APIs rather than fixed Windows kernel syscall numbers.
Its descriptor table owns up to 253 non-inheritable handles.
Standard streams occupy the other three slots.

Paths use strict UTF-8 and UTF-16 conversion with explicit bounds.
Absolute receipt paths use `/C:/...` internally.
Filesystem operations walk one component at a time from held directory handles.
Each open uses `FILE_OPEN_REPARSE_POINT` and checks the resulting handle's reparse attribute.
The adapter rejects traversal, alternate streams, reserved device basenames, and ambiguous trailing dots or spaces.

Private files receive a protected DACL for the current token user and LocalSystem.
The normalized stat record includes volume serial, file index, link count, size, owner class, and unsafe DACL writes.
Inventory and updater checks consume those actual handle results.
Ancestor owners can be the current user, System, Administrators, or TrustedInstaller.
Effective foreign grants can add a subdirectory, but cannot write existing entries or delete protected children.
Administrators ownership qualifies an ordinary file only when `TokenElevation` confirms an elevated token.
Administrators-owned directories remain system ancestors; final private directories require the actual token user.
OWNER_RIGHTS grants qualify only when the object owner already meets that policy.
These rules follow `verifier/PORTABILITY.md`; native hostile-path tests remain required.

Atomic finalization uses a source handle and a held destination directory.
`NtSetInformationFile` receives `FileRenameInformationEx`, with replacement flags selected by the caller.
No copy fallback crosses volumes.
Local NTFS checks reject remote devices for installation locks and self-update.
Advisory locks do not constrain other processes running as the same account.
Crash durability and arbitrary same-account interference remain outside the shared contract.

Process creation supplies the executable name separately from its quoted arguments.
`STARTUPINFOEX` limits inherited handles to the three selected streams.
Captured output has an independent byte limit and a 120-second deadline.
Overflow or timeout terminates and reaps the child.
Ordinary application execution remains an explicit user action.

SHA-256 and random bytes use Windows BCrypt.
Source decompression uses a fixed gzip executable with bounded captured output.
The assembly archive validator checks the decompressed bytes before extraction.
Transport uses a fixed curl executable and HTTPS-only arguments.
The parent bounds received bytes before it creates the private output file.

## Candidate prerequisites

Use Windows 11 x64 on local NTFS for native qualification.
Install LLVM with `clang.exe` and `lld-link.exe` in `C:/Program Files/LLVM/bin`.
Install the Windows SDK and the Visual Studio C build tools.
Use their developer environment when building or linking projects.
C ABI checks only compile the declared C source.
They do not execute a checker.

Source packages require `C:/Program Files/Git/usr/bin/gzip.exe` from Git for Windows.
Downloads require `C:/Windows/System32/curl.exe`.
Manual self-update requires GitHub CLI 2.93.0 or later at `C:/Program Files/GitHub CLI/gh.exe`.
The external verifier remains the candidate's provenance mechanism.
A bundled Windows verifier has not been qualified.

The build imports these Windows libraries:

- `kernel32.lib`
- `advapi32.lib`
- `bcrypt.lib`
- `ntdll.lib`
- `shell32.lib`

From the repository root, run:

```text
make -f cli/windows/x86_64/Makefile all
python tools/windows_test.py --asm build/asm-x86_64-windows.exe --target x86_64-windows --evidence build/windows/x86_64/native-test.json
```

The intended executable path is `build/asm-x86_64-windows.exe`.
A starter project declares `x86_64-windows`.
Its intended outputs are `build/app.exe` and `build/test.exe`.
The intended starter output is `Hello from asm!` followed by a line feed.
These results require native qualification before they become supported instructions.

## Evidence for this snapshot

On 2026-11-05, Apple clang 17.0.0 cross-assembled the flattened source with exit status zero:

```text
python3 tools/windows_x64.py --output build/windows/x86_64/asm.s
clang -target x86_64-pc-windows-msvc -c build/windows/x86_64/asm.s -o build/windows/x86_64/asm.obj
```

The generated assembly SHA-256 was `e1f4533af1c655ad217457dd44a09a369a7620a8aed69dfc699e23f8de5efdd0`.
The object SHA-256 was `25b516245df5ff61933ba88d671bfdc32a66561c7d82691003867341c5d6e64c`.
These digests identify source and object bytes, not a qualified executable.
The temporary-import cross-link produced 97,792 bytes with SHA-256 `e46b1ac08a42861ecb9775efddcc57853b4ed29217482546356a92eade8338a3`.
`build/windows/x86_64/cross-build-current.json` records exact compile and link arguments.
The first link attempt failed because its temporary import library lacked `NtSetInformationFile`.
Adding that existing SDK export to the local import definition permitted the cross-link.
This does not establish native SDK linking or execution.
Native CI must record the final PE digest with its actual SDK, toolchain, host, and results.

`pe.s` checks a bounded AMD64 PE32+ console executable container.
It checks header and section ranges, alignment, an executable file-backed entry, NX compatibility, and writable executable sections.
Mapped section ranges must follow the aligned headers and remain ordered and disjoint.
It does not establish program behavior or publisher identity.
The publication adapter retains the existing target-specific Linux ELF checks for cross-target records.

The generator accepts `--toolchain-bin`, `--curl-path`, and `--gh-path` for fixed qualification builds.
These choices are compiled into the executable.
There is no runtime override for the transport or verifier path.
A fixture build must remain separate from a release build.

## Regression checks with host shims

On 2026-11-05, fifteen focused checks passed on macOS through Rosetta.
They execute extracted x86-64 assembly with deterministic API shims.
They do not establish Windows API behavior or native filesystem effects.

Run the checks from the repository root:

```text
python3 cli/windows/x86_64/test_host_shims.py
```

The tests retain these reproduced regressions:

- Drive-absolute destinations were incorrectly prefixed with the current directory.
- Drive-relative and backslash network paths were incorrectly treated as relative names.
- PE section overlaps, header mappings, and raw-data extent overlaps were incorrectly accepted.
- A continuously readable capture performed 64 reads before checking its deadline.
- Unlink could request deletion of an empty directory.

The corrected deadline case performs two one-byte reads and four clock probes before it terminates the child.
The file-kind cases preserve directories during unlink and preserve regular files during rmdir.
The PE cases also retain acceptance of valid adjacent mapped sections.
A separate capture case preserves a final byte written between an empty probe and observed child exit.
A working-directory case accepts the exact extended DOS prefix returned by Windows APIs.
It continues to reject UNC and device namespaces.
Verifier environment cases keep all six native Windows paths inside the private verifier directory.
Ownership cases cover TrustedInstaller, elevated and ordinary Administrators tokens, OWNER_RIGHTS, foreign owners, and foreign write grants.
The prior ownership implementation failed seven policy cases before correction.
An additional case retains the rejection of Administrators as a private directory owner.
An exact process routine shim reproduces status 127 when API structure storage is misaligned.
Aligned storage permits that simulated launch; native error evidence must confirm the remaining real failure.
Manifest cases preserve all seven canonical target identities and reject Windows stream, device, and path aliases.
Publication metadata keeps its Linux table entry separate from the Windows host.
Foreign Windows and Mach-O executable publication remains unsupported on this candidate.

The first PE test harness placed its wrapper in a data section and failed with SIGBUS.
That harness defect was corrected before the PE rejection checks were evaluated.
The original malformed PE fixtures then reproduced acceptance before the parser fix.

## Work still required

The [first native CLI run](https://github.com/stubbi/asm/actions/runs/41942208419/job/126965560411) exercised startup and read-only registry commands.
Its runtime suite failed because project creation and protected ownership preflights stopped later workflows.
The second [native CLI run](https://github.com/stubbi/asm/actions/runs/41947783095) confirmed project creation after the working-directory correction.
Its diagnostics found TrustedInstaller ownership on the drive root and Administrators as the elevated token's default owner.
Python-created files and directories inherited that Administrators ownership.
The corrected policy uses actual token elevation, rather than assuming that every Administrators owner belongs to the caller.
Positive fixture directories receive the actual token user's owner SID; their inherited DACLs remain unchanged.
The retained second-run JSON is under `build/windows-second-native`.
The policy and process storage corrections need a native rerun.
Package lifecycle, compiler output, recovery, and updater qualification remain incomplete.
The ordinary repository CLI and verifier release gates also remain required.

Verifier environment values now convert the internal `/C:/...` representation to native `C:/...` paths.
HOME, GH_CONFIG_DIR, XDG_CACHE_HOME, XDG_CONFIG_HOME, USERPROFILE, and LOCALAPPDATA point to the private verifier directory.
These values have host-shim coverage; real Windows verifier and cache behavior still need qualification.
Manual self-update remains incomplete.

The running-image preflight currently opens the path reported by `GetModuleFileNameW`.
Its held file identity detects subsequent entry replacement.
That path lookup does not independently identify the kernel image section's original file after an earlier displacement.
This difference from Linux `/proc/self/exe` requires a reviewed Windows contract or a stronger mechanism.

NTFS POSIX rename replacement of the running CLI still needs a native test.
If Windows refuses that operation, a separately reviewed completion helper is required.
Do not report a completed update until the replacement and its recovery behavior are observed.

## Native adapter diagnostics

The separate diagnostic fixture preserves every production permission decision.
It builds an instrumented executable and operates only inside an owned temporary directory.
It records bounded NTSTATUS/component traces, normalized stat fields, token SIDs, and path ownership/DACL information.
It also records child-process setup stages, API results, and Windows error codes in a separate diagnostic executable.
An error code is meaningful only when its API result indicates failure.
The fixture runs the generated project and retains the actual exit status.
It records ambient HOME ownership before setting the positive fixture owner.
The diagnostic source cross-linked to 99,840 bytes with SHA-256 `1c3fc1702be1dab2dd96d5f57fa346aa399f8cca58227811c9ca78e16dc9e370`.
The equal-version updater check makes no network request.
The release generator never includes the diagnostic assembly.

Run this fixture in the Windows developer environment:

```text
python cli/windows/x86_64/native_diagnostics.py --evidence build/windows-evidence/x64-adapter-diagnostics.json
```

The evidence destination must not exist.
The fixture's successful collection does not mean that the recorded CLI commands passed.
Its JSON records each command's actual exit status and bounded output.

## Primary API references

The API contracts were consulted on 2026-11-05.
They document API behavior; they do not qualify this implementation.

- [Microsoft x64 calling convention](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention)
- [NtCreateFile](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile)
- [Windows command-line argument parsing](https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments)
- [Explicit process handle inheritance](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute)
- [Volume information by handle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumeinformationbyhandlew)
- [Rename information and POSIX semantics](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information)

- [Final path names and extended DOS prefixes](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew)
- [Default ownership of new objects](https://learn.microsoft.com/en-us/windows/win32/secauthz/owner-of-a-new-object)

- [Token elevation information](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ne-winnt-token_information_class)
- [Fixed account lookup](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupaccountnamew)
- [Process attribute storage](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-initializeprocthreadattributelist)
