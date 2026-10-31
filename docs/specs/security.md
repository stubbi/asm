# Security model

This document states the implemented checks and the controls required for later services. Implementation and release gates are tracked in the [roadmap](../roadmap.md).

ASM distributes executable code. A package can be correctly signed, build successfully, pass tests, and still be malicious. The interface must report what was checked, on which bytes, by which tool, and under which assumptions.

## Current implementation

The registry tools validate strict metadata, immutable release history when a baseline is supplied, artifact size and SHA-256, bounded source archives, and ELF architecture and segment bounds. Source packaging can read a pinned Git commit. The native CLI parses the bounded index and verifies fetched bytes. Fetch does not extract, execute, or overwrite a destination.

The current index relies on HTTPS and control of the registry origin. It has no separate signature, expiry, rollback protection, or authenticated namespace service. The client has no dependency lockfile. Provenance verification, advisory scans, isolated third-party builds, Lean/Kraken proof checks, and agent review are not running registry services. Their status must remain `not-run`.

The controls in the following sections are requirements for those later services. Passing the current validator is not evidence that the later controls have run.

## Trust boundaries

Treat package contents, manifests, documentation, proof projects, build output, and agent output as untrusted input. A maintainer account, CI job, registry host, mirror, or dependency can be compromised independently.

| Threat | Required control |
| --- | --- |
| A download differs from the selected release | Verify its size and SHA-256 before use; bind the digest into the lockfile |
| A release is silently replaced | Immutable version records and artifacts; append a new version instead |
| A stale or compromised mirror changes the index | Authenticate registry metadata, check expiry and monotonic versions, and retain trusted client state |
| Someone publishes under another maintainer's name | Explicit namespace ownership and a narrowly authorized publisher identity |
| A package escapes its extraction directory | Validate archive members before extraction; reject links and special files |
| A build or proof runner steals credentials | Disposable isolated workers, no publisher secrets, restricted network, resource limits |
| A dependency targets the wrong machine or calling convention | Resolve architecture, ABI, object format, and required ISA features explicitly |
| An agent follows instructions in a package README | Treat repository text as data; give analysis workers no publishing authority |
| A proof establishes a weaker or unrelated statement | Compare against a separately trusted statement and bind the result to exact inputs |

## Publication and ownership

The initial publication route is a reviewed pull request to the registry repository. Opening a pull request does not establish ownership of a name. A maintainer must verify the first namespace claim and subsequent changes against the recorded owners. A source URL or a display name is not identity verification.

Validation runs must have read-only repository permissions. They must not receive deployment credentials or use `pull_request_target` to execute contributor-controlled code. A trusted publication job must validate accepted inputs again using an approved validator revision; contributor-supplied CI output is not registry evidence.

For unattended publishing, use short-lived OIDC credentials bound to a specific repository, workflow, and allowed release context. Verify issuer, audience, expiry, signature, repository identity, and workflow claims before authorizing a single package release. Changes to publisher identity require an auditable owner action. Retain no reusable publisher token in the source tree or artifacts.

