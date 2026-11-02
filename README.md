# ASM

**A home for assembly.**

ASM is a package registry and command-line tool for assembly projects.
Create a project, use packages, and share releases with their source and verification results.

[Website](https://asm.build) · [Quick start](#quick-start) · [Status](#status) · [Why ASM](docs/why-asm.md) · [Security model](docs/specs/security.md)

## A new era for software

Programming languages made software practical for people to write and maintain.
AI opens up a different approach: generate implementations for the machine, and judge them by the experience they deliver.

The priorities are familiar: software that works, responds quickly, and protects its users.
As code becomes cheaper to produce, the cost of running it matters more.
Memory, compute, and energy use affect both the experience and the cost of delivering it.

Assembly gives direct control over instructions, memory layout, and CPU features.
AI could make that control practical for a much wider range of software.
Each implementation still needs a way to reach the people and projects that can use it.

ASM brings assembly into a shared package ecosystem: named packages, explicit machine targets, repeatable builds, and evidence tied to each release.
The goal is to make efficient, dependable software practical to distribute and reuse.

[More on the technical reasoning](docs/why-asm.md).

## Quick start

ASM 0.4.0 supports **Linux x86-64, Linux ARM64, and Apple Silicon with macOS 15 or later**.

### Install the command

Install [GitHub CLI 2.93.0 or later](https://cli.github.com/) before running the installer.

| System | Required tools |
| --- | --- |
| Linux | GitHub CLI at `/usr/bin/gh`, curl, and GNU Coreutils in `/usr/bin`. |
| Apple Silicon macOS | GitHub CLI at `/opt/homebrew/bin/gh`; other tools are supplied by macOS. |

```sh
curl -qfsS -m120 https://asm.build/install.sh | sh
```

Apply the PATH command shown by the installer.
Then check the version:

```sh
asm version
```

On Apple Silicon, the output is `asm 0.4.0 (aarch64-macos)`.

<details>
<summary>Set PATH for this terminal</summary>

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Add this command to your shell configuration to keep the setting.

</details>

[Installer source](https://asm.build/install.sh) · [Installation requirements](docs/self-update.md) · [macOS filesystem and signing requirements](docs/macos.md)

### Run your first project

Install GNU Binutils on Linux, or Xcode Command Line Tools on macOS with `xcode-select --install`.
On Debian or Ubuntu, the `binutils` package supplies the assembler and linker.

Run these commands from the directory that will contain your new project:

```sh
asm doctor &&
asm new hello &&
cd hello &&
asm run &&
asm test
```

The program prints:

```text
Hello from asm!
```

The project contains `asm.toml`, `src/main.s`, and `tests/main.s`.
Assembly source is text; `asm build` assembles and links it into the executable `build/app`.
`asm run` also runs that executable.
`asm test` builds and runs `tests/main.s`; a zero exit code passes the test.

### Update ASM

For an installation made with the installer:

```sh
asm self update
```

For an installation managed by another package manager, use that manager to update ASM.

## Projects and packages

### Describe a project

`asm.toml` names the project, its source file, and its target:

```toml
[package]
name = "hello"
version = "0.1.0"

[build]
source = "src/main.s"
target = "x86_64-linux"
```

`asm new` sets the target for your machine.
Linux ARM64 uses `aarch64-linux`; Apple Silicon macOS uses `aarch64-macos`.

### Find a package

```sh
asm search hello
asm info stubbi/hello
asm versions stubbi/hello
asm fetch stubbi/hello@0.4.0 --target x86_64-linux --kind source
```

This downloads the Linux x86-64 source archive and checks its size and SHA-256 digest.
Use `asm --help` for command options.

### Use a source dependency

This example requires Linux x86-64 and gzip at `/usr/bin/gzip`.
From a project directory:

```sh
asm add stubbi/math@0.4.0 --target x86_64-linux
asm lock
```

Include the library in your source:

```asm
.include "stubbi/math/0.4.0/x86_64-linux/src/min.s"
```

The [complete example](docs/use-a-package.md) calls `asm_u64_min` and explains its calling convention.

Commit `asm.lock` with your project.
`asm sync` restores the recorded dependencies.
`asm build --locked` requires the lock file and checks dependencies before assembly.

### Install a program

On Linux x86-64 or ARM64:

```sh
asm install stubbi/hello@0.4.0
```

This installs the matching executable at `$HOME/.local/bin/hello`.
Use `--output PATH` to choose another destination.
The destination must be a new file.

## Status

ASM is an early alpha.

| Area | Available today |
| --- | --- |
| Native CLI | Linux x86-64, Linux ARM64, and Apple Silicon macOS 15+. |
| Projects | Create, inspect, build, run, test, and clean. |
| Packages | Search, inspect versions, download source, and install executables. |
| Dependencies | Exact versions of direct source dependencies, with a lock file. |
| Registry | Package search, target filters, release records, and verification results. |
| Publication | Source archives and release records submitted through reviewed pull requests. |
| Artifact checks | Metadata, size, SHA-256, archive structure, and executable format. |
| CLI updates | Manual updates with signed release provenance. |

Projects build for the machine running ASM.
Packages can provide separate artifacts for other targets, including RISC-V Linux.

Transitive dependencies, self-service publication, account recovery, isolated public build workers, and hosted formal verification are planned.
The [roadmap](docs/roadmap.md) tracks that work.

## Publish from source

A package release records its source repository, exact Git commit, target, and artifact digests.
`asm publish` checks the release files and prepares a local submission record.
Publication proceeds through a pull request to the registry.

Follow the [publishing guide](registry/README.md) for the commands and submission process.

## Security evidence

Package records distinguish artifact checks, build provenance, formal proofs, and agent reviews.
Each result applies to a particular check and artifact.
Missing results appear as missing.

The [security model](docs/specs/security.md) explains the checks, trust boundaries, and planned verification services.

## Build from source

Install Git, Make, and Python 3.11 or later.
Linux also requires GNU Binutils, curl, GNU Coreutils, and gzip.
Apple Silicon macOS requires Xcode Command Line Tools.

```sh
git clone https://github.com/stubbi/asm.git &&
cd asm &&
make &&
make install PREFIX="$HOME/.local" &&
export PATH="$HOME/.local/bin:$PATH" &&
asm version
```

`make` selects the native implementation for your machine.
The root `asm.toml` describes the Linux x86-64 reference build.
The [ARM64 notes](cli/aarch64/README.md) cover cross-assembly; the [macOS guide](docs/macos.md) covers Apple Silicon builds.

## Contribute

Start with [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).
The [repository layout](CONTRIBUTING.md#repository-layout) explains the source, licenses, experiments, and retained measurements.
Follow the [design guide](design.md), [writing guide](docs/writing.md), and [code of conduct](CODE_OF_CONDUCT.md).

The CLI uses assembly for project and package logic, with system tools for assembly, linking, transport, and cryptographic checks.
Python handles registry operations and release automation; JavaScript supports the website.

On Linux, run `make check` from the repository root.
On macOS, run `make test`.
The [contribution guide](CONTRIBUTING.md) lists test prerequisites, including cross-toolchains.
Include the reason for your change and its validation in the pull request.
Report defects through [GitHub Issues](https://github.com/stubbi/asm/issues).

## License

ASM uses [AGPL-3.0-or-later](LICENSE).
Starter code and reference examples use MIT.
Packages retain the license declared for each version.
See the [license scope](LICENSING.md), or run `asm license`.
