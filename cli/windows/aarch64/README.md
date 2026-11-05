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
"C:/Program Files/LLVM/bin/clang.exe" --target=aarch64-pc-windows-msvc -c build/windows/aarch64/asm.s -o build/windows/aarch64/asm.obj
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
Protected administrative ancestors can have add-only child grants.
Managed user directories still require current-user ownership and reject untrusted mutable grants.
New private objects receive a protected DACL for the current user, SYSTEM, and Administrators.
The internal mode fields summarize that Windows policy; they do not claim POSIX permission equivalence.

Child creation supplies the executable path separately from the quoted argument string.
A handle allowlist passes only three duplicated standard streams.
Compiler children receive bounded SDK-related environment values and a fixed PATH.
Verifier and decompression children receive explicit environments.
The parent drains captured output and terminates an overflowing or expired child.
Downloads enter a bounded memory buffer before exclusive file creation.
SHA-256 uses the native BCrypt provider.
No digest process or ambient checksum configuration selects the result.

PE validation checks the exact size, machine, headers, alignments, directory bounds, section bounds, entry point, and protection flags.
It rejects writable executable sections.
This check does not authenticate a publisher or establish general code safety.
The shared updater retains its exact signed manifest, artifact, source commit, signer, repository, and workflow bindings.
Windows finalization uses a retained source handle and `FileRenameInfoEx` with POSIX replacement semantics.
A native test must establish actual replacement of an executing image and preservation after failure.

## Evidence and remaining qualification

On 5 November 2026, Apple clang 17.0.0 cross-assembled the prepared source for `aarch64-pc-windows-msvc`.
The initial assembly checks exposed three syntax errors; those errors were corrected before the successful check.
The source-derived ABI shim runs on Apple Silicon macOS:

```sh
python3 cli/windows/aarch64/abi_test.py --output build/windows/aarch64/abi-shim-evidence.json
```

The shim executes the production read, write, component-open, directory-enumeration, directory-lock, process-creation, deletion, and capture-loop bodies.
Its test APIs destroy volatile registers and check stack arguments at the callee's stack pointer.
The current bodies pass those checks.
Eight separate regression variants fail when executed.
Those variants restore reviewed stack, volatile-register, capture-deadline, or final-output-drain defects.
The checked deletion paths also reject a directory passed to unlink and a regular file passed to rmdir.
The capture check includes an empty peek, child completion, one pending byte, and EOF.
The shim uses test APIs and a controlled clock.
It does not establish Windows API, filesystem, or runtime behavior.

The native Windows runtime suite has not run in this subtask.
Cross-assembly does not establish command behavior, DACL compatibility, filesystem race behavior, SDK discovery, or active-image replacement.
No supported-host or release claim follows from this result.

The remaining checks include the first project, C-ABI linking, package lifecycle, hostile paths, network errors, and authenticated self-update.
The native Windows runner must also check failure cleanup and the exact tested executable digest.
The full release gates remain separate from runtime qualification.

## Primary references

The implementation review consulted these Microsoft references on 5 November 2026:

- [Windows ARM64 ABI](https://learn.microsoft.com/en-us/cpp/build/arm64-windows-abi-conventions?view=msvc-170)
- [PE and COFF format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format)
- [NtCreateFile](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile)
- [CreateProcessW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw)
- [Process handle inheritance](https://learn.microsoft.com/en-us/windows/win32/procthread/inheritance)
- [File rename information](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information)
- [FILE_RENAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info)
