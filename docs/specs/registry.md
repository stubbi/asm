# Registry v1

ASM v1 serves a static registry over HTTPS. Maintainers review publication records in GitHub pull requests. GitHub Releases holds the artifacts. The native CLI and website read indexes made from the same records.

The current implementation supports package discovery, version lists, exact artifact selection, download, and size and SHA-256 checks. It does not implement dependency graphs, lockfiles, authenticated index metadata, or unattended publishing. See the [roadmap](../roadmap.md) for those gates.

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

## Release record

The canonical path is `registry/packages/<owner>/<name>/<version>.json`.

| Field | Meaning |
| --- | --- |
| `schema` | Integer `1` |
| `name`, `version` | Exact registry identity |
| `summary` | 1 to 160 printable ASCII characters, with no outer whitespace |
| `license` | One supported SPDX license identifier |
| `source.repository` | Canonical `https://github.com/<owner>/<repo>` URL, without `.git` |
| `source.commit` | Full 40-character lowercase Git commit ID; an all-zero ID is rejected |
| `source.path` | Relative source directory within that commit, or `.` |
| `artifacts` | 1 to 6 artifact records, with one entry per target and kind |
| `yanked` | Boolean; a yanked record also needs a `yank_reason` |

An artifact has exactly these fields:

| Field | Meaning |
| --- | --- |
| `target` | `x86_64-linux`, `aarch64-linux`, or `riscv64-linux` |
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

A valid commit string alone does not prove that the source exists. `pack-git` reads a real local Git commit and packages its recorded files. Publication review must also establish that the stated public repository contains that commit.

## Targets

The registry can describe three Linux targets. The current CLI host and native build target are x86-64 Linux. It can fetch artifacts for the other targets. Their examples use GNU cross assemblers and linkers; their README files give the commands.

Target names do not yet encode every ISA extension, ABI revision, dialect, or linker option. A package must state these requirements in its documentation. An ELF header check verifies the architecture and basic segment bounds. It does not prove that the program will work on every machine with that architecture.

The AArch64 and RISC-V examples have been assembled, linked, and run under QEMU user-mode emulation. That result is distinct from a test on physical hardware. Native CLI ports, general cross-build support, library ABI selection, and dependency resolution remain separate work.

## Static layout

```text
registry/
  packages/<owner>/<name>/<version>.json
  v1/index.tsv
  v1/index.json
  v1/downloads.json
```

The default CLI endpoint is `https://asm.build/registry/v1/index.tsv`. The website uses `index.json` and `downloads.json` in the same directory. Both indexes are generated; do not edit them by hand.

