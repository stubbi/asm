# Change log

## 0.6.0

- Consolidate hello and math into one project each, with seven target subdirectories and one manifest.
- Add selected-target standalone Linux builds, isolated outputs, and test builds without execution.
- Add target-specific exact dependencies in v2 locks while retaining v1 compatibility.
- Validate every project recipe and lock row before changing artifacts or dependency state.
- Reject response-file source and checker paths before invoking build tools.
- Link assembly projects against named native libraries with optional compile-only ABI checks.
- Preserve native manifest syntax, v1 locks, legacy archive limits, and earlier published release bytes.

See the [release notes](docs/releases/0.6.0.md) and [multi-target project contract](docs/multi-target-projects.md).

## Website dependency display

- Show direct dependency declarations, requirements, and feature options for each checked source target and version.
- Link available package records and distinguish unavailable metadata from checked empty declarations.
- Preserve published artifact bytes, release records, and existing JSON and native registry feeds.

## 0.5.0

- Record executable installations, including explicit output paths, in a bounded local inventory.
- Add `asm installed`, `asm upgrade`, and `asm uninstall` on all three supported CLI hosts.
- Check case and Unicode path aliases with the destination filesystem before installation.
- Reject inventory records that claim the same installed file before upgrade or uninstall.
- Retain the recorded destination and registry origin during upgrades; reject downgrades and changed bytes for an equal version.
- Refuse changed or unmanaged files and preserve prior files after ordinary commit failures.
- Keep `update` and `remove` for source dependencies; retain unmanaged installations without automatic adoption.
- Add a disabled bundled-verifier profile for signed update authorization and release provenance.
- Keep production activation gated on offline keys, metadata renewal, review, and recovery qualification.
- Return a nonzero exit status when core command output cannot be written.
- Ignore local Git object replacements when packaging committed source or checking published history.
- Check the aggregate source-byte limit before reading each file.
- Clarify the repository layout, reference manifest, host support, and retained measurement instructions.

Published 0.4.0 artifacts remain unchanged and do not include installed-program management.
See the [release notes](docs/releases/0.5.0.md) and [installed-program contract](docs/installed-programs.md).

## 0.4.0

- Add an Apple Silicon macOS 15 CLI using native assembly, Mach-O, and libSystem adapters.
- Qualify project, registry, archive, dependency, publication, installer, and updater behavior on native macOS.
- Select release artifacts by operating system and ISA; use macOS tools without GNU Coreutils.
- Bind updates to the running executable vnode, protected APFS paths, ACL policy, and signed release provenance.
- Preserve the Linux feed for released clients and add a macOS-compatible feed.
- Require native final-byte qualification and exact-commit artifact transfer before release provenance signing.
- Keep Intel macOS unsupported. Developer ID signing and notarization are not provided.

See the [release notes](docs/releases/0.4.0.md) and [qualification contract](docs/macos.md).

## 0.3.0

- Add a native ARM64 Linux CLI with the same command and verification contracts.
- Select a published x86-64 or ARM64 executable with one bootstrap command.
- Keep unsupported hosts and wrong-architecture artifacts out of the installation path.
- Build separate architecture artifacts and compare two clean builds for each release executable.
- Require the CLI contract suite on native x86-64 and ARM64 CI runners.
- Replace quadratic catalog identity checks with bounded heap sort.
- Buffer registry output and return failure when the output cannot be written.
- Publish the x86-64 benchmark inputs, raw measurements, regressions, and reproduction steps.

See the [release notes](docs/releases/0.3.0.md) and [performance record](docs/performance-registry.md).

## 0.2.0

- Install the CLI with a bounded bootstrap script and signed release verification.
- Update the installed command with native `asm self update`.
- Bind each CLI update to the fixed workflow, repository identity, source commit, and artifact digest.
- Preserve the installed command on download, signature, permission, or replacement failure.
- License the Asm platform under AGPL-3.0-or-later.
- Keep starter text and reference examples under explicit MIT terms.
- Show license, warranty, and source information with `asm license`.
- Accept AGPL package records in the native CLI and registry validator.
- Preserve and display the license of each package version.
- Include the applicable license notices in release source archives.

Asm 0.1.0 retains its original MIT license.
See the [release notes](docs/releases/0.2.0.md) and [license scope](README.md#license).

## 0.1.0

The first alpha establishes the project workflow, curated registry, and assembly CLI.

- Create, build, run, test, and clean Linux x86-64 assembly projects.
- Search packages, inspect versions, fetch artifacts, and install checked host executables.
- Add, update, remove, verify, and restore exact direct source dependencies.
- Prepare publication records from actual source archives and executable bytes.
- Serve package metadata, source references, check states, and observed download counts.
- Build deterministic release artifacts from an exact source commit.
- Supply hello examples for x86-64, AArch64, and RISC-V, plus a source library example.

See the [release notes](docs/releases/0.1.0.md) for the support boundary and remaining work.
