# Hosted Asm registry and agent access

Status: implementation and qualification work, 5 November 2026.

Asm must run as a hosted registry through the existing ScienceHub Kubernetes infrastructure.
The skill and MCP integration must connect to that service.
Local tooling alone does not meet this outcome.

The existing private deployment preparation supplies isolated PostgreSQL, read-only request credentials, scoped operations, network rules, monitoring, and separate internal/public stages.
It is not a running service.
Production qualification requires actual data persistence, TLS, failure, recovery, and external client evidence.
The [selected PostgreSQL 18 compatibility gate](postgres18-qualification.md#measured-preflight) passed an isolated native AMD64 preflight at its recorded source.
It does not establish private-cluster or deployment qualification.

## Component and target scope

Server deployment targets, MCP adapter targets, CLI hosts, and package targets have separate qualification requirements.
An instruction set does not establish an operating system, ABI, or required CPU features.

| Component | Current implementation or preparation | Qualification limit |
| --- | --- | --- |
| Assembly registry runtime foundation | Linux x86-64, AArch64, and RV64GC/LP64D assembly ports | The recorded PostgreSQL 18.6 preflight covers AMD64 only. Deployment and other PostgreSQL 18 database architectures retain separate gates. |
| Assembly request metrics | Candidate fixed-label counter and histogram implementation on the three Linux ports | Combined-source metrics qualification and observed alert delivery remain pending. |
| MCP adapter image | Native Linux AMD64 and ARM64 image checks passed in CI | No published service or assembly server port follows from these adapter checks. |
| Private deployment | Prepared Linux AMD64 scheduling | Manifests do not qualify capacity, failover, or another architecture. |
| Package catalog | Six accepted target labels; four CLI publication targets | A declared label does not qualify an artifact or server port. |

The [README](../README.md#status) states the released CLI host support.
Intel macOS and Windows remain separate host-port requirements.

The combined source candidate adds metrics to the existing admission and PostgreSQL 18 test paths.
Its HTTP baseline requires 22 cases, including all six metrics cases and the 19 named metrics unit checks.
The separate [resource profile](deployment-envelope.md) requires 22 baseline, twelve admission, and three envelope cases.
These 37 cases remain unqualified for the combined source.
Earlier receipts retain their original source, case counts, image identities, and limits.

[Runtime run 41934599148](https://github.com/stubbi/asm/actions/runs/41934599148) and [image run 41934598837](https://github.com/stubbi/asm/actions/runs/41934598837) passed on 5 November 2026.
They tested PR merge revision `b06b5eb37e68a90381241a53c48a6b9cb6b84fde`, which contains source head `fd977e5`.
These checks do not qualify live deployment, full registry behavior, or recovery.

[Image run 41947880132](https://github.com/stubbi/asm/actions/runs/41947880132) later passed all 11 runtime cases per architecture, without skips.
AMD64 and ARM64 used native instruction execution; RISC-V64 used QEMU user emulation.
The tested PR merge revision was `09a5a2fb63185fedb9dd9b58d26199a0ea1f884f`, containing source head `4fe2c25277ed40a163b48b727ab814225d227cf8`.
These results apply to that source, not head `7d684055fc972fd511e450b77f6f0dda331cd06c` or later changes.
Later sources, other architectures, and deployment retain separate qualification gates.
See the [image evidence](server-images.md#completed-prior-image-checks) for executable digests and execution limits.

## Public implementation

Registry application logic belongs in assembly.
Mature libraries handle HTTP, PostgreSQL, transport security, and cryptography.
The existing assembly experiment remains evidence for its narrower tested scope.
Production service work must preserve its regression checks and identify additional behavior separately.

The native CLI remains assembly and keeps its existing distribution contract.
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
| Internal metrics | Bounded fixed-route request counters and duration histograms; service-capacity `503` counts as `5xx` |
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

The owner temporarily waived the Entire approval gate for this rollout on 5 November 2026.
This waiver is not a reviewer approval or a successful Entire check.
CI, immutable images, least privilege, capacity, TLS, backups, restore, and failure checks remain required.
No global change to review tooling is authorized by this waiver.

Public publication, authenticated metadata, account recovery, revocation, and isolated build/proof workers retain their architecture gates.
Serving a read-only registry does not establish those capabilities.
Every release report must state which gates actually passed and which remain open.
