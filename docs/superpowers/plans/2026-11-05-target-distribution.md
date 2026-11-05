# Target distribution implementation plan

> Use `superpowers:subagent-driven-development` for independent implementation and review.

**Goal:** Integrate each new native port without breaking released clients or declaring an unqualified host.

**Architecture:** Retain native assembly command logic and bounded registry formats. Freeze existing feed vocabularies. Add one expanded feed. Qualify executable bytes and runtime behavior independently for each host before publication.

**Tech stack:** Assembly, existing Python build tools, Go transport and cryptography, and pinned GitHub Actions.

**Spec:** The user's multi-architecture continuation, `docs/specs/registry.md`, `docs/specs/security.md`, and `docs/architecture-gates.md`.

## Constraints and acceptance

- Read both brand documents before work or handoff. Preserve files and exact evidence.
- Keep 0.5.0 and all earlier records and release assets unchanged.
- Keep `index.tsv` limited to the three existing Linux targets.
- Keep `index-macos.tsv` limited to those Linux targets and `aarch64-macos`.
- Add `index-all.tsv` with the same bounded v1 syntax. New parsers must recognize the full catalog vocabulary.
- Separate catalog recognition, native execution, installer eligibility, and declared release hosts.
- Keep `release.json` schema 1 and each asset's exact `file`, `bytes`, and `sha256` fields.
- Keep the bundled trust profile disabled until its independent provisioning gates pass.
- Treat 0.6.0 as prospective. Do not publish it or widen `cli/commands.json` hosts before qualification.
- Record source, assembly, runtime, release, and deployment states separately, with artifact digests where bytes exist.

## Review focus

Old parsers must reject neither a whole compatible feed nor their next update. Unknown targets, malformed files, wrong ABI declarations, and mismatched provenance must fail. Missing or skipped runtime tests cannot qualify a host. Windows requires native path, reparse-point, permission, and running-image replacement checks. Cross-assembly and emulation remain distinct from native execution.

## Task 1: Compatible feeds

**Files:** `tools/registry.py`, `tools/build_site.py`, `tests/test_target_indexes.py`, registry/site tests, and registry documentation.

**Interface:** Add `macos_compat_tsv(tsv)` beside `legacy_tsv(tsv)`. Both consume canonical `make_indexes` output. The full output becomes `index-all.tsv`; compatibility feeds preserve existing bytes for existing records.

- [x] Add failing cases containing all seven planned labels and verify both compatibility vocabularies.
- [x] Generate all three feeds in registry and site builds without changing row or byte limits.
- [x] Verify checked current records produce byte-identical legacy feeds.
- [x] Run registry tests, site checks, and the native CLI suite. Review the complete diff.

## Task 2: Explicit build and verifier selection

**Files:** `Makefile`, focused build-selection tests, and verifier notices tooling when required.

**Interface:** Map each integrated target to explicit assembler, linker, Go OS, Go architecture, and output names. Current pairs are Linux/x86_64 → linux/amd64, Linux/aarch64 → linux/arm64, and Darwin/aarch64 → darwin/arm64. Reject every other CLI pair. Pass identical GOOS, GOARCH, and CGO_ENABLED=0 to verifier builds and notices. Make verifier targets depend on the Makefile. Do not use a non-x86 fallback.

- [x] Add failing checks for explicit current mappings and unsupported combinations.
- [x] Replace implicit verifier architecture and OS selection without widening declared hosts.
- [ ] Add each port's build rule only when its implementation contract exists.
- [x] Run current native build/tests and verifier gates. Keep Windows verifier qualification separate from cross-compilation.

## Task 3: Port inputs and publication

**Files:** Target-specific port inputs, `tools/bootstrap.py`, `tools/release.py`, registry validators, verifier metadata allowlists, and workflows as required by the concrete ports.

**Interface:** Integrate `riscv64-linux`, `x86_64-macos`, `x86_64-windows`, and `aarch64-windows` independently. Windows executable names end in `.exe`. POSIX installer eligibility excludes Windows artifacts.

- [ ] Bind the existing ARM64 Linux release asset to an exact native qualification input, with source, version, target, digest, two clean builds, and unskipped native test evidence. Preserve existing gates.
- [ ] Review port files and exact source revisions before integration.
- [x] Add failing Windows PE format and POSIX-installer selection cases for the concrete draft artifacts. Keep native Windows provenance/runtime pending.
- [ ] Integrate target-specific native evidence and matching artifact bytes without changing published versions.
- [ ] Implement and run real platform-specific verifier state, permission, reparse, locking, and atomic-write tests. Keep native Windows execution separate from cross-compilation.
- [ ] Run first-project, package lifecycle, update/recovery, and hostile-input tests on each target.
- [ ] Run the full release gates and review all available history before any support declaration or publication.

## Current evidence

Asm 0.5.0 source is `1f1530db38eb7326ba149addf3f0b45f2f3ac026`. [Release run 41935096978](https://github.com/stubbi/asm/actions/runs/41935096978) passed. All 14 public assets and 13 provenance subjects passed independent postpublication checks. The deployed catalog commit is `4bcb109d9876404ec76fad988acab5911fd55e1a`. A native Apple Silicon public acceptance run passed all 24 installation, first-project, self-update, and program-management commands. No new port is qualified by this plan.


## Validation before main integration

The local aggregate `make check` passed: native macOS 221 tests, registry 47 tests, release 51 tests, and JavaScript 11 tests.
The release suite skipped 12 Linux-only cases on macOS; hosted Linux qualification remains required.
The release fixture also ran its exact-source native macOS tests.
The verifier race tests and actual Linux/x86-64 ELF and macOS/ARM64 Mach-O builds passed before the pending Windows adapter work.

Retained negative results include the wrong-platform verifier build, missing compatibility-feed routes, malformed PE review cases, and a corrected bounds fixture.
A broader release run failed on two Windows-label assertions while parallel validator changes were in progress.
The assertions now separate catalog format recognition from the unchanged three-host release declaration.
The complete aggregate then passed.
No test failure or skipped case qualifies a new host.