GitHub Pages serves the index and website. It does not accept uploads or run checks. The publication route uses repository review and CI. Artifact storage is separate from Pages. Capacity planning must follow [GitHub Pages' limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits).

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

### Website index

`index.json` has `schema: 1` and a `packages` array. Each package contains `name`, `summary`, `license`, `repository`, `latest`, `targets`, and `versions`. `latest` is the highest non-yanked numeric version, or `null`.

Each version contains `version`, `source`, `yanked`, `artifacts`, and `evidence`. A yanked version includes its reason. The artifact and source fields use the release-record shapes above. The website keeps all versions visible, including yanked versions.

Current evidence has `metadata`, `artifacts`, `provenance`, `formal`, and `agent_review` keys. Metadata is `validated` after schema checks. Artifacts are `validated` only after the tool checks the actual bytes, including archive or ELF structure. Without that step, artifacts are `not-run`. The other three fields are `not-run` until their separate verification services exist. None of these fields is a safety rating.

### Download counts

`downloads.json` has `schema: 1`, `source: "github-release-assets"`, an `observed_at` UTC timestamp, and a `packages` object. A package has a `total` and a `versions` map. Values are non-negative integers or `null`.

The collector matches the exact GitHub release URL and asset size. It also checks the digest when the GitHub response supplies one. A missing asset, failed request, or inconsistent response produces `null`. A measured zero remains zero. A total is available only when all its component counts are available.

These are GitHub asset downloads. They include repeated requests, automation, and both source and executable assets. They do not measure unique users or installed packages. Search order and download counts never affect artifact resolution.

## Package and publish

Use `tools/registry.py` with Python 3.11 or later. It uses the standard library.

1. Commit the source that you intend to publish. Include its manifest, source, README, and license.
2. Use `pack-git` with the full commit ID and source path. It reads Git objects and does not include dirty working files.
3. Build any executable artifact from that same committed source. Record the toolchain and test result.
4. Upload the exact artifacts to a public GitHub release. Keep the existing bytes when you retry a release.
5. Use `prepare` to compute sizes and SHA-256 digests, check each artifact, and write the publication record.
6. Submit that record as a pull request. Include the source commit, test instructions, namespace claim, and any relevant check reports.
7. Maintainers review the claim and validate against the published history. A trusted deployment job checks accepted bytes again and generates both indexes.

`pack` can make a local archive for inspection. It does not provide commit binding. `prepare` writes a local file; it does not upload, reserve a name, or publish a package. Concrete commands are in the [registry contributor guide](../../registry/README.md).

Archives use deterministic USTAR and gzip: sorted paths, normalized modes, zero timestamps and ownership, and no links or special files. The inspector reads the archive without extracting or executing it. It rejects traversal, duplicate or case-colliding paths, file/directory conflicts, invalid tar checksums, hidden trailing content, sensitive file names, and resource-limit violations.

The limits are 4096 members, 240 characters per path, 16 MiB per file, and 64 MiB for both compressed and expanded archive data. An accepted archive is a structural check, not proof of benign code. See the [security model](security.md).

## Consume a package

The native commands are:

```sh
asm search hello
asm info stubbi/hello
asm versions stubbi/hello
asm fetch stubbi/hello@0.1.0 --target x86_64-linux --kind source --output hello.tar.gz
```

Without `@version`, fetch chooses the highest published numeric version that has the requested target and kind. The defaults are `x86_64-linux` and `source`. Use exact versions in reproducible instructions.

Fetch checks byte size and SHA-256 before it exposes the output. It does not overwrite an existing destination, set an execute bit, extract, install, or run package contents. A download failure or hash mismatch is an error. Source review, extraction, and building are separate user actions. The digest is checked against the HTTPS index; v1 does not authenticate that index with a separate signing key or protect against a compromised registry origin.

`--index PATH` uses a local index. `--registry HTTPS_URL` selects another index URL. `--artifact PATH` lets fetch check a local artifact for offline tests. The same metadata and digest rules apply.

## Immutability and yanking

Once a release appears in the published history, all its fields except `yanked` and `yank_reason` are immutable. Adding another target or changing a summary also needs a new version. Removing an existing record is rejected. Identical retries are allowed.

Pass `--base-ref FULL_COMMIT` to compare against the registry history in Git, or `--baseline DIRECTORY` to compare with another registry directory. Validation without a baseline cannot detect a rewrite of previously published history.

Yanking keeps the JSON record and artifact identity but removes its rows from the native index. The current client therefore cannot make a new fetch selection for a yanked version, even by exact version. Previously downloaded bytes remain on the user's machine. There is no implemented revocation service or lockfile exception in v1.

The distinction between immutable content and a reversible yank is useful in [Cargo's publication model](https://doc.rust-lang.org/cargo/reference/publishing.html) and [PyPI's yank policy](https://docs.pypi.org/project-management/yanking/). Their client behavior differs. The preceding paragraph defines ASM v1 behavior.

Later schemas need retained namespace ownership, owner-change audit records, emergency revocation, and tombstones for takedowns. A withdrawn version must never be reused for different bytes.

## Verification

Run the local contract tests with:

```sh
python3 -m unittest discover -s tests/registry -p 'test_*.py' -v
```

The tests cover publication and index generation, committed-source packaging, immutable history, numeric versions, artifact digests, target mismatch, archive attacks, ELF bounds, and unavailable download counts. Native CLI and release tests cover the connected client and distribution routes. A passing schema test does not stand in for a real artifact download and build.
