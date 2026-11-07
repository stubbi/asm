# Retained registry snapshot

This directory retains release records for the static compatibility feeds and the hosted catalog's bootstrap imports.
The Pages build still reads these records during migration.
Published versions, licenses, source commits, and artifact digests remain part of the retained history.

This directory is not a package-submission queue.
The former pull-request publication instructions are retired.
The [hosted registry contract](../docs/hosted-registry.md#publication-boundary) records the intended publication boundary and its remaining gates.

The existing [operator procedure](../server/catalog/README.md#operator-procedure) imports accepted Git snapshots into PostgreSQL.
It does not authenticate package publishers or provide a public upload endpoint.
Public package publication remains unavailable until its service and security gates pass.

## Prepare artifacts locally

Packaging and record preparation remain available without a hosted service.
Neither operation uploads files, reserves a namespace, or publishes a package.
Published 0.6.0 `asm publish` help describes the former pull-request route.
That text does not establish a supported public submission path.

The `stubbi` namespace remains reserved for the project owner's packages.
A repository URL or display name does not establish namespace ownership.

### Prepare the source

Your package needs `asm.toml`, its declared assembly source, a README, and a license file. The README must state the architecture, ABI, assembler dialect, build commands, and test method. Use an exact numeric version such as `0.1.0`.

Use the license that applies to your package.
Asm's platform license does not set the license of packages in the registry.
The example below declares `MIT` for its example source.
The registry also accepts `AGPL-3.0-or-later` and other identifiers in the documented policy.
See [Asm's licensing guide](../README.md#license) for its separate core, template, and example scopes.

Commit the source. Record its full commit ID with `git rev-parse HEAD`. Use that ID with `pack-git`; it reads the committed files and excludes dirty working files.

The following commands show the form. Replace the uppercase values with your package details. Run them from the Asm repository. `SOURCE_REPOSITORY` is the path to your local source checkout. `FULL_COMMIT_ID` must identify a commit in that checkout.

```sh
python3 tools/registry.py pack-git SOURCE_REPOSITORY \
  --commit FULL_COMMIT_ID \
  --source-path . \
  --name owner/hello \
  --version 0.1.0 \
  --target x86_64-linux \
  --output dist/hello-0.1.0-x86_64-linux-source.tar.gz
```

Use repeated `--include PATH` options if the repository contains files that do not belong in the package. Paths are relative to `--source-path`. Include the manifest, README, license, and all files needed by the build.

A program record can also describe an ELF or Mach-O executable.
Build it from the same commit.
Use the qualified Mac host for a Mach-O executable.
Keep the toolchain versions and test results with the release.
Each release can have one source artifact and one executable artifact for each supported target.

### Prepare the record

The v1 record requires HTTPS GitHub release asset URLs.
Local preparation does not check whether those URLs exist.
The deployment verifier checks referenced artifact bytes before a compatibility build becomes public.
Published artifact bytes must never change.

Create the record from the local artifact bytes:

```sh
mkdir -p dist
asm publish \
  --name owner/hello \
  --version 0.1.0 \
  --summary 'A small Linux assembly example.' \
  --license MIT \
  --repository https://github.com/owner/hello \
  --commit FULL_COMMIT_ID \
  --source-path . \
  --artifact x86_64-linux source \
    dist/hello-0.1.0-x86_64-linux-source.tar.gz \
    https://github.com/owner/hello/releases/download/v0.1.0/hello-0.1.0-x86_64-linux-source.tar.gz \
  --output dist/hello-0.1.0.json
```

Repeat `--artifact TARGET KIND FILE URL` for other artifacts in the same release. The native command calculates size and SHA-256 from a private copy. It checks source contents or the executable's ELF or Mach-O structure before it writes the record. It makes no network request and publishes nothing.

Source packages must match the declared name, version, and target. Their manifest uses the native CLI's small TOML subset. Up to six target/kind artifacts can share one record. The output must be a new file, and its parent directory must exist.

CI and other automation can use `python3 tools/registry.py prepare` with the same publication arguments. Both routes produce the same registry schema.

## Operator imports

The current operator reads `registry/packages/` from an exact accepted commit in the Asm repository.
It requires a separate database identity, a reviewed import plan, and the expected catalog revision.
All exports advance atomically with the imported revision.
An accepted commit identifies input bytes; it does not prove that review occurred.

Namespace bindings remain explicit operator assertions.
The importer does not verify publisher identity or download artifact bytes.
Its migration, grants, namespace binding, and import commands belong to the [operator procedure](../server/catalog/README.md#operator-procedure).
Deployment and public publishing remain subject to the [hosted service gates](../docs/hosted-registry.md).

## Check retained records

Maintainers must retain namespace, source, license, target, artifact, and immutable-history checks.
To compare the snapshot with a known base commit:

```sh
python3 tools/registry.py validate \
  --registry registry \
  --base-ref FULL_BASE_COMMIT_ID
```

Metadata-only validation reports that artifact bytes were not checked. To validate local artifacts too, use `--artifacts-dir DIRECTORY`. The directory must hold every referenced asset under its release filename. The deployment tool can fetch the public artifacts and validate them before it builds the site.

The validator rejects replacement or removal of an existing version.
Code, target, or immutable metadata changes require a new version.
The v1 snapshot format supports `yanked` and `yank_reason` while retaining the version record.
The hosted importer cannot change an existing yank state.
Hosted lifecycle changes require a separate operation, which remains unimplemented.

## Rebuild the index

For a local metadata preview:

```sh
python3 tools/registry.py build --registry registry --output build/registry-preview/v1
```

For checked local artifacts, add `--artifacts-dir DIRECTORY`. Only that route marks artifact evidence as `validated`. Use the deployment verifier for public artifact downloads. Formal verification, provenance verification, and agent review remain `not-run` until those checks have been implemented and run for the exact bytes.

Read the [registry specification](../docs/specs/registry.md) for the complete schema and limits, and the [security model](../docs/specs/security.md) for the trust boundaries.
