# Security model

This document states the implemented checks and the controls required for later services. Implementation and release gates are tracked in the [roadmap](../roadmap.md).

ASM distributes executable code. A package can be correctly signed, build successfully, pass tests, and still be malicious. The interface must report what was checked, on which bytes, by which tool, and under which assumptions.

## Current implementation

The registry tools validate metadata, artifact size, and SHA-256. They compare immutable history when a baseline is supplied. They also check source archives and target-specific executable containers and segment bounds. Source packaging can read a pinned Git commit.

The native CLI parses the bounded index and verifies fetched bytes. Fetch does not extract, execute, or overwrite a destination. The archive module validates all members before extraction. It also compares cached files with the original archive bytes.

The current index relies on HTTPS and control of the registry origin. It has no separate signature, expiry, rollback protection, or authenticated namespace service. Advisory scans, isolated third-party builds, Lean/Kraken proof checks, and agent review are not running registry services. Their status must remain `not-run`.

ASM's own bootstrap installer and manual self-update command verify release provenance before installing a binary. This fixed release policy does not apply to general package downloads. A package must not inherit ASM's provenance result.

The controls in the following sections are requirements for those later services. Passing the current validator is not evidence that the later controls have run.

Exact dependency locks bind archive digests and selected targets. Native cache checks compare expected source bytes and reject unexpected members. Advisory locks coordinate ASM processes; they do not constrain other processes running as the same user.

Lock checks cover declared dependencies. GNU assembler includes and data directives can select other local files. The local build workflow is not a hermetic sandbox. Registry workers need separate isolation before they build untrusted submissions.

## Trust boundaries

Treat package contents, manifests, documentation, proof projects, build output, and agent output as untrusted input. A maintainer account, CI job, registry host, mirror, or dependency can be compromised independently.

| Threat | Required control |
| --- | --- |
| A download differs from the selected release | Verify its size and SHA-256 before use; bind the digest into the lock file |
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

Validation runs must have read-only repository permissions. They must not receive deployment credentials or use `pull_request_target` to execute contributor-controlled code. A trusted publication job must validate accepted inputs again with an approved validator revision. Contributor-supplied CI output is not registry evidence.

For unattended publishing, use short-lived OIDC credentials bound to a specific repository, workflow, and allowed release context. Verify issuer, audience, expiry, signature, repository identity, and workflow claims before authorizing a single package release. Changes to publisher identity require an auditable owner action. Retain no reusable publisher token in the source tree or artifacts.

