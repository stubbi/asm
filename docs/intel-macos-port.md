# Intel macOS CLI port

Status: the original native Intel qualification passed. The integrated candidate requires a fresh native result.
No Intel release is declared.

The user outcome is the current CLI workflow on an Intel Mac, including package management and native library linking.
The foundation requires dependable reuse and independent evidence for each target.
This port retains assembly package logic and the existing transport and cryptography boundary.

The target is `x86_64-macos`, macOS 15+, Mach-O, Apple System V AMD64 LP64.
The implementation uses baseline x86-64 instructions, without an additional AVX or CPU extension requirement.
Darwin libSystem adapters preserve the shared Linux-shaped internal syscall and file-metadata contract.
They align every external call and implement the native argument and error conventions.
Build-time Python prepares assembler syntax and platform constants; it is not a runtime command backend.

Implementation steps:

1. Add an observable x86-64 build and first-project test; retain its initial failure.
2. Add source preparation and assembly Darwin adapters, with checked SDK layouts and error normalization.
3. Add bounded Mach-O validation, publication dispatch, installed-program and safe-update qualification.
4. Reuse the shared command tests with target-correct fixtures, including native library builds and failure preservation.
5. Add native Intel CI qualification and exact-source, exact-artifact evidence. Keep Rosetta results explicitly separate.
6. Supply the implementation commit and integration contract to the release workstream through normal progress.

Review focus includes ACL allow entries, ownership-disabled APFS, displaced running images, wrong-CPU executables,
descriptor-relative operations, untrusted digest environments, failed children, and inventory alias protection.
Existing immutable releases and declared host metadata remain unchanged until their owning release gates pass.

Shared release, bootstrap, feed, and host-declaration integration belongs to the distribution session.
This branch supplies `tools/macos_x86_64.py`, `cli/macos/x86_64/`, target tests, and a standalone build entry point.
Native Intel CI must test the actual final x86-64 bytes; assembling or running under Rosetta alone is insufficient.

Platform references, checked 5 November 2026:

