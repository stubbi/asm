# Dependency resolution

Status: implementation contract, 4 November 2026. This work is not a published release.

## Outcome and scope

An author can reuse packages with nested dependencies, compatible version ranges, and selected optional features.
The native assembly CLI resolves one source artifact per package identity for its host target.
The complete selection is locked before a build.
This serves dependable reuse, inspectable evidence, and preservation of user files.

Native resolver implementations cover Linux x86-64, Linux AArch64, and Apple Silicon macOS.
They select the current host target, without cross-compilation or execution of another target.
RISC-V64 Linux, Intel macOS, and Windows need separate native ports and qualification.
Registry acceptance of a package target does not establish CLI host support.

The existing exact dependency commands and v1 locks remain supported.
`asm resolve` supplies the new manifest-driven workflow.
Legacy mutation commands reject resolution manifests and graph v3 locks with a useful next step.
They must not flatten a dependency graph into unrelated roots.

## Manifest

The package identity and one legacy build or named target recipe remain required.
All seven named recipes follow the [multi-target project contract](../multi-target-projects.md).
Dependency declarations require this explicit extension:

```toml
[resolution]
schema = "1"

[dependencies]
"example/math" = "^1.2.0"
"example/vector" = { version = "~2.3.0", optional = true, default-features = false, features = ["portable"] }

[features]
default = ["vectors"]
vectors = ["dep:example/vector", "example/math/checked"]
```

This is a strict, single-line TOML subset.
Reject unknown fields, escapes, duplicate declarations, unsupported types, and malformed references.
Dependency tables accept only `version`, `optional`, `default-features`, and `features`.
The version is required. Optional defaults to false; default-features defaults to true.
Features default to an empty list.
Names use lowercase ASCII letters, digits, underscores, and hyphens, with an initial letter and at most 32 bytes.

A feature member names a local feature, an optional dependency with `dep:owner/name`, or a dependency feature with `owner/name/feature`.
A dependency-feature member also activates that dependency.
Reject undeclared dependencies, unknown selected features, and cyclic local feature references.
Feature requests from different consumers combine additively.
An incoming request for default features enables the selected package's `default` feature, when declared.
Reject package dependency cycles with a useful error.
Assemblers still use explicit source includes and calling conventions.
This change does not add automatic symbol imports or a build sandbox.

## Version selection

Supported requirements are exact `X.Y.Z`, `*`, `^X.Y.Z`, `~X.Y.Z`, and comma-separated comparisons.
Comparison operators are `=`, `<`, `<=`, `>`, and `>=`.
All comparison terms must hold.
Components range from zero through 2147483647 and have no leading zeros.
Reject partial versions, prereleases, build metadata, OR expressions, and empty requirements.
Caret preserves the first nonzero component; `^0.0.3` excludes `0.0.4`.
Tilde preserves major and minor components.
Bare versions are exact, preserving Asm's existing convention.

Normal version structure follows [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html).
Caret and tilde follow the full-version forms in the [Cargo dependency reference](https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html).
These primary references were checked on 4 November 2026.
Asm does not implement every syntax form those references describe.

Resolve package identities in canonical byte order and try versions in descending numeric order.
Backtrack when a later requirement rejects an earlier candidate.
Do not claim that the resulting selection maximizes every package simultaneously.
Report the conflicting package and requirement when no selection satisfies the graph.
Reject malformed metadata, corrupt artifacts, and unavailable transport as errors instead of hiding them through a lower version.

## Commands and file effects

Run `asm resolve` after editing dependencies in `asm.toml`.
`--features a,b` selects additional root features; `--no-default-features` disables the root default request.
`--index PATH` selects a local v1 index. `--registry HTTPS_URL` selects another registry origin.
`--artifacts DIR` supplies archives named `<sha256>.tar.gz` without network fallback.
Artifact files and directory boundaries must reject symlinks and nonregular files.

Candidate metadata comes from the exact digest-verified source archive's `asm.toml`.
Old manifests without the extension are leaf packages.
No new mutable metadata source or changed published release record is necessary.
This preserves the existing HTTPS-origin trust limit; a checksum does not authenticate a publisher.

Exact package-target selections retain main's `# asm-lock-v2` format.
The unpublished graph format uses `# asm-lock-v3` to avoid ambiguity.
The readers reject crossed formats before changing dependency state.

Graph v3 locks retain the registry origin, root feature choices, dependency declarations, selected features, and exact artifact records.
`asm lock` and builds check the complete locked graph against the root and verified archive metadata without selecting newer versions.
`asm sync` restores exact locked artifacts without consulting a newer index.
An incompatible changed root declaration requires resolution again.

Hold the existing project operation lock during dependency state changes.
Validate the full selected graph and every artifact before the atomic lock replacement.
Preserve the previous lock, project manifest, build output, and existing cache edits after failure.
Verified unreferenced cache additions can remain after failed resolution.
Never execute package code during resolution or synchronization.

## Resource limits

| Resource | Limit |
| --- | --- |
| Manifest with resolution metadata | 8190 bytes |
| Dependencies per manifest | 64 |
| Features per manifest and members per feature | 64 |
| Feature names requested on an edge or combined for one package | 64 |
| Range text and comparison terms | 128 bytes; 8 terms |
| Selected package identities | 128 |
| Inspected candidate archives | 256 |
| Search decisions | 4096 |
| Index, lock, artifact | Existing 1 MiB, 1 MiB, and 64 MiB limits |

Exhaustion is an explicit error, never an unsatisfied-dependency claim or a truncated graph.
Candidate archive inspection costs more network traffic than a separate metadata service.
The inspection budget bounds this deliberate alpha trade-off.

## Catalog display contract

The catalog integration is separate, unmerged work in this CLI baseline.
The following requirements do not describe its current website.

Each website release shows direct dependency declarations for each checked source artifact target.
The site derives these declarations from the same validated archive bytes, bound to their SHA-256 digest.
It shows package links, requirements, optional dependencies, default-feature policies, and requested features.
Feature options show which declarations enable dependencies or request dependency features.
Links open the named package record and preserve keyboard navigation and browser history.
Packages outside the catalog have no fabricated destination.

A checked manifest without dependency declarations has a known empty list.
Missing, unchecked, or malformed metadata remains unavailable.
The display does not resolve transitive dependencies or scan assembly include directives.
An assembly include directive remains an explicit source-code instruction, separate from a package dependency declaration.
The generated JSON extension leaves published release records, artifact bytes, and the native TSV index unchanged.

## Acceptance evidence

Tests must exercise a real transitive assembly import, descending-version backtracking, range boundaries, and feature unions.
They must distinguish disabled optional dependencies from missing required packages.
They must reject cycles, unknown features, malformed metadata, unsupported targets, and excessive resources.
Corrupt or absent archives must preserve the previous lock and user files.
Independent projects and shuffled indexes must produce identical locks.
Locked builds must work offline; sync must restore the exact graph without new resolution.
Run the native CLI, registry, publication, and release-contract checks on the applicable hosts.
Keep unavailable qualification explicit.
