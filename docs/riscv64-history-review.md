# RISC-V integration history review

On 5 November 2026, this review read the complete available commit ancestry of the RISC-V branch and `origin/main`.
The checkout was not shallow.
The review starts at initial commit `93487e3aeca0e5815e21083bd3e4e282a28375f6` and includes main `bc5bfbe8c9e6122d7360fbd11dc24f396ad6360d`.
The raw commit messages remain in `build/riscv64/complete-history-review.txt`.
The implementation review also inspected affected current parsers, archive boundaries, lock readers, target builders, syscall adapters, and retained failure evidence.

The integration retains these earlier decisions:

- Package decisions stay in native assembly; cryptography and transport use fixed mature tools.
- Fetch and resolution never execute a package.
- Exact artifacts, immutable registry records, historical release licenses, and prior failure records remain unchanged.
- Directory, alias, ownership, staging, and update-denial checks remain mandatory.
- The temporary write-capable history-import transport remains removed.
- Bundled-verifier publication and production activation remain separate gates.
- Source declarations, cross-builds, emulated execution, native execution, and release support remain distinct.
- Main's seven target declarations, named recipes, exact package-target v2 locks, selected archive checks, bounds, and no-run builds remain supported.

The unpublished graph lock intentionally changes from `# asm-lock-v2` to `# asm-lock-v3`.
Main now assigns v2 to exact package-target locks.
The separate graph header prevents either reader from interpreting the other's format.
Crossed-format regressions check that the previous lock and project files survive failure.
Graph resolution retains its native-host scope; exact dependency commands retain foreign-target selection.

The original unpublished resolver and native-library inputs were copied from preserved source snapshots.
Their origin and digests are recorded in `riscv64-baseline.json`.
This does not create a historical commit or authorship claim for previously uncommitted work.

The review does not replace deterministic gates.
Full-system RISC-V CLI execution and the combined server gate remain pending until their exact source and artifact records pass.
The merge queue owns integration and release admission.
This branch does not authorize a new RISC-V release or reuse an earlier version for new bytes.
