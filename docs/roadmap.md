# Roadmap

Asm is a project tool and package registry for assembly. The CLI is written in assembly. Registry tooling and the website use other languages.

These are delivery gates. A gate closes when its behavior is implemented, tested, and available through the documented route.

## Global distribution

Asm aims to support software distribution at global scope, with assembly as its current package focus.
Substantial discovery traffic is a core requirement.
Known-package installation must remain independent of search availability.

The [architecture proposal](architecture.md) defines authenticated delivery, authoritative publication, and a rebuildable search projection.
Its [acceptance gates](architecture-gates.md) distinguish the deployed static alpha, local experiments, and proposed production behavior.
The [assembly server experiment](../experiments/assembly-server/README.md) is published for local builds and tests.
The Rust behavioral reference remains unpublished.
The proposed latency and workload targets are not measured capacity.

## Current release: 0.6.0

The code now contains:

- Native CLIs for x86-64 Linux, ARM64 Linux, and Apple Silicon macOS 15 or later.
  Each CLI supports project creation, build, run, test, and diagnostics.
- Named project implementations, standalone Linux cross builds, and target-specific direct dependencies in v2 locks.
- Optional native-library linking and compile-only ABI checks on the native host.
- Registry search, package information, version lists, checked downloads, and explicit executable installation.
- Local installation inventory, upgrades, and uninstall for recorded executables.
- Native source-archive validation, extraction, and cache comparison.
- Native preparation of local publication records without uploading files.
- Immutable registry metadata, source archive checks, ELF and Mach-O checks, and deterministic index generation.
- Package records with version history, target details, and check status.
- Download counts from GitHub release assets, with unavailable values marked explicitly.
- GNU assembly examples for x86-64, AArch64, and RISC-V Linux.

The release checks build the AArch64 and RISC-V examples with cross tools and run them under QEMU user-mode emulation.
A native RISC-V CLI remains future work.

**Release gate:** build from a clean checkout. Run the documented package workflow. Verify published artifacts through the public registry. Reject changed artifacts and malformed records.

## Installed programs

Asm 0.5.0 records executable installations and provides `installed`, `upgrade`, and `uninstall`.
Published 0.4.0 binaries do not include these commands.
`update` and `remove` continue to manage source dependencies.

The [installed-program contract](installed-programs.md) defines inventory records, file checks, and recovery limits.
These commands do not execute package code.
Earlier installations remain unmanaged; Asm does not adopt them during a CLI update.
Process interruption can require manual recovery because executable and inventory changes are separate filesystem operations.

**Acceptance gate:** install, list, upgrade, and uninstall a program through the native CLI.
Reject changed files, changed release bytes, unsupported targets, and origin changes.
Preserve existing files after corrupt downloads and failed commits.

## Direct dependencies

The native dependency commands use exact versions and a project lock file. The cache retains the locked archive and extracted source files.

**Acceptance gate:** add a library and call its exported routine. Rebuild from the lock without network access. Restore missing cache data with sync. Reject changed archives, changed source files, and unexpected cache entries. Preserve the previous lock after a failed update.

The unreleased V2 source profile adds bounded mandatory transitive resolution, numeric ranges, and complete graph locks for one explicit target.
Its [contract](specs/registry-v2.md) and [evidence](v2-dependency-evidence.md) remain separate from the released V1 capability.
Feature selection, optional dependencies, parallel versions, universal target solving, and richer conflict explanations remain future work.

## Unreleased V2 distribution

The [V2 source profile](specs/registry-v2.md) provides direct scoped publishing, signed exact installation, and explicit mirror selection.
Local tests compose the assembly API, PostgreSQL, private signing jobs, a second mirror, and the native client.
The [evidence record](registry-v2-evidence.md) identifies artifacts and failed checks.
A mirror needs static storage, synchronization, and HTTPS; it needs no database or signing keys.
Native project preparation reads committed Git objects and writes archives and manifests in assembly.
Prepared canonical manifests and digest-named objects remain an alternative.
V2 observations use normalized private logs and identity-scoped snapshots; missing or unreported traffic remains unknown.
An explicit static website build connects that registry and its observations to package pages, local search, and statistics.
Native commands still authenticate current metadata independently of the cached pages.
Self-service enrollment, dependency integration, production custody, and deployed recovery remain separate work.

## Authenticated distribution

- Bind artifact provenance to expected repository and workflow identities.
- Add optional OIDC publisher adapters with exact scopes.
- Qualify signed metadata, rollback, and expiry through the deployed distribution path.
- Exercise operational key rotation and compromise recovery with the selected custody procedure.
- Verify these properties in the client before unattended updates.

**Acceptance gate:** reject signature substitution, stale metadata, and unauthorized publisher changes. Complete a documented key-recovery exercise.

## More hosts and package interfaces

Asm 0.6.0 supports named target implementations, standalone Linux cross builds, and target-specific direct dependency locks.
The [project contract](multi-target-projects.md) separates declarations, supported builds, native execution, and registry artifacts.
The reference projects keep implementations in target subdirectories.

- Add native CLI ports beyond the current Linux and Apple Silicon macOS hosts.
- Qualify cross-target native-library sysroots and additional destination platforms.
- Describe ABI, object format, assembler dialect, and required ISA extensions in metadata.
- Separate host tools from target libraries.
- Record exported symbols and register clobbers.
- Test on native hardware where available.

**Acceptance gate:** select, build, and test the correct package implementation for each supported target. Label emulated results separately.

## Formal contracts and security evidence

Lean/Kraken integration needs a separate design review before implementation. The intended Kraken project is [AeneasVerif/kraken](https://github.com/AeneasVerif/kraken). The registry does not currently run a proof service.

- Select a small routine and a useful contract.
- Pin the semantics and proof toolchain.
- Maintain the trusted theorem statement separately from submitted proofs.
- Bind each report to exact source digests and assumptions.
- Validate exported proofs with an independent checker where supported.
- Keep model proofs distinct from claims about final binaries.
- Add maintained advisory checks and isolated build workers.

**Acceptance gate:** prove the stated contract for a real routine. Reject changed code, false statements, unsupported instructions, hidden axioms, and wrong digests.

## Agents and registry operations

- Let bounded agents propose tests, findings, and candidate proofs.
- Keep publication credentials and signing authority outside agent permissions.
- Treat package text as untrusted input.
- Add namespace recovery, moderation, incident response, and mirrors.
- Expand storage and metrics when measured usage requires it.

**Acceptance gate:** package instructions cannot change agent permissions or publish releases. Each report identifies its inputs, tool versions, scope, and outcome.

See the [registry specification](specs/registry.md) and [security model](specs/security.md) for the detailed contracts.
