# Native macOS CLI qualification

Version 0.4.0 provides the independently qualified Apple Silicon macOS CLI.
The checked catalog supplies its native executable and release-workflow provenance.
Intel macOS is unsupported and has no native qualification job.

## Target contract

The target is `aarch64-macos` on Apple Silicon, with a macOS 15 deployment floor.
Its executable format is Mach-O.
Its application binary interface follows Apple's arm64 rules.
Linux x86-64 and ARM64 remain separate implementations and qualification targets.

The CLI remains assembly.
Shared AArch64 command routines call assembly Darwin adapters through libSystem, Apple's system library.
The source preparation tool changes assembler directives and platform constants before assembly.
It does not implement CLI commands or act as a runtime backend.
The native assembly source implements project, package, dependency, publication, and update behavior.

The adapters must preserve the internal register contract and normalize operating-system errors and file metadata.
Apple reserves register x18.
Calls must use aligned stacks and Apple's argument conventions, including variadic functions.
A missing security operation must stop the command.

## Source build

Use an Apple Silicon Mac with macOS 15 or later.
Install Apple's Xcode Command Line Tools before building.
The build also requires Git, Make, and Python 3.11 or later.
Use the revision that contains the macOS implementation.

From its source directory, run:

```sh
make build/asm &&
make test
```

The native build creates `build/asm-aarch64-macos` and copies those bytes to `build/asm`.
The native test command runs `tests/macos` against that executable.
It must exercise a real Mach-O program without a Linux emulator or translated executable.
A passing local test is evidence for its cases and host, not a published support claim.

## Qualification gates

Before declaring macOS support, require these results:

- Native version, help, doctor, new, build, run, test, and clean commands pass.
- Failed builds preserve previous output; literal paths and child exit codes remain correct.
- Registry, archive, dependency, and publication commands pass native success and failure checks.
- The installer selects operating system and architecture together.
- Unavailable targets fail before downloads or installation changes.
- Existing files, symlinks, corrupt bytes, failed downloads, and failed attestations preserve installation state.
- Self-update checks bounded metadata, required identity, exact source commit, size, digest, and Mach-O structure.
- The updater checks the running image and destination identity before atomic replacement.
- The final release bytes pass native tests on macOS 15.

Updates require local APFS with ownership enabled.
All checked installation files and directories must have empty or deny-only ACLs.
An ACL is an access-control list that can grant rights beyond BSD permission bits.
Every ACL allow entry is refused, including harmless owner-only grants.
Normal macOS deny-only home ACLs remain supported.
The canonical sticky temporary directory is `/private/tmp`, with a protected user-owned child.
The `/tmp` symlink is not accepted as an installation-path ancestor.
The [update contract](self-update.md) defines the shared provenance policy and platform-specific installation boundaries.
Neither a test of Linux behavior nor an agent review qualifies the Darwin implementation.

## Catalog compatibility

Released 0.3.0 Linux clients reject unknown target rows before package or update selection.
Adding macOS rows to their existing TSV feed would prevent those clients from selecting an upgrade.
The primary `/registry/v1/index.tsv` feed therefore retains Linux targets.
The macOS CLI uses `/registry/v1/index-macos.tsv`, which also includes the macOS target.
The JSON catalog and website continue to describe all published artifacts.
Each feed retains exact artifact digests and the existing release-provenance policy.
Neither feed has independently signed expiry or rollback protection.

## CI and release evidence

Both workflows add a native `macos-15` job with a read-only repository token.
The aggregate `Test the release contract` check requires Linux x86-64, Linux ARM64, and macOS success.
Keep that aggregate required in the protected pull-request process.
Changing a workflow file does not change branch-protection settings.

The native release builder reads an exact Git commit into two clean source directories.
It builds both executables and requires identical bytes.
It then runs `make test` against the final native bytes and rejects an empty or skipped test suite.
It checks native version output, native target output, and the ad-hoc code signature.
The recorded evidence includes the commit, target, byte size, SHA-256, host, tools, and runtime results.

To prepare this evidence from a committed revision, use:

```sh
python3 tools/release.py --commit HEAD --native-target aarch64-macos --output native-dist
```

The output contains `asm-X.Y.Z-aarch64-macos` and `native-release.json`.
`X.Y.Z` comes from that commit's `cli/commands.json`.
These files are CI inputs, not a published release or catalog update.

Pinned artifact actions transfer the native bytes and evidence within the same workflow run.
The Linux release job checks the source commit, version, target, size, digest, runtime evidence, and Mach-O structure.
It includes the executable only when that commit's `cli/commands.json` declares `aarch64-macos` in `hosts`.
A missing or mismatched native input stops a declared macOS release.
This gate prevents an incomplete port from becoming a download merely because the runner built a file.

The final executable and `release.json` enter the existing release-workflow provenance attestation.
The publication job verifies the published bundle against each final payload before creating the release.
The required workflow, repository identity, source ref, source commit, signer commit, and hosted-runner policy remain fixed.
An existing version tag stops publication.
Never replace published 0.3.0 bytes or add a different executable to its release record.

## Signing boundary

GitHub provenance authenticates the required release workflow and exact artifact bytes.
It does not prove that the program is harmless.
An ad-hoc Mach-O signature permits the native signature check but does not identify the publisher.
Apple Developer ID signing and notarization are separate distribution mechanisms.
No Apple Developer ID signing identity is available on the local qualification host.
The workflow does not claim Developer ID signing or notarization.

Any future signing step must run before final native testing, digest recording, and provenance generation.
Changing a signature changes the executable bytes and requires new evidence.
Do not disable Gatekeeper as an installation step.

## References

Reviewed 2026-11-01:

- [Apple: Writing ARM64 code for Apple platforms](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms).
- [Apple: Signing Mac software with Developer ID](https://developer.apple.com/developer-id/).
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- [GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Darwin constants and structure layouts come from the selected Xcode Command Line Tools SDK headers.
Retain the actual host, SDK, test results, and released digest with qualification evidence.

## Published 0.4.0 evidence

The [release workflow](https://github.com/stubbi/asm/actions/runs/41339727993) qualified and published source commit `1dbe731fbe19d1e6201afd662699382e4983655a`.
The [immutable release](https://github.com/stubbi/asm/releases/tag/v0.4.0) includes the executable, source, checksums, metadata, and provenance bundle.

| Item | Result |
| --- | --- |
| Native release host | arm64, macOS 15.8.2 |
| Toolchain | Apple clang 17.0.0, SDK 15.5, Python 3.15.2 |
| Native tests | 166 passed, zero skipped |
| Clean builds | Two builds produced identical bytes |
| macOS asset | `asm-0.4.0-aarch64-macos`, 245296 bytes |
| SHA-256 | `6b349be8a43daf23d05c1cdae2a50caa38faec85d6ff41a7ed93cbdc5820ba1f` |
| Code signature | Ad-hoc; `codesign --verify --strict` passed |
| Publisher provenance | Downloaded payloads and metadata passed the required workflow, repository ID, source, and signer checks |
| Local application check | The published command created, built, ran, tested, and cleaned a native project on macOS 15.6.1 |

The program printed `Hello from asm!`.
The generated bootstrap also installed the real attested macOS asset into a fresh protected home.
Transport/verifier fixture tests remain distinct from these real release-verification checks.
Developer ID signing and Apple notarization were not run.
