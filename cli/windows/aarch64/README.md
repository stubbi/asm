# Windows ARM64 CLI candidate

This directory supplies native Windows ARM64 adapters for the shared AArch64 CLI.
It is an unpublished port candidate.
A successful cross-build does not establish Windows runtime support.

The user outcome is the existing Asm workflow on another explicit machine target.
The guiding principles are dependable reuse, file preservation, and trust through target-specific evidence.

## Target and prerequisites

| Property | Candidate contract |
| --- | --- |
| Target identifier | `aarch64-windows` |
| ISA | AArch64, ARMv8-A baseline instructions |
| Operating system | Windows 11 ARM64 |
| ABI | Windows ARM64, 64-bit pointers, LLP64 C data model |
| Object and executable format | ARM64 COFF and PE32+; Machine `0xAA64` |
| Additional CPU features | None requested by this implementation |
| Managed installation filesystem | Local fixed NTFS volume |

Install LLVM with `clang.exe` and `lld-link.exe` in `C:/Program Files/LLVM/bin`.
Install the Windows SDK and Visual Studio ARM64 libraries.
Use a developer environment that exposes the matching SDK import libraries.
Install Git for Windows to supply `C:/Program Files/Git/usr/bin/gzip.exe`.
Registry downloads use `C:/Windows/System32/curl.exe`.
Self-update provenance checks use GitHub CLI 2.93.0 or later at `C:/Program Files/GitHub CLI/gh.exe`.

The CLI uses assembly for package logic.
The Python preparation script only adapts shared source for the Windows assembler and selects native boundary implementations.
It does not run behind the CLI.
The generated starter files retain the shared MIT notice.
The port code uses AGPL-3.0-or-later.

## Build and check

Run these commands from the repository root in the ARM64 developer environment:

```text
python tools/windows_arm64.py --output build/windows/aarch64/asm.s
"C:/Program Files/LLVM/bin/clang.exe" --no-default-config --target=aarch64-pc-windows-msvc -c build/windows/aarch64/asm.s -o build/windows/aarch64/asm.obj
"C:/Program Files/LLVM/bin/lld-link.exe" /machine:arm64 /entry:_start /subsystem:console /nodefaultlib /nxcompat /dynamicbase /Brepro /out:build/asm-aarch64-windows.exe build/windows/aarch64/asm.obj kernel32.lib ntdll.lib advapi32.lib bcrypt.lib shell32.lib
python tools/windows_test.py --asm build/asm-aarch64-windows.exe --target aarch64-windows --evidence build/windows/aarch64/runtime-evidence.json
```

The local Makefile provides equivalent `all` and `test` targets for GNU make.
The runtime driver records the executable digest, host, commands, output, exit status, and test results.
Keep a failed result beside later results.
Run the repository CLI and release gates before publishing a Windows executable.

## Boundary contracts

The internal CLI ABI uses `x0` through `x7` for inputs and `x9` for its result.
The adapters preserve those input registers and `x19` through `x29`.
The adapters never modify the reserved Windows `x18` register.
The preparation script adds linked `x29` frames around shared calls.
Every stack allocation has 16-byte alignment.
Routine comments state local capacities, ownership, changed registers, and failure values.
Stack arguments use a separate outgoing area below each saved frame.
Native exception unwinding still requires Windows qualification.

Paths cross the Windows boundary through strict UTF-8 and UTF-16 conversion.
Inventory and updater paths use drive-absolute `C:/...` spelling.
HOME comes from the inherited HOME value, or USERPROFILE when HOME is absent.
Paths use retained directory handles for component opens and mutations.
Each opened component rejects reparse points, including junctions.
The boundary rejects parent traversal, alternate data streams, reserved DOS devices, and trailing-dot or trailing-space aliases.
The archive parser also rejects case-folded path conflicts.
These checks do not constrain a same-account process that ignores Asm's advisory locks.
Changing the process current directory requires a Windows pathname API.
That step is not a descriptor-only confinement guarantee.

File metadata records the volume serial, file index, size, link count, owner class, and observed DACL grants.
The current user, SYSTEM, Administrators, and TrustedInstaller are recognized security principals.
Protected administrative ancestors can grant directory creation without granting writes to existing children.
Managed user directories still require current-user ownership and reject untrusted mutable grants.
New private objects receive explicit current-user ownership and a protected DACL for that user, SYSTEM, and Administrators.
Only a verified elevated token can accept Administrators ownership of an ordinary regular file.
Administrators-owned directories remain administrative ancestors; they cannot qualify as private user directories.
OWNER_RIGHTS grants are accepted only when the actual owner already qualifies.
Exclusive identity probes grant the current user metadata and cleanup rights without data read, write, or execute rights.
Probe stat adapters populate only the observed volume and file identity.
They cannot establish ownership, permissions, or executable validity.
The internal mode fields summarize that Windows policy; they do not claim POSIX permission equivalence.

