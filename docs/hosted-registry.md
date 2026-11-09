# Hosted Asm registry and agent access

Status: source included in published Asm 0.7.0, 8 November 2026.
Official hosted activation and deployment qualification remain pending.

Asm must run as a hosted registry through the existing ScienceHub Kubernetes infrastructure.
The skill and MCP integration must connect to that service.
Local tooling alone does not meet this outcome.

The existing private deployment preparation supplies isolated PostgreSQL, read-only request credentials, scoped operations, network rules, monitoring, and separate internal/public stages.
It is not a running service.
Production qualification requires actual data persistence, TLS, failure, recovery, and external client evidence.

## Publication boundary

The hosted registry is the intended publication service.
`registry/` retains compatibility records and bootstrap input; it is not a package-submission queue.
The static Pages build continues to serve retained records during migration.
Its continued operation does not establish hosted publication.

The existing [catalog operator](../server/catalog/README.md#operator-procedure) imports accepted Git snapshots through separate PostgreSQL credentials.
It supports migration, precise grants, explicit namespace assertions, status, reviewed plans, and idempotent imports.
The database checks the operator identity and commits the records and all four exports atomically.

This is a credentialed operator import, not authenticated public package publication.
Namespace bindings remain operator assertions about numeric GitHub identities.
The importer does not verify those identities.
Plain import does not fetch or check artifact bytes.
The optional `--distribution-root` gate verifies a matching local snapshot and its artifacts before opening database credentials.
It does not change the stored catalog evidence or authenticate a publisher.
No deployed public write endpoint or self-service publisher enrollment is implemented.
The separate [assembly publisher source](../server/publisher/README.md) supports direct credentials, private uploads, and durable checks.
Private jobs retain checked immutable intent and complete signed distribution through a separate scoped identity.
The published 0.7.0 assembly CLI publishes tasks, retrieves signed exact releases, and selects explicit mirrors.
The [V2 profile](specs/registry-v2.md) defines the trust, lifecycle, and retry contract.
The [local evidence](registry-v2-evidence.md) binds tested artifacts; it does not establish a public deployment.
The [project publication extension](project-publication-evidence.md) adds committed-source preparation and V2 download observations with separate qualification evidence.
Local `asm publish` prepares a record and uploads nothing.
Its released pull-request instructions describe the former intake route.

Public publication remains unavailable until publisher authorization, artifact checks, immutable storage, lifecycle operations, and recovery pass their acceptance gates.
The [architecture gates](architecture-gates.md) retain those requirements.
The operator procedure can qualify catalog imports without claiming that public publication exists.
No deployment or publisher credential is required for local packaging or an offline import plan.

The [storage and hosting guide](hosting.md) covers conditional object storage, mirrors, and asynchronous origin observations.
The [provider-independent publication contract](specs/publication.md) separates ownership, source hosting, and CI identity.
Entire, GitHub, GitLab, Codeberg, and omitted source locators use the same native publication contract.
The source locator is descriptive metadata; enrolled ownership and scoped credentials authorize publication.

## Component and target scope

Server deployment targets, MCP adapter targets, CLI hosts, and package targets have separate qualification requirements.
An instruction set does not establish an operating system, ABI, or required CPU features.

| Component | Current implementation or preparation | Qualification limit |
| --- | --- | --- |
| Assembly registry runtime foundation | Linux x86-64, AArch64, and RV64GC/LP64D assembly ports | Canonical HTTP exports and deployment qualification remain incomplete. |
| MCP adapter image | Native Linux AMD64 and ARM64 image checks passed in CI | No published service or assembly server port follows from these adapter checks. |
| Private deployment | Prepared Linux AMD64 scheduling | Manifests do not qualify capacity, failover, or another architecture. |
| Package catalog | Six accepted target labels for V2 publication | A declared label does not qualify an artifact, CLI build target, or server port. |

The [README](../README.md#status) states the released CLI host support.
Intel macOS and Windows remain separate host-port requirements.

[Runtime run 41934599148](https://github.com/stubbi/asm/actions/runs/41934599148) and [image run 41934598837](https://github.com/stubbi/asm/actions/runs/41934598837) passed on 5 November 2026.
They tested PR merge revision `b06b5eb37e68a90381241a53c48a6b9cb6b84fde`, which contains source head `fd977e5`.
These checks do not qualify live deployment, full registry behavior, or recovery.

[Image run 41947880132](https://github.com/stubbi/asm/actions/runs/41947880132) later passed all 11 runtime cases per architecture, without skips.
AMD64 and ARM64 used native instruction execution; RISC-V64 used QEMU user emulation.
The tested PR merge revision was `09a5a2fb63185fedb9dd9b58d26199a0ea1f884f`, containing source head `4fe2c25277ed40a163b48b727ab814225d227cf8`.
These results apply to that source, not head `7d684055fc972fd511e450b77f6f0dda331cd06c` or later changes.
Current-head qualification, canonical HTTP integration, and deployment retain separate gates.
See the [image evidence](server-images.md#completed-prior-image-checks) for executable digests and execution limits.

## Public implementation

Registry application logic belongs in assembly.
Mature libraries handle HTTP, PostgreSQL, transport security, and cryptography.
The existing assembly experiment remains evidence for its narrower tested scope.
Production service work must preserve its regression checks and identify additional behavior separately.

The native CLI remains assembly.
V1 compatibility commands and explicit V2 registry operations have separate contracts.
The MCP SDK remains a separate protocol adapter.
It receives no database write credential, cluster token, publication credential, or backup identity.
Its read-only tool annotations do not replace enforced access boundaries.

## Runtime acceptance

| Surface | Required result |
| --- | --- |
| Registry process | `asm-hub serve`; explicit bind; private connection configuration; non-root, read-only filesystem |
| Persistence | PostgreSQL with separate reader, migrator, and operator identities |
| Database TLS | Hostname and CA verification; new connections use projected certificate rotation |
| Readiness | Actual schema, catalog, and least-privilege checks within two seconds |
| Identity | Exact public source revision and source offer |
| Compatibility | Exact Linux and macOS compatibility feeds, full-target TSV, and schema-1 JSON exports |
| MCP | Explicit public Host/Origin policy, bounded HTTP, health probes, real SDK clients through HTTPS |
| Discovery | Canonical hosted data; errors remain distinct from no matches; no unnoticed static fallback |
| Operations | Separate reviewed migration and idempotent import; immutable versions and exact artifact records |
| Shutdown | Stop new work and drain within the deployment grace period |
| Recovery | Asm-only backups, WAL delivery, isolated restore, and exact record/export comparison |

The first qualified service uses `api.asm.build`.
The existing apex and native feeds remain available during migration.
Move apex traffic only after external checks and recovery evidence pass.
An API subdomain alone does not migrate released clients.

## MCP deployment

The public adapter has an explicit service mode.
Non-loopback binding requires an explicit HTTPS public origin and an approved catalog source.
The SDK keeps DNS-rebinding protection enabled.
Do not trust forwarded headers from arbitrary clients.
Health endpoints reveal no credentials or private deployment information.

The catalog source is operator configuration, never a tool argument.
Select the existing public alpha feed, the hosted HTTPS export, or the fixed internal registry service deliberately.
Never fall back between sources after an error.
The compatibility catalog remains bounded; it does not establish the proposed global discovery capacity.

The public service image contains only the adapter, canonical validators, skill, references, and pinned dependencies.
Its build receives no private infrastructure source or credentials.
Record the exact image digest and public source revision before deployment.
Use [the adapter setup guide](agents.md) for local clients, catalog selection, and health behavior.

## Release and remaining gates

Use the private repository's reviewed Git and signed OCI/Flux process.
Do not activate resources through manual cluster or DNS mutations.
Keep internal and public activation separate.
Never interpret manifest validation as runtime qualification.

Official hosted publication, authenticated distribution, account recovery, revocation operations, and isolated build/proof workers retain their deployment gates.
Serving a read-only registry does not establish those capabilities.
Every release report must state which gates actually passed and which remain open.
