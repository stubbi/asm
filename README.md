# ASM

**A home for assembly.**

ASM is a package registry and command-line tool for assembly projects.
Build a project. Find a package. Check its target, source, and release evidence.
The CLI itself is written in assembly.

[Website](https://asm.build) · [Quick start](#quick-start) · [Status](#status) · [Why ASM](docs/why-asm.md) · [Security model](docs/specs/security.md)

## Why we are building this

We expect AI to make useful assembly cheaper to write and maintain.
If that happens, assembly needs an ecosystem that makes the results easy to use.
Every project should not need to invent its own package format, target selection, and release checks.

Our working assumptions:

1. **User experience and total cost matter.** Software must work reliably, respond quickly, and use resources well. Development and maintenance count too.
2. **AI can change the economics of assembly.** We expect more useful implementations for more machines. We will measure the effort required to make them dependable.
3. **Machine control can improve selected workloads.** Instructions, layout, algorithms, and CPU features are all possible sources of improvement.
4. **Cheaper generation may make more targets practical.** We will measure the cost of specifications, tools, proofs, integration, and maintenance.
5. **Generation requires verification.** People and agents use the same checks. A proof must state its model, assumptions, and connection to the released bytes.
6. **Performance claims must be reproducible.** Publish the workload, baseline, hardware, tools, raw results, and regressions.

These are research assumptions, not established results.
We will revise them when experiments disagree.
ASM must remain useful when a compiler already produces the best implementation for a workload.

The product follows from those assumptions: one workflow for assembly projects, with explicit targets and inspectable evidence.
Read [the full motivation](docs/why-asm.md).

### An early measured example

Our [asmwc experiment](docs/evidence.md) compares complete assembly and Rust implementations of a word counter.
On one Apple M3, default counting took 15.234 ms in assembly and 68.468 ms in Rust.
Those are warm-cache medians for a 128 MiB text file, with 24 samples per implementation.
The comparison includes differences in algorithms, input scheduling, and startup.

We checked the published record digests and recomputed the selected medians.
We did not reproduce the macOS experiment during the ASM build.
The [evidence record](docs/evidence.md) includes the baseline, raw samples, slower cases, and limits.
ASM needs to make this kind of evidence available beside the exact target artifact.

## Quick start

The current CLI runs on **Linux x86-64**.
To build from source, install Git, GNU Make, and GNU Binutils.
On Debian or Ubuntu, the Binutils package supplies `as` and `ld`.
Registry commands also use curl and SHA-256 from GNU Coreutils.
Source dependencies use gzip.
`asm doctor` checks the tools that the CLI needs.

```sh
git clone https://github.com/stubbi/asm.git
cd asm
make
./build/asm doctor
./build/asm new hello
cd hello
../build/asm run
../build/asm test
```

The program prints:

```text
Hello from asm!
```

Your project contains an `asm.toml` manifest, `src/main.s`, and `tests/main.s`.
`asm run` builds the project before it runs the program.
`asm test` builds and runs the test program.
A test succeeds when it exits with code zero.

The [hello example](examples/hello) shows the complete project.
Read [the CLI source](cli/asm.s) to follow the implementation.
The [registry module](cli/registry.s) contains the native registry client.

### Install the command

From the ASM repository, run:

```sh
make install PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
asm version
```

The `export` command applies to the current shell.
Add it to your shell configuration to keep this setting.
The installer refuses to replace a different existing `asm` command.
To replace that command deliberately, add `REPLACE=1`.
`make uninstall PREFIX="$HOME/.local"` removes the command only when its bytes match this build.

[Release downloads](https://github.com/stubbi/asm/releases) include the native binary, source archives, checksums, and build metadata.
Check the supported target and the checksum before you run a downloaded file.

### Describe a project

```toml
[package]
name = "hello"
version = "0.1.0"

[build]
source = "src/main.s"
target = "x86_64-linux"
```

The initial manifest format accepts these four string fields.
It rejects unknown fields, duplicate fields, invalid paths, and unsupported build targets.
It does not accept arbitrary build scripts.
The build uses GNU assembler syntax and writes the program to `build/app`.

### Find a package

```sh
asm search hello
asm info stubbi/hello
asm versions stubbi/hello
asm fetch stubbi/hello@0.1.0 --target x86_64-linux --kind source
```

The client checks the downloaded size and SHA-256 digest.
It refuses to overwrite an existing destination.
Fetch does not extract or execute the artifact.
Use `asm --help` for the current command syntax.

### Use a source dependency

From a project directory, add an exact version:

```sh
asm add stubbi/math@0.1.0 --target x86_64-linux
asm lock
```

ASM records the selection in `asm.lock`.
It checks and extracts the source under `.asm/packages`.
The build makes that directory available to the assembler.
Include the library explicitly in your source:

```asm
.include "stubbi/math/0.1.0/x86_64-linux/src/min.s"
```

Follow [the complete package example](docs/use-a-package.md) for a program that calls the function.

The library exports `asm_u64_min`.
Its [contract and tests](examples/math) describe the arguments, result, and register changes.

Commit `asm.lock` with your project.
Use `asm sync` to restore its exact source artifacts on another machine.
Use `asm build --locked` when a missing lock file must be an error.
Builds check existing locked dependencies before assembly.

`asm update owner/name@X.Y.Z` selects an explicit replacement version.
`asm remove owner/name` removes a selection and retains cached files.
Version ranges and transitive dependencies are future work.
A lock file checks declared packages; it does not sandbox other assembler inputs.

### Install a program

```sh
asm install stubbi/hello@0.1.0
```

ASM selects a host executable and checks its size, digest, and ELF structure.
It installs to `$HOME/.local/bin/hello` without running the program.
An existing destination causes an error.
Use `--output PATH` to choose another new file.

## Status

ASM is an early alpha.
The table below describes the implemented release boundary.
[The roadmap](docs/roadmap.md) describes the complete service we intend to build.

| Area | Current implementation |
| --- | --- |
| Native CLI | Linux x86-64 assembly, with direct Linux system calls. |
| Project workflow | Create, inspect, build, run, test, and clean projects. |
| Registry client | Search packages, inspect versions, fetch artifacts, and install checked host executables. |
| Dependencies | Add, update, remove, check, and restore exact direct source dependencies. |
| Package identity | Explicit `owner/name` namespaces and exact numeric versions. |
| Target metadata | Separate x86-64, AArch64, and RISC-V Linux artifacts. |
| Registry website | Package search, target filters, versions, artifacts, and evidence states. |
| Download counts | GitHub release-asset counts, with their observation time. |
| Source publication | Commit-bound archives, native submission preparation, and reviewed registry records. |
| Artifact checks | Bounded metadata, size and digest checks, archive inspection, and ELF target checks. |
| Formal verification | Defined evidence model. No hosted proof service yet. |

The native CLI host and a package target are separate concepts.
The x86-64 client can fetch a package for another target.
It can build and run local projects only for its supported host target.

Transitive dependency resolution, automatic public publication, account recovery, and isolated public build workers remain release gates.
The current service does not claim feature parity with npm, PyPI, or crates.io.

## Publish from source

A release record identifies a public source repository and an exact Git commit.
Each artifact has its own target, kind, size, URL, and digest.
A published version fixes its artifact digests.
Clients reject different bytes.

The initial publication path uses a reviewed pull request.
[The registry specification](docs/specs/registry.md) gives the format and commands.
`asm publish` validates actual artifact bytes and writes a local submission record.
It does not upload files or reserve a package name.
Follow the [publishing guide](registry/README.md) to prepare archives and submit the record.

The CLI's project, registry, dependency, archive, and publication logic is assembly.
It uses mature system tools for assembly, linking, HTTPS, SHA-256, and gzip.
Python handles registry operations and release automation.
JavaScript supports the website.

## Security evidence

Useful security evidence answers a specific question.
ASM records metadata checks, artifact checks, provenance, formal proofs, and agent review separately.
A missing result stays visible as missing.

Lean and Kraken can support proofs for suitable assembly routines.
A proof must identify the theorem, instruction model, toolchain, assumptions, and artifact it covers.
The public service also needs isolated workers and trusted verification rules.

Agents can propose implementations, tests, proof candidates, and reviews.
They cannot grant a release a security status by opinion.
Read [the security design](docs/specs/security.md) for the required gates and current limits.

## Contribute

Read [AGENTS.md](AGENTS.md), [design.md](design.md), and [the writing guide](docs/writing.md).
The same contribution rules apply to people and agents.
Follow the [code of conduct](CODE_OF_CONDUCT.md) in project discussions.
The [maintenance guide](docs/maintaining.md) defines review, release, and incident procedures.

To run all local checks, install Python 3.11 or later and Node.js 18 or later.
Then run:

```sh
make check
```

Tests cover user-visible behavior and rejection paths.
Keep each commit focused.
Include the reason for the change and the relevant validation in your pull request.
Report a defect through [GitHub Issues](https://github.com/stubbi/asm/issues).

## License

ASM uses the [MIT license](LICENSE).
Packages in the registry retain their own declared licenses.