Child creation supplies the executable path separately from the quoted argument string.
A handle allowlist passes only three duplicated standard streams.
Compiler children receive bounded SDK-related environment values and a fixed PATH.
Every Clang invocation disables default configuration.
Link invocations select LLVM lld and forward SDK import libraries as linker arguments.
Verifier and decompression children receive explicit environments.
Verifier HOME, XDG paths, USERPROFILE, and LOCALAPPDATA refer to the same new private verifier directory.
The parent drains captured output and terminates an overflowing or expired child.
Downloads enter a bounded memory buffer before exclusive file creation.
SHA-256 uses the native BCrypt provider.
No digest process or ambient checksum configuration selects the result.

PE validation checks the exact size, machine, headers, alignments, directory bounds, section bounds, entry point, and protection flags.
It rejects writable executable sections.
This check does not authenticate a publisher or establish general code safety.
The shared updater retains its exact signed manifest, artifact, source commit, signer, repository, and workflow bindings.
Managed Windows installation uses a stable launcher and versioned payloads.
The launcher path is `HOME/.local/bin/asm.exe`.
The selection record is `.asm-cli/current.tsv` beside the launcher.
Payloads use `.asm-cli/versions/<sha256>/asm.exe`.
The exact contract is in [the layout specification](../../../docs/superpowers/specs/2026-11-05-windows-versioned-updates-design.md).

The launcher checks one held record snapshot and the selected payload's exact bytes.
It checks the actual launcher metadata and binds each suspended child to the held payload file.
The launcher waits without a tool deadline and retains the child's complete Windows exit status.
Its own console handler accepts Ctrl+C and Ctrl+Break notifications.
Native console tests must establish the resulting cancellation behavior.

An update validates the executing payload against the active selection.
It reads compatibility requirements from the held current launcher and candidate metadata.
The updater preserves all shared release and provenance bindings.
It never executes the candidate.
A held-file rename activates the flushed replacement selection record.
The launcher and existing payloads remain unchanged.
The `.asm.lock` file uses an exclusive, nonblocking lock on byte zero.
This lock coordinates the bootstrap installer and updater.

Old payloads remain for running commands and recovery.
Launcher repair uses the bootstrap installer after existing Asm processes exit.
This design adds a launcher process and retains old payload disk use.
It does not promise transactional directory durability or protection against every same-user filesystem race.

## Evidence and remaining qualification

On 5 November 2026, Apple clang 17.0.0 cross-assembled the prepared source for `aarch64-pc-windows-msvc`.
The initial assembly checks exposed three syntax errors; those errors were corrected before the successful check.
The source-derived ABI shim runs on Apple Silicon macOS:

```sh
python3 cli/windows/aarch64/abi_test.py --output build/windows/aarch64/abi-shim-evidence.json
```

The shim executes production file, probe, directory, process-creation, deletion, and capture-loop bodies.
Its test APIs destroy volatile registers and check stack arguments at the callee's stack pointer.
The current bodies pass those checks.
Eleven separate regression variants fail when executed.
Those variants restore reviewed stack, volatile-register, capture-deadline, final-output-drain, or extended-directory-path defects.
The checked deletion paths also reject a directory passed to unlink and a regular file passed to rmdir.
Probe tests inspect actual shim-supplied identities, reject permission claims, use metadata-only access, and close failed lookups.
The directory test supplies an extended drive path from the native path API.
The current-directory setter receives its ordinary drive form.
A terminal read-only directory dot opens an independent duplicate of the held directory.
It does not request a raw NT child named dot.
The capture check includes an empty peek, child completion, one pending byte, and EOF.
The shim uses test APIs and a controlled clock.
It does not establish Windows API, filesystem, or runtime behavior.

The fifth native Windows candidate ran 45 test methods at commit `54625e990e81b603d8ea83c6f1554752c0052ed1`.
Its evidence records 38 passing methods and seven failures.
Build finalization and valid executable acceptance passed.
Inventory parsing, source decompression, updater replacement, and the displacement fixture failed.
Those results do not qualify this target.
The current corrections still require a fresh native run.
Cross-assembly does not establish command behavior, DACL compatibility, filesystem race behavior, SDK discovery, or active-image replacement.
No supported-host or release claim follows from this result.

The remaining checks include the first project, C-ABI linking, package lifecycle, hostile paths, network errors, and authenticated self-update.
The native Windows runner must also check failure cleanup and the exact tested executable digest.
The full release gates remain separate from runtime qualification.
Native table declarations use the shared selected-target parser and version 2 dependency locks.
Foreign builds fail before output mutation because this candidate has no qualified foreign toolchain contract.

Run the additional controlled host checks:

```sh
python3 cli/windows/aarch64/security_test.py --output build/windows/aarch64/security-evidence.json
python3 cli/windows/aarch64/environment_test.py --output build/windows/aarch64/environment-evidence.json
python3 cli/windows/aarch64/contracts_test.py --output build/windows/aarch64/contracts-evidence.json
python3 cli/windows/aarch64/image_test.py --output build/windows/aarch64/image-evidence.json
python3 cli/windows/aarch64/metadata_test.py --output build/windows/aarch64/metadata-evidence.json
python3 cli/windows/aarch64/inventory_test.py --output build/windows/aarch64/inventory-evidence.json
```

