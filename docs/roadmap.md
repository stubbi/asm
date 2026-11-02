# Roadmap

ASM is a project tool and package registry for assembly. The CLI is written in assembly. Registry tooling and the website use other languages.

These are delivery gates. A gate closes when its behavior is implemented, tested, and available through the documented route.

## Global distribution

ASM aims to support software distribution at global scope, with assembly as its current package focus.
Substantial discovery traffic is a core requirement.
Known-package installation must remain independent of search availability.

The [architecture proposal](architecture.md) defines authenticated delivery, authoritative publication, and a rebuildable search projection.
Its [acceptance gates](architecture-gates.md) distinguish the deployed static alpha, local experiments, and proposed production behavior.
The [assembly server experiment](../experiments/assembly-server/README.md) is published for local builds and tests.
The Rust behavioral reference remains unpublished.
The proposed latency and workload targets are not measured capacity.

## Current release

The code now contains:

- Native CLIs for x86-64 Linux, ARM64 Linux, and Apple Silicon macOS 15 or later.
  Each CLI supports project creation, build, run, test, and diagnostics.
- Registry search, package information, version lists, checked downloads, and explicit executable installation.
- Native source-archive validation, extraction, and cache comparison.
- Native preparation of publication records for reviewed pull requests.
- Immutable registry metadata, source archive checks, ELF and Mach-O checks, and deterministic index generation.
- Package pages with real records, version history, target details, and check status.
- Download counts from GitHub release assets, with unavailable values marked explicitly.
- GNU assembly examples for x86-64, AArch64, and RISC-V Linux.

The release checks build the AArch64 and RISC-V examples with cross tools and run them under QEMU user-mode emulation.
A native RISC-V CLI remains future work.

**Release gate:** build from a clean checkout. Run the documented package workflow. Verify published artifacts through the public registry. Reject changed artifacts and malformed records.

## Direct dependencies

The native dependency commands use exact versions and a project lock file. The cache retains the locked archive and extracted source files.

**Acceptance gate:** add a library and call its exported routine. Rebuild from the lock without network access. Restore missing cache data with sync. Reject changed archives, changed source files, and unexpected cache entries. Preserve the previous lock after a failed update.

Transitive resolution, version ranges, feature selection, and solver diagnostics remain future work. They require a separate resolver specification and adversarial graph tests.

## Authenticated distribution

- Bind artifact provenance to expected repository and workflow identities.
- Add narrowly scoped OIDC trusted publishers.
- Authenticate registry metadata and detect rollback or expiry.
- Test key rotation and compromise recovery.
- Verify these properties in the client before unattended updates.

**Acceptance gate:** reject signature substitution, stale metadata, and unauthorized publisher changes. Complete a documented key-recovery exercise.

## More hosts and package interfaces

- Add native CLI ports beyond the current Linux and Apple Silicon macOS hosts.
- Add general cross-build support.
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
