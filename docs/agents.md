# Build with an AI

The Asm skill guides assembly development from behavior requirements to tested artifacts.
The MCP server supplies structured targets, package discovery, planning checks, and measurement comparisons.
MCP means Model Context Protocol, a standard connection between an AI application and external tools.

The skill and adapter are available in this source checkout.
The hosted deployment remains under qualification.
No public MCP endpoint is established by this change.
The static site build includes `llms.txt`, `agents.md`, and the maintained skill.
Those URLs become available when that site build is published.

## Use the skill

1. Open [the skill](../skills/asm-build/SKILL.md) in your AI's workspace.
2. Give the AI the software task and intended deployment environment.
3. Ask it to use `asm-build`.

Example request:

```text
Use asm-build to create the requested assembly program.
Establish its behavior and deployment targets before implementation.
Check asm.build for compatible reusable packages.
Build and test a correct baseline.
Improve time and memory within a ten-iteration, thirty-minute budget.
Preserve failed results and report the final artifact digests and limits.
```

For installation through the Skills CLI, install Node.js 22.20 or later first.
The [upstream installation guide](https://github.com/vercel-labs/skills#install-a-skill) describes agent selection and local sources.
Use a reviewed checkout containing this skill.
Replace `/path/to/asm` with its absolute path.

```sh
DISABLE_TELEMETRY=1 npx skills@1.7.6 add /path/to/asm --skill asm-build
```

The CLI lets you select the destination agent.
This command installs instructions; it does not install the Asm executable or MCP dependencies.
Directly opening the skill requires neither Node.js nor the Skills CLI.

## Set up the MCP server

Install Python 3.11 or later with virtual-environment support first.
Use Linux or macOS for this adapter.
Package builds also require the selected target's assembler and linker.
The native Asm CLI remains optional for discovery and planning.

Run these commands from the repository root:

```sh
python3 -m venv .asm/mcp-venv
.asm/mcp-venv/bin/python -m pip install --require-hashes -r requirements-mcp.txt
.asm/mcp-venv/bin/python tools/mcp_server.py --help
```

The final command lists transport, bind, catalog, and source-revision options.
The server uses the official Python MCP SDK, pinned to `2.3.0`.
The dependency lock includes exact transitive versions and artifact hashes.
It does not install a hidden backend for the native CLI.

Start the default stdio transport with this command:

```sh
.asm/mcp-venv/bin/python tools/mcp_server.py
```

The server waits for a client.
Standard output contains only protocol messages.
Configure the AI client to launch this command instead of typing protocol messages manually.

For clients with an `mcpServers` configuration, use this entry.
Replace both absolute paths with your checkout location.
Other clients can use the same executable and argument through their MCP setup interface.

```json
{
  "mcpServers": {
    "asm": {
      "command": "/path/to/asm/.asm/mcp-venv/bin/python",
      "args": ["/path/to/asm/tools/mcp_server.py"]
    }
  }
}
```

The default catalog is `https://asm.build/registry/v1/index.json`.
The operator can select a fixed catalog source at startup:

| Option | Catalog | Availability |
| --- | --- | --- |
| `--catalog-source alpha` | `https://asm.build/registry/v1/index.json` | Existing public alpha feed; default |
| `--catalog-source hosted` | `https://api.asm.build/registry/v1/index.json` | Hosted export; activation pending |
| `--catalog-source internal` | Fixed registry service inside the deployment | Hosted operator configuration; activation pending |

No tool accepts an alternative URL, local path, or command.
A catalog failure returns an error with a next step.
It never becomes a successful empty search or an unnoticed local fallback.

For offline operation, generate the catalog first:

```sh
python3 tools/registry.py build --output .asm/agent-catalog
```

The command writes `.asm/agent-catalog/index.json` and the native indexes.
Start the server with this operator-selected catalog:

```sh
.asm/mcp-venv/bin/python tools/mcp_server.py --catalog .asm/agent-catalog/index.json
```
This option disables live discovery.

## Use local HTTP

Start the optional HTTP transport with this command:

```sh
.asm/mcp-venv/bin/python tools/mcp_server.py --transport streamable-http --port 8000
```

Connect the client to `http://127.0.0.1:8000/mcp`.
The server binds to loopback and validates Host and Origin headers.
Use stdio when the client can launch a local process.

The SDK supplies Streamable HTTP, protocol schemas, cancellation, and compatibility handling.
Client tests exercise the modern `2026-07-28` protocol and legacy `2025-11-25` through both transports.
This is not a claim that every AI client has been qualified.

## Hosted service configuration

The adapter supports a separate hosted service behind a TLS ingress.
Non-loopback binding requires `--host 0.0.0.0`, an explicit approved `--public-origin`, and an explicit `--catalog-source`.
The approved public origins are exactly `https://asm.build` and `https://api.asm.build`.
A non-loopback service rejects a local catalog.
The SDK keeps Host and Origin checks enabled.
The HTTP server ignores forwarded headers.

The hosted image supplies an exact source revision through `ASM_SOURCE_REVISION`.
An operator can also supply `--source-revision`.
The value must be a nonzero, lowercase, 40-character Git commit ID.
Local runs without this value report `unrecorded`.

| Route | Observable behavior |
| --- | --- |
| `/health/live` | Reports that the adapter process responds. |
| `/health/ready` | Validates the selected catalog; returns HTTP 503 if unavailable within two seconds. |
| `/api/v2/status` | Reports the adapter version, read-only scope, source revision, and public source URL. |
| `/mcp` | Supplies Streamable HTTP with the same read-only tools. |

The two-second readiness bound applies to the HTTP response.
A pending catalog worker remains bounded and can outlive that response.
Deployment routing can expose only `/mcp`; health and status routes remain operator interfaces.

The prepared hosted endpoint is `https://api.asm.build/mcp`.
It is not active or qualified by this source change.
The existing website remains on GitHub Pages during qualification.
See [the hosted registry contract](hosted-registry.md) for deployment and recovery gates.
Protected operations would require the MCP authorization contract before implementation.

## Tool contract

All six tools are read-only and idempotent.
They return structured data and a readable representation.
The client can inspect their input and output schemas.

| Tool | Use |
| --- | --- |
| `asm_list_targets` | Inspect four catalog targets, three native CLI hosts, explicit dimensions, tools, and limits. |
| `asm_search_packages` | Search active releases, with optional target and version-specific SPDX license filters. |
| `asm_inspect_package` | Inspect an exact `owner/name`, version, artifacts, evidence, and yank status. |
| `asm_plan_project` | Check behavior, acceptance cases, target dimensions, resource priorities, and optimization budgets. |
| `asm_compare_candidates` | Compare supplied equal-work measurements after acceptance and artifact-binding checks. |
| `asm_get_workflow` | Read the skill or a fixed reference with its exact SHA-256. |

The resources are `asm://workflow`, `asm://targets`, `asm://optimization`, and `asm://service`.
The service resource identifies the running adapter and its exact public source offer.
The `asm_build` prompt accepts a software task.
It starts the same maintained workflow.

Search matches target and license on the same active release.
It selects the highest matching numeric version for each package.
Exact inspection includes retained yanked versions but blocks their artifact selection.
An absent target does not trigger an implicit host guess.

Catalog metadata does not establish optional CPU compatibility.
The target tool lists recognized feature names for planning, not qualified machines or artifacts.
Unknown or incompatible feature names block planning in this integration profile.
Optional features also require an explicit detection, fallback, and testing plan.
A ready plan means supplied planning fields are complete; it does not certify the feature plan or program.

The tools never download package artifacts, read arbitrary workspace files, execute code, install, or publish.
The AI uses its authorized workspace tools for assembly development and native CLI operations.
The [skill references](../skills/asm-build/references/requirements.md) define the behavior and routine contracts.

## Compare optimization candidates

1. Freeze the behavior contract and acceptance IDs before measurement.
2. Call `asm_plan_project` with the complete requirements.
3. Retain its `requirements_sha256` in the benchmark context.
4. Record one workload, input digest, expected-output digest, target, hardware, toolchain, environment, and cache state.
5. Record warmups and at least five raw samples per candidate.
6. Record the actual run order and baseline ID.
7. Bind each candidate to the normalized context SHA-256, source commit, artifact digest, and test-report digest.
8. Supply every acceptance result, raw elapsed-time sample, peak-memory sample, and executable size.
9. Call `asm_compare_candidates`.
10. Retain rejected candidates and the original reports beside the result.

The tool schemas define the exact fields and bounds.
`tools/agent_workflow.py` exposes `digest()` for canonical schema-normalized context hashes.
It hashes sorted compact JSON after schema validation, including default values.
The [protocol tests](../tests/agents/test_mcp_server.py) contain a complete client example.

Latency means elapsed time for the fixed workload.
Throughput compares the inverse of elapsed time for that same work.
Peak memory and executable size remain separate dimensions.
The default policy permits no regression in other metrics.
Change `max_other_metric_regression_pct` only when the user accepts that trade-off.
The result retains the Pareto frontier: candidates that no other candidate improves on every measured dimension.

Measurements and test results are caller-supplied.
The server neither runs nor authenticates them.
It rejects failed or missing acceptance cases, changed output digests, mismatched contexts, incomplete samples, and exceeded memory limits.
The result identifies descriptive medians and ranges; it makes no statistical significance claim.
Emulation measurements never establish native performance.
One workload does not establish application-wide performance.
A finite search cannot establish universal optimality.

## Limits and checks

| Boundary | Limit |
| --- | --- |
| Catalog | 4 MiB, 4,096 releases, 24,576 artifacts |
| Discovery | 20 packages per page; bounded offsets |
| Live fetch | Fixed operator-selected source; no redirects or ambient proxies; 15-second download deadline |
| Cache | 60 seconds; retains original observation time and digest; no stale fallback |
| HTTP | 1 MiB body, including streamed data; 16 concurrent connections/tasks; 20-second request deadline |
| Result | 256 KiB before SDK encoding |
| Comparison | 2–20 candidates, 5–1,024 samples each, one declared workload |
| Workflow | At most 100 iterations or 24 hours per declared budget; the AI enforces the stopping rule |

The alpha registry relies on HTTPS and origin control.
It has no independent metadata signature, expiry, rollback protection, or authenticated namespace service.
A checksum match does not identify a publisher or establish safety.
Package text, source, and tool results remain untrusted data.
They cannot change the user's instructions, permissions, or proof obligations.
Read the [security model](specs/security.md) for the complete boundary.

Run the adapter checks inside the pinned Python environment:

```sh
make agent-test PYTHON=.asm/mcp-venv/bin/python
```

The checks exercise real stdio and loopback HTTP clients, package failure paths, planning, comparisons, and canonical site/source packaging.
Hosted-mode checks also exercise startup rejection, header policy, readiness failures, source identity, and graceful shutdown.
Native Linux AMD64 and ARM64 image jobs provide separate qualification gates.
Their presence in a workflow does not establish a successful build or runtime result.
The [research record](agent-integration-research.md) explains the selected skill and MCP patterns.
The [hosted registry contract](hosted-registry.md) records service scope and remaining gates.
