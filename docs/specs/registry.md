# Registry v1

Asm v1 serves a static registry over HTTPS. Maintainers review publication records in GitHub pull requests. GitHub Releases holds the artifacts. The native CLI and website read indexes made from the same records.

The native CLI supports package discovery, version lists, exact artifact selection, download, and size and SHA-256 checks. It can also prepare a local publication record. Direct dependency locks and cache verification are separate from transitive resolution. Authenticated index metadata and unattended publishing remain future work. See the [roadmap](../roadmap.md).

## Package identity

A registry name has the form `owner/name`, such as `stubbi/hello`. The local project name in `asm.toml` is `hello`.

| Part | Accepted syntax |
| --- | --- |
| Owner | `[a-z][a-z0-9-]{0,38}` |
| Name | `[a-z][a-z0-9-]{0,63}` |
| Both parts | No trailing hyphen or repeated hyphens |
| Version | Numeric `major.minor.patch`; no leading zeroes; each component is at most 2147483647 |

Names use lowercase ASCII and compare exactly. Version ranges, prereleases, and build metadata are not v1 syntax. Unsupported syntax is an error.

The first registry is curated. A maintainer must review a new namespace claim. A chosen owner prefix, source URL, or release URL does not prove ownership. The current route relies on repository review; it is not a self-service identity provider.

## Project manifest

Each source artifact has an `asm.toml` at its root:

```toml
[package]
name = "hello"
version = "0.1.0"

[build]
source = "src/main.s"
target = "x86_64-linux"
```

The native CLI accepts a small TOML subset. The publication record is separate. Registry validation checks that the project name, version, and target agree with that record. It also requires the declared assembly source, a README, and a license file.

Source builds accept the optional native library fields described in [the build contract](../native-linking.md).
A package that declares a compile-only ABI check must include its source file in the archive.
Library names are bounded metadata, not linker flags or shell commands.
Published Asm 0.5.0 binaries do not accept these fields.

## Release record

The canonical path is `registry/packages/<owner>/<name>/<version>.json`.

| Field | Meaning |
| --- | --- |
| `schema` | Integer `1` |
| `name`, `version` | Exact registry identity |
| `summary` | 1 to 160 printable ASCII characters, with no outer whitespace |
| `license` | One supported SPDX license identifier for this exact version |
| `source.repository` | Canonical `https://github.com/<owner>/<repo>` URL, without `.git` |
| `source.commit` | Full 40-character lowercase Git commit ID; an all-zero ID is rejected |
| `source.path` | Relative source directory within that commit, or `.` |
| `artifacts` | 1 to 6 artifact records, with one entry per target and kind |
| `yanked` | Boolean; a yanked record also needs a `yank_reason` |

An artifact has exactly these fields:

| Field | Meaning |
| --- | --- |
| `target` | `x86_64-linux`, `aarch64-linux`, `riscv64-linux`, or `aarch64-macos` |
| `kind` | `source` or `executable` |
| `sha256` | 64 lowercase hexadecimal characters |
| `url` | Absolute HTTPS GitHub release-asset URL |
| `bytes` | Integer from 1 through 67108864 |

Artifact URLs have this form:

```text
https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>
```

Tags and asset names use simple ASCII path segments. Percent escapes, credentials, alternate ports, queries, fragments, backslashes, and dot segments are rejected. Source assets end in `.tar.gz`. A release URL does not establish the publisher's identity. The URL owner can differ from the package owner.

Duplicate JSON keys, unknown fields, invalid types, and non-finite numbers are rejected. A manifest can be at most 64 KiB. The validator has a fixed set of supported open-source SPDX identifiers in `tools/registry.py`; v1 does not accept arbitrary license expressions. The license field is a declaration. The presence of a license file does not prove the right to distribute every included file.

The supported identifiers include `AGPL-3.0-only`, `AGPL-3.0-or-later`, `MIT`, and `Apache-2.0`.
The Asm platform's license does not replace a package's declared license.
Packages with separately licensed components must retain their notices and explain their scope.
The [licensing guide](../../LICENSING.md) defines Asm's own core, template, and example boundaries.

Published license declarations are immutable with the rest of the release record.
A later version can declare a different supported license.
The index must retain each version's declaration.

A valid commit string alone does not prove that the source exists. `pack-git` reads a real local Git commit and packages its recorded files. Publication review must also establish that the stated public repository contains that commit.

## Targets

The registry describes three Linux targets and Apple Silicon macOS.
Asm 0.5.0 has native CLIs for x86-64 Linux, AArch64 Linux, and AArch64 macOS 15 or later.
Each CLI builds projects for its own host target.
Each CLI can fetch artifacts for other registry targets.
The example README files give the commands for GNU cross assemblers and linkers.

