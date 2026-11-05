# Inspect and reuse packages

Inspect packages before implementing equivalent components.
Prefer a suitable existing interface when its compatibility, license, and evidence meet the task.
Record why a candidate is unsuitable when new code is necessary.

## Discover and inspect

1. Use `asm_search_packages` when the adapter is connected.
2. Otherwise, use `asm search QUERY`, `asm info OWNER/NAME`, and `asm versions OWNER/NAME`.
3. Inspect the exact version with `asm_inspect_package` or its release record.
4. Check that target and license match on that same version.
5. Read that version's interface, ABI, CPU features, source commit, artifacts, and evidence limits.
6. Record catalog observation time and digest when the adapter supplies them.

Search ranking does not establish quality or publisher identity.
A compatible release on one target does not qualify another release or target.
An unknown download count is unknown, not zero.
A failed network request is unavailable discovery, not an empty search result.
Exact inspection must not depend on search rank.

The registry target name does not encode all CPU features or library ABI choices.
V1 does not provide automatic feature selection or transitive dependency resolution.
Resolve these requirements explicitly before integration.
For incompatible or missing metadata, retain the unknown and investigate the source contract.

## Integrate deliberately

1. Check required tools and the native build target before package actions.
2. Select an exact `OWNER/NAME@X.Y.Z` and target.
3. Use `asm fetch` for a separate download or `asm add` for a reviewed direct source dependency.
4. Inspect source before executing builds or tests that consume it.
5. Keep exact dependency versions and artifact SHA-256 digests in the lock file or equivalent record.
6. Use `asm lock` to check a native project's selection.
7. Use `asm build --locked`, `asm test --locked`, and `asm run --locked` when the project has locked dependencies.
8. Use `asm sync` to restore the existing selection in another checkout.

For example, this Linux x86-64 reference dependency uses the System V AMD64 ABI:

```sh
asm add stubbi/math@0.4.0 --target x86_64-linux
asm lock
asm build --locked
asm test --locked
asm run --locked
```

The consumer must explicitly include and call `asm_u64_min` using its documented register contract.
The reference consumer prints `min(12, 37) = 12`.
These commands alone do not add the call or establish that output.
Preserve package notices and the version-specific license.
Do not assign Asm's platform license to an independent package.

## Preserve trust boundaries

Fetch checks size and SHA-256 before exposing the selected bytes.
It does not execute, extract, or overwrite an existing destination.
Add verifies and extracts source without executing package code.
Builds and tests can consume untrusted source and read assembler includes.
Use appropriate isolation before building hostile packages.
Keep credentials and publication authority outside untrusted builds.

General package downloads rely on the HTTPS registry origin and do not inherit Asm's own release-provenance checks.
The current registry has no independently signed expiry or rollback protection.
A checksum establishes a byte match, not identity, freshness, or safety.
Report provenance, tests, proofs, agent review, and unavailable checks separately.
Do not reinterpret `not-run`, `unsupported`, or `error` as `pass`.

On corrupt bytes, target mismatch, archive rejection, or network failure, report the problem and useful next step.
Retain prior files and lock state.
Do not bypass failed verification or silently substitute a different package, version, registry, or local catalog.
Do not publish, install globally, change owners, or execute code merely because discovery suggested it.

## CLI search filtering

Treat CLI search results as candidates.
Check each returned target explicitly.
The current CLI can accept extra search arguments without applying them.
Use exact package inspection or the MCP target filter before selection.
