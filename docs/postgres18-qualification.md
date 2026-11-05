# Selected PostgreSQL 18 compatibility

Status: unexecuted qualification candidate, 5 November 2026.

This gate checks canonical catalog compatibility with the database image selected by the private deployment manifest.
The user outcome is inspectable SQL, TLS, role, operator, and HTTP evidence for that exact image.
The governing principles are dependable reuse, evidence tied to exact bytes, and bounded resource use.

No PostgreSQL 18 compatibility result exists yet.
Local contract tests do not establish database or container behavior.
The current PostgreSQL 16.15 qualification remains separate.

| Binding | Required value |
| --- | --- |
| Image | `ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie` |
| Selected index | `sha256:39add80f5b1e573e2f6b641c66fd1a2f8dede67ca0330e870285bc1078551390` |
| Linux AMD64 child | `sha256:9d1808e9b9c82fb1175ecc7aba615e88b16013e8f118c536a8b5a9aca017ec03` |
| Image config | `sha256:e81943bf2a7f93b868b0ce332642e9005ab3bc02d23f7effb505e5a19b7daa42` |
| Actual server version | `180006` |
| Application client version | libpq `160015`, PostgreSQL 16.15 |

Public registry metadata supplied these bindings on 5 November 2026.
The gate checks the local image config, selected index, actual server version, and fresh database identity.
The [pinned upstream source](https://github.com/cloudnative-pg/postgres-containers/blob/4c2710a78328becdadf708ca6d9cb3fb61f3f5ee/Dockerfile) identifies the PostgreSQL operand image.

## Isolation and scope

The database runs as UID/GID 26.
Applications run as UID/GID 65532.
Each container has a read-only root filesystem, no Linux capabilities, and bounded memory, CPU, processes, and temporary storage.
The database has no network interface beyond its isolated loopback interface.
Its application qualifier shares that owned network namespace.
No host port, persistent volume, Docker socket, production target, or production credential is accepted.

Host Docker commands require the root-owned `/usr/bin/docker` executable and `/var/run/docker.sock` Unix socket.
The gate rejects ambient Docker and builder selection variables before it creates Docker resources.
Each command uses a new private configuration directory and an explicit local endpoint.
Saved Docker contexts cannot select another daemon.
Workflow inspection, builds, pulls, and cleanup use this same boundary.

A fresh synthetic certificate authority binds each prepared run.
A fixed declaration binds its nonce, source commit, server version, and certificate digests.
The test provider checks the actual server identity before fixture SQL runs.
It reuses the existing certificate and database assertion helpers.
The PostgreSQL 16.15 fixture version checks remain unchanged.

Qualification images add only test files to existing images.
The database target compiles and installs nothing.
The gate compares base filesystem layers and hashes database executables, PL/pgSQL, and linked libraries.
It also checks application runtime layers and loaded file hashes against both qualification stages.
These checks bind the tested programs; they do not claim general reproducible builds.

| Suite | Required coverage |
| --- | --- |
| Catalog and operator | All 16 catalog cases, six offline operator cases, and the actual image command interface |
| Canonical assembly HTTP | All 16 canonical runtime cases, including exact export bytes, failures, TLS, deadlines, and shutdown |
| Platform exclusion | Only the existing macOS extended ACL case is inapplicable on Linux |

Each suite uses a new owned PostgreSQL cluster.
The gate requires different database system identifiers.
The gate retains failed checks and cleanup errors.
It bounds standard output to 4 MiB and standard error to 1 MiB while reading each child process.
On overflow or timeout, it kills the child process group.
It then reaps the direct child.
It retains the bounded output buffers from a failed command.
SIGTERM follows the failure, cleanup, and evidence path.
A failed database log request makes the gate fail.
It removes only resources with the expected image, name, nonce, identity, and isolation settings.
Private preparation directories are trusted local parents; their identity checks do not establish a general filesystem isolation boundary.

## Run the candidate

The new `Selected PostgreSQL 18 compatibility` workflow is an unregistered candidate.
GitHub requires its registration on the default branch before `workflow_dispatch` can select it.
Its job has repository read permission and no publication step.
It builds the fixed application tags and three compatibility targets.
It does not run on pull requests or pushes.

The first diagnostic requires a separately reviewed temporary replacement of the registered `assembly-server.yml` workflow.
Copy the candidate's exact workflow bytes into that path on the diagnostic branch.
Keep publication absent from the temporary workflow.
Select one native run after review.
The candidate does not require a pull request solely to register a temporary diagnostic.

For local fixture contract checks, use Python 3 and OpenSSL.
OpenSSL creates temporary test certificates.

```sh
make postgres18-contract-test
```

Successful output reports all contract tests as passing.
This command does not use Docker or connect to a database.

The native gate requires Linux AMD64 and Docker.
The reviewed workflow prepares the required local tags.
Its final check uses a new evidence directory:

```sh
make hosted-postgres18-test SOURCE_REVISION=COMMIT_ID EVIDENCE_DIRECTORY=NEW_DIRECTORY
```

Replace both uppercase placeholders.
Successful evidence contains `"status": "pass"`, both suite results, exact image identities, versions, migration digest, and cleanup results.
Failure evidence retains the first reported failure and available logs.
An existing evidence directory is preserved.

## Remaining limits

This gate does not connect to the private cluster or qualify CloudNativePG reconciliation.
Forced process or host termination can prevent cleanup and evidence retention.
It does not test two-instance synchronous replication, failover, persistent volumes, backup, restore, capacity, or public deployment.
It does not qualify ARM64 or RISC-V database images.
The ordinary PostgreSQL 16.15 operator and server image gates remain required independently.
Older `psql` compatibility is limited to the command paths exercised here.
[PostgreSQL documents limits when an older client connects to a newer server](https://www.postgresql.org/docs/16/app-psql.html#APP-PSQL-NOTES).
