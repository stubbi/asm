# Multi-target project completion plan

> **For agentic workers:** Keep project and package logic in native assembly and verify observable behavior before completion.

**Goal:** Maintain several machine implementations under one project, with explicit builds and exact dependencies for each target.

**Architecture:** One root manifest declares named target recipes. Native assembly selects a recipe, invokes fixed tools, stages separate target outputs, and reads target-keyed v2 locks.

**Tech stack:** Native x86-64 and AArch64 assembly, GNU Binutils, LLVM/LLD, existing Python registry and release tools.

**Spec:** [Multi-target project contract](../../multi-target-projects.md).

## Outcome and principles

Authors keep one project identity and understandable target subdirectories.
Dependable reuse requires exact target selection and immutable artifacts.
Trust requires measured native or emulated checks and retained negative results.

## Constraints and decisions

- Preserve existing legacy manifests, native output paths, v1 locks, installed programs, and source-alias security checks.
- Declare seven known source targets while retaining the existing four registry artifact targets.
- Build standalone Linux targets with explicit mature tools; never execute foreign output automatically.
- Require a native host for native-library builds until a target sysroot contract is implemented.
- Keep source declarations, build support, execution support, and release qualification distinct.
- Preserve upstream schema-1 dependency metadata validation and earlier published records.
- Consolidate all existing hello and math ports under `targets/<id>` and remove superseded sibling projects.
- Integrate against current main without copying unrelated pending website or server work.
- Publish no new release or registry record as part of this change.

## Acceptance checks

- [x] Add regression tests and observe unsupported target selection and v2 lock failures.
- [x] Implement cross-target assembly, no-run tests, selected cleanup, and failure preservation on both CLI architectures.
- [x] Implement target-keyed dependency mutations and selected-cache verification on both CLI architectures.
- [x] Consolidate both reference projects and retain their ABI and output-failure tests.
- [x] Preserve current-main metadata, alias checks, and dependency schema validation during integration.
- [x] Run native macOS, Linux x86-64, and Linux AArch64 client checks.
- [x] Run registry, release, and reference-package checks with explicit platform skips.
- [x] Review the complete change and fix actionable defects.
- [x] Retain exact source/artifact digests, failed attempts, environment details, and remaining platform limits.

## Review focus

Inactive metadata must fail before cache or output changes.
A selected target must never fall back to the host implementation.
Same-package versions on different targets must remain independent.
Tool lookup, target paths, and Apple source preparation must preserve target identity.
Historical source metadata and release contracts must retain their existing validation.

## Material trade-offs

The source layout changes and source bytes are unreleased; publication requires new package versions.
Windows and Intel macOS source ports remain available without inventing CLI host or registry artifact qualification.
A separate isolated checkout preserves unrelated pending work and incorporates the ports already merged into main.

## Completion evidence

The [completion record](../../multi-target-projects-completion-evidence.json) retains checked inputs, exact artifacts, failures, review fixes, and platform limits.
