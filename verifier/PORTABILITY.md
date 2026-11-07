# Verifier platform boundary

This adapter remains gated development code.
The production root is empty, and trusted distribution remains disabled.
The native CLI keeps package selection and replacement logic in assembly.

The adapter retains verification history and reports failures on each qualified host.
Cross-compilation establishes build compatibility; native tests establish only the behavior that they exercise.

## Windows files and state

The Windows adapter requires a writable, fixed, local NTFS volume with persistent access-control lists (ACLs).
An ACL specifies which accounts can access an object.
Canonical absolute drive paths are accepted.
UNC paths, device paths, alternate data streams, reserved DOS names, and trailing-dot or trailing-space aliases are rejected.
Every traversed component rejects reparse points, including junctions and symbolic links.
Regular files require exactly one hard link.
Network shares, removable volumes, FAT, and ReFS are outside this implementation's supported filesystem contract.

The adapter walks one component at a time with `NtCreateFile` and a held parent handle.
It checks the actual handle's owner, type, and ACL.
It retains ancestor handles without delete sharing while retained state is in use.
An unrelated account cannot redirect these path-based library operations by renaming a checked ancestor.
Same-account processes and privileged administrator or SYSTEM compromise remain outside this boundary.

Ancestor owners must be the current user, SYSTEM, Administrators, or Windows TrustedInstaller.
Unrelated accounts cannot have modification, deletion, ownership-change, or ACL-change grants on an effective ancestor entry.
An ancestor can grant directory creation without permitting replacement of an existing protected child.
This accommodates the separate `FILE_ADD_SUBDIRECTORY` grant on ordinary Windows drive roots.
Ordinary ancestor checks ignore inheritance-only entries, because each descendant receives its own effective ACL check.
Final private-directory checks also reject unrelated inheritance-only grants, because library-created metadata files inherit those entries.
Unknown effective ACE types and NULL access lists are rejected.
A conservative ACL check can reject a path whose full effective Windows access rules would be safe.
There is no permission fallback.

A new final state directory receives the current user's explicit owner SID and a protected ACL during creation.
Its inheritable grants permit only that user, SYSTEM, and Administrators.
An existing final state directory must already meet that private-state contract.
It must grant inheritable current-user full control to files and directories without stopping inheritance at the first level.
This prevents library-created children from falling back to the process token's ambient default ACL.
The adapter does not repair existing unsafe permissions.
New files receive an explicit private descriptor instead of depending on their parent's inherited grants.
Ordinary files require the current user's ownership.
An elevated token can also accept Administrators as the file owner, matching Windows' default owner for elevated file creation.
A filtered or ordinary token has no such owner exception.

The maintainer's private-key reader accepts relative paths by converting them to absolute paths before the same secure checks.
It does not resolve symbolic links.
It uses the same handle, parent, owner, type, and hard-link checks.
It additionally rejects read-access grants to unrelated accounts.
Unix key mode and file checks remain unchanged.
These development tests create disposable keys; they do not provision production trust.

## Locks, replacement, and flushing

A nonblocking `LockFileEx` byte-range lock serializes refreshes through the protected lock file.
The handle remains open until unlock.
The native tests verify contention from a separate process and release after that process exits.

An atomic metadata write creates an exclusive private file beside its destination.
It writes and flushes that file before closing it.
It checks an existing destination before `MoveFileExW` with `REPLACE_EXISTING | WRITE_THROUGH`.
The adapter does not enable the cross-volume copy fallback.
A checked parent remains held throughout the operation.
Failure before replacement preserves the previous destination.
The native test holds an existing destination without delete sharing to exercise a genuine failed replacement.

Windows has no documented non-administrator equivalent of Unix directory `fsync`.
The platform state synchronization operation rechecks the private directory and flushes its fixed committed metadata files through write-capable handles.
A flush or permission failure is returned.
No directory-sync error is suppressed.
This does not establish power-loss durability for directory entries, deletions, or changes across multiple files.
The recovery tests exercise process interruption and restart, not hardware power loss.

## Metadata persistence assumptions

The pinned `go-tuf/v2` version is 2.4.2.
Its updater does not expose a replacement storage interface.
Its `persistMetadata` function writes a temporary file, closes it, renames it, and verifies the resulting bytes.
It verifies each role before that persistence step.
The client writes those exact bytes directly into retained private state.
There is no separate working cache whose loss could discard an already persisted root.
The library's rename and role-persistence ordering remain intact.

