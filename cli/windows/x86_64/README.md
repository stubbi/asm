# Windows x86-64 CLI candidate

This directory contains an unqualified Windows x86-64 implementation candidate.
It does not establish released Windows support.
Seven native Windows runs executed the CLI and retained failed runtime results.
The sixth and seventh runs each passed 44 of 45 runtime methods.
Archive lifecycle, inventory, device aliases, and image displacement now pass their native cases.
Successful updater replacement remains the one failing method.
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

On 2026-11-05, Apple clang 17.0.0 cross-assembled the sixth candidate with exit status zero:

```text
python3 tools/windows_x64.py --output build/windows/x86_64/asm.s
clang --no-default-config -target x86_64-pc-windows-msvc -c build/windows/x86_64/asm.s -o build/windows/x86_64/asm.obj
```

The generated assembly SHA-256 was `a0c727199fd157589bcdbb46e654f7e5604c7e25b5b52698520d889c8bf83191`.
The object SHA-256 was `18ba9858847fde7241524ce84485c5d34dcd6d059ae248162b6f259f0c8d06ad`.
These digests identify source and object bytes, not a qualified executable.
The temporary-import cross-link produced 99,328 bytes with SHA-256 `4137a2639468caaef0d9e77606c0f91fdd217f4791434c3e9750cc6a3fa81f11`.
`build/windows/x86_64/cross-build-sixth-candidate.json` records exact compile and link arguments.
The first link attempt failed because its temporary import library lacked `NtSetInformationFile`.
Adding that existing SDK export to the local import definition permitted the cross-link.
This does not establish native SDK linking or execution.
Native CI must record the final PE digest with its actual SDK, toolchain, host, and results.
The required `make test` run retained two macOS bootstrap timing failures among 264 tests.
One exact rerun exceeded its 20-second process deadline.
A stalled-verifier case took 13.98 seconds against its 10-second assertion.
`build/x64-third-required-make-test.log` retains the full result.
Later required `make test` runs passed 270 tests.
`build/x64-fourth-required-make-test.log` and `build/x64-sixth-required-make-test.log` retain those results separately.
The earlier failures remain recorded; they are not converted into passes.

`pe.s` checks a bounded AMD64 PE32+ console executable container.
It checks header and section ranges, alignment, an executable file-backed entry, NX compatibility, and writable executable sections.
Mapped section ranges must follow the aligned headers and remain ordered and disjoint.
Raw file ranges must also be disjoint.
A bounded pairwise check permits disjoint raw ranges in either file order.
It does not establish program behavior or publisher identity.
The publication adapter retains the existing target-specific Linux ELF checks for cross-target records.

The generator accepts `--toolchain-bin`, `--curl-path`, and `--gh-path` for fixed qualification builds.
These choices are compiled into the executable.
There is no runtime override for the transport or verifier path.
A fixture build must remain separate from a release build.

## Regression checks with host shims

On 2026-11-05, thirty-four focused checks passed on macOS.
The assembly fixtures execute through Rosetta with deterministic API shims.
Other checks inspect produced COFF layouts, Clang behavior, and diagnostic failures.
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
Aligned storage permits that simulated launch.
The third native diagnostic observed successful process setup before Clang rejected a raw `kernel32.lib` input.
The corrected argv forwards that fixed library directly to the linker.
SDK library lookup still uses the reviewed developer environment; the adapter does not infer missing SDK support.
A host Clang driver check rejects the raw library input and accepts the forwarded argument.
That check does not link an SDK executable.
Exact assembly, checker, C link, and standalone link argument checks require `--no-default-config`.
A real Clang configuration fixture confirms that this flag ignores an otherwise loaded invalid default configuration.
PE links use `/Brepro` for deterministic linker metadata.
Actual COFF symbol checks reproduced five unaligned UTF16 literals before correction.
All native API UTF16 literals now have explicit word alignment.
The lock literal was among those unaligned inputs.
The third diagnostic recorded `STATUS_DATATYPE_MISALIGNMENT` from its lock-file open, before the filesystem preflight.
Native locking and updater confirmation remain required.
Manifest cases preserve all seven canonical target identities and reject Windows stream, device, and path aliases.
Publication metadata keeps its Linux table entry separate from the Windows host.
Foreign Windows and Mach-O executable publication remains unsupported on this candidate.
A raw-pointer overlap fixture reproduced acceptance before the new file-range check.
The metadata parser rejected a valid Windows asset because its expected filename omitted `.exe`.
The corrected parser accepts the exact Windows name and rejects modified names, sizes, and digests.
Native path display removes only the internal drive marker; receipt storage remains unchanged.
Image checks cover exact API input, missing APIs, warning statuses, and mismatch handling.
The actual open routine checks the final held file before descriptor allocation and closes it after mismatch.
Only image opens request additional execute access.

