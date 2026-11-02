# Public provenance fixtures

The release manifest and bundle were downloaded from asm 0.4.0 on 2 November 2026:

- https://github.com/stubbi/asm/releases/download/v0.4.0/release.json
- https://github.com/stubbi/asm/releases/download/v0.4.0/release-attestation.sigstore.json

`sigstore-trusted-root.json` contains public Sigstore verification material fetched through sigstore-go's authenticated TUF client on the same date.
The offline tests use it to check the published bundle and reject altered bytes, signatures, and source commits.
It is test data, not asm's update root or a runtime trust override.
No fixture contains a private signing key.
