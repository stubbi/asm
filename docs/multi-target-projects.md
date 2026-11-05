# Multi-target projects

Status: unreleased source-checkout capability.
Published Asm 0.5.0 binaries do not support this extension.

## One project and explicit implementations

Keep the project identity, manifest, README, and license at the project root.
Keep platform inputs together in target subdirectories.
The reference hello and math projects use this layout:

```text
asm.toml
README.md
LICENSE
targets/
  x86_64-linux/
    src/main.s
    tests/main.s
  aarch64-macos/
    src/main.s
    tests/main.s
```

Both reference projects also contain AArch64 Linux, RISC-V Linux, Intel macOS, and both Windows implementations.
A directory can contain additional assembly files, ABI checkers, import definitions, and target instructions.
Shared source can remain outside target directories when several implementations need it.
The manifest uses paths relative to the project root.

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

Each target requires `source` and accepts optional `test`, `link`, `libraries`, and `check` strings.
An absent `test` selects `tests/main.s`.
The [native-library contract](native-linking.md) defines the optional library fields.
Targets do not inherit each other's fields.
The legacy `[build]` form remains supported and also accepts `test`.
A project cannot mix legacy build and named target tables.

The seven declaration IDs are `x86_64-linux`, `aarch64-linux`, `riscv64-linux`, `aarch64-macos`, `x86_64-macos`, `x86_64-windows`, and `aarch64-windows`.
Unknown or duplicate tables, duplicate fields, invalid paths, and malformed inactive recipes are errors.
Native build manifests and new named-target source manifests contain at most 8190 bytes.
Legacy source-archive manifests retain their existing 16384-byte acceptance limit.
Source and test paths contain at most 255 bytes.
Registry archives retain their stricter portable-path rules and 240-byte path limit.
Every explicitly declared source, test, and checker must be present in a source archive.

## Build and execution

Without `--target`, Asm selects the host implementation.
An explicit target must have a declaration in the project.
Existing native aliases remain accepted.

| CLI host | Build targets | Required tools |
| --- | --- | --- |
| Linux x86-64 or AArch64 | Three Linux targets | Native GNU Binutils, or matching GNU cross tools in `/usr/bin` |
| Apple Silicon macOS 15+ | Native macOS and three Linux targets | Apple Command Line Tools; Homebrew LLVM and LLD for Linux |

Linux cross tools use the prefixes `x86_64-linux-gnu`, `aarch64-linux-gnu`, and `riscv64-linux-gnu`.
Each prefix supplies an `-as` assembler and `-ld` linker.
On Apple Silicon, Asm uses `/opt/homebrew/opt/llvm/bin/clang` and `/opt/homebrew/opt/lld/bin/ld.lld`.
Install both Homebrew formulae before a Linux cross build:

```sh
brew install llvm lld
```

From a project directory, build a Linux implementation:

```sh
asm build --target riscv64-linux
asm test --target riscv64-linux --no-run
```

The commands produce `build/riscv64-linux/app` and `build/riscv64-linux/test`.
`--no-run` builds the test without claiming that it passed.
Its JSON result includes `"executed": false`.
Native output paths remain `build/app` and `build/test`.
`asm clean --target riscv64-linux` removes only that target's named artifacts.
Failed builds preserve the previous executable and remove their private stage.

Ordinary `asm run` and `asm test` execute only the native host target.
A cross-target execution request fails before a build changes files.
Asm never starts an emulator automatically.
Intel macOS and Windows declarations retain source ports; this CLI does not build those targets.
Their target directories contain direct tool instructions and qualification limits.
Cross-target `link = "c"` requires a target sysroot and remains unsupported.
A sysroot contains the destination platform's headers and libraries.
Build native-library projects on their declared native host.

## Exact dependencies for each target

Named-target projects and foreign-target legacy projects write `# asm-lock-v2` with the existing eight artifact fields.
Each package and target pair has one exact version, size, URL, and digest.
One package can use different versions on different targets.
The lock still uses one registry origin.

Select the target explicitly for dependency commands.
After adding an exact dependency, check and restore its target:

```sh
asm lock --target aarch64-linux
asm sync --target aarch64-linux
asm build --target aarch64-linux --locked
```

`asm add`, `asm update`, and `asm remove` affect only the selected target.
They preserve selections for other targets.
Build, lock, and sync check only the selected target's cached bytes.
They validate every row's metadata and reject duplicate pairs or undeclared targets before cache changes.
Missing inactive cache files do not prevent a selected-target build.
Counts describe the selected target.

Existing v1 locks remain readable under their native-target contract.
A named-target mutation upgrades a v1 lock atomically.
Older CLIs reject the v2 header before changing files.
Failed updates preserve the previous lock.

## Distribution and evidence

Project declarations and registry artifact support are separate contracts.
Registry v1 still accepts its existing four artifact targets and six artifacts per release.
Declaring a Windows source implementation does not qualify a Windows registry artifact or CLI host.
Published package records and artifact bytes remain immutable.
A changed source layout requires a new package version before publication.

The [completion evidence](multi-target-projects-completion-evidence.json) records exact checked bytes, native and emulated execution, failed attempts, and remaining platform limits.
The [earlier native-selection record](multi-target-projects-evidence.json) remains historical evidence for the first implementation stage.

Native qualification uses schema 2 for the selected-target build contract.
Schema 1 retains its original native-only target report.
Release admission checks the exact target report against the recorded source command metadata.
Both schemas retain exact source, artifact, native execution, and unskipped-test checks.
