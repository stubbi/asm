# asm

**A home for assembly.**

Asm is the package registry and command-line tool for assembly projects.
Create and test projects, inspect packages, and download exact artifacts.

[Website](https://asm.build) · [Quick start](#quick-start) · [Status](#status) · [Why Asm](docs/why-asm.md) · [Security model](docs/specs/security.md) · [Sponsor Asm](https://asm.build/sponsors.html)

Packages declare their targets and connect release records to exact source and artifact digests.
The [project purpose](docs/why-asm.md) explains our technical assumptions about AI-assisted assembly.

## Quick start

Asm 0.6.0 supports **Linux x86-64, Linux ARM64, and Apple Silicon with macOS 15 or later**.

### Install the command

Install [GitHub CLI 2.93.0 or later](https://cli.github.com/) before running the installer.
The installer uses it to check the CLI release's signed build provenance.

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

On Apple Silicon, the output is `asm 0.6.0 (aarch64-macos)`.

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
asm new hello &&
cd hello &&
asm run
```

The program prints:

```text
Hello from asm!
```

The project contains `asm.toml`, `src/main.s`, and `tests/main.s`.
Assembly source is text; `asm build` assembles and links it into the executable `build/app`.
`asm run` also runs that executable.
`asm test` builds and runs `tests/main.s`; a zero exit code passes the test.
If a build fails, use `asm doctor` to check the required tools.

### Update Asm

For an installation made with the installer:

```sh
asm self update
```

For an installation managed by another package manager, use that manager to update Asm.

## Projects and packages

### Describe a project

`asm.toml` names the project and declares its target implementations:

```toml
[package]
name = "hello"
version = "0.1.0"

[target.x86_64-linux]
source = "targets/x86_64-linux/src/main.s"
test = "targets/x86_64-linux/tests/main.s"

[target.aarch64-macos]
source = "targets/aarch64-macos/src/main.s"
test = "targets/aarch64-macos/tests/main.s"
```

Each target has its own source, test, and optional native-library fields.
The [hello](examples/hello/README.md) and [math](examples/math/README.md) projects keep these inputs under `targets/<id>/`.
Asm selects the host target by default.
For cross builds, install the tools listed in the [multi-target project contract](docs/multi-target-projects.md).
From either reference project, `asm build --target riscv64-linux` builds a separate Linux artifact.
`asm test --target riscv64-linux --no-run` builds its test without executing it.
Target-specific dependency selections share one v2 lock.

`asm new` creates a single-target `[build]` manifest for your host.
This form remains supported.

### Find a package

```sh
asm search hello
asm info stubbi/hello
asm versions stubbi/hello
asm fetch stubbi/hello@0.6.0 --target x86_64-linux --kind source
```

This downloads the Linux x86-64 source archive and checks its size and SHA-256 digest.
Use `asm --help` for command options.

### Use a source dependency

This example requires Linux x86-64 and gzip at `/usr/bin/gzip`.
From a project directory:

```sh
asm add stubbi/math@0.6.0 --target x86_64-linux
asm lock
```

Include the library in your source:

```asm
.include "stubbi/math/0.6.0/x86_64-linux/targets/x86_64-linux/src/min.s"
```

The [complete example](docs/use-a-package.md) calls `asm_u64_min` and explains its calling convention.

Commit `asm.lock` with your project.
`asm sync` restores the recorded dependencies.
`asm build --locked` requires the lock file and checks dependencies before assembly.

### Install a program

Program management works on all three CLI hosts.
A package must provide a matching executable.
For `hello` 0.6.0, use Linux x86-64 or ARM64:

```sh
asm install stubbi/hello@0.6.0
```

This installs the matching executable at `$HOME/.local/bin/hello`.
Use `--output PATH` to choose another destination.
The destination must be a new file.
Asm records both default and custom destinations in its local inventory.
One package identity has at most one managed installation.

Inspect and manage recorded programs:

```sh
asm installed
asm upgrade stubbi/hello
asm uninstall stubbi/hello
```

`upgrade` selects the highest available host version from the recorded registry.
Use `owner/name@version` to select an exact version.
`update` and `remove` continue to manage project source dependencies.

Updating Asm does not adopt earlier installations; programs without an inventory record remain unmanaged.
See the [installed-program contract](docs/installed-programs.md) for file checks, recovery, and limits.

## Status

The current published version is [Asm 0.6.0](https://github.com/stubbi/asm/releases/tag/v0.6.0).

| Area | Available today |
| --- | --- |
| Native CLI | Linux x86-64, Linux ARM64, and Apple Silicon macOS 15+. |
| Projects | Create, inspect, build, run, test, and clean; select native or standalone Linux implementations. |
| Packages | Search, inspect versions, download artifacts, install executables, list installations, upgrade, and uninstall. |
| Dependencies | Exact direct source dependencies, with target-specific selections in a shared lock file. |
| Registry | Package search, target filters, release records, and verification results. |
| Publication | Local record preparation; hosted publication remains under qualification. |
| Artifact checks | Metadata, size, SHA-256, archive structure, and executable format. |
| CLI updates | Manual updates with signed release provenance. |

Asm 0.6.0 adds named target implementations, standalone Linux cross builds, and target-specific dependency locks.
The [release notes](docs/releases/0.6.0.md) describe the commands, artifact scope, and limits.

Projects select the native host by default.
Explicit standalone Linux builds produce separate artifacts without executing them.
Cross-target native-library linking remains unsupported.
Packages can provide separate artifacts for other targets, including RISC-V Linux.

Transitive dependencies, self-service publication, account recovery, isolated public build workers, and hosted formal verification are planned.
The [roadmap](docs/roadmap.md) tracks that work.

## Prepare a release record

A package release records its source repository, exact Git commit, target, and artifact digests.
`asm publish` checks the release files and prepares a local release record.
It makes no network request and publishes nothing.
The hosted operator can import accepted catalog snapshots.
Public publisher authentication and hosted deployment remain unqualified.

Use the [packaging and compatibility guide](registry/README.md) to prepare artifacts and records.
The [hosted publication boundary](docs/hosted-registry.md#publication-boundary) states the remaining requirements.

## Build with an AI

The [Asm development skill](skills/asm-build/SKILL.md) guides requirements, target selection, package reuse, tests, and bounded performance work.
The [MCP setup guide](docs/agents.md) connects AI clients to read-only discovery, planning, and measurement-comparison tools.
The AI uses its authorized workspace tools to build and execute software.

Hosted registry and MCP deployment remain under qualification.
The [hosted registry contract](docs/hosted-registry.md) records the implementation scope and remaining recovery, security, and runtime gates.

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
It runs the assembler and linker to create the executable.
It also provides test and installation commands.
The root `asm.toml` describes the Linux x86-64 reference build.
The [CLI source guide](cli/README.md) explains the layout and installation helper.
The [ARM64 notes](cli/aarch64/README.md) cover cross-assembly; the [macOS guide](docs/macos.md) covers Apple Silicon builds.

## Support Asm

Help fund maintainer time, registry operations, security work, and documentation.
The [sponsorship page](https://asm.build/sponsors.html) lists company and individual options, recognition, and terms.
Sponsorships are arranged by email.
Confirm availability and payment details before you pay.

## Contribute

Start with [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).
The [repository layout](CONTRIBUTING.md#repository-layout) explains the source, licenses, experiments, and retained measurements.
Follow the [design guide](design.md), [writing guide](docs/writing.md), and [code of conduct](CODE_OF_CONDUCT.md).

The CLI uses assembly for project and package logic, with system tools for assembly, linking, transport, and cryptographic checks.
Python handles registry operations, release automation, and the separate MCP protocol adapter; JavaScript supports the website.
The hosted registry runtime foundation uses assembly with mature protocol and database libraries.
The [bundled-verifier migration](docs/trusted-distribution.md) uses Go for the Sigstore and TUF adapter.

On Linux, run `make check` from the repository root.
On macOS, run `make test`.
The [contribution guide](CONTRIBUTING.md) lists test prerequisites, including cross-toolchains.
Include the reason for your change and its validation in the pull request.
Report defects through [GitHub Issues](https://github.com/stubbi/asm/issues).

## License

Copyright (c) 2026 ASM contributors.

Unless a file has a separate notice, Asm uses [AGPL-3.0-or-later](LICENSE).
You can use version 3 or a later version published by the Free Software Foundation.
Asm is provided without warranty.

| Material | License |
| --- | --- |
| CLI, registry tools, website, tests, and project documentation | AGPL-3.0-or-later |
| `cli/templates.s`, `cli/aarch64/templates.s`, and their emitted starter text | MIT |
| Reference packages under `examples/` | Each package's included MIT license |
| Independently published packages | The license declared by that package version |
| Earlier published versions | The license included with that version |

Starter assembly files contain the complete MIT notice.
The same notice remains in [examples/hello/LICENSE](examples/hello/LICENSE) and [examples/math/LICENSE](examples/math/LICENSE).
It covers the identified MIT material and preserves the notice for material originally distributed in Asm 0.1.0.

Running Asm does not assign its license to a separate program.
Copied or linked package code has its own license conditions.
Contributions use the license that applies to the affected material.
Keep required copyright and permission notices.

Asm 0.1.0 was published under MIT.
Asm 0.2.0 introduced AGPL-3.0-or-later for the platform.
Earlier releases retain their original bytes and licenses.
Run `asm license` for the identifier, source location, and warranty notice.
