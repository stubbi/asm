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

Our working assumptions come from LeAm:

1. **User experience and total cost matter.** Software must work reliably, respond quickly, and use resources well. Development and maintenance count too.
2. **AI can change the economics of assembly.** We expect more useful implementations for more machines. We will measure the effort required to make them dependable.
3. **Machine control can improve selected workloads.** Instructions, layout, algorithms, and CPU features are all possible sources of improvement.
4. **Portability still needs evidence.** Each target needs a clear interface, suitable tools, tests, and applicable proofs.
5. **Generation requires verification.** People and agents use the same checks. A proof must state its model, assumptions, and connection to the released bytes.
6. **Performance claims must be reproducible.** Publish the workload, baseline, hardware, tools, raw results, and regressions.

These are research assumptions, not established results.
We will revise them when experiments disagree.
ASM must remain useful when a compiler already produces the best implementation for a workload.

The product follows from those assumptions: one workflow for assembly projects, with explicit targets and inspectable evidence.
Read [the full motivation](docs/why-asm.md).

## Quick start

The current CLI runs on **Linux x86-64**.
To build from source, install Git, GNU Make, and GNU Binutils.
On Debian or Ubuntu, the Binutils package supplies `as` and `ld`.

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
```

Add `$HOME/.local/bin` to your `PATH` if your shell does not include it.
The installer refuses to replace a different existing `asm` command.
To replace that command deliberately, add `REPLACE=1`.
`make uninstall` removes the command only when its bytes match this build.

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

## Status

ASM is an early alpha.
The table below describes the implemented release boundary.
[The roadmap](docs/roadmap.md) describes the complete service we intend to build.

| Area | Current implementation |
| --- | --- |
| Native CLI | Linux x86-64 assembly, with direct Linux system calls. |
| Project workflow | Create, inspect, build, run, test, and clean projects. |
| Registry client | Search packages, inspect versions, and fetch checked artifacts. |
| Package identity | Explicit `owner/name` namespaces and exact numeric versions. |
| Target metadata | Separate x86-64, AArch64, and RISC-V Linux artifacts. |
| Registry website | Package search, target filters, versions, artifacts, and evidence states. |
| Download counts | GitHub release-asset counts, with their observation time. |
| Source publication | Commit-bound archives and reviewed registry submissions. |
| Artifact checks | Bounded metadata, size and digest checks, archive inspection, and ELF target checks. |
| Formal verification | Defined evidence model. No hosted proof service yet. |

The native CLI host and a package target are separate concepts.
The x86-64 client can fetch a package for another target.
It can build and run local projects only for its supported host target.

Full dependency resolution, automatic public publication, account recovery, and isolated public build workers remain release gates.
The current service does not claim feature parity with npm, PyPI, or crates.io.

## Publish from source

A release record identifies a public source repository and an exact Git commit.
Each artifact has its own target, kind, size, URL, and digest.
The registry keeps the bytes of a published version immutable.

The initial publication path uses a reviewed pull request.
[The registry specification](docs/specs/registry.md) gives the format and commands.
Python tools prepare and validate registry records.
They are service and release tools, separate from the assembly CLI implementation.

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