Before library initialization, the adapter checks every existing fixed role through the secure handle gate.
It rejects reparse points, extra hard links, unsafe owners, and unsafe modification grants before any transport request.
The private directory and all protected ancestors remain held throughout library operations.
New library temporary files inherit the protected directory's private ACL.
Same-account and administrator mutation remain outside this boundary.

The bounded profile permits only `root.json`, `timestamp.json`, `snapshot.json`, and `targets.json` as retained roles.
`MaxDelegations=0` prevents delegated-role traversal and persistence.
No remote pathname becomes a retained role name.
A library upgrade must recheck these persistence calls, fixed names, ACL inheritance, and rename behavior.

The adapter flushes retained files before each subsequent transport request and after `Refresh`, including failed refreshes.
Ordinary process exit after a library role rename retains that role independently of the next transport callback.
The interrupted-root tests cover restart after verified root persistence.
The Windows boundary test observes the actual final root rename rather than causing exit in the next fetch.
The timestamp regression test verifies retained progress when a later snapshot download fails.
These results do not establish recovery after hardware power loss.

Root recovery still commits the verified root before removing obsolete timestamp and snapshot history.
It advances `rotation-root.json` only after both removals and the platform flush complete.
The failed-cleanup test requires timestamp removal, a failed snapshot removal, and successful recovery on the next refresh.
Windows injects that failure with a held snapshot handle; Unix retains its nonempty-directory fixture.

## Native qualification commands

Use Go 1.27.3 and the checked `go.mod` and `go.sum`.
On Windows, use a current-user temporary directory on fixed local NTFS with protected profile ancestors.
The suite changes ACLs only on disposable fixtures.
Junction fixtures use the native reparse API and need no symbolic-link privilege.
The separate symbolic-link fixture skips only when Windows denies that privilege.
The foreign-owner test requires `SeRestorePrivilege` and skips explicitly when the native token lacks it.
It temporarily changes only a disposable file's owner and restores its original owner and privilege state.
Unsupported-filesystem coverage requires additional native volumes; ordinary hosted tests do not establish those cases.

Run the complete Windows suite in PowerShell:

```powershell
cd verifier
$env:GOMAXPROCS = '2'
go test -p=2 -count=1 -timeout=180s -json ./...
```

Run race checks separately where the target Go toolchain supports them:

```powershell
go test -p=2 -race -count=1 -timeout=180s ./...
```

A race build can require a supported C toolchain.
A Windows ARM64 functional result does not imply race-detector availability.
Run the existing `make verifier-test` gate on Linux and macOS.

## RISC-V helper requirements

The local cross-build used Go 1.27.3, `CGO_ENABLED=0`, `GOOS=linux`, `GOARCH=riscv64`, and `GORISCV64=rva20u64`.
The toolchain also reports `rva20u64` when `GORISCV64` is unset.
This profile requires more instructions than the freestanding RV64I/LP64 example.
Go's minimum requirements include RVA20U64 mandatory extensions.
The helper's requirements must be recorded separately from an assembly package's requirements.
A successful static cross-build does not establish RISC-V runtime qualification.

An emulated Linux qualification worker needs QEMU user mode and matching `binfmt_misc` registration.
The interrupted-recovery tests start child copies of the same test executable.
Those children also need transparent RISC-V execution.
Run the cross-built tests explicitly:

```sh
GOMAXPROCS=2 CGO_ENABLED=0 GOOS=linux GOARCH=riscv64 GORISCV64=rva20u64 \
  go test -p=2 -c -o asm-verifier-riscv64.test .
qemu-riscv64 ./asm-verifier-riscv64.test -test.count=1 -test.timeout=180s
```

Record the emulator version, CPU configuration, host kernel, toolchain, source commit, and binary digest with the result.
Label that result as emulation.
Go does not treat QEMU user mode as a supported Linux platform.
Native hardware remains a separate qualification result.

## Primary sources

Reviewed on 5 November 2026:

- [Microsoft: NtCreateFile](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile).
- [Microsoft: GetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo).
- [Microsoft: ACE inheritance](https://learn.microsoft.com/en-us/windows/win32/secauthz/ace-inheritance-rules).
- [Microsoft: file access rights](https://learn.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants).
- [Microsoft: FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers).
- [Microsoft: MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).
- [go-tuf v2.4.2 updater source](https://github.com/theupdateframework/go-tuf/blob/v2.4.2/metadata/updater/updater.go).
- [Go build environment](https://go.dev/doc/install/source#environment).
- [Go minimum requirements](https://go.dev/wiki/MinimumRequirements).
