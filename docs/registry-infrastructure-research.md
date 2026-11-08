# Registry infrastructure research

**Research date: 7 November 2026. Status: recommendation, not deployment evidence.**

This research supports dependable publication and simple hosting with a small operating burden.
It applies the brand principles of resource care, dependable reuse, and claims supported by evidence.
The [architecture](architecture.md), [acceptance gates](architecture-gates.md), and [security specification](specs/security.md) remain authoritative project contracts.

## Recommendation

Use PostgreSQL for publication authority, ownership, audit events, and durable background jobs.
Use S3-compatible storage for retained artifacts and generated distribution metadata.
Serve artifacts through a content delivery network (CDN).
A CDN caches responses near consumers.
Keep artifact delivery independent of the application and database.

Begin with PostgreSQL search and a bounded database job queue.
Add another service only when measured requirements justify its operating cost.
Reuse existing cluster ingress, certificates, database operators, monitoring, and backup mechanisms where their isolation and capacity meet Asm's requirements.
Existing infrastructure still has capacity, maintenance, and recovery costs.

Cloudflare R2 Standard is a candidate for public distribution because Internet transfer has no separate charge.
Backblaze B2 is a candidate for independent backups or workloads with more retained bytes than transfers.
Neither recommendation establishes provider qualification or an account's entitlements.

The current architecture proposes assembly application logic with mature protocol libraries.
The user confirmed that application logic must remain in assembly.
Using another language for the application would change that decision.
Registry operations, tests, and deployment tools have a separate implementation boundary.

### Source hosting and publisher identity

GitHub is not a requirement for the new publication protocol.
Entire supports native Git repositories as well as GitHub mirrors.
The first Asm credential path works independently of either source host or a CI service.
It binds an opaque Asm owner to exact packages and permitted operations.
An operator records enrollment and recovery responsibility before granting that authority.
The optional repository URL describes the source; it does not authenticate ownership or prove the declared commit's contents.
Source archives remain mandatory and are checked without fetching the repository.

Depot documents Entire-native CI and includes the full repository identity in OIDC claims.
Its `et` namespace identifies native repositories; `gh` identifies GitHub mirrors.
Buildkite also documents an Entire integration, currently labeled preview.
These are possible later integrations, not required services or implemented Asm issuer policies.
An OIDC integration must qualify the selected CI issuer, claims, audience, expiry, replay protection, and package authorization.
Do not infer those properties from Git compatibility or GitHub Actions workflow syntax.

