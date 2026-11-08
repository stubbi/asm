# Contribute to Asm

Read [the project purpose](docs/why-asm.md) and [AGENTS.md](AGENTS.md).
Follow the [code of conduct](CODE_OF_CONDUCT.md) in project spaces.
Use [design.md](design.md) for interface changes.
Use [the writing guide](docs/writing.md) for documentation and messages.
Read [the license scope](README.md#license) before contributing code or other material.
Contributions use the license that applies to the affected files.
Keep required notices and identify the origin of imported material.

## Repository layout

| Path | Purpose |
| --- | --- |
| `cli/` | Native CLI implementations, shared starter text, and platform adapters. |
| `verifier/` | Bundled Sigstore and TUF adapter, maintainer tools, and trust tests. Production activation is gated. |
| `tools/` | Build preparation, registry operations, installation generation, releases, and measurement tools. |
| `tests/` | CLI, registry, release, and site checks, including failure cases. |
| `examples/` | Independently licensed reference packages used by tests and release builds. |
| `registry/packages/` | Retained compatibility records and operator bootstrap imports, including earlier licenses and artifact digests. |
| `server/` | Canonical assembly HTTP runtime and the `server/catalog/` schema and operator contract. |
| `containers/` | Build and qualification recipes for MCP, the server, and the isolated registry operator. |
| `site/` | Static website sources. The site builder generates indexes and the installer. |
| `docs/` | Current guides, specifications, proposals, release notes, and evidence reports. |
| `experiments/` | The [local assembly server experiment](experiments/assembly-server/README.md), its fixture, tests, and recorded limits. |
| `.github/` | Review templates, ownership rules, and checked build and publication workflows. |

The root `asm.toml` defines the Linux x86-64 reference build.
Use `make` for native host selection.
The manifest describes one project with a legacy build or named target implementations.
Project declarations do not establish CLI host support.

The [registry report](docs/performance-registry.md) links to measurements retained at an exact historical commit.
That record includes failed and superseded runs.
Remove completed implementation plans when current specifications cover their decisions and Git retains their history.

## Set up the project

Use Linux x86-64, Linux ARM64, or Apple Silicon macOS 15 or later for native CLI checks.
Install Git, Make, Python 3.11 or later, and Node.js 18 or later.
Standalone website builds also require Node.js for the pinned, vendored Terser minifier.
No npm installation is required.
Linux also needs GNU Binutils, curl, GNU Coreutils, and gzip.
Linux x86-64 release checks need AArch64 and RISC-V GNU cross-binutils and QEMU user emulation.
On macOS, install Xcode Command Line Tools. The OS supplies the other native tools.
Cross-build checks on Apple Silicon also require Homebrew LLVM and LLD.
Clone the repository.
Run `make test` on macOS.
Run `make check` on Linux for the complete cross-target release suite.

The tests use temporary directories.
Registry tests do not need publisher credentials.
Cross-target examples need the corresponding GNU tools and QEMU for local execution.
The release workflow installs those tools from Ubuntu packages.
CI requires Linux x86-64, Linux ARM64, and native macOS qualification before a release.

Verifier changes also require the Go version declared in `verifier/go.mod`.
Run `make verifier-test` for bundled-verifier or trust-publication changes.
The [trust guide](docs/trusted-distribution.md) defines the separate production activation gates.

## Make a change

Use the [feature proposal form](https://github.com/stubbi/asm/issues/new?template=feature.yml) for a substantial behavior change.
Describe the user problem first.
Keep the change focused on that problem.
Add a behavioral test when the change affects a meaningful contract or failure path.
Update the documentation when behavior changes.
Run the relevant checks before you submit a pull request.

Use a short imperative commit subject.
Include a specific scope when it helps the reader.
Explain non-obvious decisions in the commit body.
Do not include build output or local credentials.

## Prepare a package

Follow [the registry specification](docs/specs/registry.md).
Use an exact source commit and an explicit open-source license.
Provide one artifact record for each supported target and artifact kind.
Keep source and executable artifacts distinct.
Do not replace a published version.
Public publication remains unavailable while the [hosted service](docs/hosted-registry.md#publication-boundary) is under qualification.

## Report a defect

Include the Asm version, host target, command, and observed result.
Give the smallest example that reproduces the defect.
Remove secrets and private data from logs.
Use [GitHub Issues](https://github.com/stubbi/asm/issues) for ordinary defects.
Read [SECURITY.md](SECURITY.md) for a vulnerability report.

## Review a pull request

Apply the minimalism and complete-history review requirements in [AGENTS.md](AGENTS.md).
Check the result through the public interface.
Check the failure paths and file effects.
Compare claims with the current source and evidence.
Review a specification change separately from a proof or implementation that depends on it.
Do not approve a weaker check merely because it passes.
Use the [maintenance guide](docs/maintaining.md) for repository controls, releases, and incident recovery.
