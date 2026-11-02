# Change log

## Unreleased

- Return a nonzero exit status when core command output cannot be written.
- Ignore local Git object replacements when packaging committed source or checking published history.
- Check the aggregate source-byte limit before reading each file.
- Clarify the repository layout, reference manifest, host support, and retained measurement instructions.

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
- License the ASM platform under AGPL-3.0-or-later.
- Keep starter text and reference examples under explicit MIT terms.
- Show license, warranty, and source information with `asm license`.
- Accept AGPL package records in the native CLI and registry validator.
- Preserve and display the license of each package version.
- Include the applicable license notices in release source archives.

ASM 0.1.0 retains its original MIT license.
See the [release notes](docs/releases/0.2.0.md) and [license scope](LICENSING.md).

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
