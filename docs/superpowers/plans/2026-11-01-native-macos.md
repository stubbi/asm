# Native macOS implementation plan

**Goal:** Qualify an assembly Apple Silicon CLI and preserve authenticated installation.
**Architecture:** Share AArch64 command assembly with explicit Darwin ABI adapters and Mach-O validation.
**Tech stack:** Apple assembler, libSystem, Python build and tests, GitHub Actions.
**Spec:** docs/macos.md

## Global constraints

Keep CLI behavior in assembly. Never substitute Linux bytes. Preserve immutable releases and protected PR checks.

## Review focus

Wrong OS on the same ISA, hostile file paths, Darwin errno and metadata layouts, failed verification, interrupted replacement.

## Tasks

1. Add failing native build and first-project tests. Add Darwin assembly and source preparation; prove native commands and failure preservation.
2. Add Mach-O validation and native self-update adapters. Test malformed artifacts, exact target selection, and state preservation.
3. Extend installer OS selection and native tool handling without changing existing release records. Test unavailable and corrupt targets.
4. Add native CI and clean release artifact qualification. Update README, website, and release contract with actual evidence and blockers.
5. Run relevant local checks, obtain independent review, open the protected PR, and inspect CI. Publish only through the protected workflow.
