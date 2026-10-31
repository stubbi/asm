# Roadmap

ASM is intended to be the project tool and package registry for assembly. The CLI is written in assembly. The registry, website, and validation services may use other languages where that makes them easier to operate and audit.

The items below are delivery gates, not release dates. An item becomes complete when its behavior is implemented, tested, and available through the documented route. A proposed command or a website mockup does not count as a shipped service.

## 0. A usable first release

**In progress.**

- A native assembly CLI with help, version, diagnostics, project creation, and a working build/run loop on its initial host platform.
- A real source package, immutable version metadata, and a downloadable artifact.
- A static registry and package pages at `asm.build`, with search, version history, target information, source, license, and honest check status.
- A documented contributor route for publishing through reviewed pull requests.
- Checksums, bounded archive validation, and tests for invalid input and version replacement.

**Exit test:** start from a clean supported machine, build the CLI, create a project, consume the example package through the documented registry route, build and run it, and reject a modified artifact. Unsupported commands must fail clearly rather than print a success message.

## 1. Stable packages and dependency resolution

- Freeze a versioned manifest/index schema with migration rules.
- Add exact locked versions, transitive dependency resolution, deterministic target selection, and an offline verified cache.
- Separate build-host tools from target libraries; track ABI, object format, assembler dialect, and ISA requirements.
- Make publish, yank, ownership, and immutable-version checks enforceable in CI.
- Add download statistics from a real event or release-asset source. Until then, show that the metric is unavailable.

**Exit test:** a multi-package project resolves identically from a lockfile; yanked versions are excluded from new locks; wrong-target and hash-mismatch cases fail before execution.

## 2. Authenticated distribution

- Publish CLI and package provenance tied to exact artifact digests and expected workflow identities.
- Introduce narrowly scoped OIDC trusted publishers for unattended releases.
- Add authenticated registry metadata, rollback/freeze protection, key rotation, and recovery drills.
- Verify on the client as well as at publication time; keep self-update disabled until this route is complete.

**Exit test:** substitution, downgrade, expired metadata, and publisher-identity changes are detected using adversarial fixtures. A documented recovery can rotate compromised keys without replacing trusted history.

## 3. More hosts and targets

- Add native CLI ports beyond the initial platform.
- Ship target-specific package examples for x86-64, AArch64, and RISC-V as their toolchains are implemented.
- Test native execution where possible and identify emulator-only results explicitly.
- Document calling conventions, exported symbols, clobbers, and cross-compilation requirements.

**Exit test:** the same project workflow selects and tests the correct implementation for each supported target. Listing a target in a manifest is insufficient.

## 4. Security evidence and formal contracts

- Add maintained advisory checks and isolated static-analysis/build workers.
- Integrate a pinned Lean/Kraken toolchain for a documented subset of routines and architectures.
- Check submitted proofs against separately trusted statements, audited axioms, and exact source digests.
- Display the proposition and assumptions behind each result. Keep source-model proofs distinct from final-binary claims.

**Exit test:** a real routine passes its stated contract; altered code, false claims, unsupported instructions, hidden axioms, and wrong digests fail. Publish the reproducible evidence.

## 5. Agent-assisted review and registry operations

- Run bounded agents to propose tests, review changes, explain findings, and generate candidate proofs.
- Keep models outside the publication/signing authority and treat package text as untrusted input.
- Add independent moderation, incident response, namespace recovery, abuse handling, mirrors, and capacity planning.
- Move artifact storage and counters beyond GitHub Pages when measured usage requires it.

**Exit test:** prompt-injection fixtures cannot change permissions or publish a package, and every reported outcome links to the exact inputs and checker that produced it.

See the [registry specification](specs/registry.md) and [security model](specs/security.md) for the contracts these gates enforce.