Sources: [Entire code hosting](https://entire.com/features/code-hosting), inspected 7 November 2026;
[Depot's Entire integration](https://preview.depot.dev/docs/ci/integrations/entire), inspected 7 November 2026;
[Buildkite's Entire integration](https://buildkite.com/docs/pipelines/source-control/entire), inspected 7 November 2026.

The released V1 client and catalog retain their GitHub-specific contract.
The new local API does not silently change those released records or provide native V2 publishing.

### Runtime maintenance

The initial publisher fixture tested OpenSSL 3.0.22; it did not select that branch for production.
OpenSSL's current policy lists 3.0 as unsupported and supports 3.5 LTS through 8 April 2030.
The publisher now defaults to exact OpenSSL 3.5.9 and passed its local HTTP and ABI checks against that source-built release.
Deployment images and their security-update policy still need qualification before activation.
Do not turn an older fixture's passing result into a production dependency recommendation.
Source: [OpenSSL release strategy](https://openssl-library.org/policies/releasestrat/), inspected 7 November 2026.

### Self-hosted object storage

MinIO's community repository was archived on 25 April 2026 and states that it is no longer maintained.
Its community distribution is source-only; historical binaries receive no updates.
Do not select that community edition as a maintained production default.
An existing installation needs its own version, maintenance, isolation, and recovery assessment before Asm reuses it.
Sources: [MinIO repository and distribution policy](https://github.com/minio/minio), inspected 7 November 2026;
[last listed security release](https://github.com/minio/minio/releases/tag/RELEASE.2025-10-15T17-29-55Z), inspected 7 November 2026.

Garage and RustFS are candidates for a separate on-premises evaluation.
Neither project's S3 label establishes Asm's required atomic conditional writes or durability.
Qualify those exact operations and access controls before choosing either service.
Sources: [Garage project](https://github.com/deuxfleurs-org/garage), inspected 7 November 2026;
[official RustFS container guidance](https://docs.rustfs.com/en/installation/container), inspected 7 November 2026.

R2 remains a public-distribution candidate under the stated pricing assumptions.
An independent backup provider remains a separate durability choice.
No provider account or production object store was qualified by this research.

## ScienceHub inventory

These are retained observations from a read-only inspection on 7 November 2026.
The sources were the private ScienceHub repository and its explicitly selected cluster configuration.
The default Kubernetes context pointed to another cluster and was not used.
No cluster resource, deployment stage, credential, or DNS record was changed.
The exact inspection time and complete repository revision were not retained; do not infer a reproducible deployment snapshot.

| Observed component | Version or topology | Reuse decision |
| --- | --- | --- |
| Kubernetes | k3s 1.36.5; five nodes | Reuse after checking scheduling, requests, limits, and node-failure headroom |
| Ingress | Traefik 3.7.5; two replicas | Reuse for reviewed HTTPS routes and admission limits |
| Certificates | cert-manager 1.20.3 | Reuse certificate issuance and rotation mechanisms |
| PostgreSQL operations | CloudNativePG 1.30.1; Barman plugin 0.15.1 | Reuse with separate Asm database, roles, certificates, and backup identity |
| Existing PostgreSQL | 18.6; single instance | Do not equate local 16.15 tests with qualification on this version or high availability |
| Object storage | One MinIO StatefulSet and one 20 GiB volume | Assess maintenance and recovery separately; do not reuse shared application or root credentials |
| Analytics | ClickHouse 26.8.10.6; 20 GiB volume | Available, but unnecessary for the initial bounded observation ledger |
| Monitoring | VictoriaMetrics 1.153, alert evaluation, and Alertmanager | Reuse metrics collection and alerts with separate Asm budgets |
| Secrets | 1Password synchronization | Reuse scoped secret delivery; keep publisher, worker, and backup identities separate |
| Deployment | Flux with signed OCI artifacts | Use the existing reviewed deployment process |
| CDN | None established by inspection | Qualify a separate public delivery service |

The MinIO image was digest-pinned; repository comments declared an older upstream release.
Its actual executable version was not established by the inventory.
The community maintenance warning above applies before selecting it for new Asm data.

Point-in-time memory use was 64% and 79% on the application nodes and 86% on the control plane.
One application node's configured memory limits totaled 191% of allocatable memory.
Mostly idle CPU does not establish spare memory or capacity after a node failure.
These values are a dated utilization snapshot, not a reservation or a load result.

A current PostgreSQL backup had succeeded, but the latest three restore-drill Jobs had failed.
The last retained successful restore drill was dated 30 October 2026.
Require a successful Asm-specific isolated restore comparison before activation; a backup result alone does not establish recovery.

The `asm` and `asm-public` Flux stages were intentionally suspended.
No Asm namespace, runtime, database, or public route was live during inspection.
The repository prepared isolation, migration, import, backups, MCP, network policies, and alerts; image references still required qualification.
Preserve those holds until exact images, resource headroom, external client checks, and recovery meet the deployment gates.

## Lessons from public registries

### crates.io

crates.io uses PostgreSQL for accounts, ownership, releases, download counts, jobs, and full-text search.
It retains large objects in S3.
Sparse package metadata and immutable archives pass through CDNs.
Its earlier application redirect for each download coupled delivery to application availability.
CDN log processing removed that dependency.
Publication validates authority and content before recording a version and queuing subsequent work.

These boundaries support Asm's proposed separation of distribution, publication, and discovery.
They do not establish Asm's performance or require copying crates.io's complete deployment.
Source: [architecture at commit `068499c07c62769785bda7ab2c686c197d23876a`](https://github.com/rust-lang/crates.io/blob/068499c07c62769785bda7ab2c686c197d23876a/docs/ARCHITECTURE.md), 14 October 2026.

### PyPI Warehouse

Warehouse uses PostgreSQL and deploys containers through Kubernetes.
Its documentation describes a system for PyPI, rather than a general self-hosting product.
Its storage implementation supports multiple providers and sends CDN requests directly to storage.
Asm can adopt that delivery boundary without adopting the complete Warehouse stack.

Sources: [Warehouse architecture](https://dev.pypi.org/application/), inspected 7 November 2026;
[storage at commit `0b73348718bb5b1b032ad315b20d92f1d70c99c0`](https://github.com/pypi/warehouse/blob/0b73348718bb5b1b032ad315b20d92f1d70c99c0/warehouse/packaging/services.py), 27 October 2026.

### bandersnatch

Bandersnatch separates synchronization from static serving.
It supports filesystem storage and S3, including custom endpoints.
Its configuration bounds verification concurrency and supports a separate public serving prefix.
This is a useful model for Asm mirrors.

Sources: [bandersnatch 8.2.0 storage documentation](https://bandersnatch.readthedocs.io/en/latest/storage_options.html), inspected 7 November 2026;
[8.2.0 release](https://pypi.org/project/bandersnatch/8.2.0/), 14 October 2026.

## Mirror and registry requirements

| Responsibility | Read-only mirror | Publishing registry |
| --- | --- | --- |
| Retained files | Filesystem or S3-compatible storage | Private staging and retained object storage |
| HTTP delivery | Static server or object endpoint, TLS, ranges, cache headers | The same delivery boundary |
| Synchronization | Bounded synchronization and retained progress | Durable publication jobs and reconciliation |
| Trust | Upstream trusted root and authenticated metadata | Root custody, routine signers, rotation, recovery |
| Freshness | Last successful synchronization and metadata expiry | Publication revisions and authenticated policy updates |
| PostgreSQL | Not required for static delivery | Ownership, versions, audit, idempotency, jobs |
| Authentication | Optional local access control | Required publisher and administrator authorization |
| Recovery | Retained known-good state and a repeatable synchronization | Database, objects, signing state, and restore exercises |
| Statistics | Optional local reporting with stated coverage | Delayed aggregates with source and coverage records |

An S3 bucket cannot supply account ownership, publication authorization, and audit transactions by itself.
A mirror supplies bytes without obtaining publication authority.
An independent private registry needs its own identity and trust configuration.
An air-gapped mirror also needs an explicit metadata refresh policy.
Expired metadata must not become acceptable through an undocumented verification exception.

The proposed trust profile uses The Update Framework (TUF).
TUF verifies signatures, versions, hashes, expiry, and root rotation.
Source: [TUF specification 1.0.37](https://theupdateframework.github.io/specification/latest/), modified 8 October 2026.

## Public list prices

Prices were inspected on 7 November 2026.
Amounts use US dollars and decimal units: 1 TB equals 1,000 GB.
These prices exclude taxes, compute, database operation, backups, and staff time.
Account agreements and provider changes can alter the result.

| Service | Published rate | Important condition |
| --- | --- | --- |
| R2 Standard storage | $0.015/GB-month | First 10 GB-month free monthly |
| R2 Class A operations | $4.50/million | First million free monthly; includes writes and lists |
| R2 Class B operations | $0.36/million | First 10 million free monthly; includes reads |
| R2 Internet transfer | No egress charge | Other Cloudflare products can have separate charges |
| B2 storage | Starts at $6.95/TB-month | First 10 GB free |
| B2 Internet transfer | Free through three times average stored bytes | Additional transfer costs $0.01/GB outside eligible partner delivery |
| Logpush to R2 | $0.03/GB beyond 25 GB/month | Allowance applies per account; dataset entitlement still matters |
| Logpush externally | $0.10/GB beyond 25 GB/month | Workers trace logs have separate pricing |

Sources: [R2 pricing](https://developers.cloudflare.com/r2/pricing/), updated 30 October 2026;
[B2 pricing](https://www.backblaze.com/cloud-storage/pricing), inspected 7 November 2026;
[Logpush pricing](https://developers.cloudflare.com/logs/logpush/pricing/), updated 12 October 2026.

R2 rounds billable operations up to its billing units.
Its Standard free allowance does not apply to Infrequent Access.
Backblaze documents free transfer to Cloudflare under its partner arrangement.
That arrangement does not establish Cloudflare delivery charges or an account's permitted workload.
Source: [private B2 delivery through Cloudflare](https://help.backblaze.com/hc/en-us/articles/360010017893-Delivering-Private-Backblaze-B2-Content-Through-Cloudflare-CDN), updated 26 June 2026.

### Illustrative monthly scenarios

These are arithmetic estimates, not measured service bills.
Storage stays constant for the month.
Each scenario assumes the full published free allowance remains available to Asm.

| Workload | R2 estimate | B2 estimate |
| --- | --- | --- |
| 100 GB retained; operations within R2 allowances | $1.35 storage | About $0.63 storage |
| 1 TB retained; operations within R2 allowances | $14.85 storage | About $6.88 storage |
| 100 GB; 2 million Class A; 20 million Class B | $9.45 storage and operations | Not estimated; operation classes differ |
| 1 TB retained; 20 TB public transfer | $14.85 storage, plus operations | About $176.88 storage and direct transfer |

The B2 transfer example excludes eligible partner routing.
Its free direct transfer allowance is 3 TB for the stated 1 TB storage workload.
The remaining 17 TB costs $170.
Separately, 100 GB of Logpush export to R2 costs $2.25 after its allowance, before storage and operations.
Actual cache misses, object sizes, retries, logs, and backup copies need workload measurements.

## Delivery and statistics caveats

R2 production delivery needs a custom domain.
Its `r2.dev` endpoint is rate-limited and intended for development.
Default cache rules do not cache every file type.
Source: [R2 public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/), inspected 7 November 2026.

Download observations are not user counts or completed installations.
Caches, mirrors, automated requests, and missing records affect their meaning.
PyPI documents these limits and separates download analysis from cached project pages.
Source: [PyPI download analysis](https://packaging.python.org/en/latest/guides/analyzing-pypi-package-downloads/), inspected 7 November 2026.

Logpush now documents self-service availability on Free, Pro, and Business plans.
Dataset availability depends on the account's products.
Failed or disabled export intervals cannot be backfilled through Logpush.
Source: [Logpush availability and delivery limits](https://developers.cloudflare.com/logs/logpush/), updated 30 October 2026.

Recommended statistics records include the source, interval, delay, counting rule, and completeness state.
A batch identifier and digest can prevent duplicate imports when committed with its aggregate changes.
Missing reports must remain unknown.
Personal request fields need a defined purpose, retention period, and clear user choice before collection.

## Provider qualification and unresolved evidence

An S3-compatible API does not establish equivalent storage semantics.
S3 and R2 document conditional writes that can prevent replacement.
R2 explicitly documents atomic evaluation of `If-None-Match: *`.
A timed-out write can remain in flight after a negative read.
Sources: [S3 conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html), inspected 7 November 2026;
[R2 consistency](https://developers.cloudflare.com/r2/reference/consistency/), updated 14 October 2026.

1. Test concurrent conditional creation against the selected provider.
2. Test stale conditional updates and ambiguous write failures.
3. Verify each retained object's length and SHA-256 through the delivery endpoint.
4. Test failed publication without changing the previous valid metadata head.
5. Test metadata freshness, cache behavior, ranges, and corrupt objects.
6. Restore database records, retained objects, and required trust material from independent backups.

An object ETag is not a portable artifact digest.
S3 multipart uploads and some encryption modes produce other ETag forms.
Source: [S3 object API](https://docs.aws.amazon.com/AmazonS3/latest/API/API_Object.html), inspected 7 November 2026.

### Local compatibility result

On 7 November 2026, seven checks passed against an isolated RustFS 1.0.4 single-node fixture.
The fixture used the official Linux AMD64 image with this digest:

```text
rustfs/rustfs@sha256:ed9210d6411d77ffceb70d94b964a3cb7d225983368bc25bebe01e995293dcc2
```

The executable reported source commit `46337942d55f3a8e6a97b147ca98d9ea8115555d`.
The [provider test instructions](../deploy/mirror/README.md#local-s3-compatibility-check) record the scope and reproduction command.
Two concurrent conditional creates produced one success and one HTTP 412 refusal.
Stale conditional updates, invalid credentials, corrupt existing bytes, and an unavailable connection preserved the relevant retained state.
The SDK adapter and raw SDK operations used a dedicated local bucket and synthetic credentials.
The fixture was removed after testing.

This result covers the exercised single-node operations.
It does not qualify distributed consistency, power-loss durability, production permissions, TLS, CDN delivery, or a paid provider account.
Source: [RustFS 1.0.4 release](https://github.com/rustfs/rustfs/releases/tag/1.0.4), inspected 7 November 2026.

This research did not qualify any storage account, CDN configuration, application deployment, or recovery procedure.
It did not measure Asm traffic, operating cost, database capacity, or publication throughput.
The architecture's capacity and recovery gates remain required.
The material trade-off is fewer operating services, with PostgreSQL and object storage carrying explicit durability and recovery responsibilities.