[npm's trusted publishing](https://docs.npmjs.com/trusted-publishers/) and [PyPI's security model](https://docs.pypi.org/trusted-publishers/security-model/) provide useful precedents. Short-lived credentials reduce exposure. The workflow and people allowed to trigger it remain trusted.

## Integrity, provenance, and registry freshness

These are separate checks:

- **Integrity:** the downloaded bytes match a digest already trusted by the client.
- **Provenance:** an expected identity attested to those bytes and their build context.
- **Freshness:** the client has not been served expired or rolled-back registry state.

A checksum served beside an archive is useful against accidental corruption. It does not authenticate an index compromised along with the archive. HTTPS does not remove that distinction.

Use GitHub artifact attestations or a Sigstore bundle for release provenance. Verify the artifact digest, certificate identity, OIDC issuer, expected repository/workflow, and the relevant transparency evidence. Verification against any valid signer is insufficient. [GitHub documents artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations); [Sigstore documents identity-bound blob verification](https://docs.sigstore.dev/quickstart/quickstart-cosign/). A valid attestation establishes origin, not code safety, as [PyPI explicitly explains](https://docs.pypi.org/attestations/security-model/).

Before the client supports unattended registry updates or unattended self-updates, implement an audited TUF client or an equivalently reviewed update protocol. Pin the initial root through the CLI release. Separate signing roles. Keep root authority offline. Test key rotation and compromise recovery. Follow [TUF's specified client checks](https://theupdateframework.github.io/specification/) for metadata versions, expiry, hashes, signatures, and consistent snapshots. A custom signature over one JSON file is not a substitute for that protocol.

Never silently downgrade verification after an unavailable service, expired metadata, or invalid signature. A future explicit offline mode may use already-verified, locked artifacts; it must show which freshness checks could not be performed.

## Bootstrap and manual self-update

The bootstrap installer installs the CLI for Linux x86-64, Linux ARM64, or Apple Silicon macOS 15+ when the checked release supplies that executable. It detects the host locally with `uname`. Each target has a separate fixed URL, size, and digest. An unsupported host fails before downloads or file changes. The assembly command `asm self update` manages later manual updates. Both routes require a direct, user-owned `$HOME/.local/bin/asm` installation. They do not request administrator access or replace a command owned by another package manager.

The installer script is obtained from `https://asm.build/install.sh`. HTTPS and control of that origin are the initial script trust boundary. A signature check inside a modified installer cannot make that installer trustworthy.

The quick-start command streams the script to a POSIX shell. The shell must parse the complete function and final entry block before installation starts. An incomplete entry block does not download an artifact or change the installation. The installer never runs the downloaded ASM command.

The quick-start pipeline is for interactive use. Its exit status can be zero if curl fails before it sends any script bytes. Curl still reports the download error. For scripts and CI, use the complete-download route in the installation instructions. That route requires a successful download before execution. The separate inspection route keeps the downloaded file for review before execution.

Both routes use GitHub CLI 2.93.0 or later for Sigstore verification. This minimum includes the upstream [TUF mirror authentication-header fix](https://github.com/cli/cli/security/advisories/GHSA-8xvp-7hj6-mcj9). The verifier receives no GitHub credentials or ambient trust-root configuration. It uses a fresh home, configuration directory, and cache. Bounded standard proxy variables can change routing; they cannot change the required identity or trusted roots.

The policy fixes the repository name and numeric identity. It also fixes the release workflow, main source ref, OIDC issuer, SLSA predicate, and hosted-runner requirement. The source and signer commits must match the selected release. A valid signature from another repository, workflow, or commit is insufficient. The verifier must return exactly one matching repository identity.

Each release contains the action-produced `release-attestation.sigstore.json` bundle. It is a single JSON object with a 1 MiB limit. The release job verifies every payload against this same published bundle without a GitHub account. The bundle supplies signature evidence, not replacement trust roots.

The site offers the bootstrap only for checked CLI releases from 0.2.0 onward. It also downloads the required bundle before publication. A missing or malformed bundle stops the site build. These site checks establish availability and format; the installer performs signature verification. Earlier releases retain the source-build route.

The native updater also downloads and verifies `release.json`, with the same size limit. Its bounded assembly parser rejects malformed JSON and duplicate keys. The signed manifest must match the version, tag, repository, source commit, and selected executable's name, size, and digest. Both the manifest and executable must satisfy the same provenance policy.

Both installation routes check the byte size and SHA-256 digest before exposing the file. The site checks the executable format before it generates the bootstrap script. The native updater also checks the downloaded ELF or Mach-O format and segment bounds. macOS also verifies the code signature and rejects ACL allow entries or ownership-disabled APFS. Bootstrap finalization refuses an existing different destination. Self-update checks the running executable's device and inode before staging and again before replacement. It uses a private stage and an advisory directory lock. It syncs the candidate before the final atomic rename. The candidate is not executed during installation or updating.

The bootstrap accepts an existing file only if its ownership, link count, permissions, size, and digest match the installation contract.
This no-op creates no temporary files and does not download files or run the provenance verifier.
It can succeed when the existing installation directories permit no writes.

The manual command refuses a downgrade. An equal selected version is a no-op; it does not reverify the installed file or establish registry freshness. A stale index can hide a newer release. The protocol has no independently signed expiry, emergency revocation record, or durable metadata-version history. GitHub CLI's root refresh does not supply those missing ASM release guarantees.

This protocol is not an audited TUF client for ASM metadata. It does not enable unattended updates. The repository, release workflow, GitHub identity service, verifier, and trusted roots remain trusted. Same-account processes can ignore advisory locks. Atomic replacement does not promise directory durability after power loss.

Read [the self-update contract](../self-update.md) for exact identities, supported filesystems, permission requirements, and recovery instructions.

## Archive and execution policy

The source registry rejects absolute paths, `..` traversal, duplicate paths, ambiguous separators, and NUL bytes. It also rejects links, devices, FIFOs, and other special entries. Limit file count, path length, individual file size, total expanded size, and archive size. Extraction must remain inside a newly created staging directory and become visible atomically only after validation succeeds.

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

Yanking removes a version from the v1 native index without changing its recorded bytes. There is no implemented client revocation service. A later emergency-revocation policy must block known malicious artifacts. It must preserve an audit record, reason, and replacement guidance. Any legal or secret-removal exception must leave a tombstone; the old version must never become assignable to different content.

## Lean and Kraken

The proposed Kraken integration is [AeneasVerif/kraken](https://github.com/AeneasVerif/kraken), the assembly-semantics project associated with Lean. This is the researched interpretation of the requested “Kraken,” not an installed dependency or completed integration.

Its README, checked on 2026-10-31, describes x64 and AArch64 support. RISC-V is planned. It reasons at an abstraction above assembly and linking. Its documented x64 scope covers sequential computation and excludes operating-system and concurrency features, among other limitations.

ASM must pin a reviewed commit and publish the exact supported subset. Coverage must identify the supported instructions and targets.

Start with small routines and explicit contracts: arithmetic results, bounds on memory access, preserved registers, and preconditions. A proof about a mathematical model has a defined scope. It does not automatically cover toolchains, loaders, operating systems, timing, or final executables. Reproducible builds and provenance help connect inputs and outputs; they do not prove that translation preserves semantics.

A proof record must identify the source digest, routine, target, ABI, theorem, and assumptions. It must also identify semantics, toolchain, and proof-dependency revisions. The trusted statement must be maintained separately from the submitted proof. Unsupported instructions or an unproved source-to-model correspondence must fail the requested proof claim, not be replaced with axioms.

For the default proof profile, reject `sorryAx`, custom axioms, and native-evaluation shortcuts that add unapproved trust. Audit transitive axioms against a documented allowlist. A successful `lake build` alone is insufficient for adversarial submissions. Follow Lean's [proof-validation guidance](https://lean-lang.org/doc/reference/latest/ValidatingProofs/). Isolate proof generation. Validate exported proof data. Compare the resulting theorem against the trusted statement with a separate checker. Where supported by the pinned toolchain, use `comparator` with an independent checker. Lean's [axiom reference](https://lean-lang.org/doc/reference/latest/Axioms/) explains why an accepted theorem is still conditional on its axioms.

## LLMs and agents

Agents may propose tests, inspect changes, identify suspicious routines, explain findings, and generate candidate proofs. Their output is advisory until reproduced by a deterministic check or accepted through an accountable review.

Give each analysis job a bounded input set and disposable workspace. Keep registry signing, credentials, releases, and owner changes outside its permissions. Record the model identifier, prompt/policy revision, input digests, tool calls, and report. Redact credentials and private data before any external model request. Repository comments and documentation must not be allowed to change the agent's tools or policy.

No model verdict may override a failed digest, unauthorized publisher, unsupported proof, or failed kernel check. There is no “LLM approved” safety badge. A proven finding may trigger a defined quarantine rule. Uncertain findings need review, supporting evidence, and an appeal route.

## Release gates

Before public unattended installation, test rejection of tampered archives, malformed metadata, hostile paths, and target mismatches. Also test signature substitution, stale metadata, and compromised publisher identities. Before displaying formal-verification results, test incorrect theorems, changed instructions, hidden axioms, and mismatched artifact digests.

Before accepting untrusted build or proof jobs, test isolation independently of the package being evaluated. A static site, a policy document, and a green workflow run do not establish these guarantees by themselves.