- [Apple Intel ABI](https://developer.apple.com/documentation/xcode/writing-64-bit-intel-code-for-apple-platforms).
- [GitHub hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), including `macos-15-intel`.
- The selected Xcode Command Line Tools SDK headers, asserted by the target ABI tests.

Developer ID signing and notarization remain unavailable. Ad-hoc signatures and publisher provenance have separate meanings.

Evidence and failed attempts will be recorded after execution, with source and artifact digests.

## Build and qualification commands

Install Apple's Command Line Tools, Make, Git, and Python 3.11+.
The source entry point is separate until distribution integration is complete.

```sh
make -f cli/macos/x86_64/Makefile all
make -f cli/macos/x86_64/Makefile test
```

The second command atomically selects the Intel test executable as `build/asm`.
Do not run another architecture's suite against that alias concurrently.
A plain source build uses fixed `/usr/local/bin/gh` for the existing manual-update provenance protocol.
A release must supply the Intel bootstrap/verifier mapping through the distribution workstream.

Native qualification materializes two clean snapshots from one committed revision:

```sh
python3 tools/qualify_macos_x86_64.py --commit HEAD --output native-intel
```

This command rejects translated execution by default.
`--allow-rosetta` records translated evidence and cannot label it native.
It retains command output, tests, byte size, digest, source revision, ABI, OS minimum, and tool versions.
The final tests run against the compared bytes, without resigning afterward.
A failed or empty suite, skipped case, expected failure, or changed artifact stops qualification.
The shared Git reader disables replacement objects and reads original blobs and executable modes.
Local archive attributes cannot substitute or omit qualification inputs.

## Retained local evidence

The [5 November record](intel-macos-evidence.json) binds the frozen production inputs to the tested Intel bytes.
The local macOS 15.6.1 host executed this x86-64 Mach-O through Rosetta.
All 175 Intel cases passed, without skips or increased deadlines.
The 42 registry tests passed.
The native Apple Silicon regression suite passed 223 cases, without skips.
That result remains separate from Intel qualification.

The tested Intel file has 157680 bytes.
Its SHA-256 is `b016e68208330a7cc2165b0ef9f41026b0e5771295bf1b07726d97ab82d4578c`.
These are unpublished source-port bytes, with an ad-hoc signature.
They do not extend the immutable published 0.5.0 release.
A new release and final distribution qualification are still required.

The shared native-link inputs originate from committed snapshot `997a9ab`.
The newer 0.5.0 installed-program alias protection remains in place.
Review found and fixed compiler response-file interpretation and a 64-bit result truncation defect.
Build source and checker paths reject components that start with `@` before invoking tools.
A Clang `./` prefix alone was insufficient because cc1 also receives the source basename.
The regressions retain separate unprefixed response files so they exercise the original failure.

Native Intel CI, final installer integration, release provenance, Developer ID, and notarization have distinct gates.
The records retain each result and its exact source; distribution gates remain unrun.


## Native Intel result

[Native Intel qualification](https://github.com/stubbi/asm/actions/runs/41940484143) passed on 5 November 2026.
The [native record](intel-macos-native-evidence.json) binds the result to source `cea61bdfc8f87555f93d2e00bde15063f3df680b`.
The runner used x86-64 macOS 15.7.9 without Rosetta, Apple clang 17, and SDK 15.5.
All 175 cases passed without skips or expected failures.
Two clean builds produced identical bytes, and final-byte code-signature and identity checks passed.

The qualified file has 157712 bytes.
Its SHA-256 is `919aedbead9a56e78dfdfe06198408e7fbf9bc5262f3545d8d4bea24d4acaea2`.
The downloaded CI artifact retained that digest and passed the local strict signature check.
It remains an unpublished port artifact, with an ad-hoc signature.

The first native run passed 174 of 175 cases and retained its failure record.
The failed case exposed assembler startup inheriting an invalid `SDKROOT`.
All fixed assembler, linker, and compiler children now receive only the fixed PATH and locale.
Executed user applications continue to inherit their environment.
The same unchanged hostile-environment test passed in the final native run.

One follow-up commit message incorrectly described a Rosetta retry as passing.
The retry also timed out; the local evidence record contains the correction.
Native execution and translated execution remain distinct records.

## Integration with selected-target projects

The integration preserves main `bc5bfbe`, including seven project declarations, separate target outputs, and v2 dependency locks.
Native host substitutions leave Linux recipe names and compiler triples unchanged.
The source entry point builds native Intel macOS projects and three standalone Linux targets.
Install Homebrew LLVM and LLD for Linux cross builds:

```sh
brew install llvm lld
```

The Intel adapter uses `/usr/local/opt/llvm/bin/clang` and `/usr/local/opt/lld/bin/ld.lld`.
It passes explicit triples, ELF linker emulations, bounded arguments, and the existing fixed compiler environment.
Foreign execution and cross-target native-library linking remain refused before output changes.
The native suite now includes the shared selected-target and v2-lock cases, plus both unified reference projects.
Qualification requires at least 206 cases, without skips or expected failures.
The standalone workflow installs the required cross tools and retains exact-source build and runtime records.

The first local integration suite ran through Rosetta: 205 cases, 15 failures, two errors, and one skip.
Missed native update suffixes and an outdated unsupported-Intel publication assertion caused the functional failures.
The absent Intel Homebrew cross tools caused the skip.
Targeted update and publication cases passed after the corrections.
An earlier two-case probe also retained a 15-second build timeout and the obsolete target-list assertion failure.
The unified-reference probe exposed a missing Intel hello test entry and an incorrect math output expectation.
The hello project now declares a native startup smoke test; the existing math output remains unchanged.
A proposed archive fixture failed during setup because portable archive paths already reject `@`.
That invalid fixture was removed; main's archive validation remains unchanged.
Native manifest source and checker paths retain their response-file guards.

The integration review covered the complete available main history from `93487e3` through `bc5bfbe`.
It retained immutable catalog records, version-specific licenses, source-bound dependencies, hosted catalog contracts, and prior security checks.
Independent agent review found no blocking integration defect.
Its fixture-fidelity advisory restored native ARM64 Linux entry-source fixtures; final qualification counts include the added suffix test.
Agent review remains advisory.

This source PR has no merge dependency on distribution PR #29.
Root Makefile selection, admitted registry targets, compatible feeds, installer/verifier mapping, and release fan-in remain distribution work.
Published clients' legacy macOS feed must exclude unknown Intel rows.
After 0.6.0 is published, Intel release activation requires a new version and fresh exact-byte release evidence.
The coordinator owns merging; distribution owners own activation and signed publication.

The distribution review found the original qualifier used unrestricted `git archive`.
Git replacement objects or local export attributes could change the input without changing its recorded commit.
The qualifier now uses the existing guarded Git reader and shared materializer for both snapshots.
Seven real-repository regressions cover commit, tree, and blob replacements, both export attributes, modes, and missing commits.
All seven passed; all five substitution cases rejected the earlier archive-based extraction in an isolated mutation check.
The registry suite then passed 76 cases.
The earlier 89cdfb1 workflow remains an intermediate result; final qualification must use the corrected source reader.