Target names do not yet encode every ISA extension, ABI revision, dialect, or linker option. A package must state these requirements in its documentation. An ELF header check verifies the architecture and basic segment bounds. It does not prove that the program will work on every machine with that architecture.

The AArch64 and RISC-V examples have been assembled, linked, and run under QEMU user-mode emulation.
That result is distinct from a test on physical hardware.
A native RISC-V CLI, general cross-build support, library ABI selection, and transitive dependency resolution remain future work.

macOS executables use thin arm64 Mach-O, the Apple ABI, PIE, and a non-executable stack.
Native validation checks bounded commands, segment protections, entry points, deployment requirements, and the code signature.
Linux executable publication rejects a macOS declaration; prepare macOS executables on the qualified Mac host.
These format checks do not establish publisher identity or program behavior.

## Static layout

```text
registry/
  packages/<owner>/<name>/<version>.json
  v1/index.tsv
  v1/index-macos.tsv
  v1/index.json
  v1/downloads.json
```

Linux uses `https://asm.build/registry/v1/index.tsv`. macOS uses `https://asm.build/registry/v1/index-macos.tsv`. The website uses `index.json` and `downloads.json`. These indexes are generated; do not edit them by hand.

GitHub Pages serves the index and website. It does not accept uploads or run checks. The publication route uses repository review and CI. Artifact storage is separate from Pages. Capacity planning must follow [GitHub Pages' limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits).

The primary `index.tsv` retains Linux rows for released 0.3 clients.
`index-macos.tsv` includes the additional macOS target.
The JSON index describes all published targets.
Both native feeds use the same format below.

### Native index

The first line is exactly `# asm-registry-v1` followed by LF. Each data row has eight tab-separated fields:

| Column | Value |
| --- | --- |
| 1 | `owner/name` |
| 2 | Exact version |
| 3 | Target |
| 4 | Kind |
| 5 | SHA-256 |
| 6 | Artifact URL |
| 7 | Decimal byte size |
| 8 | Summary |

Every line ends in LF, including the last line. Blank data rows, CR, NUL, and other control characters are rejected. A row can be at most 2048 bytes excluding its LF. The index can be at most 1 MiB and can contain at most 4096 artifact rows.

Rows sort by ASCII package name, numeric version, target, then kind. Yanked releases are excluded. Clients must parse the entire bounded index before they trust a selected row.

The native TSV index does not contain a license field.
Use the JSON release record or website version details to inspect a license declaration.

### Website index

`index.json` has `schema: 1` and a `packages` array.
Each package contains `name`, `summary`, `license`, `repository`, `latest`, `targets`, and `versions`.
`latest` is the highest non-yanked numeric version, or `null`.
The package-level `license` is a convenience field for that latest active version.
When no version is active, consumers must use each version's own license field.

Each version contains `version`, `license`, `source`, `yanked`, `artifacts`, and `evidence`.
Its `license` comes from that exact release record, including for a yanked version.
A yanked version also includes its reason.
The artifact and source fields use the release-record shapes above.
The website keeps all versions visible, including yanked versions.
An absent version license is unavailable; consumers must not substitute the latest version's declaration.

Current evidence has `metadata`, `artifacts`, `provenance`, `formal`, and `agent_review` keys. Metadata is `validated` after schema checks. Artifacts are `validated` only after the tool checks the actual bytes, including archive, ELF, or Mach-O structure. Without that step, artifacts are `not-run`. The other three fields are `not-run` until their separate verification services exist. None of these fields is a safety rating.

#### Declared source dependencies

A verified site build writes optional declarations to `registry/v1/dependencies.json`.
The existing catalog JSON and native TSV formats remain unchanged for existing clients.
The builder derives declarations from each source artifact's root `asm.toml` after size, SHA-256, archive, and project validation.
It reuses the existing artifact download and does not execute or resolve package code.

The declaration file has `schema: 1` and a `sources` array.
Each source entry contains `name`, `version`, `target`, and `metadata`.
The name, version, target, and source digest must match an exact catalog artifact before the website displays its metadata.
The file has a four-MiB limit and at most 4096 source entries.
Duplicate source identities make the declaration file unavailable in the browser.
Missing or invalid declarations must not make the package catalog unavailable.
The `metadata` object contains these fields:

| Field | Meaning |
| --- | --- |
| `schema` | Integer `1` for this generated metadata format |
| `source_sha256` | Exact source artifact SHA-256 |
| `dependencies` | Direct declarations sorted by package identity |
| `features` | Declared feature names mapped to their manifest member strings |

Each dependency contains `name`, `requirement`, `optional`, `default_features`, and `features`.
String requirements normalize to `optional: false`, `default_features: true`, and an empty feature list.
Inline declarations retain their explicit values and use those defaults for omitted fields.
The manifest extension below defines accepted requirements, features, and bounds.

A checked legacy source manifest has empty dependency and feature declarations.
An unchecked source artifact has no source entry; its declarations are unavailable, not known empty.
Executable artifacts never inherit source dependency declarations.
Different target artifacts can declare different dependencies for the same package version.
These declarations do not describe resolved transitive dependencies, assembler includes, or executable contents.

The optional file does not change published release records, source archives, or existing registry indexes.
Its source digest identifies the checked bytes; it does not authenticate the publisher.

#### Dependency manifest extension

Source archives can declare dependencies with this explicit schema:

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

The extension uses a strict single-line ASCII TOML subset with an 8190-byte manifest limit.
Existing package and build fields remain required.
Unknown fields, duplicate declarations, escapes, unsupported syntax, and malformed references are errors.
Dependency inline tables accept only `version`, `optional`, `default-features`, and `features`.
`version` is required. `optional` defaults to false; `default-features` defaults to true.
Requested features default to an empty list.

Requirements accept exact `X.Y.Z`, `*`, `^X.Y.Z`, `~X.Y.Z`, and comma-separated comparisons.
Comparison operators are `=`, `<`, `<=`, `>`, and `>=`; all terms must hold.
Ranges contain at most 128 bytes and eight terms.
Version components range from zero through 2147483647 without leading zeros.
Partial versions, prereleases, build metadata, and OR expressions are unsupported.
Bare versions are exact. Caret preserves the first nonzero component; tilde preserves major and minor components.
These declarations do not make the published CLI a transitive resolver.

Each manifest can declare at most 64 dependencies and 64 features.
Each feature or requested-feature list can contain at most 64 unique entries.
Feature names contain at most 32 lowercase ASCII letters, digits, underscores, or hyphens, with an initial letter.
A member names a local feature, `dep:owner/name`, or `owner/name/feature`.
`dep:` members must name declared optional dependencies.
Dependency-feature members must name declared dependencies.
Local feature references must exist and contain no cycles.

The website shows these direct declarations for each source target and version.
It links available package records and labels packages absent from the catalog.
Assembly include directives remain explicit source-code instructions.

### Download counts

`downloads.json` has `schema: 1`, `source: "github-release-assets"`, an `observed_at` UTC timestamp, and a `packages` object. A package has a `total` and a `versions` map. Values are non-negative integers or `null`.

The collector matches the exact GitHub release URL and asset size. It also checks the digest when the GitHub response supplies one. A missing asset, failed request, or inconsistent response produces `null`. A measured zero remains zero. A total is available only when all its component counts are available.

These are GitHub asset downloads. They include repeated requests, automation, and both source and executable assets. They do not measure unique users or installed packages. Search order and download counts never affect artifact resolution.

## Package and publish

Use `tools/registry.py` with Python 3.11 or later. It uses the standard library.

1. Commit the source that you intend to publish. Include its manifest, source, README, and license.
2. Use `pack-git` with the full commit ID and source path. It excludes dirty working files and ignores local object replacements.
3. Build any executable artifact from that same committed source. Record the toolchain and test result.
4. Upload the exact artifacts to a public GitHub release. Keep the existing bytes when you retry a release.
5. Use `prepare` to compute sizes and SHA-256 digests, check each artifact, and write the publication record.
6. Submit that record as a pull request. Include the source commit, test instructions, namespace claim, and any relevant check reports.
7. Maintainers review the claim and validate against the published history. A trusted deployment job checks accepted bytes again and generates both indexes.

`pack` can make a local archive for inspection. It does not provide commit binding. `prepare` writes a local file; it does not upload, reserve a name, or publish a package. The native `asm publish` command prepares the same record without Python. Concrete commands are in the [registry contributor guide](../../registry/README.md).

Archives use deterministic USTAR and gzip: sorted paths, normalized modes, zero timestamps and ownership, and no links or special files. The inspector reads the archive without extracting or executing it. It rejects traversal, duplicate paths, case collisions, file/directory conflicts, invalid checksums, and hidden trailing content. It also rejects sensitive file names and resource-limit violations.

An archive can contain 4096 members. Paths can contain 240 characters. Files can contain 16 MiB. Both compressed data and the expanded TAR stream are limited to 64 MiB. Source collectors check the remaining byte budget before reading each file. An accepted archive is a structural check, not proof of benign code. See the [security model](security.md).

## Consume a package

The native commands are:

```sh
asm search hello
asm info stubbi/hello
asm versions stubbi/hello
asm fetch stubbi/hello@0.2.0 --target x86_64-linux --kind source --output hello.tar.gz
```

Without `@version`, fetch chooses the highest published numeric version that has the requested target and kind.
The default target is the CLI host: `x86_64-linux`, `aarch64-linux`, or `aarch64-macos`.
The default kind is `source`.
Use exact versions in reproducible instructions.

Fetch checks byte size and SHA-256 before it exposes the output. It does not overwrite an existing destination, set an execute bit, extract, install, or run package contents. A download failure or hash mismatch is an error. Source review, extraction, and building are separate user actions. The digest is checked against the HTTPS index. V1 has no separate signing key for that index. A compromised registry origin can replace both metadata and artifacts.

`--index PATH` uses a local index. `--registry HTTPS_URL` selects another index URL. `--artifact PATH` lets fetch check a local artifact for offline tests. The same metadata and digest rules apply.

Asm 0.5.0 records executable installations and provides `asm installed`, `asm upgrade`, and `asm uninstall`.
The [installed-program contract](../installed-programs.md) defines their local state and failure behavior.
Published 0.4.0 binaries do not include these management commands.
Both default destinations and explicit `--output PATH` destinations receive inventory records.
One package identity has at most one managed installation.
Earlier installations remain unmanaged; updating Asm does not adopt them.

Upgrade retains the recorded path and registry origin.
It selects the highest available host version unless an exact version is supplied.
It rejects downgrades and changed digests or sizes for an equal version.
Upgrade and uninstall refuse missing or changed installed files.
The commands `update` and `remove` continue to manage project source dependencies.

## Direct dependencies and locks

This example requires Linux x86-64 because `stubbi/math` uses the System V AMD64 ABI.

Use an exact version to add a source dependency:

```sh
asm add stubbi/math@0.2.0
asm lock
asm build --locked
```

Add accepts source packages for the CLI's native build target: `x86_64-linux`, `aarch64-linux`, or `aarch64-macos`.
It checks the artifact before extraction and writes `asm.lock` after extraction succeeds.
It runs no package code.

The lock starts with `# asm-lock-v1` and a `# registry ORIGIN` line. Its remaining rows use the eight native-index fields. One row identifies each direct dependency. A lock uses one registry origin. Local test indexes use the origin `local`.

The source cache is `.asm/packages/<owner>/<name>/<version>/<target>`. The original archive is `.asm/cache/<sha256>.tar.gz`. Builds verify locked archive hashes and compare every extracted file with its archive content. Changed, missing, or unexpected members cause an error.

Normal builds verify dependencies when a lock exists. `--locked` also rejects a missing lock. `asm lock` checks the existing lock and cache; it does not resolve newer versions.

`asm sync` restores exact locked artifacts through their recorded URLs. It does not query a newer index. It retains local cache edits and reports a mismatch instead of discarding them.

`asm update owner/name@version` selects an explicit replacement version. `asm remove owner/name` removes its lock entry and retains cache files. Failed updates preserve the prior lock. Advisory file locks coordinate Asm processes in the same project.

The assembler receives `.asm/packages` as an include directory. For the math example, use:

```asm
.include "stubbi/math/0.2.0/x86_64-linux/src/min.s"
```

Lock checks cover declared dependencies. Assembly source can also select other local files through includes or data directives. This is not a hermetic build sandbox. Source caches should remain unchanged; copy a package elsewhere before editing it.

V1 has no transitive resolver, version ranges, feature selection, or automatic symbol imports.

## Immutability and yanking

Once a release appears in the published history, all its fields except `yanked` and `yank_reason` are immutable. Adding another target or changing a summary also needs a new version. Removing an existing record is rejected. Identical retries are allowed.

Pass `--base-ref FULL_COMMIT` to compare against the registry history in Git, or `--baseline DIRECTORY` to compare with another registry directory. Validation without a baseline cannot detect a rewrite of previously published history.

Yanking keeps the JSON record and artifact identity but removes its rows from the native index. The current client cannot make a new fetch or add selection for a yanked version, even by exact version. Previously downloaded bytes remain on the user's machine. There is no implemented revocation service. Existing locks retain exact artifact URLs and digests; sync does not read the current index.

The distinction between immutable content and a reversible yank is useful in [Cargo's publication model](https://doc.rust-lang.org/cargo/reference/publishing.html) and [PyPI's yank policy](https://docs.pypi.org/project-management/yanking/). Their client behavior differs. The preceding paragraph defines Asm v1 behavior.

Later schemas need retained namespace ownership, owner-change audit records, emergency revocation, and tombstones for takedowns. A withdrawn version must never be reused for different bytes.

## Verification

Run the local contract tests with:

```sh
python3 -m unittest discover -s tests/registry -p 'test_*.py' -v
```

The tests cover publication, index generation, committed-source packaging, immutable history, numeric versions, and artifact digests. They also cover target mismatch, archive attacks, ELF bounds, and unavailable download counts. Native CLI and release tests cover the connected client and distribution routes. A passing schema test does not stand in for a real artifact download and build.
