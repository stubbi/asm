# Contribute to ASM

Read [the project purpose](docs/why-asm.md) and [AGENTS.md](AGENTS.md).
Follow the [code of conduct](CODE_OF_CONDUCT.md) in project spaces.
Use [design.md](design.md) for interface changes.
Use [the writing guide](docs/writing.md) for documentation and messages.
Read [the license scope](LICENSING.md) before contributing code or other material.
Contributions use the license that applies to the affected files.
Keep required notices and identify the origin of imported material.

## Set up the project

Use Linux x86-64 or ARM64 for the native CLI checks.
Install Git, GNU Make, GNU Binutils, Python 3.11 or later, and Node.js 18 or later.
Also install curl, GNU Coreutils, and gzip.
On x86-64, install AArch64 and RISC-V GNU cross-binutils and QEMU user emulation for release checks.
Clone the repository.
Run `make check`.

The tests use temporary directories.
Registry tests do not need publisher credentials.
Cross-target examples need the corresponding GNU tools and QEMU for local execution.
The release workflow installs those tools from Ubuntu packages.
CI checks both native CLI hosts before it permits a release.

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

## Submit a package

Follow [the registry specification](docs/specs/registry.md).
Use an exact source commit and an explicit open-source license.
Provide one artifact record for each supported target and artifact kind.
Keep source and executable artifacts distinct.
Do not replace a published version.

## Report a defect

Include the ASM version, host target, command, and observed result.
Give the smallest example that reproduces the defect.
Remove secrets and private data from logs.
Use [GitHub Issues](https://github.com/stubbi/asm/issues) for ordinary defects.
Read [SECURITY.md](SECURITY.md) for a vulnerability report.

## Review a pull request

Check the result through the public interface.
Check the failure paths and file effects.
Compare claims with the current source and evidence.
Review a specification change separately from a proof or implementation that depends on it.
Do not approve a weaker check merely because it passes.
Use the [maintenance guide](docs/maintaining.md) for repository controls, releases, and incident recovery.