A capture setup failure leaked its pipe write handle before stream ownership transferred.
An exact process API shim reproduced that leak when `SetHandleInformation` failed.
The adapter now owns the successful pipe outputs before that call.
The regression checks exact handle closures after setup failure, process creation failure, and successful capture.
Repeated stream cleanup does not close those handles again.
`build/x64-eighth-before-pipe-ownership-fix.log` retains the failing check.
`build/x64-eighth-host-shims.log` retains all thirty-four passing checks.
The required `make test` passed 270 tests; `build/x64-eighth-required-make-test.log` retains that result.
The changed source and diagnostic cross-builds are recorded in `build/windows/x86_64/eighth/cross-build.json`.
These checks do not establish native Windows failure behavior.

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
The third [native CLI run](https://github.com/stubbi/asm/actions/runs/42010274631) passed the corrected owner preflights and C ABI execution.
It retained failures for standalone linking and lock-file creation.
Its diagnostic found that the apparent filesystem failure followed an unaligned lock-file open.
The current literal alignment and linker arguments need a native rerun.
Package lifecycle, compiler output, recovery, and updater qualification remain incomplete.
The ordinary repository CLI and verifier release gates also remain required.

Verifier environment values now convert the internal `/C:/...` representation to native `C:/...` paths.
HOME, GH_CONFIG_DIR, XDG_CACHE_HOME, XDG_CONFIG_HOME, USERPROFILE, and LOCALAPPDATA point to the private verifier directory.
These values have host-shim coverage; real Windows verifier and cache behavior still need qualification.
Manual self-update remains incomplete.

The running-image preflight opens the module path and retains its final file handle.
It requests `FILE_EXECUTE | SYNCHRONIZE` for that image check.
The runtime resolves `NtQueryInformationProcess` from the already loaded `ntdll.dll` module.
`ProcessImageFileMapping` class 44 receives the held handle through an eight-byte input pointer.
Only `STATUS_SUCCESS` qualifies that file as the process image.
The same descriptor supplies later owner, file identity, and replacement checks.
An observed mismatch reports that the running executable differs from the installed file.
An unavailable or unsupported identity mechanism requires manual installation of the verified release.
There is no path-equality fallback.

Class 44 is an undocumented Windows interface and remains a target-specific assumption.
Microsoft warns that this native API can change or become unavailable.
The fourth native fixture observed original-file status zero before and after displacement.
A byte-identical replacement with a different file identity returned `C0000001`.
That fixture later failed during its preservation check; the full scenario was not qualified.
The earlier CLI returned success after displacement, and that negative result remains retained.
The corrected native scenario passed in the sixth and seventh runs.

The [fifth native run](https://github.com/stubbi/asm/actions/runs/42019241381) still rejected the positive source archive.
Direct gzip probes passed with both empty and minimal Windows environments.
Each produced 10,240 bytes with the expected raw tar digest.
This result does not establish the CLI's capture or extraction behavior.
The diagnostic's archive index used Windows text translation and failed before decompression.
Its corrected byte writer preserves the registry's required LF line endings.
A simulated Windows translation case reproduces the old CRLF error and passes after correction.

Source review found a separate stage-finalization access defect.
The archive root was reopened read-only before `SetSecurityInfo` changed its protected DACL.
That operation requires `WRITE_DAC` on the retained handle.
The prepared private stage reopen now requests only that additional right.
Ordinary ancestors and read-only directory opens retain their previous access masks.
The exact stage, native-open, and protection routines reproduce access denied before correction and success afterward.
The sixth and seventh native runs subsequently passed the source archive lifecycle cases.

The first combined stage fixture crashed because its constant followed the extracted Intel-syntax instruction.
Clang interpreted that forward symbol as a memory operand.
Moving the constant before the instructions corrected the fixture.
The meaningful access-denied result was evaluated only after that correction.
The target preparation also defines its named internal flag before all instructions.

Windows device-name checks now reject superscript digits one, two, and three after COM or LPT.
Twelve bare and extension forms reproduced acceptance before correction.
Ordinary superscript filenames remain accepted.

The next diagnostic reuses the real positive updater fixture with separately instrumented CLI bytes.
Its test transport and verifier enforce arguments but validate no real signature.
It records raw rename, DACL, and flush API results alongside each commit syscall result.
The logger preserves the API return value and thread error value across trace writes.
A deterministic error-clobber case failed before that preservation change and now passes.
The [sixth native run](https://github.com/stubbi/asm/actions/runs/42033134716) reached all three provenance bindings.
Opening, protecting, flushing, and closing the candidate succeeded.
The final `NtSetInformationFile` returned `C0000022` (`STATUS_ACCESS_DENIED`).
The adapter returned an error and preserved the prior executable.
Ordinary installed-program replacement passed in the same run.

A source-derived constructor check records source delete access, the held destination directory, flags three, and information class 65.
It also records the exact `asm.exe` name, fourteen-byte name length, thirty-four-byte request, and descriptor cleanup.
These host observations establish the constructed request, not Windows rename compatibility.
Microsoft documents an executing-file restriction alongside the POSIX open-handle flags.
No backup swap, unmap finalizer, or replacement fallback has been added to production.

`rename_probe.py` compares identical owned ordinary and suspended-image targets.
It queries actual granted access, attributes, file identities, final paths, digests, and native completion status.
The child remains suspended and is never resumed.
A private kill-on-close job and bounded termination waits retain process ownership.
Only disposable files are mutated; the supplied CLI is read-only input.
An invalid probe remains an error and does not establish target support.

Run the native comparison separately:

```text
python cli/windows/x86_64/rename_probe.py --binary build/asm-x86_64-windows.exe --evidence build/windows-evidence/x64-rename-comparison.json
```

The evidence destination must not exist.
The existing native diagnostic driver also collects this comparison before its updater case.
The [seventh native run](https://github.com/stubbi/asm/actions/runs/42038909292) completed both comparison cases.
The ordinary target replacement returned zero for both native status and completion status.
The identical request against the suspended image returned `C0000022` for both statuses.
Both cases reported source access `0x130081`, parent access `0x120081`, and held-target access `0x1200a1`.
The denied case preserved source and target file identities and digests, then terminated and reaped the owned child.
This establishes a mapped-target distinction on that Windows x64 runner.
It does not establish every internal kernel condition behind that denial.
The retained comparison is under `build/windows-seventh-native`.


Atomic replacement of the running CLI remains blocked by the observed native denial.
A different completion mechanism requires separate review and native evidence.
Do not report a completed update until the replacement and its recovery behavior are observed.

## Native adapter diagnostics

The separate diagnostic fixture preserves every production permission decision.
It builds an instrumented executable and operates only inside an owned temporary directory.
It records bounded NTSTATUS/component traces, normalized stat fields, token SIDs, and path ownership/DACL information.
It also records child-process setup stages, API results, and Windows error codes in a separate diagnostic executable.
An error code is meaningful only when its API result indicates failure.
The fixture runs the generated project and retains the actual exit status.
It records ambient HOME ownership before setting the positive fixture owner.
The diagnostic source cross-linked to 101,376 bytes with SHA-256 `01281907169ff2f6870bba9099802a1c1a4d6d45a176cc5deed92edd81274386`.
The equal-version updater check makes no network request.
The release generator never includes the diagnostic assembly.

Run this fixture in the Windows developer environment:

```text
python cli/windows/x86_64/native_diagnostics.py --evidence build/windows-evidence/x64-adapter-diagnostics.json
```

The evidence destination must not exist.
The fixture's successful collection does not mean that the recorded CLI commands passed.
A timeout retains bounded partial output and returns collection failure.
A process-start error retains its operating-system error details.
A finalizer writes partial evidence when a later collection step raises an exception.
Two deterministic host cases exercise those failure paths.
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

- [Clang configuration files](https://clang.llvm.org/docs/UsersManual.html#configuration-files)
- [Clang linker arguments](https://clang.llvm.org/docs/ClangCommandLineReference.html#linker-options)

- [Native process-query availability](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess)
- [Pinned process-class declaration](https://github.com/winsiderss/systeminformer/blob/0a4975a4763ad202747397ef5daf5893849b5b00/phnt/include/ntpsapi.h#L208)
- [Pinned class 44 research notes](https://github.com/m417z/ntdoc/blob/43061ffc1205edd6b49a146b03ebd243f36f3565/descriptions/processinfoclass.md#processimagefilemapping-44)

- [DACL update handle access](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo)
- [Reserved Windows names](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file)
