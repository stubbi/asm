# Operator image implementation plan

Goal: package explicit registry operations for short, isolated AMD64 Linux Jobs.
The CLI and HTTP application remain assembly.
Use the reviewed four-export schema without changing its SQL or trust policy.

The operator image owns no cluster identity or embedded database credential.
It runs as UID/GID 65532 with a read-only root filesystem.
Projected input uses fsGroup 65532 and a separate writable private volume.
The governing principles are dependable reuse, human control, and evidence with clear limits.

## Interfaces and files

- `tools/operator_source.py` creates a bounded, complete HEAD bundle from a clean checkout.
  It verifies source identity and reconstructs one bare accepted ref without runtime fetching.
- `tools/prepare_operator.py` snapshots fixed projected URL and TLS files into a new private directory.
  Optional explicit DNS resolution uses a bounded child without credentials.
  The existing operator's strict ownership, TLS, and numeric-address policy remains unchanged.
  Private staging and atomic no-replace publication keep partial snapshots and unrelated destinations separate.
- `tools/operator_entrypoint.py` exposes the approved command-first interface with fixed source, schema, and psql paths.
- `containers/operator.Dockerfile` uses the reviewed pinned Debian and PostgreSQL source strategy.
  Its final stage contains Python, Git, psql, libpq, notices, source objects, and resolved package metadata.
  Its derived qualification stage alone contains PostgreSQL server tools and synthetic fixtures.
- `tools/test_operator_image.py` checks the actual final image and derived qualification image.
  It records loaded-library digests, package versions, source identity, resource limits, and complete applicable test results.
- `.github/workflows/operator-images.yml` qualifies native AMD64 with read authority.
  Only a main push can publish the exact qualified artifact and provenance.
- `tests/operator_image/` retains source, preparation, and image-contract regressions.
- `docs/operator-images.md` states commands, evidence, assumptions, and remaining limits.

## Acceptance sequence

1. Observe source-integrity tests fail before implementing bundle creation and restoration.
2. Implement complete bounded bundles with no unrelated refs or ambient Git configuration.
3. Observe preparation tests fail before implementing fixed projected-volume snapshots.
4. Test destination preservation, ownership, permissions, GID, symlink, rotation, short-write, and DNS failures.
5. Build a separate final image with no compiler or PostgreSQL server.
6. Bind complete source, schema, dependencies, and qualification to the exact final image.
7. Run actual offline plan commands and the complete applicable SQL suite in isolated native CI.
8. Retain failed evidence and require zero skipped applicable tests.
9. Review the diff, commit the component, and hand the exact source to the root agent for CI.

## Limits

The resolved Debian packages can change between repository updates.
Qualified immutable image bytes and recorded dependency versions establish the accepted artifact.
This does not promise byte-for-byte reproducibility across repository updates.
Snapshots serve short operator Jobs; they do not implement serving-certificate rotation.
Other architectures, live credentials, Kubernetes deployment, capacity, and recovery remain outside this qualification.
PostgreSQL 16.15 fixture checks do not qualify the private PostgreSQL 18.6 server.
