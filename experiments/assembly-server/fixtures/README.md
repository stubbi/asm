# Local test schema

`0001_registry.sql` is a byte-identical copy of the reviewed registry migration.
Its source checkpoint is `286a75c9d806aaed3e91bd54785db2ac60f5310a` from the unpublished Asm behavioral reference.
The copied SQL is included here so this experiment does not require that checkout or its Rust executable.
The repository's AGPL-3.0-or-later license applies to this original Asm material.

The migration's SHA-384 is:

```text
e9fce69caa758cb9d15a700d92b76aba0fc3ca466a81624733124a742f2211aadae612ab877bd908a6e1d6ab5e803ef2
```

The fixture verifies this digest against the server's readiness guard before creating a cluster.
It applies the schema and its migration record in one transaction.
The migration record uses the SQLx-compatible table layout retained by the readiness guard.
SQLx is not a dependency of this experiment.

The fixture then inserts 23 fixed package records through parameterized SQL.
Separate migrator, operator, and reader roles preserve the tested privilege boundary.
Each release, artifact, publication seal, and audit record is inserted in one `READ COMMITTED` transaction.
`p00.json` retains the reference's declared field order and escaping for a representative record.
Its canonical bytes exclude the final newline.
The suite compares their digest with the retained row and checks the acceptance audit fields.

This helper creates test data.
It does not implement publication authorization, record validation, or artifact verification for a live service.
Its success does not establish those contracts.
