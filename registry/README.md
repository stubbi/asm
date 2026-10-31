# Publish a package

The registry accepts open-source assembly packages through reviewed pull requests. The current transport uses GitHub release assets. Publication is separate from local packaging.

Use a namespace that you control. A maintainer reviews each new namespace claim. The `stubbi` namespace is reserved for the project owner's packages; a source URL alone does not grant permission to publish under it.

## Prepare the source

Your package needs `asm.toml`, its declared assembly source, a README, and a license file. The README must state the architecture, ABI, assembler dialect, build commands, and test method. Use an exact numeric version such as `0.1.0`.

Commit the source. Record its full commit ID with `git rev-parse HEAD`. Use that ID with `pack-git`; it reads the committed files and excludes dirty working files.

The following commands show the form. Replace the uppercase values with your package details. Run them from the ASM repository. `SOURCE_REPOSITORY` is the path to your local source checkout. `FULL_COMMIT_ID` must identify a commit in that checkout.

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

For a program, you can also publish an ELF executable. Build it from the same commit. Keep the toolchain versions and test results with the release. Each release can have one source artifact and one executable artifact for each supported target.

## Prepare the record

Upload your exact artifact files to a public GitHub release. Check that the release is public and that the URLs work. Do not replace the bytes at a published URL.

Create the record from the local artifact bytes:

```sh
mkdir -p registry/packages/owner/hello
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
  --output registry/packages/owner/hello/0.1.0.json
```

Repeat `--artifact TARGET KIND FILE URL` for other artifacts in the same release. The native command calculates size and SHA-256 from a private copy. It checks source contents or ELF structure before it writes the record. It makes no network request and publishes nothing.

Source packages must match the declared name, version, and target. Their manifest uses the native CLI's small TOML subset. Up to six target/kind artifacts can share one record. The output must be a new file, and its parent directory must exist.

CI and other automation can use `python3 tools/registry.py prepare` with the same publication arguments. Both routes produce the same registry schema.

## Submit and review

Open a pull request with the record. Include the source commit, license, test commands and results, and evidence that you control the namespace. State whether each result used native hardware or emulation. Do not commit generated indexes or artifact binaries in a package-submission pull request.

Maintainers must check namespace ownership, source availability, license declarations, target requirements, and artifact bytes. They must compare the proposed registry with its published history. To validate against a known base commit:

```sh
python3 tools/registry.py validate \
  --registry registry \
  --base-ref FULL_BASE_COMMIT_ID
```

Metadata-only validation reports that artifact bytes were not checked. To validate local artifacts too, use `--artifacts-dir DIRECTORY`. The directory must hold every referenced asset under its release filename. The deployment tool can fetch the public artifacts and validate them before it builds the site.

The validator rejects replacement or removal of an existing version. To change code, add a target, or correct immutable metadata, publish a new version. To withdraw a release from the native index, set `yanked` to `true` and add a plain-text `yank_reason`. The release record remains in the website's version history.

## Rebuild the index

For a local metadata preview:

```sh
python3 tools/registry.py build --registry registry --output registry/v1
```

For checked local artifacts, add `--artifacts-dir DIRECTORY`. Only that route marks artifact evidence as `validated`. Use the deployment verifier for public artifact downloads. Formal verification, provenance verification, and agent review remain `not-run` until those checks have been implemented and run for the exact bytes.

Read the [registry specification](../docs/specs/registry.md) for the complete schema and limits, and the [security model](../docs/specs/security.md) for the trust boundaries.
