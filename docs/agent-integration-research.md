# Agent integration research

Research date: 4 November 2026.
Status: source observations and implementation decisions, not a security certification.

## Outcome and evidence

An assembly author needs a useful workflow from requirements to tested software.
A package consumer needs exact identities, compatible targets, and inspectable evidence.
The [brand foundation](brand/foundation.md) requires dependable reuse, resource care, human control, and evidence with explicit limits.
The [messaging guide](brand/messaging.md) prohibits universal performance and safety claims.

This research informs the [agent workflow](agents.md) and [hosted registry contract](hosted-registry.md).
It does not establish a deployed remote service or measured improvements in assembly development.
No external server or skill was installed during this research.

## Popular MCP implementations

MCP means Model Context Protocol.
It connects an AI application to external tools and context.
GitHub stars measure repository interest.
They do not measure correctness, successful tasks, or security.

The following counts came from GitHub's API on 4 November 2026, between 22:33:22 and 22:33:24 UTC.
Each link identifies the exact API source.

| Implementation | Stars | Relevant role |
| --- | ---: | --- |
| [Context7](https://api.github.com/repos/upstash/context7) | 64,200 | Documentation discovery and retrieval |
| [Playwright MCP](https://api.github.com/repos/microsoft/playwright-mcp) | 39,180 | Browser observations and actions |
| [GitHub MCP](https://api.github.com/repos/github/github-mcp-server) | 34,230 | Repository tools and access configuration |
| [Official reference servers](https://api.github.com/repos/modelcontextprotocol/servers) | 91,796 | Educational examples and protocol demonstrations |
| [Official TypeScript SDK](https://api.github.com/repos/modelcontextprotocol/typescript-sdk) | 13,707 | Protocol implementation |
| [Official Go SDK](https://api.github.com/repos/modelcontextprotocol/go-sdk) | 5,308 | Protocol implementation |

These are a selected comparison set, not an exhaustive ranking of every server.
The official reference collection explicitly requires deployment-specific security work.
Its examples are not a substitute for a service threat model.
See its [scope and warning](https://github.com/modelcontextprotocol/servers#readme).

Two ranking services were also inspected on 4 November 2026:

| Source | Observed result | Meaning and limit |
| --- | --- | --- |
| [mcp.so](https://mcp.so/rankings/servers) | Playwright 84, GitHub 80, Context7 79 | Its score mixes search demand, stars, and its quality checks. |
| [CheckMCP](https://www.checkmcp.dev/best/best-mcp-servers-overall) | Context7 repository 100/A; Playwright repository 100/A; hosted Context7 87/B | Repository and endpoint scores use different criteria. |

The opened mcp.so page placed those servers first, second, and fourth.
Its search-result cache showed a different ordering among tied entries.
Neither source supplied a common user-review rating for all implementations.
CheckMCP describes repository scoring through maintenance, licensing, adoption, and documentation.
Its live-endpoint scoring covers different properties, including security and tool schemas.
These scores cannot establish a universal safest server.

## Patterns selected for Asm

The following decisions are Asm-specific conclusions from the inspected examples.
They are not capabilities provided by those servers to Asm.

| Source | Observed pattern | Asm decision |
| --- | --- | --- |
| [Context7 tools](https://github.com/upstash/context7#available-tools) | Resolve an identifier before retrieving focused documentation. | Separate search from exact package inspection. |
| [GitHub tool configuration](https://github.com/github/github-mcp-server#tool-configuration) | Explicit tool selection and enforced read-only configuration. | Expose six narrow read-only tools. |
| [GitHub lockdown mode](https://github.com/github/github-mcp-server#lockdown-mode) | Content filtering has stated authorization limits. | Treat package text as untrusted data, including text from popular packages. |
| [Playwright MCP](https://github.com/microsoft/playwright-mcp#readme) | Structured observations support subsequent actions. | Return bounded structured package and evidence records. |
| [Playwright security](https://github.com/microsoft/playwright-mcp#security) | The adapter is not a security boundary. | Preserve Asm's existing trust checks and execution boundary. |

Playwright's maintainers also describe CLI and skill workflows as an option for coding agents.
This supports keeping Asm's workflow in a skill while the agent uses its existing workspace tools.
No token-cost improvement was measured for Asm.

The selected tools cover targets, package search, exact inspection, requirements, candidate comparisons, and workflow retrieval.
They do not build, execute, install, publish, or change ownership.
The native assembly CLI retains package operations.
The Python adapter reuses canonical registry validation rather than implementing another package format.

## Protocol and SDK baseline

On 4 November 2026, the official [latest specification](https://modelcontextprotocol.io/specification/latest) resolved to **2026-07-28**.
That revision uses self-contained requests and per-request capabilities.
Earlier revisions used connection initialization and protocol sessions.
The [compatibility specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning) defines the transition.

The standard transports remain [stdio and Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports).
Stdio carries newline-delimited messages through a child process.
Standard output must contain protocol messages only.
See the [stdio contract](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio).

The current [HTTP contract](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http) removes protocol sessions and the earlier GET stream endpoint.
It requires Origin validation and recommends loopback binding for local servers.
Asynchronous notifications and cancellation differ across protocol eras.
Compatibility must follow the SDK and client tests, not remembered lifecycle behavior.

The implementation selects the [official Python SDK](https://github.com/modelcontextprotocol/python-sdk), **mcp==2.3.0**.
Existing registry tooling already uses Python.
This choice avoids another language and a handwritten protocol implementation.
It does not move native CLI behavior into Python.

The [PyPI release](https://pypi.org/project/mcp/2.3.0/) was inspected on 4 November 2026.
Its [JSON metadata](https://pypi.org/pypi/mcp/2.3.0/json) requires Python 3.10 or later and records these artifacts:

| Artifact | Upload time, UTC | SHA-256 |
| --- | --- | --- |
| `mcp-2.3.0-py3-none-any.whl` | 2026-10-02 22:06:52.119073 | `dd0c44c089d16453e8ae31a3877a0054d7a2314caaa81f5e0541b9b1734b2377` |
| `mcp-2.3.0.tar.gz` | 2026-10-02 22:06:56.091381 | `8b147a50441cf059dc88c684e0aeed3687f0aa0f39c6cde7b90330effd2b34d8` |

These digests identify the observed SDK artifacts.
They do not establish an Asm release result or replace dependency review.

Other observed options were TypeScript server 2.4.0 and Go SDK v1.8.0.
Their sources are [npm metadata](https://registry.npmjs.org/@modelcontextprotocol/server/latest) and the [Go release record](https://github.com/modelcontextprotocol/go-sdk/releases/tag/v1.8.0).
They remain alternatives, not dependencies selected for this implementation.

## Skills research

The [skills.sh directory](https://www.skills.sh/) was inspected on 4 November 2026.
Its [documentation](https://www.skills.sh/docs) says the leaderboard uses aggregated installation telemetry from its CLI.
An installation count is not a unique-user count, task-success result, or security rating.
The directory also states that it cannot guarantee each listed skill's quality or security.
Asm does not adopt installation telemetry for this integration.

The directory displayed the following rounded counts:

| Skill | Displayed installs | Research use |
| --- | ---: | --- |
| [find-skills](https://www.skills.sh/vercel-labs/skills/find-skills) | 4.2M | Narrow triggers and discovery before selection |
| [grill-me](https://www.skills.sh/mattpocock/skills/grill-me) | 1.5M | Requirement questions and investigation of available facts |
| [tdd](https://www.skills.sh/mattpocock/skills/tdd) | 1.2M | Observable behavior and incremental implementation |
| [frontend-design](https://www.skills.sh/anthropics/skills/frontend-design) | 1.1M | An example of focused domain guidance; not an assembly implementation guide |

Popularity selected examples for inspection.
It did not establish that every instruction should be adopted.

The actual [find-skills source](https://github.com/vercel-labs/skills/blob/main/skills/find-skills/SKILL.md) separates discovery from installation.
Asm adopts clear activation conditions and a concrete next action.
Asm package selection still requires target, identity, licensing, and evidence checks.
Popularity does not authorize execution or installation.

The [grilling source](https://github.com/mattpocock/skills/blob/main/skills/productivity/grilling/SKILL.md) distinguishes environmental facts from user decisions.
Asm adopts investigation before questions and explicit behavioral requirements.
It does not adopt exhaustive interviewing or an extra approval gate for already authorized work.

The [tdd source](https://github.com/mattpocock/skills/blob/main/skills/engineering/tdd/SKILL.md) emphasizes public behavior and small implementation steps.
Asm adopts externally observable acceptance cases and rejects tests that repeat the implementation.
Its existing test requirements govern the checks.

The official [skill-creator source](https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md) describes evaluation through realistic prompts and repeated improvement.
Asm adopts a separate forward-test of the maintained skill.
Static formatting checks alone cannot demonstrate useful agent behavior.

The [Agent Skills specification](https://agentskills.io/specification), inspected on the same date, defines the portable format.
It requires `SKILL.md`, a matching lowercase name, and a description explaining activation.
It recommends a short main workflow with focused references loaded when needed.
Its experimental `allowed-tools` field is not a portable security boundary.

The selected Asm skill therefore uses explicit triggers, one maintained workflow, and references for targets, requirements, packages, and optimization.
It declares prerequisites before commands and preserves differences between cross assembly, emulation, native execution, and untested targets.

## Security and validation consequences

The original local integration selected stdio by default and optional loopback HTTP.
The hosted preparation added explicit bind, public-origin, catalog-source, health, and source-revision configuration on 5 November 2026.
These changes retain the separate protocol adapter and its read-only scope.
They do not establish a running public MCP endpoint.
The static site publishes guidance and skill files; a separate service must run the adapter.

The [MCP tool specification](https://modelcontextprotocol.io/specification/2026-07-28/server/tools) requires input validation, access controls, rate limits, and output sanitization.
It also defines structured results and output schemas.
Tool annotations do not enforce authorization.

Asm-specific acceptance checks cover bounded catalogs, duplicate fields, invalid schemas, hostile redirects, and network errors.
Search must match target and license on the same active release.
Exact inspection must not depend on search ranking.
Unknown CPU requirements must remain unknown.
Catalog observation time and digest must remain attached to results.

HTTP checks must cover Origin, Host, body limits, concurrency, and streamed requests.
Stdio checks must cover framing, standard-output purity, EOF, and invalid requests.
The [MCP Inspector](https://modelcontextprotocol.io/docs/2026-07-28/tools/inspector) supplies independent manual and scriptable client interfaces.
SDK client tests must record the protocol versions actually exercised.

The [authorization specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization) applies to protected HTTP services.
Public activation requires separate deployment qualification.
Protected operations require a separate authorization decision and implementation.
The [security guidance](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices) prohibits token passthrough and describes resource-specific authorization risks.
The prepared read-only adapter does not establish authenticated publication or protected-operation controls.

Candidate comparisons use supplied measurements.
They cannot certify that a benchmark ran or that an output is correct.
Claims must remain conditional on the declared workload, acceptance results, target, hardware, toolchain, and measurement method.
Finite measurements cannot establish universal optimality.

The [security model](specs/security.md) remains authoritative for Asm trust boundaries.
A checksum match does not authenticate a publisher.
Tests, provenance, proofs, and agent review establish different things.
Absent and failed evidence must remain visible.

## Remaining limits

The ranking observations are snapshots and can change.
External source branches can change after the recorded date.
No comparative benchmark or security audit of these external implementations was performed.
No public MCP deployment, automatic build service, or universal optimization result is claimed.
Implementation results belong in the task's validation record, separate from this research.