[npm's trusted publishing](https://docs.npmjs.com/trusted-publishers/) and [PyPI's security model](https://docs.pypi.org/trusted-publishers/security-model/) provide useful precedents: short-lived credentials reduce exposure, but the workflow and people allowed to trigger it remain trusted.

## Integrity, provenance, and registry freshness

These are separate checks:

- **Integrity:** the downloaded bytes match a digest already trusted by the client.
- **Provenance:** an expected identity attested to those bytes and their build context.
- **Freshness:** the client has not been served expired or rolled-back registry state.

A checksum served beside an archive is useful against accidental corruption. It does not authenticate an index compromised along with the archive. HTTPS does not remove that distinction.

Use GitHub artifact attestations or a Sigstore bundle for release provenance. Verify the artifact digest, certificate identity, OIDC issuer, expected repository/workflow, and the relevant transparency evidence. Verification against any valid signer is insufficient. [GitHub documents artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations); [Sigstore documents identity-bound blob verification](https://docs.sigstore.dev/quickstart/quickstart-cosign/). A valid attestation establishes origin, not code safety, as [PyPI explicitly explains](https://docs.pypi.org/attestations/security-model/).

Before the client supports unattended registry updates or self-updates, implement an audited TUF client or an equivalently reviewed update protocol. Pin the initial root through the CLI release, separate signing roles, keep root authority offline, and test key rotation and compromise recovery. Follow [TUF's specified client checks](https://theupdateframework.github.io/specification/) for metadata versions, expiry, hashes, signatures, and consistent snapshots. A custom signature over one JSON file is not a substitute for that protocol.

Never silently downgrade verification after an unavailable service, expired metadata, or invalid signature. A future explicit offline mode may use already-verified, locked artifacts; it must show which freshness checks could not be performed.

## Archive and execution policy

The source registry must reject absolute paths, `..` traversal, duplicate normalized paths, backslash/drive-name ambiguity, NUL bytes, symlinks, hard links, devices, FIFOs, and other special entries. Limit file count, path length, individual file size, total expanded size, and archive size. Extraction must remain inside a newly created staging directory and become visible atomically only after validation succeeds.

Installing or adding a dependency must not execute package code or install hooks. Build recipes must describe tools and arguments rather than interpolate package-controlled strings into a shell. Assembly includes and macros can still read files, and assemblers and linkers have their own attack surface. Registry builds therefore require isolation even when a package has no shell script.

Build workers must not share writable caches with unrelated jobs. Cache keys must include source, dependency digests, target, compiler/linker identity, and relevant options. Publishing credentials belong to a separate job that consumes validated results. These choices follow the separation of build workers and signing authority described in the [SLSA threat model](https://slsa.dev/spec/v1.2/threats).

## Findings and evidence

Each check result must identify:

- Package, version, artifact SHA-256, and target.
- Checker and policy versions, configuration digest, and run time.
- Outcome: `pass`, `fail`, `not-run`, `unsupported`, or `error`.
- Covered files or routines, findings, assumptions, and an inspectable report.
- The identity that produced the evidence and how that identity was verified.

`not-run`, `unsupported`, and `error` must never be rendered as passing. Counts of successful checks are not safety scores. A package page may say “archive validated” or “this routine's stated contract was proved”; it must not infer “safe package.”

Use OSV for known-advisory checks where a dependency has a supported ecosystem identity or a known upstream commit. [OSV supports version and commit queries](https://google.github.io/osv.dev/api/). Do not invent an `ASM` ecosystem identifier and assume coverage. An empty response means no matching advisory was returned at that time. Native ASM advisories need their own maintained identifiers and version ranges until an upstream mapping exists.

Yanking removes a version from the v1 native index without changing its recorded bytes. There is no implemented client revocation service. A later emergency-revocation policy must be able to block a known malicious artifact, preserve an audit record, and give a reason and replacement guidance. Any legal or secret-removal exception must leave a tombstone; the old version must never become assignable to different content.

## Lean and Kraken

The proposed Kraken integration is [AeneasVerif/kraken](https://github.com/AeneasVerif/kraken), the assembly-semantics project associated with Lean. This is the researched interpretation of the requested “Kraken,” not an installed dependency or completed integration.

Its current README describes x64 and AArch64 support, with RISC-V planned. It reasons at an abstraction above assembly and linking. Its documented x64 scope covers sequential computation and excludes operating-system and concurrency features, among other limitations. ASM must pin a reviewed commit and publish the exact supported subset instead of promising verification for every instruction or target.

Start with small routines and explicit contracts: arithmetic results, bounds on memory access, preserved registers, and preconditions. A proof about a mathematical model does not automatically cover the assembler, linker, loader, operating system, timing behavior, or final executable. Reproducible builds and provenance help connect inputs and outputs; they do not prove that translation preserves semantics.

A proof record must bind the source/artifact digest, routine, target/ABI, semantics revision, theorem statement, assumptions, Lean/toolchain versions, and imported proof dependencies. The trusted statement must be maintained separately from the submitted proof. Unsupported instructions or an unproved source-to-model correspondence must fail the requested proof claim, not be replaced with axioms.

For the default proof profile, reject `sorryAx`, custom axioms, and native-evaluation shortcuts that add unapproved trust. Audit transitive axioms against a documented allowlist. A successful `lake build` alone is insufficient for adversarial submissions. Follow Lean's [proof-validation guidance](https://lean-lang.org/doc/reference/latest/ValidatingProofs/): isolate proof generation, validate exported proof data, and compare the resulting theorem against the trusted statement using a separate checker. Where supported by the pinned toolchain, use `comparator` with an independent checker. Lean's [axiom reference](https://lean-lang.org/doc/reference/latest/Axioms/) explains why an accepted theorem is still conditional on its axioms.

## LLMs and agents

Agents may propose tests, inspect changes, identify suspicious routines, explain findings, and generate candidate proofs. Their output is advisory until reproduced by a deterministic check or accepted through an accountable review.

Give each analysis job a bounded input set and disposable workspace. Keep registry signing, credentials, releases, and owner changes outside its permissions. Record the model identifier, prompt/policy revision, input digests, tool calls, and report. Redact credentials and private data before any external model request. Repository comments and documentation must not be allowed to change the agent's tools or policy.

No model verdict may override a failed digest, unauthorized publisher, unsupported proof, or failed kernel check. There is no “LLM approved” safety badge. A proven finding may trigger a narrowly defined quarantine rule; uncertain findings go to review with the evidence and the ability to appeal.

## Release gates

Before public unattended installation, demonstrate rejection of tampered archives, malformed metadata, hostile paths, target mismatches, signature substitution, stale metadata, and compromised publisher identities. Before displaying formal-verification results, include negative tests with an incorrect theorem, a changed instruction, a hidden axiom, and a mismatched artifact digest.

Before accepting untrusted build or proof jobs, test isolation independently of the package being evaluated. A static site, a policy document, and a green workflow run do not establish these guarantees by themselves.