The security shim executes the production owner and DACL routines with eleven controlled cases.
It covers elevated file owners, administrative directories, foreign grants, OWNER_RIGHTS, and directory-add grants.
The environment shim checks native private paths and rejection of an ambiguous root.
The contract shim checks twelve source-path cases and eight publication target cases.
Two restored boundary defects fail during actual shim execution.
Cross-object inspection verifies even addresses for native UTF-16 literals.
Removing the lock-name alignment produces an odd address in the retained regression object.
These shims do not establish Windows authorization, process creation, or NTFS behavior.
The updater now checks the retained executable handle against the process creation image through runtime-resolved `NtQueryInformationProcess` class 44.
The handle includes execute and synchronization rights.
Only exact status zero succeeds.
Missing APIs and unsupported results require manual installation; an observed identity mismatch preserves both files.
The native fixture observed original-file status zero and replacement-file status `C0000001`.
This internal Windows API is an explicit platform assumption.
The native current-image control passed.
The displacement fixture needs its corrected native rename call before it can test the adapter.
A pathname from GetModuleFileNameW cannot replace this identity check.

## Primary references

The implementation review consulted these Microsoft references on 5 November 2026:

- [Windows ARM64 ABI](https://learn.microsoft.com/en-us/cpp/build/arm64-windows-abi-conventions?view=msvc-170)
- [PE and COFF format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format)
- [NtCreateFile](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile)
- [CreateProcessW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw)
- [Process handle inheritance](https://learn.microsoft.com/en-us/windows/win32/procthread/inheritance)
- [File rename information](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information)
- [FILE_RENAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info)

The ownership review also consulted these Microsoft references on 5 November 2026:

- [TOKEN_ELEVATION](https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-token_elevation)
- [SetSecurityDescriptorOwner](https://learn.microsoft.com/windows/win32/api/securitybaseapi/nf-securitybaseapi-setsecuritydescriptorowner)

The compiler review consulted these LLVM references on 5 November 2026:

- [Clang configuration files](https://clang.llvm.org/docs/UsersManual.html#configuration-files)
- [Clang linker selection](https://clang.llvm.org/docs/Toolchain.html#linker)

The PE parser uses the shared installation contract: one means valid, and zero means invalid.
Publication adapts that result to its separate zero-on-success contract.
The retained native fourth executable passes the corrected host parser check.
Corrupt DOS bytes, a foreign machine, and truncation fail that check.
Release metadata tests bind the exact Windows `.exe` asset name, size, and digest.
These host checks do not authenticate provenance or establish Windows file authorization.
The full prepared source-package validator accepts the raw TAR fixture on the host.
Native decompression remains unresolved; the next native diagnostic records gzip status and captured byte counts.

The inventory regression executes the complete prepared receipt parser and metadata validators on an Apple Silicon host.
A serialized native drive path with spaces and an ampersand passes.
A virtual drive prefix, drive-relative path, and traversal are rejected.
Restoring the Unix-only root check makes the valid receipt fail.
This host parser result still requires the native install, list, upgrade, and uninstall round trip.

Archive publication reopens only the newly-created private stage root with `WRITE_DAC`.
That right permits the existing final `SetSecurityInfo` operation.
Ordinary read-only directory and ancestor handles retain their original requested rights.
A source-derived host check executes stage creation, native component open, and DACL finalization.
Its API shim rejects finalization when the observed handle lacks `WRITE_DAC`.
The current preparation passes; removing either narrow flag or access mapping fails.
This is a separate later archive defect; native capture evidence still determines the original failure boundary.

## Versioned lifecycle checks

The managed ARM64 source cross-assembles and links with temporary import declarations.
These declarations are a local build aid, not Windows SDK qualification.
Host shims execute the actual record parser, held PE parser, held hash routine, launcher, and cleanup routines.
They check strict framing, bounds, metadata flags, exact class 44 status, handle ownership, and launch ordering.
They also check an infinite wait and a complete `0xC000013A` child status.
The reserved-store check examines every checked directory in package and inventory walks.
Native mutation opens and rename destinations also check their held parent directories.
Registry and dependency workspaces check their current directory before creating files or locks.
These checks cover `fetch --output` and standalone commands as well as installed-program operations.
It compares the remembered store identity and the native canonical long path.
These checks also protect inventory directory creation when HOME points inside an existing store.
Native tests must qualify NTFS aliases, access rules, selection ordering, and console events.

Run the local routine checks on Apple Silicon:

```sh
make -C cli/windows/aarch64 managed-test PYTHON=python3
python3 cli/windows/aarch64/managed_pe_test.py --artifact build/asm-aarch64-windows.exe --output build/windows/aarch64/managed-pe-held-evidence.json
```

Use an actual cross-built PE artifact for the second command.
A passing shim does not establish native Windows support.
The earlier 45-of-46 direct-update results remain negative evidence.
The direct executing-file replacement protocol is superseded only for this unpublished Windows candidate.
